defmodule AtlasRuntime.Boundary.HistoryFacadeTest do
  @moduledoc """
  The Runtime's history facade (`AtlasRuntime.Boundary.History`) on its implementation
  (`AtlasRuntime.History`, HR): the right and the input are checked by the facade, before
  the implementation is reached (§13.1 Q1, Q2), and the implementation cannot lose a
  capability. The history reads themselves are `test/history/`.
  """
  # The implementation reads the Runtime home from the application environment.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Boundary.History, as: F
  alias AtlasRuntimeBoundary.Generator.{InvalidInput, NotPermitted}

  @moduletag :tmp_dir

  @reader {"local:test", [:read]}
  @lib Path.expand("../../lib/atlas_runtime", __DIR__)

  test "both capabilities need read; read_all alone is not read" do
    assert %NotPermitted{capability: :list_turns, right: :read} =
             F.list_turns({"x", [:read_all]}, %{})

    assert %NotPermitted{capability: :get_turn, right: :read} =
             F.get_turn({"x", []}, %{turn_id: "t-1"})
  end

  test "a bad input is invalid input, before the skeleton" do
    assert %InvalidInput{capability: :list_turns} = F.list_turns(@reader, %{worker: "dev1"})
    assert %InvalidInput{capability: :get_turn} = F.get_turn(@reader, %{})
  end

  test "a valid input reaches the implementation", %{tmp_dir: dir} do
    previous = Application.get_env(:atlas_runtime, :runtime_home)
    Application.put_env(:atlas_runtime, :runtime_home, dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:atlas_runtime, :runtime_home, previous),
        else: Application.delete_env(:atlas_runtime, :runtime_home)
    end)

    # A home with no turns: an empty last page, and no such turn.
    assert %F.Outcome.Turns{turns: [], more: false} = F.list_turns(@reader, %{limit: 5})
    assert %F.Outcome.NotFound{} = F.get_turn(@reader, %{turn_id: "t-1"})
  end

  test "the implementation without a capability fails its own compilation", %{tmp_dir: dir} do
    source = File.read!(Path.join(@lib, "history.ex"))
    assert {_out, 0} = elixirc(dir, source)

    for name <- [:list_turns, :get_turn] do
      # The whole function: from its `@impl` to the `end` that closes it.
      dropped = Regex.replace(~r/\n  @impl true\n  def #{name}\(.*?\n  end\n/s, source, "\n")
      refute dropped == source
      assert {out, status} = elixirc(dir, dropped)
      assert status != 0
      assert out =~ "AtlasRuntime.History does not implement capability #{name}/2"
    end
  end

  defp elixirc(dir, source) do
    file = Path.join(dir, "history.ex")
    File.write!(file, source)
    out = Path.join(dir, "ebin")
    File.mkdir_p!(out)

    paths =
      Enum.flat_map(
        Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
        &["-pa", &1]
      )

    System.cmd(System.find_executable("elixirc"), paths ++ ["-o", out, file],
      cd: dir,
      stderr_to_stdout: true
    )
  end
end
