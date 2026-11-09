defmodule AtlasFlow.Runs.HandoffTest do
  @moduledoc """
  Disjoint phase admission on one kind: a selected subflow presents a fact while the
  fact is in the phase its selection admits, the legacy flow on the kind presents it in
  every other, and the run's own last write moves the fact from one phase to the other.
  At every moment exactly one of them writes the fact's presentation: through a lost
  acknowledgement of that write, a restart before it reached Facts, and a restart after.
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
