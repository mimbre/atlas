defmodule AtlasCode.Effects do
  @moduledoc """
  Code's receiver of Flow's effects (Flow's effect contract, version 1): `integrate` of a
  GitHub pull at exactly the revision the run was asked about, the way it is done by
  hand. Update the branch from its base when it is behind; wait for CI on that result;
  merge it when CI is green, fenced by the head GitHub must still have; refuse on a
  conflict, red CI, a closed pull or a head that moved. And `publish`: a subject's result as
  a GitHub pull (see "Publish" below).

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
  `revision` (a commit, or a `rev_` handle of Code's) and its `fingerprint` must be the
  digest of that payload by the request's `fingerprint_definition`, with `approved` equal to
  it: so the revision merged is the one approved. The repository must be listed in
  `repositories`. A handle is resolved, once, when the request is accepted, through Code's
  own record of it (`<home>/revisions/<handle>.json`, `AtlasCode.put_revision/3`): it must
  be the handle of that record's commit in the pull's repository (`github.com/<owner>/<repo>`),
  otherwise it is refused `unknown_revision`, also for a handle of another repository. The
  journal's `line` starts at the resolved commit; the request keeps the handle.

  GitHub is reached through `github: {module, config}` (`AtlasCode.Effects.GitHub`).

  **Publish.** The request's `input` names the `repository` (`github.com/<owner>/<repo>`,
  listed in `repositories`), the `base` branch, and the `result`: the ref
  (`refs/atlas/results/<task>`) a Runtime pushed the task's result commit to in Code's
  copy of that repository (`AtlasCode.Service.result/3`), resolved once when it is
  accepted. Code pushes that commit to the branch `atlas/<task>` on GitHub and opens a
  pull from it onto `base`, titled with the payload's `title`, its body the
  `description` and, when the input has them, its `review` (`%{"task", "verdict",
  "findings"}`: what an independent review of the result found) and its `fix` (`%{"task",
  "answer"}`: the task that fixed those findings, whose result this is; its commit sits on
  the author's, both on `base`). Done, with `reference` and `outputs` `%{"url"}`, is that
  pull's web address. A repeat first looks the branch's pull up, so it is never opened
  twice; a branch already at another commit is refused `branch_taken`. A result with no
  changes against `base` (its tree is that of the commit it shares with Code's copy of
  `base`: what the pull would show) is refused `no_changes` when it is accepted, and
  nothing is pushed or opened.

  **Onto an open pull.** An `input` that names a `pull` (its web address, in that same
  repository; otherwise refused `invalid_pull`) puts the result on that pull instead: Code
  reads the pull and pushes the commit to its branch (`head_ref`), never forced, so a result
  made on top of the pull's head fast-forwards it. Done with that pull's address; nothing
  is opened and its body is not changed. A pull whose head is the result already is done
  without a push; a closed or merged pull is refused `closed`; a branch the result does not
  fast-forward is refused `branch_taken`.
  """

  alias AtlasBus.{Digest, SubjectFingerprint}

  @address ~r{\Ahttps://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([0-9]+)\z}
  @commit ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/
  @handle ~r/\Arev_[0-9a-f]{64}\z/
  @id ~r/\A[0-9a-f]{64}\z/
  @methods ~w(merge squash rebase)
  @result ~r{\Arefs/atlas/results/([A-Za-z0-9][A-Za-z0-9._-]*)\z}
  @branch ~r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}
  @repository ~r{\Agithub\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\z}

  @doc """
  The receiver's settings: `dir` (its journal's folder), `github` (`{module, config}`),
  `repositories` (`["owner/repo"]`, the only ones it integrates), `merge_method`
  (`merge`, `squash` or `rebase`; `merge` by default), `home` (the Code home whose
  `revisions/` resolves `rev_` handles; `dir` by default, so a journal kept in Code's home
  needs no more) and `results` (how a publication's result ref is resolved: a function of
  the repository and the ref answering `{:ok, %{"dir", "commit"}}` or `:error`; by
  default `AtlasCode.Service.result/3` of the Code registered in this BEAM). Code's
  `update_review` reads this journal (`AtlasCode.start/2`'s `effects:`, the home by
  default).
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
      home: Map.get(opts, "home", dir),
      github: {module, config},
      repositories: repositories,
      merge_method: method,
      results: Map.get(opts, "results", &registered_result/2)
    }
  end

  defp registered_result(repository, ref),
    do: AtlasCode.Service.result(AtlasCode.settings(), repository, ref)

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
      {:ok, changes} ->
        save(file, Map.merge(record, Map.put(changes, "phase", "accepted")))
        |> then(&carry_on(s, file, &1))

      {:refused, reason, details} ->
        save(file, Map.put(record, "outcome", refused(reason, details)))["outcome"]
    end
  end

  defp check(s, %{"operation" => "publish"} = r) do
    input = r["input"]
    payload = r["payload"]

    cond do
      not (is_map(input) and is_binary(input["result"]) and Regex.match?(@result, input["result"])) ->
        {:refused, "invalid_result", %{}}

      not (is_binary(input["base"]) and Regex.match?(@branch, input["base"])) ->
        {:refused, "invalid_base", %{}}

      not (is_map(payload) and is_binary(payload["title"]) and String.trim(payload["title"]) != "") ->
        {:refused, "invalid_title", %{}}

      slug(r) not in s.repositories ->
        {:refused, "repository_not_allowed", %{"repository" => input["repository"]}}

      Map.has_key?(input, "pull") and not onto_repository?(input["pull"], slug(r)) ->
        {:refused, "invalid_pull", %{"pull" => input["pull"]}}

      true ->
        case s.results.(input["repository"], input["result"]) do
          {:ok, %{"dir" => dir, "commit" => commit}} ->
            if unchanged?(dir, commit, input["base"]),
              do: {:refused, "no_changes", %{"base" => input["base"]}},
              else: {:ok, %{"dir" => dir, "commit" => commit}}

          _ ->
            {:refused, "unknown_result", %{"result" => input["result"]}}
        end
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
               (Regex.match?(@commit, payload["revision"]) or
                  Regex.match?(@handle, payload["revision"]))) ->
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
        with {:ok, commit} <- resolve(s, slug(r), payload["revision"]),
             do: {:ok, %{"line" => [commit]}}
    end
  end

  # Whether `commit` changes nothing against `base` in the Git repository `dir`: its tree is
  # that of the commit it shares with the base branch, so its pull would have no files. A
  # base Code's copy does not hold says nothing.
  defp unchanged?(dir, commit, base) do
    git = &System.cmd("git", ["--git-dir", dir | &1], stderr_to_stdout: true)

    with {out, 0} <- git.(["merge-base", commit, "refs/heads/" <> base]),
         shared = String.trim(out),
         {trees, 0} <- git.(["rev-parse", shared <> "^{tree}", commit <> "^{tree}"]),
         [same, same] <- String.split(trees) do
      true
    else
      _ -> false
    end
  end

  # A commit is itself; a handle is the commit Code recorded it for, in the pull's repository
  # only (see "The request" in the module's documentation).
  defp resolve(s, slug, revision) do
    if Regex.match?(@commit, revision) do
      {:ok, revision}
    else
      repository = "github.com/" <> slug

      # The handle names its repository and commit: one recorded for another repository, or
      # under another name, is not this pull's.
      with {:ok, bytes} <- File.read(Path.join([s.home, "revisions", revision <> ".json"])),
           {:ok, %{"commit" => commit}} when is_binary(commit) <- JSON.decode(bytes),
           true <- AtlasCode.handle(repository, commit) == revision do
        {:ok, commit}
      else
        _ -> {:refused, "unknown_revision", %{"revision" => revision}}
      end
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

  # A publication onto an existing pull: the result pushed to that pull's branch, never
  # forced. It is done once the pull's head is the result: a repeat after the push pushes
  # nothing.
  defp step(
         s,
         _file,
         %{"request" => %{"operation" => "publish", "input" => %{"pull" => url}} = r} = record
       ) do
    {module, config} = s.github
    slug = slug(r)

    with {:ok, pull} <- module.pull(config, slug, pull_number(url)) do
      cond do
        pull["head"] == record["commit"] ->
          {:outcome, published(url)}

        pull["merged"] == true or pull["state"] != "open" ->
          {:outcome, refused("closed", %{"pull" => url})}

        true ->
          case module.push(config, slug, record["dir"], record["commit"], pull["head_ref"]) do
            :ok ->
              {:outcome, published(url)}

            {:error, :branch_taken} ->
              {:outcome, refused("branch_taken", %{"branch" => pull["head_ref"]})}

            other ->
              other
          end
      end
    end
    |> unavailable(record["phase"])
  end

  # A publication: the branch's pull when there is one (an earlier attempt opened it),
  # else the result pushed to the branch and its pull opened.
  defp step(s, _file, %{"request" => %{"operation" => "publish"} = r} = record) do
    {module, config} = s.github
    slug = slug(r)
    [_, task] = Regex.run(@result, r["input"]["result"])
    branch = "atlas/" <> task

    pull = %{
      "head" => branch,
      "base" => r["input"]["base"],
      "title" => r["payload"]["title"],
      "body" => body(r, task)
    }

    with {:ok, nil} <- module.find_pull(config, slug, branch),
         :ok <- module.push(config, slug, record["dir"], record["commit"], branch),
         {:ok, url} <- module.create_pull(config, slug, pull) do
      {:outcome, published(url)}
    else
      {:ok, url} when is_binary(url) -> {:outcome, published(url)}
      {:error, :branch_taken} -> {:outcome, refused("branch_taken", %{"branch" => branch})}
      other -> other
    end
    |> unavailable(record["phase"])
  end

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

  defp published(url), do: %{"status" => "done", "reference" => url, "outputs" => %{"url" => url}}

  # The pull's body: the subject's description, its review and fix, what merging it does, and
  # who wrote it.
  defp body(r, task) do
    description = r["payload"]["description"]

    Enum.join(
      [
        if(is_binary(description) and String.trim(description) != "", do: description),
        review(r["input"]["review"]),
        fix(r["input"]["fix"]),
        "Atlas #{r["subject"]}, task #{task}: merging this finishes it.",
        "<sub>Written by an AI agent (Atlas #{r["subject"]}).</sub>"
      ]
      |> Enum.reject(&is_nil/1),
      "\n\n"
    )
  end

  defp review(%{"task" => task} = review) do
    said =
      case review["verdict"] do
        "approved" -> "approved it"
        "changes_required" -> "asks for changes"
        _ -> "gave no verdict; see its answer"
      end

    findings = for f <- List.wrap(review["findings"]), is_binary(f), do: "- " <> f

    Enum.join(
      ["**Review.** An independent agent review (task #{task}) #{said}." | findings],
      "\n"
    )
  end

  defp review(_none), do: nil

  defp fix(%{"task" => task} = fix) do
    answer =
      case fix["answer"] do
        text when is_binary(text) ->
          text |> String.split("\n") |> Enum.map_join("\n", &("> " <> &1))

        _ ->
          "> (no answer)"
      end

    "**Fix.** An agent fixed what the review found (task #{task}); this is its result. Its answer:\n\n" <>
      answer
  end

  defp fix(_none), do: nil

  defp slug(%{"operation" => "publish", "input" => %{"repository" => repository}})
       when is_binary(repository) do
    case Regex.run(@repository, repository) do
      [_, slug] -> slug
      nil -> nil
    end
  end

  defp slug(%{"operation" => "publish"}), do: nil

  defp slug(%{"target" => target}) do
    [_, owner, repo, _] = Regex.run(@address, target)
    owner <> "/" <> repo
  end

  defp number(%{"target" => target}), do: pull_number(target)

  defp pull_number(url) do
    [_, _, _, number] = Regex.run(@address, url)
    String.to_integer(number)
  end

  defp onto_repository?(url, slug) do
    case is_binary(url) && Regex.run(@address, url) do
      [_, owner, repo, _] -> owner <> "/" <> repo == slug
      _ -> false
    end
  end

  defp save(file, record) do
    AtlasCode.write_atomic(file, JSON.encode!(record))
    record
  end
end
