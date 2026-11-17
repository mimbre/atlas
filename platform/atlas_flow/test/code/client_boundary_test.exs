defmodule AtlasFlow.Code.ClientBoundaryTest do
  @moduledoc """
  F1.5a: Flow's Code client (`AtlasFlow.Code.Client.Boundary`) against a real Code: a
  temporary home with a local bare repository, started with `register: true`, reached
  through Code's facade `AtlasCode.Boundary` in this BEAM. A task's input gives the
  snapshot of its branch's current revision at its root; a moved branch gives a new one;
  a refusal and no Code at all are told apart. Not async: one Code instance holds the
  registered name at a time.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Code.Client.Boundary, as: C

  @repository "github.com/flow-code/app"

  setup_all do
    # Git here never reads the user's or the system's configuration (as Code's own tests).
    config = Path.join(System.tmp_dir!(), "atlas-flow-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(config)
    File.write!(Path.join(config, "gitconfig"), "[init]\n\ttemplateDir =\n")
    vars = ~w(GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM XDG_CONFIG_HOME)
    saved = Map.new(vars, &{&1, System.get_env(&1)})
    System.put_env("GIT_CONFIG_GLOBAL", Path.join(config, "gitconfig"))
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")
    System.put_env("XDG_CONFIG_HOME", config)

    on_exit(fn ->
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
      File.rm_rf!(config)
    end)

    :ok
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "atlas-flow-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    source = Path.join(dir, "app-source")
    git(dir, ["init", "-q", "-b", "develop", source])
    commit(source, %{"README.md" => "hello\n", "bin/check" => "#!/bin/sh\n"})
    remote = Path.join(dir, "app.git")
    git(dir, ["clone", "-q", "--bare", source, remote])

    home = Path.join(dir, "home")
    File.mkdir!(home)

    File.write!(
      Path.join(home, "config.json"),
      JSON.encode!(%{"port" => 0, "repositories" => %{@repository => "file://" <> remote}})
    )

    File.write!(Path.join(home, "runtime.token"), "flow-code-test-token\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    {:ok, pid, _port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)
    %{dir: dir, home: home, pid: pid, source: source, remote: remote}
  end

  defp input(base \\ "develop"), do: %{"code" => @repository, "base" => base, "root" => "app"}

  test "the base is Code's snapshot of the branch's current revision, at the root", c do
    assert {:ok, "sha256:" <> hex = snapshot_id} = C.base(input())
    assert hex =~ ~r/\A[0-9a-f]{64}\z/

    # The snapshot Code recorded is that one revision of the repository, placed at the root.
    manifest = JSON.decode!(File.read!(Path.join([c.home, "snapshots", hex <> ".json"])))
    assert [%{"repository" => @repository, "path" => "app"}] = manifest["repositories"]
    paths = for e <- manifest["entries"], do: e["path"]
    assert "app/README.md" in paths and "app/bin/check" in paths

    # The same revision is the same snapshot; a moved branch is a new one.
    assert C.base(input()) == {:ok, snapshot_id}
    commit(c.source, %{"NEW.md" => "new\n"})
    git(c.source, ["push", "-q", c.remote, "develop"])
    assert {:ok, moved} = C.base(input())
    assert moved != snapshot_id
  end

  test "a refusal is named after Code's outcome" do
    assert C.base(input("missing")) == {:refused, :unknown_reference}
    assert C.base(%{input() | "code" => "github.com/flow-code/other"}) == {:refused, :forbidden}
  end

  test "without a registered Code, the base is unavailable", c do
    :ok = AtlasCode.stop(c.pid)
    assert {:unavailable, message} = C.base(input())
    assert message =~ "No Code instance is registered"
  end

  defp commit(source, files) do
    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
