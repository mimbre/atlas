defmodule AtlasCode.GitTest do
  # Code's Git endpoint (AtlasCode.Git): a Runtime with its work source token fetches a base's
  # ref over Git's smart HTTP; without a valid token it gets nothing.
  use ExUnit.Case, async: false

  alias AtlasCode.Boundary
  alias AtlasCode.Boundary.Outcome

  setup {AtlasCode.TestDir, :tmp_dir}

  @client {"test:flow", [:snapshot]}
  @token "runtime-work-source-token"
  @env "ATLAS_CODE_GIT_TEST_CREDENTIALS"

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "app-source")
    git(dir, ["init", "-q", "-b", "develop", source])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "README.md"), "hello\n")
    File.write!(Path.join(source, "lib/app.ex"), "defmodule App, do: nil\n")
    # A package lockfile whose one dependency is a folder of the repository: npm ci, offline.
    File.mkdir_p!(Path.join(source, "dep"))
    File.mkdir_p!(Path.join(source, "web"))
    File.write!(Path.join(source, "dep/package.json"), ~s({"name":"dep","version":"1.0.0"}))
    File.write!(Path.join(source, "web/.gitignore"), "node_modules/\n")

    File.write!(
      Path.join(source, "web/package.json"),
      ~s({"name":"web","private":true,"dependencies":{"dep":"file:../dep"}})
    )

    File.write!(Path.join(source, "web/package-lock.json"), """
    {"name": "web", "lockfileVersion": 3, "requires": true, "packages": {
      "": {"name": "web", "dependencies": {"dep": "file:../dep"}},
      "../dep": {"version": "1.0.0"},
      "node_modules/dep": {"resolved": "../dep", "link": true}}}
    """)

    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "app"])
    remote = Path.join(dir, "app.git")
    git(dir, ["clone", "-q", "--bare", source, remote])

    home = Path.join(dir, "home")
    File.mkdir!(home)
    File.write!(Path.join(home, "runtime.token"), "code-token\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    config = %{"port" => 0, "repositories" => %{"github.com/test/app" => "file://" <> remote}}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    {:ok, pid, _port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)

    sha = Base.encode16(:crypto.hash(:sha256, @token), case: :lower)
    System.put_env(@env, JSON.encode!(%{"mini" => %{"holder" => "m", "token_sha256" => sha}}))
    on_exit(fn -> System.delete_env(@env) end)
    git = start_supervised!({AtlasCode.Git, %{"port" => 0, "credentials_env" => @env}})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(git)

    %{url: "http://127.0.0.1:#{port}", dir: dir}
  end

  test "a Runtime fetches a base's ref, its dependencies prepared, with its token and only with it",
       %{url: url, dir: dir} do
    base_id = "code-" <> snapshot()
    ref = "refs/atlas/bases/" <> base_id
    cache = Path.join(dir, "runtime.git")
    git(dir, ["init", "-q", "--bare", cache])
    fetch = ["--git-dir", cache, "fetch", "-q", "#{url}/bases/#{base_id}", "+#{ref}:#{ref}"]

    {_, 0} = System.cmd("git", fetch, env: header(@token), stderr_to_stdout: true)

    # The base's commit, and on it one commit that adds what npm ci installed.
    assert git(dir, ["--git-dir", cache, "rev-parse", ref <> "^"]) ==
             git(dir, ["-C", Path.join(dir, "app-source"), "rev-parse", "develop"])

    assert git(dir, ["--git-dir", cache, "diff", "--name-only", ref <> "^", ref]) ==
             "web/node_modules/.package-lock.json\nweb/node_modules/dep\n"

    assert git(dir, ["--git-dir", cache, "show", ref <> ":README.md"]) == "hello\n"

    for env <- [header("another-token"), [{"GIT_TERMINAL_PROMPT", "0"}]] do
      other = Path.join(dir, "other-#{System.unique_integer([:positive])}.git")
      git(dir, ["init", "-q", "--bare", other])
      args = ["--git-dir", other | Enum.drop(fetch, 2)]
      assert {_, status} = System.cmd("git", args, env: env, stderr_to_stdout: true)
      assert status != 0
    end
  end

  test "a Runtime pushes a result commit on the base under the ref Flow named", %{
    url: url,
    dir: dir
  } do
    base_id = "code-" <> snapshot()
    base = "refs/atlas/bases/" <> base_id
    cache = Path.join(dir, "runtime.git")
    git(dir, ["init", "-q", "--bare", cache])
    fetch = ["--git-dir", cache, "fetch", "-q", "--depth", "1", "#{url}/bases/#{base_id}"]
    {_, 0} = System.cmd("git", fetch ++ ["+#{base}:#{base}"], env: header(@token))

    blob = cache |> git_in(["hash-object", "-w", "--stdin"], "changed\n") |> String.trim()
    index = [{"GIT_INDEX_FILE", Path.join(dir, "index")}]
    git_in(cache, ["read-tree", base], "", index)
    git_in(cache, ["update-index", "--add", "--cacheinfo", "100644,#{blob},README.md"], "", index)
    tree = cache |> git_in(["write-tree"], "", index) |> String.trim()

    commit =
      cache |> git_in(["commit-tree", tree, "-p", base, "-m", "result"], "") |> String.trim()

    push = ["--git-dir", cache, "push", "-q", "#{url}/bases/#{base_id}"]
    result = "refs/atlas/results/TK-1"
    {_, 0} = System.cmd("git", push ++ ["#{commit}:#{result}"], env: header(@token))

    {:ok, code} = AtlasCode.Service.base_repository(AtlasCode.settings(), base_id)
    assert git(dir, ["--git-dir", code, "rev-parse", result]) == commit <> "\n"
    assert git(dir, ["--git-dir", code, "show", result <> ":README.md"]) == "changed\n"

    # The result resolves like a branch, so a review gets it as its base: its commit, and on
    # it the dependencies.
    reviewed = "code-" <> snapshot(result)
    ref = "refs/atlas/bases/" <> reviewed
    fetch = ["--git-dir", cache, "fetch", "-q", "#{url}/bases/#{reviewed}", "+#{ref}:#{ref}"]
    {_, 0} = System.cmd("git", fetch, env: header(@token), stderr_to_stdout: true)
    assert git(dir, ["--git-dir", cache, "rev-parse", ref <> "^"]) == commit <> "\n"
    assert git(dir, ["--git-dir", cache, "show", ref <> ":README.md"]) == "changed\n"
  end

  test "an update of a pull: develop merged into its head, conflicts marked; the result on it folds into one merge",
       %{url: url, dir: dir} do
    # The pull's head and develop change the README each their own way.
    source = Path.join(dir, "app-source")
    remote = Path.join(dir, "app.git")
    commit = ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qam"]
    git(source, ["checkout", "-q", "-b", "feature"])
    File.write!(Path.join(source, "README.md"), "pull\n")
    git(source, commit ++ ["pull"])
    git(source, ["checkout", "-q", "develop"])
    File.write!(Path.join(source, "README.md"), "develop\n")
    git(source, commit ++ ["develop"])
    git(source, ["push", "-q", remote, "develop", "feature:refs/pull/7/head"])
    head = source |> git(["rev-parse", "feature"]) |> String.trim()
    develop = source |> git(["rev-parse", "develop"]) |> String.trim()

    update = "refs/atlas/updates/7/develop"
    base_id = "code-" <> snapshot(update)
    base = "refs/atlas/bases/" <> base_id
    cache = Path.join(dir, "runtime.git")
    git(dir, ["init", "-q", "--bare", cache])
    fetch = ["--git-dir", cache, "fetch", "-q", "#{url}/bases/#{base_id}", "+#{base}:#{base}"]
    {_, 0} = System.cmd("git", fetch, env: header(@token), stderr_to_stdout: true)

    # The base's commit is the merge: the pull's head and develop, the conflict marked.
    merge = cache |> git_in(["rev-parse", base <> "^"], "") |> String.trim()
    assert git_in(cache, ["rev-parse", merge <> "^@"], "") == head <> "\n" <> develop <> "\n"
    readme = git_in(cache, ["show", merge <> ":README.md"], "")
    assert readme =~ "<<<<<<<" and readme =~ "pull" and readme =~ "develop"

    assert git_in(cache, ["log", "-1", "--format=%B", merge], "") =~
             ~r/\AAtlas: merge develop into pull #7\n\nConflicts:\n\tREADME.md/

    # Its agent resolves it; the Runtime pushes its result on the merge.
    blob = cache |> git_in(["hash-object", "-w", "--stdin"], "both\n") |> String.trim()
    index = [{"GIT_INDEX_FILE", Path.join(dir, "index")}]
    git_in(cache, ["read-tree", merge], "", index)
    git_in(cache, ["update-index", "--add", "--cacheinfo", "100644,#{blob},README.md"], "", index)
    tree = cache |> git_in(["write-tree"], "", index) |> String.trim()

    result =
      cache |> git_in(["commit-tree", tree, "-p", merge, "-m", "result"], "") |> String.trim()

    ref = "refs/atlas/results/TK-2"
    push = ["--git-dir", cache, "push", "-q", "#{url}/bases/#{base_id}"]
    {_, 0} = System.cmd("git", push ++ ["#{result}:#{ref}"], env: header(@token))

    # Published onto the pull: one merge commit, the result's tree on the pull's head and
    # develop, no commit with conflict markers; the result's ref names it, and it folds once.
    {:ok, code} = AtlasCode.Service.base_repository(AtlasCode.settings(), base_id)
    folded = AtlasCode.Effects.fold(code, result, ref)
    assert folded != result
    assert git_in(code, ["rev-parse", folded <> "^@"], "") == head <> "\n" <> develop <> "\n"
    assert git_in(code, ["show", folded <> ":README.md"], "") == "both\n"

    assert git_in(code, ["log", "-1", "--format=%s", folded], "") =~
             "Merge develop into pull #7"

    assert git_in(code, ["rev-parse", ref], "") == folded <> "\n"
    assert AtlasCode.Effects.fold(code, folded, ref) == folded
    assert AtlasCode.Effects.fold(code, result, ref) == folded
  end

  defp git_in(git_dir, args, input, env \\ []) do
    file = Path.join(System.tmp_dir!(), "git-in-#{System.unique_integer([:positive])}")
    File.write!(file, input)
    script = ~s(exec git --git-dir "$0" "$@" < "$GIT_IN")
    config = ["-c", "user.name=t", "-c", "user.email=t@t"]

    {output, 0} =
      System.cmd("sh", ["-c", script, git_dir | config ++ args], env: [{"GIT_IN", file} | env])

    output
  end

  defp header(token),
    do: [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.extraHeader"},
      {"GIT_CONFIG_VALUE_0", "Authorization: Bearer " <> token}
    ]

  # The hex of a snapshot of the repository's `reference` (develop, at `app`).
  defp snapshot(reference \\ "develop") do
    %Outcome.Resolved{revision: revision} =
      Boundary.resolve_reference(@client, %{
        "repository" => "github.com/test/app",
        "reference" => reference
      })

    repositories = [
      %{"repository" => "github.com/test/app", "revision" => revision, "path" => "app"}
    ]

    %Outcome.Created{snapshot_id: "sha256:" <> hex} =
      Boundary.create_snapshot(@client, %{"repositories" => repositories})

    hex
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
