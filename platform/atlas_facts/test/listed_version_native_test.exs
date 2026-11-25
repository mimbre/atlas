defmodule AtlasFacts.ListedVersionNativeTest do
  @moduledoc """
  IS-Atlas-84 against the pinned rela: its list answers carry no version, so a fact Facts
  loads at start has none; the first single read of it reads rela's version once, and an
  edit made on that version after someone else wrote the fact is refused (rela's 412).
  """
  use ExUnit.Case, async: false
  alias AtlasFacts.{Cache, NativeRela, Rela}
  @moduletag :tmp_dir
  # Needs rela-server-headless-sqlite and platform/atlas_facts/rela/scripts/config.py (Python with PyYAML).
  @moduletag :integration
  @root NativeRela.root()
  @bin NativeRela.bin()
  @moduletag skip: not NativeRela.available?()

  defp start_rela(dir) do
    python = System.get_env("ATLAS_CONFIG_PYTHON") || "python3"
    project = Path.join(@root, "products/software_factory/model/targets/rela")
    config = Path.join(@root, "platform/atlas_facts/rela/scripts/config.py")

    {output, code} =
      System.cmd(python, [config, "copy", "--root", project, "--data", dir],
        stderr_to_stdout: true
      )

    assert code == 0, output

    {rela, _pid, _process} = NativeRela.start(dir)
    rela
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
