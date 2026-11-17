defmodule AtlasFlow.Publish do
  @moduledoc """
  Publishes a task's frozen result as a Code review (F2/F3 plan §3.2 step 1; F3-P): an
  author or fix task whose check passed (exit 0) and whose result is `complete` becomes a
  draft review on the package's repository, or moves the package's open review to it.

  **Checks first.** Before any call to Code it:
  - reads the task's pinned change set (`AtlasFlow.Results.manifest/1`) and, for each write
    entry, the stored blob (`AtlasFlow.Results.blob/1`), checked against the entry's size and
    sha256 (`AtlasChangeset.verify_blob/2`);
  - recomputes every root's `csf_` fingerprint with `AtlasChangeset`, on the change set's own
    base, and refuses unless they are exactly the task's `result_fingerprints`;
  - takes the one root the repository is placed at (its last name, as `AtlasFlow.Bases`
    places it) and refuses any other root.

  A refused publication sends nothing to Code: `{:error, reason}` with `reason` one of
  `:not_publishable` (no passed check, no complete result, or not an author or fix task),
  `:no_result`, `:fingerprint_mismatch`, `:unmapped_root`, `:empty_change`,
  `:blob_missing`, `:blob_mismatch` or `:no_base`.

  **Then Code** (the publishing client, `AtlasFlow.Code.Client.publishing/0`):
  `create_change` on the task's base (`base_snapshot`, and the repository's revision in it:
  the task's `base_revision`, or else Code's record of the snapshot, read with Bases'
  snapshot-only client) → `put_change_blob` for
  each blob Code still misses → `seal_change` → either `create_review` with `draft: true`
  (the package's first review) or `update_review` of the package's open review from the
  last revision Flow published on it. Both pass the change's `fpr_` fingerprint as Flow
  computed it from the change it created (Code's own definition: the request without
  `change_id`, entries sorted by path), so Code refuses any other content. A refusal of
  Code's is `{:error, {:code, tag}}`.

  **Ids from the task key.** The change, review and update ids are UUIDs derived from the
  task key (`id/2`), so a repeat of a publication (after a crash, a restart, a second cast)
  is the same change and the same review or update in Code: never a second review.

  **The published revision (N1).** The answer's `published_revision` is what the task
  records as its `published_revision`: the review's `revision` for a first review (the
  sealed change's revision), and the update's `revision` for a fix (Code's new commit of the
  sealed tree on the review's head, not the sealed change's revision).

  **The body.** The review's body carries its fields (`body_fields/1` reads them back): the
  check that passed, the provenance, `why_now`, and the attribution Code requires.

  Pure but for the calls to Results and Code; it writes no fact. Landing (F3-L) calls it and
  records the answer.
  """

  alias AtlasFlow.Code.Client
  alias AtlasFlow.Results

  @attribution "Written by an AI agent (Atlas Flow)."
  @marker "atlas-flow-publication"

  @type request :: %{
          required(:task_key) => String.t(),
          required(:task) => map(),
          required(:repository) => String.t(),
          required(:target) => String.t(),
          required(:title) => String.t(),
          optional(:why_now) => String.t() | nil,
          optional(:provenance) => map() | nil,
          optional(:review) => %{review_id: String.t(), revision: String.t()} | nil
        }

  @type publication :: %{
          kind: :created | :updated,
          change_id: String.t(),
          review_id: String.t(),
          update_id: String.t() | nil,
          sealed_revision: String.t(),
          published_revision: String.t(),
          fingerprint: String.t(),
          link: String.t() | nil
        }

  @doc """
  Publishes `request`'s task (see the moduledoc):

  - `task_key`, and `task`: the task fact's values (string keys);
  - `repository` (Code's name), `target` (the branch it asks to land on), `title`;
  - `why_now` and `provenance`, for the body;
  - `review`: the package's open review and the last revision Flow published on it
    (`%{review_id, revision}`), or nil for the package's first review.

  Options: `client:` (default `AtlasFlow.Code.Client.publishing/0`), `snapshot_client:` (the
  one read of a snapshot when the task has no `base_revision`; default
  `AtlasFlow.Code.Client.default/0`, which has the `snapshot` right the publishing client
  lacks), `results:` (the result store, default `AtlasFlow.Results`).
  """
  @spec publish(request(), keyword()) :: {:ok, publication()} | {:error, term()}
  def publish(request, opts \\ []) do
    client = Keyword.get(opts, :client, Client.publishing())
    snapshots = Keyword.get(opts, :snapshot_client, Client.default())
    results = Keyword.get(opts, :results, Results)

    with {:ok, entries} <- checked(request, results),
         {:ok, base_revision} <- base_revision(request, snapshots),
         change_request = change_request(request, base_revision, entries),
         fingerprint = fingerprint(change_request),
         {:ok, sealed} <- seal(client, change_request, results) do
      review(client, request, change_request.change_id, sealed, fingerprint)
    end
  end

  @doc """
  The deterministic id (a lowercase UUID) of `kind` (`"change"`, `"review"`, `"update"`)
  for `task_key`: the same task always gets the same change, review and update.
  """
  @spec id(String.t(), String.t()) :: String.t()
  def id(kind, task_key) when is_binary(kind) and is_binary(task_key) do
    <<a::binary-size(4), b::binary-size(2), c::16, d::16, e::binary-size(6), _::binary>> =
      :crypto.hash(:sha256, ["atlas-flow/publish/", kind, 0, task_key])

    # Version 8 (custom), RFC 9562 variant.
    c = Bitwise.bor(Bitwise.band(c, 0x0FFF), 0x8000)
    d = Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000)

    Enum.map_join([a, b, <<c::16>>, <<d::16>>, e], "-", &Base.encode16(&1, case: :lower))
  end

  @doc "The fields a body carries (`body/1`'s input), or nil when it carries none."
  @spec body_fields(String.t()) :: map() | nil
  def body_fields(body) when is_binary(body) do
    case Regex.run(~r/<!-- #{@marker} (.*?) -->/s, body) do
      [_, json] -> JSON.decode!(json)
      nil -> nil
    end
  end

  @doc """
  The review's body: its fields (`check`, `provenance`, `why_now`, `attribution`, `task`)
  as readable text, and as one machine-readable block (`body_fields/1`).
  """
  @spec body(map()) :: String.t()
  def body(fields) do
    check = fields["check"]

    """
    #{fields["why_now"] || ""}

    | | |
    |---|---|
    | Task | `#{fields["task"]}` |
    | Check | exit #{check["exit_status"]}#{if check["ending"], do: " (#{check["ending"]})", else: ""} |
    #{Enum.map_join(Enum.sort(fields["provenance"]), "\n", fn {k, v} -> "| #{k} | `#{text(v)}` |" end)}

    <!-- #{@marker} #{JSON.encode!(fields)} -->

    <sub>#{fields["attribution"]}</sub>
    """
  end

  defp text(value) when is_binary(value) or is_number(value), do: to_string(value)
  defp text(value), do: JSON.encode!(value)

  @doc "The fields of a request's body (see `body/1`)."
  @spec fields(request()) :: map()
  def fields(%{task_key: key, task: task} = request) do
    provenance =
      %{"attempt" => task["attempt"], "runtime" => task["runtime"], "base" => task["base_id"]}
      |> Map.merge(stringify(request[:provenance] || %{}))
      |> Map.reject(fn {_k, v} -> is_nil(v) end)

    %{
      "task" => key,
      "check" => %{"exit_status" => task["check_exit_status"], "ending" => task["check_ending"]},
      "provenance" => provenance,
      "why_now" => request[:why_now],
      "attribution" => @attribution
    }
  end

  # -- Checks, before any call to Code ------------------------------------------------

  defp checked(%{task_key: key, task: task} = request, results) do
    with :ok <- publishable(task),
         {:ok, manifest} <- manifest(key, results),
         :ok <- fingerprints(manifest, task["result_fingerprints"]),
         {:ok, entries} <- root(manifest, request.repository),
         :ok <- blobs(entries, results) do
      {:ok, entries}
    end
  end

  defp publishable(task) do
    if task["kind"] in ["author", "fix"] and task["result_state"] == "complete" and
         task["check_exit_status"] == 0 and is_binary(task["base_snapshot"]),
       do: :ok,
       else: {:error, :not_publishable}
  end

  defp manifest(key, results) do
    case Results.manifest(key, results) do
      {:ok, manifest} -> {:ok, manifest}
      :not_found -> {:error, :no_result}
    end
  end

  # Every root's fingerprint computed again from its entries on the change set's base: the
  # task's `result_fingerprints` must be exactly these (D42), whatever the stored change set
  # itself claims.
  defp fingerprints(%{"base" => base, "roots" => roots}, recorded)
       when is_binary(base) and is_list(roots) and is_binary(recorded) do
    plain = %{"base" => base, "roots" => Enum.map(roots, &Map.delete(&1, "fingerprint"))}

    with :ok <- AtlasChangeset.validate(plain),
         {:ok, recorded} <- JSON.decode(recorded),
         true <- is_list(recorded) do
      computed = for f <- AtlasChangeset.fingerprints(plain), do: {f.root, f.fingerprint}
      recorded = for r <- recorded, is_map(r), do: {r["root"], r["fingerprint"]}

      if Enum.sort(computed) == Enum.sort(recorded),
        do: :ok,
        else: {:error, :fingerprint_mismatch}
    else
      _ -> {:error, :fingerprint_mismatch}
    end
  end

  defp fingerprints(_manifest, _recorded), do: {:error, :fingerprint_mismatch}

  # The repository is placed at its last name in the base (AtlasFlow.Bases); that is the
  # only root a publication maps, and its paths are the repository's.
  defp root(%{"roots" => roots}, repository) do
    name = repository |> String.split("/") |> List.last()

    case roots do
      [%{"root" => ^name, "entries" => [_ | _] = entries}] -> {:ok, entries}
      [%{"root" => ^name}] -> {:error, :empty_change}
      _ -> {:error, :unmapped_root}
    end
  end

  defp blobs(entries, results) do
    Enum.reduce_while(writes(entries), :ok, fn entry, :ok ->
      case Results.blob(entry["sha256"], results) do
        {:ok, size, content} ->
          if size == entry["size"] and AtlasChangeset.verify_blob(entry, content) == :ok,
            do: {:cont, :ok},
            else: {:halt, {:error, :blob_mismatch}}

        :not_found ->
          {:halt, {:error, :blob_missing}}
      end
    end)
  end

  # A symlink's bytes are its target, which travels in the change itself.
  defp writes(entries), do: for(%{"op" => "write", "kind" => "file"} = e <- entries, do: e)

  # -- Code ---------------------------------------------------------------------------

  defp base_revision(%{task: %{"base_revision" => revision}}, _client) when is_binary(revision),
    do: {:ok, revision}

  defp base_revision(%{task: task, repository: repository}, client) do
    case Client.snapshot_revision(client, task["base_snapshot"], repository) do
      {:ok, revision} -> {:ok, revision}
      {:error, tag} -> {:error, {:code, tag}}
    end
  end

  defp change_request(request, base_revision, entries) do
    %{
      change_id: id("change", request.task_key),
      snapshot_id: request.task["base_snapshot"],
      repository: request.repository,
      base_revision: base_revision,
      entries: Enum.map(entries, &change_entry/1)
    }
  end

  defp change_entry(%{"op" => "delete", "path" => path}), do: %{"path" => path, "op" => "delete"}

  defp change_entry(entry),
    do:
      Map.take(entry, ~w(path op kind mode size sha256 target))
      |> Map.reject(&is_nil(elem(&1, 1)))

  @doc """
  The `fpr_` fingerprint of a change request, as Code computes it: `"fpr_"` and the sha256
  of the request's JSON without `change_id`, its entries sorted by path (string keys, in
  `JSON.encode!/1`'s order; no nil values).
  """
  @spec fingerprint(map()) :: String.t()
  def fingerprint(change_request) do
    canonical =
      change_request
      |> stringify()
      |> Map.delete("change_id")
      |> Map.update!("entries", &Enum.sort_by(&1, fn entry -> entry["path"] end))
      |> JSON.encode!()

    "fpr_" <> Base.encode16(:crypto.hash(:sha256, canonical), case: :lower)
  end

  defp seal(client, change_request, results) do
    with {:ok, change} <- code(Client.create_change(client, change_request)),
         :ok <- upload(client, change, results),
         {:ok, %{state: :sealed, revision: revision}} when is_binary(revision) <-
           code(Client.seal_change(client, change.change_id)) do
      {:ok, revision}
    else
      {:ok, _not_sealed} -> {:error, {:code, :incomplete_upload}}
      error -> error
    end
  end

  defp upload(client, %{change_id: id, missing: missing}, results) do
    Enum.reduce_while(missing, :ok, fn sha, :ok ->
      with {:ok, _size, content} <- Results.blob(sha, results),
           bytes = IO.iodata_to_binary(Enum.to_list(content)),
           true <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == sha,
           {:ok, _change} <- code(Client.put_change_blob(client, id, sha, bytes)) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _gone_or_changed -> {:halt, {:error, :blob_mismatch}}
      end
    end)
  end

  defp review(
         client,
         %{review: %{review_id: review_id, revision: last}} = request,
         change_id,
         sealed,
         fingerprint
       ) do
    update = %{
      update_id: id("update", request.task_key),
      review_id: review_id,
      change_id: change_id,
      revision: last,
      fingerprint: fingerprint
    }

    with {:ok, answer} <- code(Client.update_review(client, update)) do
      {:ok,
       %{
         kind: :updated,
         change_id: change_id,
         review_id: review_id,
         update_id: update.update_id,
         sealed_revision: sealed,
         published_revision: answer.revision,
         fingerprint: fingerprint,
         link: answer[:link]
       }}
    end
  end

  defp review(client, request, change_id, sealed, fingerprint) do
    review = %{
      review_id: id("review", request.task_key),
      change_id: change_id,
      target: request.target,
      title: request.title,
      body: body(fields(request)),
      fingerprint: fingerprint,
      draft: true
    }

    with {:ok, answer} <- code(Client.create_review(client, review)) do
      {:ok,
       %{
         kind: :created,
         change_id: change_id,
         review_id: answer.review_id,
         update_id: nil,
         sealed_revision: sealed,
         published_revision: answer.revision,
         fingerprint: fingerprint,
         link: answer[:link]
       }}
    end
  end

  defp code({:ok, _} = ok), do: ok
  defp code({:error, tag}), do: {:error, {:code, tag}}

  defp stringify(term), do: term |> JSON.encode!() |> JSON.decode!() |> drop_nil()

  defp drop_nil(map) when is_map(map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {k, drop_nil(v)})

  defp drop_nil(list) when is_list(list), do: Enum.map(list, &drop_nil/1)
  defp drop_nil(other), do: other
end
