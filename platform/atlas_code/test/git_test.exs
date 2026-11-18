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

  test "a Runtime fetches a base's ref with its token, and only with it", %{url: url, dir: dir} do
    base_id = "code-" <> snapshot()
    ref = "refs/atlas/bases/" <> base_id
    cache = Path.join(dir, "runtime.git")
    git(dir, ["init", "-q", "--bare", cache])
    fetch = ["--git-dir", cache, "fetch", "-q", "#{url}/bases/#{base_id}", "+#{ref}:#{ref}"]

    {_, 0} = System.cmd("git", fetch, env: header(@token), stderr_to_stdout: true)

    assert git(dir, ["--git-dir", cache, "ls-tree", "-r", "--name-only", ref]) ==
             "README.md\nlib/app.ex\n"

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

  # The hex of a snapshot of the repository's develop at `app`.
  defp snapshot do
    %Outcome.Resolved{revision: revision} =
      Boundary.resolve_reference(@client, %{
        "repository" => "github.com/test/app",
        "reference" => "develop"
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
