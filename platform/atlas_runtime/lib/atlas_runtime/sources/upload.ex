defmodule AtlasRuntime.Sources.Upload do
  @moduledoc """
  Result upload to a work source (decision §5.2 "Result upload", §3 protection 6; M2 plan
  W6).

  For one leased work whose attempt has ended and is quiescent:

  1. It reads the work as the **source's client** through `AtlasRuntime.Boundary.Work`
     (`get_work`), with the right `:read` only. Whatever
     rights the caller's client holds, `choose_path` is never used here, so the facade's
     projection cuts every path on the Runtime's machine (D44) before anything is sent.
     The agent's `answer`, which the projection passes as stored, is redacted here by the
     core's rule for a check's output tail (protection 6, H2): the work folder becomes `.`
     and any other path under the Runtime home `<runtime-home>`.
  2. With the option `git` (a lease whose input names a `result_ref`), it first commits the
     work's folder on the base's commit and pushes it to the source's Code under that ref:
     the result travels over Git (IS-Atlas-100).
  3. It sends `report(ended)` with the result and the provenance, fenced by the
     `lease_id`. It sends no change set and never uploads a blob (`work_source` 0.5.0 has
     no `put_blob`); a `missing` the source names anyway is logged and ignored.

  Stops: `lease_lost` from `report`: stop at once, nothing more is sent. A source that
  cannot be reached (`{:error, reason}` from `report`) is not a stop: it is answered as it
  is, and the puller tries again. A repeat (after a restart or an unreachable source) pushes
  the same commit again and sends the same report again, at the same revision; both are
  idempotent at the source.

  The source is reached through the `{module, ref}` seam below (`report/2`).
  The M1 `work_source` contract's in-BEAM and HTTP client targets are adapted to it by the
  puller (assembly A3).
  """

  require Logger

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Folders

  @typedoc "The source as the upload calls it: a module implementing this behaviour and its ref."
  @type source :: {module(), term()}

  @typedoc "The report this upload sends: `state` is always `:ended`."
  @type report :: %{
          lease_id: String.t(),
          revision: non_neg_integer(),
          state: :ended,
          result: %{result: map() | nil, provenance: map() | nil}
        }

  @callback report(ref :: term(), report()) ::
              {:recorded, [String.t()]} | :lease_lost | {:error, term()}

  @terminal [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]

  @type outcome ::
          {:ok, %{uploaded: [], skipped: [String.t()]}}
          | {:stopped, :lease_lost}
          | {:error, :not_found | :not_ended | term()}

  @doc """
  Uploads the ended attempt of `work_id` under `lease_id` to `source`, reading as `client`.

  Options:
  - `:attempt`: the attempt to upload (default: the work's current one);
  - `:home`: the Runtime home whose paths the answer must not name (default: the running
    core's, `AtlasRuntime.Work.runtime/0`);
  - `:git`: the result over Git: `%{url, env, dir, base, ref, tree}`;
    the folder `tree` is committed on the base's commit under Code's prepared `base` in the
    Git cache `dir`, without the dependencies `base` adds, and pushed to `url` as `ref`,
    `env` a function that answers Git's environment (the source's token).
  """
  @spec run({String.t(), [atom()]}, source(), String.t(), String.t(), keyword()) :: outcome()
  def run(client, source, lease_id, work_id, options \\ []) do
    reader = reader(client)

    with {:ok, work} <- read_work(reader, work_id),
         {:ok, attempt} <- ended_attempt(work, Keyword.get(options, :attempt)),
         {:ok, redact} <- redaction(client, work_id, options),
         :ok <- push(work_id, options[:git]),
         report = report(lease_id, work, attempt, redact),
         {:recorded, missing} <- call(source, :report, report) do
      recorded(lease_id, missing)
    else
      :lease_lost -> stop(:lease_lost, lease_id)
      {:error, _} = error -> error
    end
  end

  # The result over Git (option `git`): the work's root as it ended, every file Git does not
  # ignore, less the dependencies Code's prepared base added, committed on the base's commit
  # under it, and pushed to the source's Code as `ref`: it diffs against the repository's base
  # with the agent's changes only. A lease without a result_ref (a read-only work) pushes
  # nothing: its result is its answer.
  defp push(_work_id, nil), do: :ok

  defp push(work_id, git) do
    index = Path.join(git.dir, "index-" <> work_id)

    env =
      [
        {"GIT_DIR", git.dir},
        {"GIT_WORK_TREE", git.tree},
        {"GIT_INDEX_FILE", index},
        {"GIT_TERMINAL_PROMPT", "0"},
        {"GIT_AUTHOR_NAME", "Atlas Runtime"},
        {"GIT_AUTHOR_EMAIL", "runtime@atlas"},
        {"GIT_COMMITTER_NAME", "Atlas Runtime"},
        {"GIT_COMMITTER_EMAIL", "runtime@atlas"}
      ] ++ git.env.()

    git_cmd = fn args ->
      {out, 0} = System.cmd("git", args, env: env, cd: git.tree, stderr_to_stdout: true)
      String.trim(out)
    end

    try do
      git_cmd.(["read-tree", git.base])
      git_cmd.(["add", "-A", "."])
      paths = index <> ".paths"
      File.write!(paths, git_cmd.(["diff", "--name-only", "-z", git.base <> "^", git.base]))

      if File.stat!(paths).size > 0 do
        args = ["--ignore-unmatch", "--pathspec-from-file=" <> paths, "--pathspec-file-nul"]
        git_cmd.(["--literal-pathspecs", "rm", "-r", "-q", "--cached" | args])
      end

      tree = git_cmd.(["write-tree"])

      commit =
        git_cmd.(
          ["-c", "commit.gpgsign=false", "commit-tree", tree, "-p", git.base <> "^"] ++
            ["-m", "Atlas result of #{work_id}"]
        )

      git_cmd.(["push", "--quiet", git.url, "+#{commit}:#{git.ref}"])
      :ok
    after
      File.rm(index)
      File.rm(index <> ".paths")
    end
  end

  # Only :read: the projection then redacts paths whatever the caller's rights (D44).
  defp reader({id, _rights}), do: {id, [:read]}

  defp read_work(reader, work_id) do
    case F.get_work(reader, %{work_id: work_id}) do
      %F.Outcome.Found{work: work} -> {:ok, work}
      _ -> {:error, :not_found}
    end
  end

  defp ended_attempt(work, number) do
    attempt =
      if number,
        do: Enum.find(work.attempts, &(&1.attempt == number)),
        else: List.last(work.attempts)

    case attempt do
      %{state: state, quiescent: true} = attempt when state in @terminal -> {:ok, attempt}
      nil -> {:error, :not_found}
      _ -> {:error, :not_ended}
    end
  end

  defp report(lease_id, work, attempt, redact) do
    %{
      lease_id: lease_id,
      revision: work.revision,
      state: :ended,
      result: %{
        result: attempt.result |> plain() |> redact_answer(redact),
        provenance: plain(attempt.provenance)
      }
    }
  end

  # A source of work_source 0.5.0 names no missing blob; one that does is logged, and
  # nothing is uploaded: a result travels over Git only.
  defp recorded(lease_id, missing) do
    skipped = Enum.uniq(missing)

    if skipped != [],
      do:
        Logger.warning("upload #{lease_id}: source named blobs #{inspect(skipped)}; none is sent")

    {:ok, %{uploaded: [], skipped: skipped}}
  end

  defp redact_answer(%{answer: answer} = result, redact) when is_binary(answer),
    do: %{result | answer: redact.(answer)}

  defp redact_answer(result, _redact), do: result

  # The core's rule (work/server.ex `redaction/4`, private there): the work's folder, and a
  # client-named folder it ran in, become `.`; any other path under the Runtime home, as given
  # or resolved, `<runtime-home>`; by plain prefix replacement. Applied whatever the caller's
  # rights, as the source never holds choose_path.
  defp redaction(client, work_id, options) do
    case Keyword.get_lazy(options, :home, fn -> (AtlasRuntime.Work.runtime() || %{})[:home] end) do
      home when is_binary(home) ->
        expanded = Path.expand(home)

        prefixes =
          Enum.uniq(
            for(path <- [folder(client, work_id)], is_binary(path), do: {path, "."}) ++
              [
                {Folders.path(home, work_id), "."},
                {Path.join([expanded, "workers", "work-" <> work_id]), "."},
                {Folders.real(expanded), "<runtime-home>"},
                {expanded, "<runtime-home>"}
              ]
          )

        {:ok,
         fn text ->
           Enum.reduce(prefixes, text, fn {from, to}, text -> String.replace(text, from, to) end)
         end}

      _ ->
        {:error, :not_found}
    end
  end

  # A folder work's folder, which only a client with choose_path can name; read, never sent.
  defp folder({_id, rights} = client, work_id) do
    with true <- :choose_path in rights,
         %F.Outcome.Found{work: %{request: %{workspace: %{path: path}}}} <-
           F.get_work(client, %{work_id: work_id}) do
      path
    else
      _ -> nil
    end
  end

  defp call({module, ref}, :report, input), do: module.report(ref, input)

  defp stop(reason, lease_id) do
    Logger.warning("upload #{lease_id}: stopped (#{inspect(reason)})")
    {:stopped, reason}
  end

  # The contract's structs as plain maps, nil fields dropped.
  defp plain(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()

  defp plain(%{} = map),
    do: for({k, v} <- map, v != nil, into: %{}, do: {k, plain(v)})

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value
end
