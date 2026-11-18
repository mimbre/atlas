defmodule AtlasFlow.FakeCode do
  @moduledoc """
  An `AtlasFlow.Code.Client` in memory, for Bases' and Publish's tests. The client is
  `{FakeCode, pid}`.

  It holds repositories (`reference => revision`) and revisions (`path => bytes`, under
  `bin/` executable; or `path => {:symlink, target}`). Its manifest lists the entries in
  descending path order, so Bases' own sort is what the tests see. It records every call with the calling process, and it
  can be set to answer (`:ok`), to fail (`:failing`: Code answers `provider_unavailable`)
  or to block (`:blocked`: a call waits until `release/1`, then answers as `:ok`, or fails
  when the mode is `:failing` by then).

  For Publish (F3) it keeps changes, reviews and updates as Code does, in Code's terms:
  - a change repeats as itself with the same request and is a `conflict` with another; its
    `missing` blobs are the written files' sha256 not put yet; it seals into a revision once
    none is missing;
  - a review's `fingerprint`, and an update's, must be the change's own (`fpr_` of its
    request without `change_id`, entries sorted by path, as Code computes it), or the answer
    is `fingerprint_mismatch`;
  - a review repeats as itself; a draft is at `work/flow-review-<id>`, another review at
    `work/review-<id>` (`locations/1`). Its revision is the sealed change's;
  - an update needs the review's current revision (`revision_mismatch` otherwise) and moves
    the review to a **new** revision, the change's tree committed on the review's head, as
    Code does; it repeats as itself;
  - `review_status` answers what `status/3` set (open, a draft or not, at its revision, CI
    `none` by default).

  `requests/1` gives every call with its input, oldest first.
  """
  @behaviour AtlasFlow.Code.Client
  use Agent

  @chunk 64 * 1024

  def start_link(repositories \\ %{}) do
    Agent.start_link(fn ->
      %{
        repositories: repositories,
        mode: :ok,
        calls: [],
        requests: [],
        snapshots: %{},
        waiting: [],
        changes: %{},
        reviews: %{},
        updates: %{}
      }
    end)
  end

  def client(fake), do: {__MODULE__, fake}

  @doc "Sets `reference` of `repository` to `revision`, holding `files` (`path => bytes`)."
  def put(fake, repository, reference, revision, files) do
    Agent.update(fake, fn s ->
      update_in(s.repositories, fn repositories ->
        Map.update(
          repositories,
          repository,
          %{refs: %{reference => revision}, revisions: %{revision => files}},
          fn r ->
            %{
              refs: Map.put(r.refs, reference, revision),
              revisions: Map.put(r.revisions, revision, files)
            }
          end
        )
      end)
    end)
  end

  def mode(fake, mode) when mode in [:ok, :failing, :blocked],
    do: Agent.update(fake, &%{&1 | mode: mode})

  @doc "Lets every blocked call go on, answering as the mode now says."
  def release(fake) do
    waiting = Agent.get_and_update(fake, &{&1.waiting, %{&1 | waiting: []}})
    for {pid, ref} <- waiting, do: send(pid, {:release, ref})
    :ok
  end

  @doc "The calls so far, oldest first: `{capability, caller pid}`."
  def calls(fake), do: fake |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "The calls so far with their inputs, oldest first: `{capability, input}`."
  def requests(fake), do: fake |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "Where each review is: `review_id => location`."
  def locations(fake),
    do: Agent.get(fake, &Map.new(&1.reviews, fn {id, review} -> {id, review.location} end))

  @doc "Sets what `review_status` answers of review `id` (merged into its report)."
  def status(fake, id, report),
    do: Agent.update(fake, &update_in(&1.reviews[id].report, fn r -> Map.merge(r, report) end))

  @doc "How many calls are blocked right now."
  def blocked(fake), do: Agent.get(fake, &length(&1.waiting))

  @impl true
  def resolve_reference(fake, repository, reference) do
    answer(fake, :resolve_reference, fn s ->
      case s.repositories[repository] do
        %{refs: %{^reference => revision}} -> {:ok, revision}
        _ -> {:error, :unknown_reference}
      end
    end)
  end

  @impl true
  def create_snapshot(fake, [%{repository: repository, revision: revision, path: path}]) do
    answer(fake, :create_snapshot, fn s ->
      case s.repositories[repository] do
        %{revisions: %{^revision => _}} ->
          id = "sha256:" <> sha256(:erlang.term_to_binary({repository, revision, path}))
          {:update, {:ok, id}, put_in(s.snapshots[id], {repository, revision, path})}

        _ ->
          {:error, :unknown_revision}
      end
    end)
  end

  @impl true
  def get_manifest(fake, snapshot_id) do
    answer(fake, :get_manifest, fn s ->
      case files(s, snapshot_id) do
        nil ->
          {:error, :not_found}

        {repository, path, files} ->
          {:ok,
           for {file, content} <- Enum.sort(files, :desc) do
             {kind, mode, bytes, target} =
               case content do
                 {:symlink, target} -> {"symlink", "120000", target, target}
                 bytes -> {"file", file_mode(file), bytes, nil}
               end

             %{
               repository: repository,
               path: path <> "/" <> file,
               kind: kind,
               mode: mode,
               size: byte_size(bytes),
               sha256: sha256(bytes),
               target: target
             }
           end}
      end
    end)
  end

  defp file_mode(file), do: if(String.starts_with?(file, "bin/"), do: "100755", else: "100644")

  @impl true
  def get_blob(fake, snapshot_id, digest) do
    answer(fake, :get_blob, fn s ->
      with {_repository, _path, files} <- files(s, snapshot_id),
           {_file, content} <-
             Enum.find(files, fn {_, content} -> sha256(bytes(content)) == digest end),
           bytes = bytes(content) do
        {:ok, byte_size(bytes), chunks(bytes)}
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  @impl true
  def snapshot_revision(fake, snapshot_id, repository) do
    answer(fake, {:snapshot_revision, snapshot_id, repository}, fn s ->
      case s.snapshots[snapshot_id] do
        {^repository, revision, _path} -> {:ok, revision}
        {_other, _revision, _path} -> {:error, :repository_mismatch}
        nil -> {:error, :not_found}
      end
    end)
  end

  @impl true
  def create_change(fake, request) do
    request = stringify(request)

    answer(fake, {:create_change, request}, fn s ->
      id = request["change_id"]

      case s.changes[id] do
        nil ->
          change = %{
            request: request,
            blobs:
              MapSet.new(for %{"kind" => "symlink", "sha256" => d} <- request["entries"], do: d),
            revision: nil
          }

          {:update, {:ok, change_view(id, change)}, put_in(s.changes[id], change)}

        %{request: ^request} = change ->
          {:ok, change_view(id, change)}

        _other ->
          {:error, :conflict}
      end
    end)
  end

  @impl true
  def put_change_blob(fake, id, digest, content) do
    answer(fake, {:put_change_blob, %{"change_id" => id, "sha256" => digest}}, fn s ->
      cond do
        not Map.has_key?(s.changes, id) ->
          {:error, :not_found}

        sha256(content) != digest or digest not in written(s.changes[id]) ->
          {:error, :invalid_request}

        true ->
          s = update_in(s.changes[id].blobs, &MapSet.put(&1, digest))
          {:update, {:ok, change_view(id, s.changes[id])}, s}
      end
    end)
  end

  @impl true
  def seal_change(fake, id) do
    answer(fake, {:seal_change, %{"change_id" => id}}, fn s ->
      case s.changes[id] do
        nil ->
          {:error, :not_found}

        %{revision: revision} = change when is_binary(revision) ->
          {:ok, change_view(id, change)}

        change ->
          if missing(change) == [] do
            change = %{change | revision: "rev_" <> sha256("sealed:" <> fingerprint(change))}
            {:update, {:ok, change_view(id, change)}, put_in(s.changes[id], change)}
          else
            {:error, :incomplete_upload}
          end
      end
    end)
  end

  @impl true
  def create_review(fake, request) do
    request = stringify(request)

    answer(fake, {:create_review, request}, fn s ->
      id = request["review_id"]
      change = s.changes[request["change_id"]]

      cond do
        match?(%{request: ^request}, s.reviews[id]) ->
          {:ok, review_view(s.reviews[id])}

        Map.has_key?(s.reviews, id) ->
          {:error, :conflict}

        change == nil ->
          {:error, :not_found}

        change.revision == nil ->
          {:error, :change_not_sealed}

        is_binary(request["fingerprint"]) and request["fingerprint"] != fingerprint(change) ->
          {:error, :fingerprint_mismatch}

        true ->
          prefix = if request["draft"] == true, do: "work/flow-review-", else: "work/review-"

          review = %{
            request: request,
            review_id: id,
            change_id: request["change_id"],
            repository: change.request["repository"],
            target: request["target"],
            revision: change.revision,
            location: prefix <> id,
            link: "https://github.example/pull/" <> id,
            report: %{
              state: :open,
              draft: request["draft"] == true,
              at_revision: true,
              ci: :none,
              failing: nil,
              approvals: [],
              changes_requested: [],
              mergeable: nil,
              behind_base: nil
            }
          }

          {:update, {:ok, review_view(review)}, put_in(s.reviews[id], review)}
      end
    end)
  end

  @impl true
  def update_review(fake, request) do
    request = stringify(request)

    answer(fake, {:update_review, request}, fn s ->
      id = request["update_id"]
      review = s.reviews[request["review_id"]]
      change = s.changes[request["change_id"]]

      cond do
        match?(%{request: ^request}, s.updates[id]) ->
          {:ok, s.updates[id].answer}

        Map.has_key?(s.updates, id) ->
          {:error, :conflict}

        review == nil or change == nil ->
          {:error, :not_found}

        review.report.state != :open ->
          {:error, :review_not_open}

        change.revision == nil ->
          {:error, :change_not_sealed}

        request["revision"] != review.revision ->
          {:error, :revision_mismatch}

        request["fingerprint"] != fingerprint(change) ->
          {:error, :fingerprint_mismatch}

        true ->
          # The change's tree committed on the review's head: a new revision.
          revision = "rev_" <> sha256("update:" <> review.revision <> ":" <> change.revision)

          answer = %{
            update_id: id,
            review_id: review.review_id,
            change_id: request["change_id"],
            repository: review.repository,
            previous_revision: review.revision,
            revision: revision,
            state: :open,
            link: review.link
          }

          s = put_in(s.reviews[review.review_id].revision, revision)
          s = put_in(s.reviews[review.review_id].change_id, request["change_id"])
          {:update, {:ok, answer}, put_in(s.updates[id], %{request: request, answer: answer})}
      end
    end)
  end

  @impl true
  def mark_ready(fake, id) do
    answer(fake, {:mark_ready, %{"review_id" => id}}, fn s ->
      case s.reviews[id] do
        nil ->
          {:error, :not_found}

        %{report: %{state: state}} when state != :open ->
          {:error, :review_not_open}

        review ->
          s = put_in(s.reviews[id].report.draft, false)
          {:update, {:ok, %{review_id: id, revision: review.revision, link: review.link}}, s}
      end
    end)
  end

  @impl true
  def review_status(fake, id) do
    answer(fake, {:review_status, %{"review_id" => id}}, fn s ->
      case s.reviews[id] do
        nil ->
          {:error, :not_found}

        review ->
          {:ok,
           Map.merge(review.report, %{review_id: id, revision: review.revision, link: review.link})}
      end
    end)
  end

  defp change_view(id, change) do
    %{
      change_id: id,
      state: if(change.revision, do: :sealed, else: :open),
      missing: missing(change),
      revision: change.revision
    }
  end

  defp review_view(review),
    do:
      Map.take(review, [:review_id, :change_id, :repository, :target, :revision, :link])
      |> Map.put(:state, :open)

  defp written(change),
    do: for(%{"op" => "write", "sha256" => d} <- change.request["entries"], do: d)

  defp missing(change),
    do:
      change
      |> written()
      |> Enum.reject(&MapSet.member?(change.blobs, &1))
      |> Enum.uniq()
      |> Enum.sort()

  # Code's fingerprint of a change: its request without `change_id`, entries sorted by path.
  defp fingerprint(change) do
    canonical =
      change.request
      |> Map.delete("change_id")
      |> Map.update!("entries", &Enum.sort_by(&1, fn entry -> entry["path"] end))
      |> JSON.encode!()

    "fpr_" <> sha256(canonical)
  end

  # As decoded JSON, the way Code takes a request: string keys, no nil values.
  defp stringify(request),
    do: request |> JSON.encode!() |> JSON.decode!() |> drop_nil()

  defp drop_nil(map) when is_map(map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {k, drop_nil(v)})

  defp drop_nil(list) when is_list(list), do: Enum.map(list, &drop_nil/1)
  defp drop_nil(other), do: other

  defp bytes({:symlink, target}), do: target
  defp bytes(bytes), do: bytes

  defp files(s, snapshot_id) do
    with {repository, revision, path} <- s.snapshots[snapshot_id],
         do: {repository, path, s.repositories[repository].revisions[revision]}
  end

  # A lazy stream of chunks of at most 64 KiB.
  defp chunks(bytes) do
    Stream.unfold(bytes, fn
      <<>> -> nil
      <<chunk::binary-size(@chunk), rest::binary>> -> {chunk, rest}
      rest -> {rest, <<>>}
    end)
  end

  # `capability` is its name, or `{name, input}` for the calls `requests/1` lists with their
  # inputs (`calls/1` lists every call by name).
  defp answer(fake, capability, fun) do
    caller = self()

    {name, request} =
      case capability do
        {name, input} ->
          {name, [{name, input}]}

        {name, snapshot, repository} ->
          {name, [{name, %{snapshot_id: snapshot, repository: repository}}]}

        name ->
          {name, []}
      end

    mode =
      Agent.get_and_update(fake, fn s ->
        {s.mode, %{s | calls: [{name, caller} | s.calls], requests: request ++ s.requests}}
      end)

    mode = if mode == :blocked, do: block(fake), else: mode

    case mode do
      :failing ->
        {:error, :provider_unavailable}

      _ok ->
        Agent.get_and_update(fake, fn s ->
          case fun.(s) do
            {:update, answer, s} -> {answer, s}
            answer -> {answer, s}
          end
        end)
    end
  end

  defp block(fake) do
    ref = make_ref()
    caller = self()
    Agent.update(fake, &%{&1 | waiting: [{caller, ref} | &1.waiting]})

    receive do
      {:release, ^ref} -> Agent.get(fake, & &1.mode)
    end
  end

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end
