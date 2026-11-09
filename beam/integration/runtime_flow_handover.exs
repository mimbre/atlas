# Run in the umbrella with MIX_ENV=test; invoked by the external e2e test harness.
ExUnit.start(seed: 0)

# Runtime runs the neutral model of its tests (AtlasRuntime.TestModel). Flow's side: the
# same legacy flow, compiled from the Rela DSL into the model Flow's items run (a neutral
# one, with no runs selected), walking that neutral model's relations and turn.
defmodule HandoverPack do
  use RelaDSL.Flow.Legacy,
    name: :pack,
    behaviour: AtlasFlow.Legacy,
    flow: [
      kinds: [:box],
      on: :card,
      field: :todo,
      state_field: :step,
      handover_field: :later,
      owner_relation: :owned_by,
      states: [
        [
          name: :checking,
          when: [values: [phase: [:check]]],
          owner: [kind: :clerk, key: "bob"],
          expected: "Check it"
        ],
        [name: :packing, owner: [kind: :clerk, key: "ada"], expected: "Pack it"]
      ]
    ]
end

defmodule HandoverModel do
  use AtlasFlow.TestModel,
    legacy: [HandoverPack],
    selection: %{"sort" => nil},
    relations: AtlasRuntime.TestModel.relations(),
    turn: AtlasRuntime.TestModel.turn()
end

defmodule RuntimeFlowHandoverTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Engine, FakeFacts}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")

    # A fresh supervisor for the turns: none is left from another test.
    :ok = Supervisor.terminate_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasRuntime.Root, AtlasRuntime.Supervisor)
    eventually(fn -> Registry.count(AtlasRuntime.Turns) == 0 end)

    # And none outlives this test: the umbrella runs the other apps' tests in this VM, where
    # a turn still renewing its lease puts facts on their Bus.
    on_exit(fn ->
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, pid)
    end)

    # Umbrella Flow tests may leave item processes under their application supervisor.
    # None may reconcile against this test's replacement Facts endpoint.
    if Process.whereis(AtlasFlow.Supervisor) do
      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
          do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)

      eventually(fn -> Registry.count(AtlasFlow.Items) == 0 end)
    end

    start_supervised!({FakeFacts, description: FakeFacts.description_of(AtlasRuntime.TestModel)})
    FakeFacts.put("clerk", %{"key" => "ada"})
    FakeFacts.put("clerk", %{"key" => "bob"})
    %{dir: dir}
  end

  # Ada's box: its card is hers, and its flow has a state for it.
  defp box(owner \\ "ada", step \\ "packing") do
    FakeFacts.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-B-1"]}})

    FakeFacts.put("card", %{
      "key" => "C-B-1",
      "values" => %{"step" => step},
      "links" => %{"owned_by" => List.wrap(owner)}
    })
  end

  defp engine(dir, more \\ []) do
    opts =
      [
        machine: "here",
        agents: %{"ada" => %{"port" => "stub"}},
        silence: 900,
        max: 60_000,
        lease: 100,
        every: 200,
        stub_dir: dir,
        crash_pause: 50,
        leave_grace: 300,
        model: AtlasRuntime.TestModel,
        name: Engine
      ]
      |> Keyword.merge(more)

    start_supervised!({Engine, opts})
  end

  defp run(key), do: FakeFacts.get("run", key)

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("did not happen")
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end

  # The Flow item is explicitly suspended after it saves its handover. Runtime can
  # reconcile as often as it likes while Flow cannot react to the end hint or its timer.
  for ending <- [:outcome, :crash, :silence, :restart] do
    test "a pending handover cannot be starved after #{ending}", %{dir: dir} do
      box()
      card = FakeFacts.get("card", "C-B-1")

      FakeFacts.put(
        "card",
        Map.put(card, "origins", %{
          "owned_by" => %{"by" => "human", "position" => 1}
        })
      )

      opts = [
        every: 3_600_000,
        agents: %{
          "ada" => %{"port" => "stub"},
          "bob" => %{"port" => "stub"}
        }
      ]

      runtime = engine(dir, opts)
      eventually(fn -> run("R-C-B-1-1") != nil end)
      [{turn, _}] = Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1")

      {:ok, _} = Application.ensure_all_started(:atlas_flow)

      flow =
        start_supervised!(
          {AtlasFlow.Item, {"box", "B-1", [every: 3_600_000, model: HandoverModel]}}
        )

      :sys.get_state(flow)
      item = FakeFacts.get("box", "B-1") |> put_in(["values", "phase"], "check")
      FakeFacts.put("box", item)
      send(flow, :look)
      :sys.get_state(flow)
      card = FakeFacts.get("card", "C-B-1")
      assert card["values"]["later"] != nil
      assert card["links"]["owned_by"] == ["ada"]
      :sys.suspend(flow)
      on_exit(fn -> if Process.alive?(flow), do: :sys.resume(flow) end)

      # Pending transfer does not revoke the running turn's ownership or authority.
      Engine.round(runtime)
      assert Process.alive?(turn)
      ref = Process.monitor(turn)

      case unquote(ending) do
        :outcome ->
          FakeFacts.put("run", put_in(run("R-C-B-1-1"), ["values", "result"], "packed it"))
          Engine.round(runtime)

        :crash ->
          Process.exit(AtlasRuntime.Turn.agent(turn), :kill)

        :silence ->
          :sys.replace_state(turn, &%{&1 | active: System.system_time(:millisecond) - 10_000})
          send(turn, :tick)

        :restart ->
          DynamicSupervisor.terminate_child(AtlasRuntime.Supervisor, turn)
      end

      assert_receive {:DOWN, ^ref, :process, ^turn, _}, 3_000
      eventually(fn -> Registry.lookup(AtlasRuntime.Turns, "R-C-B-1-1") == [] end)
      Engine.round(runtime)
      assert run("R-C-B-1-1")["values"]["status"] == "over"

      # Several acknowledged rounds, then a fresh Runtime: no memory or timer grace
      # can substitute for the durable handover barrier.
      for _ <- 1..3, do: Engine.round(runtime)
      stop_supervised!(Engine)
      runtime = engine(dir, opts)
      Engine.round(runtime)
      settle_turns()
      assert run("R-C-B-1-2") == nil
      assert FakeFacts.get("card", "C-B-1")["links"]["owned_by"] == ["ada"]

      :sys.resume(flow)
      # A fresh Flow process must also recover the pending transfer from Facts.
      stop_supervised!(AtlasFlow.Item)

      flow =
        start_supervised!(
          {AtlasFlow.Item, {"box", "B-1", [every: 3_600_000, model: HandoverModel]}}
        )

      :sys.get_state(flow)
      card = FakeFacts.get("card", "C-B-1")
      assert card["links"]["owned_by"] == ["bob"]
      assert card["values"]["later"] == nil
      Engine.round(runtime)
      settle_turns()
      assert run("R-C-B-1-2")["links"]["run_by"] == ["bob"]
    end
  end

  defp settle_turns do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
        do: :sys.get_state(pid)
  end

  test "Flow can cancel a stale handover and allow the retained owner to continue", %{dir: dir} do
    box()

    FakeFacts.put("card", %{
      "key" => "C-B-1",
      "values" => %{
        "step" => "packing",
        "todo" => "Pack it",
        "later" => JSON.encode!(%{"from" => ["ada"], "position" => 1})
      },
      "links" => %{"owned_by" => ["ada"]},
      "origins" => %{"owned_by" => %{"by" => "human", "position" => 2}}
    })

    runtime = engine(dir, every: 3_600_000)
    Engine.round(runtime)
    settle_turns()
    assert FakeFacts.all("run") == []

    {:ok, _} = Application.ensure_all_started(:atlas_flow)

    flow =
      start_supervised!(
        {AtlasFlow.Item, {"box", "B-1", [every: 3_600_000, model: HandoverModel]}}
      )

    :sys.get_state(flow)
    assert FakeFacts.get("card", "C-B-1")["values"]["later"] == nil
    assert FakeFacts.get("card", "C-B-1")["links"]["owned_by"] == ["ada"]
    Engine.round(runtime)
    settle_turns()
    assert run("R-C-B-1-1")["links"]["run_by"] == ["ada"]
  end
end
