defmodule AtlasFlow.IndependentReviewTest do
  use ExUnit.Case, async: false
  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Talk}

  test "settled answer exists while later subject B remains held before reconciliation" do
    Application.put_env(:atlas_bus, :store, "independent-held")
    :ok = AtlasBus.attach("independent-reviewer")
    start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
    FakeFacts.put("maker", %{"key" => "mia"})

    for key <- ["A", "B", "C"] do
      FakeFacts.put("widget", %{"key" => key, "values" => %{"title" => key}})
    end

    clock = start_supervised!({ManualClock, ~U[2026-11-14 00:00:00Z]})

    engine =
      start_supervised!(
        {Engine, model: AtlasFlow.Workshop, every: 3_600_000, clock: {ManualClock, clock}}
      )

    Engine.round(engine)
    before = length(FakeFacts.stored_from_flow())
    parent = self()
    ref = make_ref()

    :ok =
      :sys.install(
        engine,
        {fn
           n, {:in, :round_step}, _ ->
             n = n + 1

             if n in [1, 2] do
               send(parent, {ref, :held, n})
               receive do: ({^ref, :go} -> :ok)
             end

             n

           n, _, _ ->
             n
         end, 0}
      )

    ManualClock.advance(clock, 3_600_000)
    assert_receive {^ref, :held, 1}, 1_000
    # B's durable subject changes without a hint, so only its planned step can apply it.
    b = FakeFacts.get("widget", "B")
    FakeFacts.put("widget", put_in(b, ["values", "state"], "done"))

    {:stored, position} =
      Talk.put("widget", %{"op" => "change", "key" => "A", "values" => %{"state" => "done"}})

    request = %{Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    send(engine, {ref, :go})
    assert_receive {^ref, :held, 2}, 1_000
    assert_received {:atlas_bus, %Envelope{id: id, class: "answer"}, %{"settled" => settled}}
    assert id == request.id and settled >= position
    assert FakeFacts.get("widget", "A")["values"]["todo"] == nil
    # Subject B has not reconciled or projected: it is still held, with its old cursor.
    config = AtlasFlow.TestModel.config()
    key = AtlasFlow.Runs.Run.key("tend", "widget", "B", 1)

    assert {:ok, %{"status" => "active"}} =
             AtlasFlow.Runs.Store.decode(config, FakeFacts.get("cursor", key))

    assert FakeFacts.get("widget", "B")["values"]["todo"] == "Tend it"

    IO.puts(
      "HELD_PROOF: settled=#{settled} requested=#{position}; B held before reconcile, cursor active, projection unchanged"
    )

    send(engine, {ref, :go})
    Engine.idle(engine)

    assert {:ok, %{"status" => "completed"}} =
             AtlasFlow.Runs.Store.decode(config, FakeFacts.get("cursor", key))

    writes = Enum.drop(FakeFacts.stored_from_flow(), before)
    assert Enum.count(writes, &(&1["key"] == "A")) == 1
    assert Enum.count(writes, &(&1["key"] == "B")) == 1
  end
end
