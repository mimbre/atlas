# Run in the umbrella with MIX_ENV=test; invoked by the external e2e test harness.
ExUnit.start(seed: 0)

# Runtime runs the neutral model of its tests (AtlasRuntime.TestModel), and so does Flow:
# its selected subflow `pack` (ada packs a box, bob checks it), whose run Flow keeps as a
# fact and projects on the box's card (`AtlasFlow.Runs.Projection`, the one writer of what
# a run presents). What Runtime reads of the card is its presentation, as Facts derives it
# from the run and what Flow wrote (`AtlasFacts.Presentation`). Flow keeps nothing: each
# projection reads Facts again, so a fresh Flow is a projection like any other.
defmodule RuntimeFlowHandoverTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{Engine, FakeFacts}
  alias AtlasFlow.Runs.{Projection, Run, Store}

  @model AtlasRuntime.TestModel
  @now ~U[2026-11-14 00:00:00Z]

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

    start_supervised!({FakeFacts, description: FakeFacts.description_of(AtlasRuntime.TestModel)})
    FakeFacts.put("clerk", %{"key" => "ada"})
    FakeFacts.put("clerk", %{"key" => "bob"})
    %{dir: dir}
  end

  # Ada's box: its card is hers, and the run of its subflow packs it (as Flow wrote it).
  defp box(owner \\ "ada", step \\ "packing") do
    FakeFacts.put("box", %{"key" => "B-1", "links" => %{"card" => ["C-B-1"]}})

    FakeFacts.put("card", %{
      "key" => "C-B-1",
      "values" => %{"step" => step, "todo" => "Pack it"},
      "links" => %{"owned_by" => List.wrap(owner)}
    })

    put_run(Run.new("pack", flow(), FakeFacts.get("box", "B-1"), [], @now))
  end

  defp runner, do: AtlasFlow.Model.load(@model, :prod, %{})
  defp flow, do: runner().flows["pack"]

  # The run as Flow stores it, its entry writes acknowledged; and the card presented.
  defp put_run(run) do
    run = put_in(run, ["pending", "writes"], [])
    FakeFacts.put("job", %{"key" => run["key"], "values" => Store.encode(runner().config, run)})
    present()
    run
  end

  defp run_of_box do
    key = Run.key("pack", "box", "B-1", 1)
    {:ok, run} = Store.decode(runner().config, FakeFacts.get("job", key))
    run
  end

  # The box moved on: its run takes the change, as Flow's store does.
  defp moves(values) do
    box = FakeFacts.get("box", "B-1")
    box = Map.update!(box, "values", &Map.merge(&1, values))
    FakeFacts.put("box", box)
    {:ok, run} = Run.step(run_of_box(), flow(), box, @now)
    put_run(run)
  end

  # Flow projects the run on the card, from a process of its own on the Bus, as the
  # engine does; then Facts presents the card again.
  defp project do
    runner = runner()

    Task.async(fn ->
      :ok = AtlasBus.attach("flow-#{System.unique_integer([:positive])}")
      {:ok, _} = Projection.project(runner, "box", "B-1")
    end)
    |> Task.await()

    present()
  end

  # What Facts answers as the card's presentation, from the run and what Flow wrote.
  defp present do
    presenter = Enum.find(@model.presentation(), &(&1["kind"] == "card"))
    card = Map.delete(FakeFacts.get("card", "C-B-1"), "presentation")
    box = FakeFacts.get("box", "B-1")
    runs = for {:ok, r} <- [safe_run()], do: r
    shown = AtlasFacts.Presentation.view(presenter, card, box, runs, fn -> false end)
    FakeFacts.put("card", Map.put(card, "presentation", shown))
  end

  defp safe_run do
    case FakeFacts.get("job", Run.key("pack", "box", "B-1", 1)) do
      nil -> :none
      fact -> Store.decode(runner().config, fact)
    end
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

  # Flow saves its handover, then does nothing until the end: Runtime can reconcile as
  # often as it likes while Flow does not react to the end hint.
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

      present()

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

      # The box is all packed: the run moves on to bob's check, and Flow defers the
      # handover while ada's turn runs.
      moves(%{"phase" => "check"})
      project()
      card = FakeFacts.get("card", "C-B-1")
      assert card["values"]["later"] != nil
      assert card["links"]["owned_by"] == ["ada"]
      assert card["presentation"]["handover"] != nil

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

      # Flow, fresh or not, recovers the pending transfer from Facts alone.
      project()
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

    present()

    runtime = engine(dir, every: 3_600_000)
    Engine.round(runtime)
    settle_turns()
    assert FakeFacts.all("run") == []

    project()
    assert FakeFacts.get("card", "C-B-1")["values"]["later"] == nil
    assert FakeFacts.get("card", "C-B-1")["links"]["owned_by"] == ["ada"]
    Engine.round(runtime)
    settle_turns()
    assert run("R-C-B-1-1")["links"]["run_by"] == ["ada"]
  end
end
