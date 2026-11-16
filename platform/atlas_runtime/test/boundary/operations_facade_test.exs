defmodule AtlasRuntime.Boundary.OperationsFacadeTest do
  @moduledoc """
  The Runtime's operations facade (`AtlasRuntime.Boundary.Operations`) on its skeleton
  (`AtlasRuntime.Operations`): refusals come from the facade for every capability, before
  the implementation runs (§13.1 Q4); an undeclared answer is a contract error; the
  skeleton cannot lose a capability; and the persisted mode translates into runtime info
  one way (Q6).
  """
  use ExUnit.Case, async: true

  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntime.Model.RuntimeMode.RuntimeMode
  alias AtlasRuntimeBoundary.Generator.{ContractError, InvalidInput, NotPermitted}

  @moduletag :tmp_dir

  @operator {"local:test", [:inspect, :operate]}
  @lib Path.expand("../../lib/atlas_runtime", __DIR__)

  # The skeleton raises when it is reached, so an answer here is the facade's own.
  describe "a missing right" do
    test "pause needs operate: inspect alone is not permitted" do
      assert %NotPermitted{capability: :pause, right: :operate} = F.pause({"x", [:inspect]})
    end

    test "runtime_info needs inspect: operate alone is not permitted" do
      assert %NotPermitted{capability: :runtime_info, right: :inspect} =
               F.runtime_info({"x", [:operate]})
    end

    test "every capability checks its right before its input" do
      for {call, right} <- [
            {&F.runtime_info/1, :inspect},
            {&F.policy/1, :inspect},
            {&F.pause/1, :operate},
            {&F.resume/1, :operate},
            {&F.drain/1, :operate},
            {&F.stop(&1, %{"force" => "yes"}), :operate},
            {&F.release_slot(&1, %{}), :operate},
            {&F.clear_quota_mark(&1, %{}), :operate}
          ] do
        assert %NotPermitted{right: ^right} = call.({"x", []})
      end
    end
  end

  describe "a bad input" do
    # stop declares no refused outcome, so the facade's InvalidInput answers.
    test "stop with a force that is no boolean is invalid input" do
      assert %InvalidInput{capability: :stop, reasons: [_ | _]} =
               F.stop(@operator, %{force: "yes"})
    end

    # release_slot declares refused, the contract's invalid_input outcome.
    test "release_slot with a slot that is no string is refused as invalid" do
      assert %F.Outcome.Refused{reason: :invalid, detail: detail} =
               F.release_slot(@operator, %{slot: 1})

      assert detail =~ "slot"
    end

    # Through a test implementation: the real stop would stop this Runtime (O1).
    test "a valid input reaches the implementation" do
      facade = facade_on(fn -> raise "reached" end)
      assert_raise RuntimeError, "reached", fn -> facade.stop(@operator, %{force: true}) end

      assert_raise RuntimeError, "reached", fn ->
        facade.release_slot(@operator, %{slot: "dev1"})
      end
    end
  end

  describe "an undeclared outcome" do
    test "a bare map instead of the runtime_info struct is a contract error" do
      facade = facade_on(fn -> {:runtime_info, %{}} end)

      assert_raise ContractError, ~r/none of the declared outcomes/, fn ->
        facade.runtime_info(@operator)
      end
    end
  end

  # Each case compiles the skeleton in an `elixirc` of its own, against this build, as
  # an incremental compile of that one file would.
  describe "the skeleton" do
    test "compiles unchanged", %{tmp_dir: dir} do
      assert {_out, 0} = elixirc(dir, File.read!(Path.join(@lib, "operations.ex")))
    end

    test "without a capability fails its own compilation", %{tmp_dir: dir} do
      for {name, arity} <- [runtime_info: 1, drain: 1, stop: 2, clear_quota_mark: 2] do
        source = drop_capability(File.read!(Path.join(@lib, "operations.ex")), name)
        assert {out, status} = elixirc(dir, source)
        assert status != 0, "#{name}: #{out}"

        assert out =~
                 "AtlasRuntime.Operations does not implement capability #{name}/#{arity}"
      end
    end

    test "is not started" do
      for path <- [
            Path.join(@lib, "application.ex"),
            Path.expand("../../host/service.exs", __DIR__)
          ] do
        code = File.read!(path)
        refute code =~ ~r/AtlasRuntime\.(Operations|History)\b/, path
      end
    end
  end

  describe "the persisted mode (Q6)" do
    # The facade's model is the Runtime's runtime_mode record (AtlasRuntime.Model.RuntimeMode):
    # it translates one way, with the rest of runtime_info supplied by the core.
    test "translates into runtime_info and the stopping outcome, changed_by kept out" do
      {:ok, mode} =
        RuntimeMode.new(mode: :paused, changed_at: ~U[2026-11-16 09:00:00Z], changed_by: "op")

      supply = [
        runtime_build: "b-1",
        incarnation: "i-1",
        policy_version: 3,
        slots: [%{name: "dev1", busy: false}]
      ]

      assert {:ok, %F.RuntimeInfo{mode: :paused, incarnation: "i-1"} = value} =
               F.from_model(mode, supply: supply)

      refute Map.has_key?(Map.from_struct(value), :changed_by)
      refute Map.has_key?(Map.from_struct(value), :changed_at)

      assert {:ok, %F.Outcome.Stopping{mode: :paused}} =
               F.from_model(mode, supply: supply, as: :stopping)

      refute function_exported?(F, :to_model, 1)
    end

    test "every persisted mode is a runtime_info mode" do
      for value <- [:open, :paused, :draining] do
        {:ok, mode} =
          RuntimeMode.new(mode: value, changed_at: ~U[2026-11-16 09:00:00Z], changed_by: "op")

        assert {:ok, %F.RuntimeInfo{mode: ^value}} =
                 F.from_model(mode,
                   supply: [runtime_build: "b", incarnation: "i", policy_version: 1, slots: []]
                 )
      end
    end
  end

  ## Helpers

  defp drop_capability(source, name) do
    dropped = Regex.replace(~r/\n  @impl true\n  def #{name}\(.*\n/, source, "\n")
    refute dropped == source, "no capability #{name} to drop"
    dropped
  end

  defp elixirc(dir, source) do
    file = Path.join(dir, "operations.ex")
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

  # A facade of the operations contract on an implementation whose runtime_info, stop and
  # release_slot answer `answer.()`; every other capability is AtlasRuntime.Operations'.
  defp facade_on(answer) do
    n = System.unique_integer([:positive])
    facade = Module.concat(AtlasRuntime.Test, "OperationsFacade#{n}")
    implementation = Module.concat(AtlasRuntime.Test, "Operations#{n}")
    :persistent_term.put({implementation, :answer}, answer)

    Code.compile_string("""
    defmodule #{inspect(facade)} do
      use AtlasRuntimeBoundary.Generator.Targets.Boundary,
        contract: AtlasRuntimeBoundary.Operations,
        implementation: #{inspect(implementation)}
    end

    defmodule #{inspect(implementation)} do
      use #{inspect(facade)}.Implementation
      @impl true
      def runtime_info(_c), do: :persistent_term.get({__MODULE__, :answer}).()
      @impl true
      def policy(c), do: AtlasRuntime.Operations.policy(c)
      @impl true
      def pause(c), do: AtlasRuntime.Operations.pause(c)
      @impl true
      def resume(c), do: AtlasRuntime.Operations.resume(c)
      @impl true
      def drain(c), do: AtlasRuntime.Operations.drain(c)
      @impl true
      def stop(_c, _i), do: :persistent_term.get({__MODULE__, :answer}).()
      @impl true
      def release_slot(_c, _i), do: :persistent_term.get({__MODULE__, :answer}).()
      @impl true
      def clear_quota_mark(c, i), do: AtlasRuntime.Operations.clear_quota_mark(c, i)
    end
    """)

    facade
  end
end
