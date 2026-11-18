defmodule AtlasRuntimeBoundary.FacadesTest do
  # The operations and history contracts compile into a facade and a behaviour, here on
  # their skeletons (test/support). A skeleton missing a capability, or with another arity,
  # fails compilation, also when only the skeleton recompiles; struct literals are checked
  # at compile time; the facade checks the right and the input before it calls a skeleton.
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.{InvalidInput, NotPermitted}
  alias AtlasRuntimeBoundary.Test.{HistoryFacade, NotImplemented, OperationsFacade}

  @moduletag :tmp_dir

  @support Path.expand("support", __DIR__)

  @operator {"local:test", [:inspect, :operate]}
  @inspector {"remote:test", [:inspect]}

  describe "the behaviours" do
    test "one callback per capability, with its arity" do
      for {facade, contract} <- [
            {OperationsFacade, AtlasRuntimeBoundary.Operations},
            {HistoryFacade, AtlasRuntimeBoundary.History}
          ] do
        expected =
          for c <- contract.__schema__().capabilities,
              do: {c.name, if(c.input, do: 2, else: 1)}

        behaviour = Module.concat(facade, Implementation)
        assert Enum.sort(behaviour.behaviour_info(:callbacks)) == Enum.sort(expected)
      end
    end
  end

  describe "the operations facade" do
    test "needs operate to change the Runtime, before it reads the input" do
      for call <- [
            fn c -> OperationsFacade.pause(c) end,
            fn c -> OperationsFacade.resume(c) end,
            fn c -> OperationsFacade.drain(c) end,
            fn c -> OperationsFacade.stop(c, %{"force" => "not a boolean"}) end,
            fn c -> OperationsFacade.release_slot(c, %{}) end,
            fn c -> OperationsFacade.clear_quota_mark(c, %{"harness" => "claude"}) end
          ] do
        assert %NotPermitted{right: :operate} = call.(@inspector)
      end
    end

    test "inspect is enough to inspect" do
      assert_raise NotImplemented, ~r/runtime_info/, fn ->
        OperationsFacade.runtime_info(@inspector)
      end

      assert_raise NotImplemented, ~r/policy/, fn -> OperationsFacade.policy(@inspector) end

      assert %NotPermitted{right: :inspect} = OperationsFacade.runtime_info({"x", [:operate]})
    end

    test "an invalid release input is refused as invalid; the skeleton is not reached" do
      assert %OperationsFacade.Outcome.Refused{reason: :invalid, detail: detail} =
               OperationsFacade.release_slot(@operator, %{"slot" => "dev1", "worker" => "dev1"})

      # An unknown key is named generically, never repeated (D44).
      assert detail =~ "input has an unknown field"

      assert %InvalidInput{capability: :stop} =
               OperationsFacade.stop(@operator, %{"force" => "yes"})
    end

    test "a valid input reaches the skeleton, which answers nothing untrue" do
      assert_raise NotImplemented, ~r/release_slot/, fn ->
        OperationsFacade.release_slot(@operator, %{"slot" => "dev1"})
      end

      assert_raise NotImplemented, ~r/stop/, fn -> OperationsFacade.stop(@operator, %{}) end
    end
  end

  describe "the history facade" do
    test "needs read, and checks the input before the skeleton" do
      assert %NotPermitted{right: :read} = HistoryFacade.get_turn({"x", [:inspect]}, %{})

      assert %InvalidInput{capability: :list_turns} =
               HistoryFacade.list_turns({"x", [:read]}, %{"worker" => "dev1"})

      assert_raise NotImplemented, ~r/get_turn/, fn ->
        HistoryFacade.get_turn({"x", [:read]}, %{"turn_id" => "t-1"})
      end
    end
  end

  describe "struct literals" do
    test "an unknown field, or a missing required one, fails compilation" do
      assert_raise KeyError, ~r/key :mod not found/, fn ->
        literal("%AtlasRuntimeBoundary.Test.OperationsFacade.RuntimeInfo{mod: :open}")
      end

      assert_raise ArgumentError, ~r/the following keys must also be given.*:incarnation/, fn ->
        literal("""
        %AtlasRuntimeBoundary.Test.OperationsFacade.RuntimeInfo{
          runtime_build: "b", mode: :open, policy_version: 1, slots: []}
        """)
      end

      assert_raise KeyError, ~r/key :worker not found/, fn ->
        literal("%AtlasRuntimeBoundary.Test.HistoryFacade.Turn{turn_id: \"t\", worker: \"w\"}")
      end
    end
  end

  # Each case compiles in an `elixirc` of its own, as a project would, without
  # --warnings-as-errors, against this project's build.
  describe "a skeleton that misses a capability" do
    test "fails its own compilation when only it recompiles (incremental)", %{tmp_dir: dir} do
      source = drop_capability(read_support("operations_skeleton.ex"), "stop")
      assert {out, status} = elixirc(dir, %{"operations_skeleton.ex" => source})
      assert status != 0

      assert out =~
               "AtlasRuntimeBoundary.Test.OperationsSkeleton does not implement capability stop/2"

      source = drop_capability(read_support("history_skeleton.ex"), "get_turn")
      assert {out, status} = elixirc(dir, %{"history_skeleton.ex" => source})
      assert status != 0

      assert out =~
               "AtlasRuntimeBoundary.Test.HistorySkeleton does not implement capability get_turn/2"
    end

    test "with another arity fails compilation", %{tmp_dir: dir} do
      source =
        String.replace(
          read_support("operations_skeleton.ex"),
          "def pause(_client), do:",
          "def pause(_client, _extra), do:"
        )

      assert {out, status} = elixirc(dir, %{"operations_skeleton.ex" => source})
      assert status != 0
      assert out =~ "does not implement capability pause/1 (it has pause/2)"
    end

    test "the unchanged skeletons compile", %{tmp_dir: dir} do
      assert {_out, 0} =
               elixirc(dir, %{
                 "operations_skeleton.ex" => read_support("operations_skeleton.ex"),
                 "history_skeleton.ex" => read_support("history_skeleton.ex")
               })
    end
  end

  defp read_support(file), do: File.read!(Path.join(@support, file))

  # The source without the capability's @impl and def.
  defp drop_capability(source, name) do
    dropped = Regex.replace(~r/\n  @impl true\n  def #{name}\(.*\n/, source, "\n")
    refute dropped == source, "no capability #{name} to drop"
    dropped
  end

  defp elixirc(dir, files) do
    for {name, body} <- files, do: File.write!(Path.join(dir, name), body)
    out = Path.join(dir, "ebin")
    File.mkdir_p!(out)

    paths =
      Enum.flat_map(
        Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin")),
        &["-pa", &1]
      )

    System.cmd(
      System.find_executable("elixirc"),
      paths ++ ["-o", out | Map.keys(files)],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  defp literal(expression) do
    Code.compile_string("""
    defmodule Literal#{System.unique_integer([:positive])} do
      def f, do: #{expression}
    end
    """)
  end
end
