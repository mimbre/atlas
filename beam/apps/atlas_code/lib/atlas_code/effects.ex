defmodule AtlasCode.Effects do
  @moduledoc """
  Code's receiver of Flow's effects (Flow's effect contract, version 1): `integrate` of a
  GitHub pull at exactly the revision the run was asked about, the way it is done by
  hand. Update the branch from its base when it is behind; wait for CI on that result;
  merge it when CI is green, fenced by the head GitHub must still have; refuse on a
  conflict, red CI, a closed pull or a head that moved.

  `handle/2` takes one body, `%{"operation" => "submit" | "lookup", "request" => r,
  "digest" => d}`, and answers it:

    * `done`, with `reference` and `outputs` `%{"sha", "head"}`: merged; `sha` is the
      merge commit, `head` the head it merged;
    * `refused`, with `reason` (a code) and `details`: blocked, nothing merged;
    * `working`, with `phase`: not done yet. Flow takes no answer from it and asks again
      by lookup, which carries the work on;
    * `not_found` (a lookup of an id never submitted), `conflict` (the id is bound to
      another request) or `invalid` (a request that does not match its digest).

  **The journal.** `<dir>/effects/<id>.json` holds the request and its digest, written
  before any call to GitHub, then the phase and, once there is one, the outcome; each
  write is atomic. An id names one request for ever. A done or refused record is only
  replayed; any other is carried on from what GitHub holds now, so a repeat after a
  crash at any point never acts twice:

    * `accepted`: read; nothing asked of GitHub yet;
    * `updating`: an update of the branch from its base was asked for (GitHub does it
      later). The new head is taken only when it is a merge of the last head and a commit
      of the base; anything else on the branch is a head that moved;
    * `checking`: waiting for CI on the last head;
    * `merging`: the merge of `merging` was asked for. A repeat reads the pull first: one
      merged at that head is done, whoever merged it. Before every attempt, the pull must
      still be open at that head, current with its base and green in CI.

  `line` is the heads the integration may merge: the revision asked about, then each
  update of it from its base. A pull merged at any other head is refused, never done.

  **Access refused.** GitHub refusing access (a token missing, expired or without the
  permission) ends a request as `refused` only where that refusal proves what happened:
  on any read before anything was asked of GitHub (`accepted`, `checking`), and on the
  first merge call itself. `merge_attempted` is stored before that call; later refusals
  cannot resolve an earlier call that may still complete. Old `merging` records without
  this marker are uncertain too. While uncertain, a changed head, base or CI pauses new
  writes without ending reconciliation. Once an update or a
  merge may have been asked (`updating`, `merging`), a refused read proves nothing: the
  request stays `working`, and the next lookup with access reads what GitHub did.

  Removing a repository from the allow-list also pauses unfinished requests already
  journaled for it, before any GitHub call. Their outcome stays unknown until access is
  enabled again; stored terminal outcomes can still be replayed.

  **The request.** Its `target` is the pull's GitHub address, `payload` holds the
  `revision` (a commit) and its `fingerprint` must be the digest of that payload by the
  request's `fingerprint_definition`, with `approved` equal to it: so the revision merged
  is the one approved. The repository must be listed in `repositories`.

  GitHub is reached through `github: {module, config}` (`AtlasCode.Effects.GitHub`).
  """

  alias AtlasBus.{Digest, SubjectFingerprint}

  @address ~r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)\z}
  @commit ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/
  @id ~r/\A[0-9a-f]{64}\z/
  @methods ~w(merge squash rebase)

  @doc """
  The receiver's settings: `dir` (its journal's folder), `github` (`{module, config}`),
  `repositories` (`["owner/repo"]`, the only ones it integrates) and `merge_method`
  (`merge`, `squash` or `rebase`; `merge` by default).
  """
  def new(opts) do
    opts = Map.new(opts, fn {k, v} -> {to_string(k), v} end)
    dir = Map.fetch!(opts, "dir")
    {module, config} = Map.fetch!(opts, "github")
    repositories = Map.fetch!(opts, "repositories")
    method = Map.get(opts, "merge_method", "merge")

    unless is_list(repositories) and Enum.all?(repositories, &is_binary/1),
      do: raise(ArgumentError, "repositories must list owner/repo names")

    unless method in @methods,
      do: raise(ArgumentError, "merge_method must be one of #{inspect(@methods)}")

    File.mkdir_p!(Path.join(dir, "effects"))

    %{
      dir: dir,
      github: {module, config},
      repositories: repositories,
      merge_method: method
    }
  end

  @doc "The answer to one body (see the module's documentation)."
  def handle(s, %{"request" => %{"id" => id} = r, "digest" => digest} = body)
      when is_binary(id) and is_binary(digest) do
    base = %{"version" => 1, "id" => id, "digest" => digest, "fingerprint" => r["fingerprint"]}

    if not Regex.match?(@id, id) or r["version"] != 1 do
      Map.put(base, "status", "invalid")
    else
      file = Path.join([s.dir, "effects", id <> ".json"])

      case File.read(file) do
        {:ok, bytes} ->
          record = JSON.decode!(bytes)

          # One id names one request for ever; a different one is never acted on.
          if record["digest"] == digest and record["request"] == r,
            do: Map.merge(base, carry_on(s, file, record)),
            else: Map.put(base, "status", "conflict")

        {:error, :enoent} ->
          cond do
            Digest.of_term(r) != digest -> Map.put(base, "status", "invalid")
            body["operation"] == "lookup" -> Map.put(base, "status", "not_found")
            body["operation"] == "submit" -> Map.merge(base, accept(s, file, r, digest))
            true -> Map.put(base, "status", "invalid")
          end
      end
    end
  end

  def handle(_s, _body), do: %{"version" => 1, "status" => "invalid"}

  # A new request: stored before anything is asked of GitHub, refused at once when it
  # cannot be integrated as asked.
  defp accept(s, file, r, digest) do
    record = %{"request" => r, "digest" => digest}

    case check(s, r) do
      :ok ->
        save(
          file,
          Map.merge(record, %{"phase" => "accepted", "line" => [r["payload"]["revision"]]})
        )
        |> then(&carry_on(s, file, &1))

      {:refused, reason, details} ->
        save(file, Map.put(record, "outcome", refused(reason, details)))["outcome"]
    end
  end

  defp check(s, r) do
    definition = r["fingerprint_definition"]
    payload = r["payload"]

    cond do
      r["operation"] != "integrate" ->
        {:refused, "unsupported_operation", %{"operation" => r["operation"]}}

      not (is_binary(r["target"]) and Regex.match?(@address, r["target"])) ->
        {:refused, "invalid_target", %{}}

      not (is_map(payload) and is_binary(payload["revision"]) and
               Regex.match?(@commit, payload["revision"])) ->
        {:refused, "invalid_revision", %{}}

      not (is_map(definition) and definition["relations"] == [] and
             is_list(definition["fields"]) and "revision" in definition["fields"] and
             Enum.all?(definition["fields"], &Map.has_key?(payload, &1)) and
               SubjectFingerprint.of(%{"values" => payload}, definition) == r["fingerprint"]) ->
        {:refused, "fingerprint_mismatch", %{}}

      r["approved"] != r["fingerprint"] ->
        {:refused, "not_approved", %{}}

      slug(r) not in s.repositories ->
        {:refused, "repository_not_allowed", %{"repository" => slug(r)}}

      true ->
        :ok
    end
  end

  # A record with an outcome is replayed; any other is carried on one step from what
  # GitHub holds now. GitHub being unreachable leaves it as it is.
  defp carry_on(_s, _file, %{"outcome" => outcome}), do: outcome

  defp carry_on(s, file, record) do
    if slug(record["request"]) in s.repositories do
      result = step(s, file, record)

      # An open-pull read and a later refusal cannot rule out a delayed earlier merge.
      result =
        case result do
          {:outcome, %{"status" => "refused", "reason" => reason}}
          when reason != "merged_elsewhere" ->
            if uncertain_merge?(record), do: :unchanged, else: result

          _ ->
            result
        end

      case result do
        {:outcome, outcome} -> save(file, Map.put(record, "outcome", outcome))["outcome"]
        {:phase, changes} -> working(save(file, Map.merge(record, changes)))
        :unchanged -> working(record)
        {:continue, changes} -> carry_on(s, file, save(file, Map.merge(record, changes)))
      end
    else
      # Disabling access is not evidence of the outcome of an earlier remote write.
      working(record)
    end
  end

  defp uncertain_merge?(record),
    do: Map.get(record, "merge_attempted", record["phase"] == "merging") == true

  defp step(s, file, %{"request" => r, "line" => line} = record) do
    {module, config} = s.github
    {slug, number} = {slug(r), number(r)}
    last = List.last(line)

    with {:ok, pull} <- module.pull(config, slug, number) do
      cond do
        pull["merged"] == true and pull["head"] in line ->
          {:outcome, done(pull["merge_commit"], pull["head"])}

        pull["merged"] == true ->
          {:outcome, refused("merged_elsewhere", %{"head" => pull["head"]})}

        pull["state"] != "open" ->
          {:outcome, refused("closed", %{})}

        pull["head"] != last ->
          moved(s, record, pull, slug)

        pull["mergeable"] == false ->
          {:outcome, refused("conflict", %{"head" => last})}

        true ->
          with {:ok, behind?} <- behind?(module, config, slug, pull["base"], last) do
            cond do
              behind? and uncertain_merge?(record) -> :unchanged
              behind? -> update(s, record, slug, number, last)
              true -> ci(s, file, record, slug, number, last)
            end
          end
      end
    end
    |> unavailable(record["phase"])
  end

  # The head is not the last one of the line: an update of it from its base, while one
  # was asked for, joins the line; anything else moved it.
  defp moved(s, record, pull, slug) do
    {module, config} = s.github
    head = pull["head"]

    with "updating" <- record["phase"],
         {:ok, [first, other]} <- module.parents(config, slug, head),
         true <- first == List.last(record["line"]),
         {:ok, true} <- on_base?(module, config, slug, pull["base"], other) do
      {:continue, %{"phase" => "checking", "line" => record["line"] ++ [head]}}
    else
      {:error, _} = error -> error
      _ -> {:outcome, refused("stale_revision", %{"head" => head})}
    end
  end

  # Stored as `updating` before GitHub is asked, so a repeat knows an update may be on its
  # way; asked again while the head is unchanged, fenced by that head.
  defp update(_s, %{"phase" => phase}, _slug, _number, _last) when phase != "updating",
    do: {:continue, %{"phase" => "updating"}}

  defp update(s, _record, slug, number, last) do
    {module, config} = s.github

    case module.update_branch(config, slug, number, last) do
      :ok -> :unchanged
      {:error, :conflict} -> {:outcome, refused("conflict", %{"head" => last})}
      # Not done: the head moved meanwhile (the next step reads which head it is), or
      # another reason (no maintainer edits, nothing to update): refused, if GitHub still
      # holds that head.
      {:error, {:unprocessable, why}} -> unprocessable(module, config, slug, number, last, why)
      # Refused, so not done now; an earlier update that lands later merges nothing.
      {:error, {:refused, reason}} -> {:outcome, refused(reason, %{"head" => last})}
      other -> other
    end
  end

  # Green: `merging` is stored before the merge is asked for.
  defp ci(s, file, record, slug, number, last) do
    {module, config} = s.github

    case module.checks(config, slug, last) do
      {:ok, :success} ->
        if record["phase"] == "merging" do
          # Persist before the remote call, including a crash before its answer arrives.
          save(file, Map.put(record, "merge_attempted", true))
          merge(s, slug, number, last)
        else
          {:continue, %{"phase" => "merging", "merging" => last, "merge_attempted" => false}}
        end

      {:ok, :pending} ->
        if uncertain_merge?(record), do: :unchanged, else: {:phase, %{"phase" => "checking"}}

      {:ok, {:failure, names}} ->
        {:outcome, refused("ci_failed", %{"head" => last, "checks" => names})}

      other ->
        other
    end
  end

  defp merge(s, slug, number, head) do
    {module, config} = s.github

    case module.merge(config, slug, number, head, s.merge_method) do
      {:ok, sha} ->
        {:outcome, done(sha, head)}

      # GitHub's head is no longer `head`: the next step reads what it is.
      {:error, :head_moved} ->
        :unchanged

      {:error, {:not_mergeable, why}} ->
        {:outcome, refused("not_mergeable", %{"head" => head, "why" => why})}

      # Terminal only on the first attempt; carry_on preserves prior uncertainty.
      {:error, {:refused, reason}} ->
        {:outcome, refused(reason, %{"head" => head})}

      other ->
        other
    end
  end

  defp unprocessable(module, config, slug, number, last, why) do
    with {:ok, pull} <- module.pull(config, slug, number) do
      if pull["head"] == last and pull["state"] == "open" and pull["merged"] != true,
        do: {:outcome, refused("update_refused", %{"head" => last, "why" => why})},
        else: :unchanged
    end
  end

  defp behind?(module, config, slug, base, head) do
    with {:ok, %{"behind_by" => n}} <- module.compare(config, slug, base, head), do: {:ok, n > 0}
  end

  defp on_base?(module, config, slug, base, commit) do
    with {:ok, %{"ahead_by" => n}} <- module.compare(config, slug, base, commit),
         do: {:ok, n == 0}
  end

  # GitHub unreachable, or an answer it gives without acting (a rate limit): try again on
  # the next lookup. A read refused access is terminal only while nothing may have been
  # asked of GitHub (see "Access refused" in the module's documentation).
  defp unavailable({:error, {:refused, _}}, phase) when phase in ["updating", "merging"],
    do: :unchanged

  defp unavailable({:error, {:refused, reason}}, _phase), do: {:outcome, refused(reason, %{})}
  defp unavailable({:error, _}, _phase), do: :unchanged
  defp unavailable(other, _phase), do: other

  defp working(record), do: %{"status" => "working", "phase" => record["phase"]}

  defp done(sha, head),
    do: %{"status" => "done", "reference" => sha, "outputs" => %{"sha" => sha, "head" => head}}

  defp refused(reason, details),
    do: %{"status" => "refused", "reason" => reason, "details" => details}

  defp slug(%{"target" => target}) do
    [_, owner, repo, _] = Regex.run(@address, target)
    owner <> "/" <> repo
  end

  defp number(%{"target" => target}) do
    [_, _, _, number] = Regex.run(@address, target)
    String.to_integer(number)
  end

  defp save(file, record) do
    AtlasCode.write_atomic(file, JSON.encode!(record))
    record
  end
end
