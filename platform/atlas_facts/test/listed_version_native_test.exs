defmodule AtlasFacts.ListedVersionNativeTest do
  @moduledoc """
  IS-Atlas-84 against the pinned rela: its list answers carry no version, so a fact Facts
  loads at start has none; the first single read of it reads rela's version once, and an
  edit made on that version after someone else wrote the fact is refused (rela's 412).
  """
  use ExUnit.Case, async: false
  alias AtlasFacts.{Cache, Rela}
  @moduletag :tmp_dir
  # Needs rela-server-headless-sqlite and platform/atlas_facts/rela/scripts/config.py (Python with PyYAML).
  @moduletag :integration
  @root Path.expand("../../..", __DIR__)
  # rela's binaries, found as in guidance_native_test.exs.
  @bin Enum.find(
         [System.get_env("ATLAS_E2E_RELA_BIN"), System.get_env("ATLAS_RELA_BIN")],
         &(&1 not in [nil, ""])
       ) ||
         if(File.exists?(Path.join([@root, "../rela-bin", "rela-server-headless-sqlite"])),
           do: Path.join(@root, "../rela-bin"),
           else: Path.expand("~/.local/share/atlas/test/bin")
         )
  @moduletag skip: not File.exists?(Path.join(@bin, "rela-server-headless-sqlite"))

  defp start_rela(dir) do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"
    project = Path.join(@root, "products/software_factory/model/targets/rela")
    config = Path.join(@root, "platform/atlas_facts/rela/scripts/config.py")

    {output, code} =
      System.cmd(python, [config, "copy", "--root", project, "--data", dir],
        stderr_to_stdout: true
      )

    assert code == 0, output

    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)

    process =
      Port.open({:spawn_executable, Path.join(@bin, "rela-server-headless-sqlite")}, [
        :binary,
        :exit_status,
        args: ["-project", dir, "-bind", "127.0.0.1", "-port", to_string(port), "-quiet"]
      ])

    {:os_pid, pid} = Port.info(process, :os_pid)
    on_exit(fn -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true) end)
    rela = {Rela.Http, "http://127.0.0.1:#{port}/api/v1"}
    wait(rela, 100)
    rela
  end

  defp wait(rela, remaining) do
    case Rela.description(rela) do
      {:ok, _} ->
        :ok

      _ when remaining > 0 ->
        Process.sleep(20)
        wait(rela, remaining - 1)

      other ->
        flunk("private rela failed to start: #{inspect(other)}")
    end
  end

  test "a stale edit of a fact loaded at start is refused", %{tmp_dir: dir} do
    assert {"rela version 26.11.9\n", 0} = System.cmd(Path.join(@bin, "rela"), ["version"])
    rela = start_rela(dir)
    {:ok, description} = Rela.description(rela)

    extra =
      @root
      |> Path.join("products/software_factory/model/targets/rela/atlas.json")
      |> File.read!()
      |> JSON.decode!()

    # A kind with one plain required field: the worker a turn is by.
    turn = extra["runtime"]["turn"]
    [kind] = description["relations"][turn["by"]]["to"]
    %{"plural" => plural, "primary" => primary} = description["entities"][kind]

    assert {:ok, []} = Rela.create(rela, plural, "listed-worker", %{primary => "Listed"}, %{})

    # Facts starts: the fact is listed, without a version.
    cache = Cache.open(rela)
    assert :ok = Cache.load(cache, description)
    assert {:ok, listed} = Rela.list(rela, plural)
    assert %{version: nil} = Enum.find(listed, &(&1.key == "listed-worker"))

    # Its first single read finds none and reads rela's.
    assert {:ok, %{version: version}} = Rela.get(cache, plural, "listed-worker")
    assert is_binary(version)

    # Someone saves on it; an edit made on the same read is then refused.
    assert {:ok, []} =
             Rela.change(cache, plural, "listed-worker", %{primary => "First"}, version, %{})

    assert {:error, :version_mismatch} =
             Rela.change(cache, plural, "listed-worker", %{primary => "Stale"}, version, %{})

    assert {:ok, %{properties: %{^primary => "First"}}} =
             Rela.get(rela, plural, "listed-worker")
  end
end
