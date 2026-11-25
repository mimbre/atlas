defmodule AtlasFlow.Runs.GoneTest do
  @moduledoc """
  A run whose subject or subflow is gone ends (`ended`) once, with why in
  `blocked_reason`, in one versioned write; later rounds neither read it nor write or log
  anything for it. The real Engine, `FakeFacts` and a manual clock.
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @every 3_600_000

  setup do
    Application.put_env(:atlas_bus, :store, "gone-#{System.unique_integer([:positive])}")
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    FakeFacts.put("clerk", %{"key" => "ada"})
    for key <- ~w(B-1 B-2), do: FakeFacts.put("box", box(key))
    clock = start_supervised!({ManualClock, ~U[2026-11-25 00:00:00Z]})

    engine =
      start_supervised!(
        {Engine, every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Depot}
      )

    :ok = Engine.round(engine)
    assert run("B-1")["status"] == "active"
    %{engine: engine, config: TestModel.config()}
  end

  defp box(key), do: %{"key" => key, "values" => %{"phase" => "first"}}

  defp run(key, flow \\ "sort") do
    case FakeFacts.get("cursor", Run.key(flow, "box", key, 1)) do
      nil -> nil
      fact -> elem(Store.decode(TestModel.config(), fact), 1)
    end
  end

  # Flow has settled every hint up to `position` (its answer to `_settled`).
  defp settled(position) do
    request = %{AtlasBus.Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    id = request.id

    receive do
      {:atlas_bus, %AtlasBus.Envelope{id: ^id, class: "answer"}, _} -> :ok
    end
  end

  # Later rounds read, write and log nothing for the ended run of `key`.
  defp left_alone(c, key, flow \\ "sort") do
    ended = run(key, flow)
    sent = FakeFacts.sent()

    log =
      capture_log(fn ->
        for _ <- 1..2, do: :ok = Engine.round(c.engine)
      end)

    assert log == ""
    assert run(key, flow) == ended
    assert FakeFacts.sent() == sent
  end

  # A round's plan does not name the deleted subject of `key`: its ended run is not read.
  defp unplanned(c, key) do
    {:ok, %{subjects: subjects}} = Store.plan(c.config, %{})
    refute {"box", key} in subjects
  end

  test "a deleted subject without its delete hint ends its run once", c do
    GenServer.call(FakeFacts, {:drop, "box", "B-1"})
    :ok = Engine.round(c.engine)

    ended = run("B-1")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "subject_removed"}
    assert run("B-2")["status"] == "active"
    left_alone(c, "B-1")
    unplanned(c, "B-1")
  end

  test "a deleted subject's delete hint ends its run once", c do
    {:stored, position} = Talk.put("box", %{"op" => "delete", "key" => "B-1"})
    settled(position)

    ended = run("B-1")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "subject_removed"}
    left_alone(c, "B-1")
    unplanned(c, "B-1")
  end

  test "a run whose writes Facts refuses because its subject is gone ends once", c do
    # The run owes its subject a write when the subject is deleted; Facts refuses it.
    write = %{
      "id" => "owed",
      "kind" => "box",
      "content" => %{"op" => "change", "key" => "B-1", "values" => %{"mark" => "again"}}
    }

    owing = put_in(run("B-1"), ["pending", "writes"], [write])
    fact = FakeFacts.get("cursor", owing["key"])
    FakeFacts.put("cursor", Map.put(fact, "values", Store.encode(c.config, owing)))
    GenServer.call(FakeFacts, {:drop, "box", "B-1"})
    GenServer.call(FakeFacts, {:refuse_write, "box", "B-1"})
    :ok = Engine.round(c.engine)

    ended = run("B-1")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "subject_removed"}
    left_alone(c, "B-1")
    unplanned(c, "B-1")
  end

  test "a run of a subflow taken out of the model ends once", c do
    # A run of `design`, which the model no longer has, still active in Facts.
    old =
      run("B-2")
      |> Map.merge(%{"flow" => "design", "state" => "designing"})
      |> Map.put("key", Run.key("design", "box", "B-2", 1))

    FakeFacts.put("cursor", %{"key" => old["key"], "values" => Store.encode(c.config, old)})
    :ok = Engine.round(c.engine)

    ended = run("B-2", "design")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "flow_removed: design"}
    assert Map.drop(ended, ~w(status blocked_reason)) == Map.drop(old, ~w(status blocked_reason))
    assert run("B-2")["status"] == "active"
    left_alone(c, "B-2", "design")
  end

  test "a run in a state its subflow no longer has ends once its subject is gone", c do
    # Blocked for a removed state, then its subject deleted (no hint): it does not wait
    # for the state to come back.
    removed = Map.put(run("B-1"), "state", "sorting")
    fact = FakeFacts.get("cursor", removed["key"])
    FakeFacts.put("cursor", Map.put(fact, "values", Store.encode(c.config, removed)))
    :ok = Engine.round(c.engine)
    assert run("B-1")["blocked_reason"] == "state_removed: sorting"

    GenServer.call(FakeFacts, {:drop, "box", "B-1"})
    :ok = Engine.round(c.engine)

    ended = run("B-1")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "subject_removed"}
    assert ended["state"] == "sorting"
    left_alone(c, "B-1")
    unplanned(c, "B-1")
  end

  test "a restart asked for a deleted subject ends its run once instead", c do
    config = put_in(c.config, ["selection", "sort", "restart_by"], ["owner"])
    flows = %{"sort" => TestModel.sort()}
    FakeFacts.put("box", %{"key" => "B-3", "values" => %{"phase" => "first", "result" => "ok"}})
    {:ok, _} = Store.reconcile(config, flows, ~U[2026-11-25 00:00:00Z])
    done = run("B-3")
    assert done["status"] == "completed"

    request = %{
      "op" => "submit",
      "key" => "restart-B-3",
      "values" => %{
        "run" => done["key"],
        "entry" => done["entry"],
        "roles" => ["restart"],
        "changed_fields" => %{}
      }
    }

    assert {:stored, _} = Talk.put("choice", request, "restart-B-3")
    GenServer.call(FakeFacts, {:drop, "box", "B-3"})
    assert {:ok, _} = Store.reconcile(config, flows, ~U[2026-11-25 00:01:00Z])

    ended = run("B-3")
    assert {ended["status"], ended["blocked_reason"]} == {"ended", "subject_removed"}
    assert ended["generation"] == 1
    assert FakeFacts.get("cursor", Run.key("sort", "box", "B-3", 2)) == nil

    sent = FakeFacts.sent()

    log =
      capture_log(fn ->
        for _ <- 1..2, do: {:ok, _} = Store.reconcile(config, flows, ~U[2026-11-25 00:02:00Z])
      end)

    assert log == ""
    assert run("B-3") == ended
    assert FakeFacts.sent() == sent
    unplanned(c, "B-3")
  end
end
