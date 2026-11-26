defmodule AtlasCode.Dependencies do
  @moduledoc """
  A base's dependencies, prepared on the server, which has the network the Runtime and its
  agents have not.

  `prepared/2` answers the commit Code serves for a base commit: a child of it that adds what
  its lockfiles fetch. Per lockfile in the base, in the lockfile's folder:
  - `mix.lock`: `mix deps.get` (the sources under `deps/`);
  - `package-lock.json`: `npm ci --ignore-scripts` (`node_modules/`, nothing built).

  A lockfile named in `from` (`%{path => commit}`) is prepared from that commit's version of
  it instead: Code's update merge passes the lockfiles it conflicts in with develop, whose
  conflict markers no `mix deps.get` or `npm ci` takes, so they are prepared from develop's
  (IS-Atlas-132). The base keeps the conflicted one; its agent regenerates it. A lockfile the
  other commit does not have is not prepared.

  The `mix.lock` preparations share a Hex home of their own, outside the copy of the base, so
  its registry cache holds exactly the Hex registry entries of the base's locked packages. It
  is added as `.atlas/hex/cache.ets` (`hex_registry/0`): an agent's `bin/check` resolves Hex
  offline against it, so a package the base pins resolves on a machine whose own Hex cache
  never saw it (IS-Atlas-13). The server's Hex configuration and package cache are used, never
  added.

  Every file a preparation adds (ignored or not) is kept as a tree under
  `refs/atlas/dependencies/<key>`, the key the lockfiles' paths and contents and what a
  preparation adds (`@preparation`): a base with the same lockfiles reuses it, so the work is
  done again only when a lockfile changes. The prepared commit has a fixed author, committer
  and date, so a base always gives the same one.
  """

  @lockfiles ["mix.lock", "package-lock.json"]

  # What a preparation adds besides the lockfiles' fetches; part of the key, so a tree prepared
  # before the Hex registry was added is prepared again.
  @preparation "hex-registry"

  @identity [
    {"GIT_AUTHOR_NAME", "Atlas Code"},
    {"GIT_AUTHOR_EMAIL", "code@atlas"},
    {"GIT_AUTHOR_DATE", "1970-01-01T00:00:00Z"},
    {"GIT_COMMITTER_NAME", "Atlas Code"},
    {"GIT_COMMITTER_EMAIL", "code@atlas"},
    {"GIT_COMMITTER_DATE", "1970-01-01T00:00:00Z"}
  ]

  @doc "Where a prepared base carries the Hex registry entries of its locked packages."
  def hex_registry, do: ".atlas/hex/cache.ets"

  @doc """
  The commit on `commit` (in the Git directory `dir`) that adds the base's dependencies, its
  lockfiles named in `from` prepared from the commit `from` gives them.
  """
  @spec prepared(Path.t(), String.t(), %{String.t() => String.t()}) :: String.t()
  def prepared(dir, commit, from \\ %{}) do
    lockfiles =
      for {line, path} <- listing(dir, commit),
          Path.basename(path) in @lockfiles,
          {line, _} <-
            if(other = from[path], do: listing(dir, other, path), else: [{line, path}]),
          do: {line, path}

    key =
      :crypto.hash(:sha256, [@preparation | Enum.map(lockfiles, &elem(&1, 0))])
      |> Base.encode16(case: :lower)

    ref = "refs/atlas/dependencies/" <> key

    dependencies =
      case System.cmd("git", ["--git-dir", dir, "rev-parse", "--verify", "-q", ref]) do
        {oid, 0} -> String.trim(oid)
        _ -> prepare(dir, commit, lockfiles, ref)
      end

    git(dir, nil, fn git ->
      # Both trees into one index: the base's files and the dependencies beside them.
      git.(["read-tree", commit, dependencies])
      tree = git.(["write-tree"])
      git.(["commit-tree", tree, "-p", commit, "-m", "Atlas: the base's dependencies"])
    end)
  end

  # `ls-tree` lines of `commit` (of `path` only, when given), each with its path.
  defp listing(dir, commit, path \\ nil) do
    paths = if path, do: ["--", path], else: []
    args = ["--git-dir", dir, "ls-tree", "-r", "--full-tree", commit | paths]
    {listing, 0} = System.cmd("git", args, env: [{"GIT_LITERAL_PATHSPECS", "1"}])

    for line <- String.split(listing, "\n", trim: true),
        [_meta, path] = String.split(line, "\t", parts: 2),
        do: {line, path}
  end

  # The lockfiles' preparation in a copy of the base, each lockfile as its `ls-tree` line has
  # it (another commit's version, from `prepared/3`'s `from`); the files it added become the
  # tree of a commit under `ref`.
  defp prepare(dir, commit, lockfiles, ref) do
    unique = System.unique_integer([:positive])
    work = Path.join(System.tmp_dir!(), "atlas-dependencies-#{unique}")
    hex_home = Path.join(System.tmp_dir!(), "atlas-dependencies-hex-#{unique}")
    File.mkdir_p!(work)

    try do
      hex = hex_home(hex_home)
      script = ~s(git --git-dir "$1" archive "$2" | tar -x -C "$3")
      {_, 0} = System.cmd("sh", ["-c", script, "sh", dir, commit, work], stderr_to_stdout: true)

      for {line, path} <- lockfiles do
        [_mode, "blob", blob | _] = String.split(line, [" ", "\t"])
        {bytes, 0} = System.cmd("git", ["--git-dir", dir, "cat-file", "blob", blob])
        File.write!(Path.join(work, path), bytes)

        {command, args} =
          case Path.basename(path) do
            "mix.lock" -> {"mix", ["deps.get"]}
            "package-lock.json" -> {"npm", ["ci", "--ignore-scripts", "--no-audit", "--no-fund"]}
          end

        {_, 0} =
          System.cmd(command, args,
            cd: Path.join(work, Path.dirname(path)),
            env: outside_release() ++ hex,
            stderr_to_stdout: true
          )
      end

      registry = Path.join(hex_home, "cache.ets")

      if File.exists?(registry) do
        File.mkdir_p!(Path.dirname(Path.join(work, hex_registry())))
        File.cp!(registry, Path.join(work, hex_registry()))
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
      File.rm_rf!(hex_home)
    end
  end

  # A Hex home of its own (HEX_HOME), so its registry cache gets only what the base's
  # lockfiles resolve: the server's Hex configuration (hex.config: mirrors, repositories) is
  # copied in and its package cache linked, so the server fetches no package twice.
  defp hex_home(dir) do
    File.mkdir_p!(dir)
    server = System.get_env("HEX_HOME") || Path.expand("~/.hex")
    config = Path.join(server, "hex.config")
    if File.regular?(config), do: File.cp!(config, Path.join(dir, "hex.config"))
    packages = Path.join(server, "packages")
    if File.dir?(packages), do: File.ln_s!(packages, Path.join(dir, "packages"))
    [{"HEX_HOME", dir}]
  end

  # mix and npm run as tools of their own, not inside this release: the release's own
  # variables (its boot script, root and bin dirs) and its erts on PATH would make `mix` boot
  # the release.
  defp outside_release do
    release = System.get_env("ROOTDIR")

    path =
      (System.get_env("PATH") || "")
      |> String.split(":")
      |> Enum.reject(&(is_binary(release) and String.starts_with?(&1, release)))
      |> Enum.join(":")

    unset =
      for {name, _} <- System.get_env(),
          String.starts_with?(name, "RELEASE_") or name in ~w(ROOTDIR BINDIR EMU PROGNAME),
          do: {name, nil}

    [{"PATH", path} | unset]
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
