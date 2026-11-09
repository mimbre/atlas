defmodule AtlasFlow.Runs.HandoffTest do
  @moduledoc """
  Disjoint phase admission on one kind: a selected subflow presents a fact while the
  fact is in the phase its selection admits, the legacy flow on the kind (or a second
  selected subflow, for the next phase) presents it in every other, and the run's own
  last write moves the fact from one phase to the other. At every moment exactly one of
  them writes the fact's presentation: through a lost acknowledgement of that write, a
  restart before it reached Facts, and a restart after; the second subflow's run starts
  once, on its own cursor, even across a restart before it was made.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, Item, ManualClock, Sorts}
  alias AtlasFlow.Runs.{Run, Store}

  @now ~U[2026-11-12 00:00:00Z]

  @selection %{
    "subject" => "box",
    "legacy" => "pack",
    "projection" => %{"field" => "todo", "owner_relation" => "owned_by"},
    "admission" => %{"phase" => ["first"]},
    "imports" => [],
    "migrations" => [],
    # A completed run on a fact still in its phase (its last write not stored yet, or the
    # fact put back) presents nothing itself: the legacy flow does.
    "follow_through" => %{"state" => "done", "when" => %{"phase" => ["first"]}}
  }

  defmodule Handing do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Handing],
      selection: %{"sort" => Module.get_attribute(AtlasFlow.Runs.HandoffTest, :selection)}
  end

  defmodule Unfollowed do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Handing],
      selection: %{
        "sort" =>
          Map.delete(
            Module.get_attribute(AtlasFlow.Runs.HandoffTest, :selection),
            "follow_through"
          )
      }
  end

  defmodule Written do
    @moduledoc false

    defmodule Stacking do
      @moduledoc """
      The box's second phase as a subflow of its own: it starts when the first phase's run
      moved the box on (a predicate), or joins its wait for a box that never had a phase.
      """
      use RelaDSL.Schema

      subflow :stack, label: "Stack", subject: :box do
        run_as("system:depot")
        owner(default: {:clerk, :bob})
        start(:predicate, when: "entity.phase == 'second'")
        initial(:stacking)

        state :stacking, label: "Stack it" do
          branch(to: :stacked, when: "entity.mark == 'stacked'")
          present(expected: "Stack it")
        end

        final(:stacked, label: "Stacked")
      end
    end
  end

  defmodule Stacking do
    use AtlasFlow.Sorts, from: Written.Stacking, subflow: :stack
  end

  @projection %{"field" => "todo", "owner_relation" => "owned_by"}

  # Two subflows on one kind, one per phase: together they admit every box, so the
  # legacy flow on the kind presents none, and no follow-through is needed.
  @phases %{
    "sort" => %{
      "subject" => "box",
      "legacy" => "pack",
      "projection" => @projection,
      "admission" => %{"phase" => ["first"]},
      "imports" => [],
      "migrations" => []
    },
    "stack" => %{
      "subject" => "box",
      "legacy" => "pack",
      "projection" => @projection,
      "admission" => %{"phase" => ["second", nil]},
      "imports" => [%{"when" => %{"phase" => [nil]}, "state" => "stacking"}],
      "migrations" => []
    }
  }

  defmodule Phased do
    use AtlasFlow.TestModel,
      subflows: [AtlasFlow.Sorts.Handing, AtlasFlow.Runs.HandoffTest.Stacking],
      selection: Module.get_attribute(AtlasFlow.Runs.HandoffTest, :phases)
  end

  setup do
    Application.put_env(:atlas_bus, :store, "handoff-#{System.unique_integer([:positive])}")
    :ok = Supervisor.terminate_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    {:ok, _} = Supervisor.restart_child(AtlasFlow.Root, AtlasFlow.Supervisor)
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    clock = start_supervised!({ManualClock, @now})
    on_exit(&stop_items/0)
    {:ok, clock: {ManualClock, clock}}
  end

  defp box(key), do: FakeFacts.get("box", key)
  defp presented(key), do: {box(key)["values"]["todo"], box(key)["links"]["owned_by"]}
  defp run(model, key), do: Store.decode(config(model), FakeFacts.get("cursor", run_key(key)))
  defp run_key(key), do: Run.key("sort", "box", key, 1)
  defp config(model), do: AtlasFlow.Model.load(model, :prod).config

  defp handed(key) do
    for %{"key" => ^key, "values" => %{"phase" => "second"}} = c <- FakeFacts.sent(), do: c
  end

  defp items(key), do: Registry.lookup(AtlasFlow.Items, {"box", key})

  test "the run's last write hands the fact over; a lost acknowledgement and a restart keep one writer",
       %{clock: clock} do
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    opts = [every: 3_600_000, clock: clock, model: Handing]
    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    flush_items()

    # In its first phase the run presents it, to the run's owner.
    assert presented("B-1") == {"Sort it", ["ada"]}
    assert {:ok, %{"state" => "waiting", "status" => "active"}} = run(Handing, "B-1")

    # It is done: the run ends and owes the write that moves the fact on. Facts stores
    # it, and the answer is lost.
    FakeFacts.lose_ack("box")
    FakeFacts.put("box", put_in(box("B-1"), ["values", "result"], "ok"))
    Engine.round(engine)
    assert {:ok, ended} = run(Handing, "B-1")
    assert {ended["state"], ended["status"]} == {"done", "completed"}
    assert [%{"id" => id}] = ended["pending"]["writes"]
    assert box("B-1")["values"]["phase"] == "second"

    # The fact left the run's phase: the legacy flow presents it now, and only it.
    flush_items()
    assert presented("B-1") == {"Pack it", ["bob"]}
    assert [{_, _}] = items("B-1")

    # Restarted, Flow sends the write again under its id: Facts answers it from its
    # ledger, nothing is stored twice, and the run's debt is paid.
    stop_supervised!(Engine)
    stop_items()
    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    assert {:ok, paid} = run(Handing, "B-1")
    assert {paid["state"], paid["status"], paid["entry"]} == {"done", "completed", ended["entry"]}
    assert paid["pending"]["writes"] == []
    assert [_] = handed("B-1")
    assert Run.digest({run_key("B-1"), ended["entry"], "set"}) == id

    flush_items()
    assert presented("B-1") == {"Pack it", ["bob"]}
    assert [{_, _}] = items("B-1")

    # Another round, and a later change in the legacy phase, move the run no more.
    Engine.round(engine)
    assert {:ok, ^paid} = run(Handing, "B-1")
  end

  # B-2 ended while Flow stopped before its last write reached Facts: still in the run's
  # phase, with a completed run that owes the write.
  defp ended_unsent(model) do
    FakeFacts.put("box", %{
      "key" => "B-2",
      "values" => %{"phase" => "first", "result" => "ok", "todo" => "Sort it"},
      "links" => %{"owned_by" => ["ada"]},
      "origins" => %{"owned_by" => %{"by" => "flow"}}
    })

    subject = %{"key" => "B-2", "version" => 1, "values" => %{"phase" => "first"}}

    waiting =
      Run.new("sort", Sorts.Handing, subject, [], @now) |> put_in(["pending", "writes"], [])

    {:ok, ended} =
      Run.step(waiting, Sorts.Handing, %{subject | "values" => box("B-2")["values"]}, @now)

    assert {ended["status"], length(ended["pending"]["writes"])} == {"completed", 1}

    FakeFacts.put("cursor", %{
      "key" => ended["key"],
      "values" => Store.encode(config(model), ended)
    })

    ended
  end

  # The fact's process alone, as after a restart of Flow whose round has not come yet.
  defp look(model, key, clock) do
    runner = AtlasFlow.Model.load(model, :prod)
    spec = {Item, {"box", key, every: 3_600_000, clock: clock, runner: runner}}
    {:ok, pid} = DynamicSupervisor.start_child(AtlasFlow.Supervisor, spec)
    ref = Process.monitor(pid)

    try do
      :sys.get_state(pid)
      :sys.get_state(pid)
    catch
      :exit, _ -> :ok
    end

    ref
  end

  test "restarted before the last write reached Facts: the legacy flow presents it, never none",
       %{clock: clock} do
    ended = ended_unsent(Handing)

    # Its process looks before any round: the run is completed and the fact still in the
    # run's phase, so the legacy flow presents it (follow-through), not the run, and not
    # nobody.
    look(Handing, "B-2", clock)
    assert presented("B-2") == {"Pack it", ["bob"]}
    assert handed("B-2") == []

    # The round pays the write; the fact leaves the phase; the same writer presents it.
    engine = start_supervised!({Engine, every: 3_600_000, clock: clock, model: Handing})
    Engine.round(engine)
    assert {:ok, paid} = run(Handing, "B-2")

    assert {paid["status"], paid["entry"], paid["pending"]["writes"]} ==
             {"completed", ended["entry"], []}

    assert [_] = handed("B-2")
    flush_items()
    assert presented("B-2") == {"Pack it", ["bob"]}
    assert [{_, _}] = items("B-2")
  end

  test "without a follow-through that window has no writer: what was presented is cleared",
       %{clock: clock} do
    ended_unsent(Unfollowed)
    ref = look(Unfollowed, "B-2", clock)

    # Why the selection names one: the completed run presents nothing, and its process
    # stops, until a round or a hint brings the legacy flow in: neither what is expected nor
    # its owner is left.
    assert presented("B-2") == {nil, []}
    assert_receive {:DOWN, ^ref, :process, _, :normal}
  end

  defp stack(model, key, generation \\ 1) do
    case FakeFacts.get("cursor", Run.key("stack", "box", key, generation)) do
      nil -> nil
      fact -> elem(Store.decode(config(model), fact), 1)
    end
  end

  defp blank({todo, owners}), do: {if(todo in [nil, ""], do: nil, else: todo), owners || []}

  test "two subflows on one fact: the first's last write starts the second once; one writer throughout",
       %{clock: clock} do
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    engine = start_supervised!({Engine, every: 3_600_000, clock: clock, model: Phased})
    Engine.round(engine)
    flush_items()

    # The first phase: its run presents it; the second has no run yet.
    assert presented("B-1") == {"Sort it", ["ada"]}
    assert stack(Phased, "B-1") == nil

    # It ends, moves the box on, and the second starts on its predicate in the same round:
    # its own run, its own cursor; it presents the box, and only it.
    FakeFacts.put("box", put_in(box("B-1"), ["values", "result"], "ok"))
    Engine.round(engine)
    flush_items()
    assert {:ok, %{"state" => "done", "status" => "completed"}} = run(Phased, "B-1")
    second = stack(Phased, "B-1")
    assert {second["state"], second["status"], second["entry"]} == {"stacking", "active", 1}
    refute Map.has_key?(second["last_input"], "import")
    assert presented("B-1") == {"Stack it", ["bob"]}
    assert [{_, _}] = items("B-1")

    # It ends too: nothing presents the box, and no legacy flow takes it.
    FakeFacts.put("box", put_in(box("B-1"), ["values", "mark"], "stacked"))
    Engine.round(engine)
    flush_items()
    assert %{"state" => "stacked", "status" => "completed"} = done = stack(Phased, "B-1")
    assert blank(presented("B-1")) == {nil, []}

    # Reopened (put back in its first phase, then moved on again): neither run starts again
    # and no new generation is made, as no selection declares one: only an explicit restart.
    for phase <- ["first", "second"] do
      FakeFacts.put("box", put_in(box("B-1"), ["values", "phase"], phase))
      Engine.round(engine)
      flush_items()
      assert stack(Phased, "B-1") == done
      assert stack(Phased, "B-1", 2) == nil
      assert FakeFacts.get("cursor", Run.key("sort", "box", "B-1", 2)) == nil
      assert blank(presented("B-1")) == {nil, []}
    end
  end

  test "an explicit restart presents its new generation, never the completed one before it",
       %{clock: clock} do
    FakeFacts.put("box", %{"key" => "B-4", "values" => %{"phase" => "second"}})
    engine = start_supervised!({Engine, every: 3_600_000, clock: clock, model: Phased})
    Engine.round(engine)
    flush_items()
    assert presented("B-4") == {"Stack it", ["bob"]}

    # It ends: nothing presents the box.
    FakeFacts.put("box", put_in(box("B-4"), ["values", "mark"], "stacked"))
    Engine.round(engine)
    flush_items()
    assert %{"status" => "completed"} = done = stack(Phased, "B-4")
    assert blank(presented("B-4")) == {nil, []}

    # Reopened, then restarted explicitly: the next generation, stored as Flow stores a run.
    # It presents the box again, to its owner; the first stays completed, as it was.
    FakeFacts.put("box", update_in(box("B-4"), ["values"], &Map.delete(&1, "mark")))
    {:ok, second} = Run.restart(done, Stacking, box("B-4"), @now)
    assert second["generation"] == 2

    FakeFacts.put("cursor", %{
      "key" => second["key"],
      "values" => Store.encode(config(Phased), second),
      "links" => %{}
    })

    Engine.round(engine)
    flush_items()
    assert %{"state" => "stacking", "status" => "active"} = stack(Phased, "B-4", 2)
    assert presented("B-4") == {"Stack it", ["bob"]}
    assert stack(Phased, "B-4") == done

    # The new generation ends too: nothing presents the box any more.
    FakeFacts.put("box", put_in(box("B-4"), ["values", "mark"], "stacked"))
    Engine.round(engine)
    flush_items()
    assert %{"status" => "completed"} = stack(Phased, "B-4", 2)
    assert blank(presented("B-4")) == {nil, []}
  end

  test "restarted between the first's end and the second's creation: exactly one second run",
       %{clock: clock} do
    # The first phase's run ended and its last write reached Facts; Flow stopped before it
    # made the second's run.
    FakeFacts.put("box", %{
      "key" => "B-3",
      "values" => %{"phase" => "second", "result" => "ok", "todo" => "Sort it"},
      "links" => %{"owned_by" => ["ada"]},
      "origins" => %{"owned_by" => %{"by" => "flow"}}
    })

    subject = %{"key" => "B-3", "version" => 1, "values" => %{"phase" => "first"}}

    waiting =
      Run.new("sort", Sorts.Handing, subject, [], @now) |> put_in(["pending", "writes"], [])

    {:ok, ended} =
      Run.step(waiting, Sorts.Handing, %{subject | "values" => box("B-3")["values"]}, @now)

    ended = put_in(ended, ["pending", "writes"], [])

    FakeFacts.put("cursor", %{
      "key" => ended["key"],
      "values" => Store.encode(config(Phased), ended)
    })

    # Restarted, the second's creation is stored and its answer lost: the next round finds
    # the stored run by its stable key and makes no other; restarted again, the same.
    FakeFacts.lose_ack("cursor")
    opts = [every: 3_600_000, clock: clock, model: Phased]
    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    Engine.round(engine)
    flush_items()
    second = stack(Phased, "B-3")
    assert {second["state"], second["status"], second["entry"]} == {"stacking", "active", 1}
    assert presented("B-3") == {"Stack it", ["bob"]}

    stop_supervised!(Engine)
    stop_items()
    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    flush_items()
    assert stack(Phased, "B-3") == second
    assert stack(Phased, "B-3", 2) == nil

    creates =
      for %{"op" => "create", "key" => key} <- FakeFacts.sent(),
          key == Run.key("stack", "box", "B-3", 1),
          do: key

    assert creates == [Run.key("stack", "box", "B-3", 1)]
    assert presented("B-3") == {"Stack it", ["bob"]}
    assert [{_, _}] = items("B-3")
  end

  test "a fact with no phase is the second subflow's from the start, imported into its wait",
       %{clock: clock} do
    FakeFacts.put("box", %{"key" => "B-4", "values" => %{}})
    engine = start_supervised!({Engine, every: 3_600_000, clock: clock, model: Phased})
    Engine.round(engine)
    flush_items()

    assert FakeFacts.get("cursor", run_key("B-4")) == nil
    imported = stack(Phased, "B-4")

    assert {imported["state"], imported["last_input"]} ==
             {"stacking", %{"version" => 1, "import" => true}}

    assert presented("B-4") == {"Stack it", ["bob"]}
  end

  defp flush_items do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor) do
      send(pid, :look)

      try do
        :sys.get_state(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp stop_items do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
        do: DynamicSupervisor.terminate_child(AtlasFlow.Supervisor, pid)
  end
end
