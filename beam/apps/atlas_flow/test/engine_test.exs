defmodule AtlasFlow.EngineTest do
  # The engine's own rules: one writer per run across full restarts, refusal, and the model
  # it is wired to.
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  # A selected subflow this runner cannot run (an effect no service is enabled for).
  defmodule Unrunnable do
    use AtlasFlow.TestModel, subflows: [AtlasFlow.Sorts.Unbound]
  end

  setup do
    Application.put_env(:atlas_bus, :store, "state-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    :ok
  end

  defp todo(key), do: FakeFacts.get("box", key)["values"]["todo"]

  test "Flow keeps no process of its own per fact: only the engine and its activities' inboxes" do
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    engine = start_supervised!({Engine, every: 3_600_000, model: AtlasFlow.Depot})
    Engine.round(engine)
    assert todo("B-1") == "Sort it"

    assert Enum.sort(for {id, _, _, _} <- Supervisor.which_children(AtlasFlow.Root), do: id) ==
             Enum.sort([AtlasFlow.Activities.Pass.Inbox, AtlasFlow.Activities.Effect.Inbox])

    refute Process.whereis(AtlasFlow.Items)
    refute Process.whereis(AtlasFlow.Supervisor)
  end

  test "a full restart keeps the run, its entry and its original deadline; one writer throughout" do
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    FakeFacts.put("box", %{"key" => "B-2", "values" => %{"phase" => "second"}})
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})
    opts = [every: 3_600_000, clock: {ManualClock, clock}, model: AtlasFlow.Depot]

    engine = start_supervised!({Engine, opts})
    Engine.round(engine)
    assert todo("B-1") == "Sort it"
    # Not admitted by any selected subflow: nothing presents it.
    assert todo("B-2") == nil
    key = Run.key("sort", "box", "B-1", 1)
    config = TestModel.config()
    {:ok, first} = Store.decode(config, FakeFacts.get("cursor", key))
    assert first["entry"] == 1
    ManualClock.advance(clock, 299_999)
    Engine.round(engine)
    stop_supervised!(Engine)
    restarted = start_supervised!({Engine, opts})
    Engine.round(restarted)
    {:ok, waiting} = Store.decode(config, FakeFacts.get("cursor", key))
    assert waiting == first
    ManualClock.advance(clock, 2)
    Engine.round(restarted)
    {:ok, second} = Store.decode(config, FakeFacts.get("cursor", key))
    assert second["entry"] == 2
    assert second["last_input"]["due"] == "2026-11-12T00:05:00.000Z"
    send(restarted, :round)
    Engine.round(restarted)
    assert {:ok, ^second} = Store.decode(config, FakeFacts.get("cursor", key))
    stop_supervised!(Engine)
    again = start_supervised!({Engine, opts})
    Engine.round(again)
    assert {:ok, ^second} = Store.decode(config, FakeFacts.get("cursor", key))
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first", "result" => "ok"}})
    Engine.round(again)
    {:ok, completed} = Store.decode(config, FakeFacts.get("cursor", key))
    assert completed["status"] == "completed"
    assert todo("B-1") == nil
    stop_supervised!(Engine)
    final_engine = start_supervised!({Engine, opts})
    Engine.round(final_engine)
    assert {:ok, ^completed} = Store.decode(config, FakeFacts.get("cursor", key))
    # One run of the box throughout: no second generation was made.
    assert FakeFacts.get("cursor", Run.key("sort", "box", "B-1", 2)) == nil
  end

  test "a selected subflow the runner cannot run refuses selected execution with zero writes" do
    FakeFacts.put("box", %{"key" => "B-1", "values" => %{"phase" => "first"}})
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})
    engine = start_supervised!({Engine, clock: {ManualClock, clock}, model: Unrunnable})

    Engine.round(engine)
    assert FakeFacts.sent() == []
    Engine.round(engine)
    assert FakeFacts.sent() == []
  end

  test "Flow does not start without a model, or with a module that is no model" do
    Application.delete_env(:atlas, :model)
    assert_raise ArgumentError, fn -> AtlasFlow.Model.configured!() end
    assert_raise ArgumentError, ~r/lacks/, fn -> AtlasFlow.Model.check!(FakeFacts) end
    assert AtlasFlow.Model.check!(AtlasFlow.Depot) == AtlasFlow.Depot
  end
end
