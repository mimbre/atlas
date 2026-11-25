defmodule AtlasFlow.HealthTest do
  # IS-Atlas-117: what Flow says about its health, for Control's health page. The Engine
  # notes when its round was due and when it finished, Dispatch each Runtime's poll, and
  # `_health` answers from that table alone, also while the Engine is held mid-round.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, Health, ManualClock, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L

  @every 60_000

  defp health!(endpoint \\ nil) do
    name = :"health_#{System.unique_integer([:positive])}"
    start_supervised!({Health, name: name, endpoint: endpoint})
    name
  end

  defp at(clock), do: ManualClock.now(clock) |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The round ended, and the Engine has also set its next one (after answering).
  defp idle(engine) do
    Engine.idle(engine)
    :sys.get_state(engine)
  end

  describe "the Engine's round" do
    setup do
      Application.put_env(:atlas_bus, :store, "health-#{System.unique_integer([:positive])}")
      :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
      start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
      FakeFacts.put("maker", %{"key" => "mia"})
      FakeFacts.put("widget", %{"key" => "W-1", "values" => %{"title" => "W-1"}})
      clock = start_supervised!({ManualClock, ~U[2026-11-23 10:00:00Z]})
      table = health!()

      engine =
        start_supervised!(
          {Engine,
           every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Workshop, health: table}
        )

      idle(engine)
      %{clock: clock, table: table, engine: engine}
    end

    test "a finished round says when it was due and finished, and when the next is due", c do
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == nil
      assert flow["last_due"] == "2026-11-23T10:00:00Z"
      assert flow["last_finished"] == "2026-11-23T10:00:00Z"
      assert flow["next_due"] == "2026-11-23T10:01:00Z"
    end

    test "a round held while it steps keeps its due; the report does not wait for it", c do
      test = self()
      ref = make_ref()

      hold = fn
        false, {:in, :round_step}, _state ->
          send(test, {ref, :held})
          receive do: ({^ref, :go} -> :ok)
          true

        held, _event, _state ->
          held
      end

      :ok = :sys.install(c.engine, {hold, false})
      ManualClock.advance(c.clock, @every)
      assert_receive {^ref, :held}

      # Held at its first step, the round that was due at 10:01 stays due; nine minutes on
      # it is still the round stepping, as on 2026-11-23.
      ManualClock.advance(c.clock, 9 * 60_000)
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == "2026-11-23T10:01:00Z"
      assert flow["last_due"] == "2026-11-23T10:00:00Z"

      send(c.engine, {ref, :go})
      :sys.remove(c.engine, hold)
      idle(c.engine)
      flow = Health.report(c.table)["flow"]
      assert flow["due"] == nil
      assert flow["last_due"] == "2026-11-23T10:01:00Z"
      assert flow["last_finished"] == at(c.clock)
    end
  end

  test "Dispatch notes each Runtime's last poll" do
    dir = Path.join(System.tmp_dir!(), "health-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    table = health!()
    ctx = L.start(dir, health: table)

    assert {:polled, _} = WorkSource.poll({"mini", "ada"}, L.poll_input("mini", [], %{}))
    L.advance(ctx, 90)
    assert {:polled, _} = WorkSource.poll({"laptop", "bea"}, L.poll_input("laptop", [], %{}))

    assert Health.report(table)["runtimes"] == [
             %{"runtime" => "laptop", "polled_at" => "2026-11-17T12:01:30Z"},
             %{"runtime" => "mini", "polled_at" => "2026-11-17T12:00:00Z"}
           ]
  end

  test "`_health` is answered over the Bus" do
    endpoint = "flow/health-#{System.unique_integer([:positive])}"
    table = health!(endpoint)
    Health.polled("mini", ~U[2026-11-23 10:00:00Z], table)
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    request = %{Envelope.new("request", "_health") | address: endpoint}
    :ok = AtlasBus.send(request, %{})
    id = request.id

    assert_receive {:atlas_bus, %Envelope{class: "answer", id: ^id}, answer}
    assert answer["runtimes"] == [%{"runtime" => "mini", "polled_at" => "2026-11-23T10:00:00Z"}]
    assert answer["flow"]["due"] == nil
    assert is_binary(answer["at"])
  end

  test "a write without a table is dropped" do
    assert Health.polled("mini", DateTime.utc_now(), :no_such_health_table) == :ok
    assert Health.report(:no_such_health_table)["runtimes"] == []
  end
end
