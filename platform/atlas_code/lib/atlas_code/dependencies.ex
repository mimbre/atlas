defmodule AtlasCode.Dependencies do
  @moduledoc """
  A base's dependencies, prepared on the server, which has the network the Runtime and its
  agents have not.

  `prepared/2` answers the commit Code serves for a base commit: a child of it that adds what
  its lockfiles fetch. Per lockfile in the base, in the lockfile's folder:
  - `mix.lock`: `mix deps.get` (the sources under `deps/`);
  - `package-lock.json`: `npm ci --ignore-scripts` (`node_modules/`, nothing built).

  Every file a preparation adds (ignored or not) is kept as a tree under
  `refs/atlas/dependencies/<key>`, the key the lockfiles' paths and contents: a base with the
  same lockfiles reuses it, so the work is done again only when a lockfile changes. The
  prepared commit has a fixed author, committer and date, so a base always gives the same one.
  """

  @lockfiles ["mix.lock", "package-lock.json"]
  @identity [
    {"GIT_AUTHOR_NAME", "Atlas Code"},
    {"GIT_AUTHOR_EMAIL", "code@atlas"},
    {"GIT_AUTHOR_DATE", "1970-01-01T00:00:00Z"},
    {"GIT_COMMITTER_NAME", "Atlas Code"},
    {"GIT_COMMITTER_EMAIL", "code@atlas"},
    {"GIT_COMMITTER_DATE", "1970-01-01T00:00:00Z"}
  ]

  @doc "The commit on `commit` (in the Git directory `dir`) that adds the base's dependencies."
  @spec prepared(Path.t(), String.t()) :: String.t()
  def prepared(dir, commit) do
    {listing, 0} = System.cmd("git", ["--git-dir", dir, "ls-tree", "-r", "--full-tree", commit])

    lockfiles =
      for line <- String.split(listing, "\n", trim: true),
          [_meta, path] = String.split(line, "\t", parts: 2),
          Path.basename(path) in @lockfiles,
          do: {line, path}

    key = :crypto.hash(:sha256, Enum.map(lockfiles, &elem(&1, 0))) |> Base.encode16(case: :lower)
    ref = "refs/atlas/dependencies/" <> key

    dependencies =
      case System.cmd("git", ["--git-dir", dir, "rev-parse", "--verify", "-q", ref]) do
        {oid, 0} -> String.trim(oid)
        _ -> prepare(dir, commit, Enum.map(lockfiles, &elem(&1, 1)), ref)
      end

    git(dir, nil, fn git ->
      # Both trees into one index: the base's files and the dependencies beside them.
      git.(["read-tree", commit, dependencies])
      tree = git.(["write-tree"])
      git.(["commit-tree", tree, "-p", commit, "-m", "Atlas: the base's dependencies"])
    end)
  end

  # The lockfiles' preparation in a copy of the base; the files it added become the tree of a
  # commit under `ref`.
  defp prepare(dir, commit, lockfiles, ref) do
    work =
      Path.join(System.tmp_dir!(), "atlas-dependencies-#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)

    try do
      script = ~s(git --git-dir "$1" archive "$2" | tar -x -C "$3")
      {_, 0} = System.cmd("sh", ["-c", script, "sh", dir, commit, work], stderr_to_stdout: true)

      for path <- lockfiles do
        {command, args} =
          case Path.basename(path) do
            "mix.lock" -> {"mix", ["deps.get"]}
            "package-lock.json" -> {"npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"]}
          end

        {_, 0} =
          System.cmd(command, args,
            cd: Path.join(work, Path.dirname(path)),
            stderr_to_stdout: true
          )
      end

      git(dir, work, fn git ->
        git.(["read-tree", commit])
        added = Path.join(work, ".atlas-added")
        File.write!(added, git.(["ls-files", "-z", "--others"]))
        git.(["read-tree", "--empty"])
        git.(["add", "--force", "--pathspec-from-file=" <> added, "--pathspec-file-nul"])
        tree = git.(["write-tree"])
        dependencies = git.(["commit-tree", tree, "-m", "Atlas: dependencies"])
        git.(["update-ref", ref, dependencies])
        dependencies
      end)
    after
      File.rm_rf!(work)
    end
  end

  # Git in `dir` (with `work` its work tree, or none) and an index of its own; each call
  # answers its output, trimmed.
  defp git(dir, work, fun) do
    index = Path.join(System.tmp_dir!(), "atlas-index-#{System.unique_integer([:positive])}")
    env = [{"GIT_DIR", dir}, {"GIT_INDEX_FILE", index}, {"GIT_LITERAL_PATHSPECS", "1"}]
    env = if work, do: [{"GIT_WORK_TREE", work} | env], else: env
    options = [env: env ++ @identity, stderr_to_stdout: true]
    options = if work, do: [{:cd, work} | options], else: options

    try do
      fun.(fn args ->
        {out, 0} = System.cmd("git", args, options)
        String.trim(out)
      end)
    after
      File.rm(index)
    end
  end
end
