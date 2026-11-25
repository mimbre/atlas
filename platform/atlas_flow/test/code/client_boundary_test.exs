defmodule AtlasFlow.Code.ClientBoundaryTest do
  # The adapter on Code's facade against a real Code: a home of its own with a local bare
  # repository, registered in this BEAM. Flow depends on Code with `runtime: false`, so the
  # test starts Code itself. Not async: one Code instance holds the registered name.
  use ExUnit.Case, async: false

  alias AtlasFlow.Bases
  alias AtlasFlow.Code.Client

  @client {AtlasFlow.Code.Client.Boundary, {"flow", [:snapshot]}}
  @repository "github.com/test/app"
  @chunk 64 * 1024
  @large_size 3 * @chunk + 4_321

  setup_all do
    # Git here reads no configuration of the user's or the system's, as in Code's tests.
    dir = Path.join(System.tmp_dir!(), "atlas-flow-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gitconfig"), "[init]\n\ttemplateDir =\n")
    keys = ~w(GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM XDG_CONFIG_HOME)
    saved = Map.new(keys, &{&1, System.get_env(&1)})

    System.put_env(%{
      "GIT_CONFIG_GLOBAL" => Path.join(dir, "gitconfig"),
      "GIT_CONFIG_NOSYSTEM" => "1",
      "XDG_CONFIG_HOME" => dir
    })

    {:ok, _} = Application.ensure_all_started(:atlas_code)

    on_exit(fn ->
      for {key, value} <- saved,
          do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

      File.rm_rf!(dir)
    end)

    %{dir: dir}
  end

  setup %{dir: dir} do
    dir = Path.join(dir, "case-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    large = :crypto.strong_rand_bytes(@large_size)
    remote = bare(dir, %{"README.md" => "hello\n", "data/large.bin" => large})

    home = Path.join(dir, "home")
    File.mkdir_p!(home)
    # Code's HTTP routes need a token; this test calls only the facade.
    File.write!(Path.join(home, "runtime.token"), "token\n")
    File.chmod!(Path.join(home, "runtime.token"), 0o600)
    config = %{"port" => 0, "repositories" => %{@repository => "file://" <> remote}}
    File.write!(Path.join(home, "config.json"), JSON.encode!(config))
    {:ok, pid, _port} = AtlasCode.start(home, register: true)
    on_exit(fn -> AtlasCode.stop(pid) end)

    %{large: large, code: pid, remote: remote, dir: dir}
  end

  test "resolve, snapshot, manifest, and a blob streamed in chunks", %{large: large} do
    assert {:ok, revision} = Client.resolve_reference(@client, @repository, "develop")
    assert {:error, :unknown_reference} = Client.resolve_reference(@client, @repository, "none")

    placement = %{repository: @repository, revision: revision, path: "app"}
    assert {:ok, "sha256:" <> _ = snapshot_id} = Client.create_snapshot(@client, [placement])
    assert {:ok, ^snapshot_id} = Client.create_snapshot(@client, [placement])

    assert {:ok, entries} = Client.get_manifest(@client, snapshot_id)
    assert Enum.map(entries, & &1.path) == ["app/README.md", "app/data/large.bin"]

    assert Enum.all?(
             entries,
             &match?(%{repository: @repository, kind: "file", mode: "100644"}, &1)
           )

    entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))
    assert {:ok, @large_size, content} = Client.get_blob(@client, snapshot_id, entry.sha256)
    refute is_binary(content) or is_list(content)
    sizes = content |> Enum.map(&byte_size/1)
    assert length(sizes) > 1 and Enum.max(sizes) <= @chunk
    assert Enum.join(content) == large

    unknown = String.duplicate("0", 64)
    assert {:error, :not_found} = Client.get_blob(@client, snapshot_id, unknown)
    assert {:error, :not_found} = Client.get_manifest(@client, "sha256:" <> unknown)

    assert {:error, :not_permitted} =
             Client.get_manifest({AtlasFlow.Code.Client.Boundary, {"flow", []}}, snapshot_id)
  end

  test "a base from the real Code: its names and its blobs", %{large: large} do
    assert {:ok, %{base_id: "code-" <> hex, manifest: manifest, snapshot_id: snapshot_id}} =
             Bases.for(@client, @repository, "develop")

    assert snapshot_id == "sha256:" <> hex
    {:ok, entries} = Client.get_manifest(@client, snapshot_id)

    name = :"bases_#{System.unique_integer([:positive])}"
    start_supervised!({Bases, name: name, client: @client})
    :ok = Bases.request(@repository, "develop", {self(), :ready}, name)
    assert_receive :ready, 10_000
    assert {:ok, %{manifest: ^manifest}} = Bases.cached(@repository, "develop", name)

    assert Bases.names(manifest, name) ==
             {:ok, MapSet.new([manifest | Enum.map(entries, & &1.sha256)])}

    large_entry = Enum.find(entries, &(&1.path == "app/data/large.bin"))
    assert {:ok, @large_size, stream} = Bases.blob(large_entry.sha256, snapshot_id, name)
    assert Enum.join(stream) == large
  end

  test "no Code registered: unavailable", %{code: pid} do
    :ok = AtlasCode.stop(pid)
    assert {:error, :unavailable} = Client.resolve_reference(@client, @repository, "develop")
  end

  # A local bare repository with one commit of `files` on develop: Code's remote.
  defp bare(dir, files) do
    source = Path.join(dir, "source")
    git(dir, ["init", "-q", "-b", "develop", source])

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(source, path)))
      File.write!(Path.join(source, path), content)
    end

    git(source, ["add", "-A"])
    git(source, ["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base"])
    remote = Path.join(dir, "app.git")
    git(dir, ["clone", "-q", "--bare", source, remote])
    remote
  end

  defp git(dir, args) do
    {output, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    output
  end
end
