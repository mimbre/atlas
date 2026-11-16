defmodule ReviewerDueRoundTest do
  use ExUnit.Case, async: false
  alias AtlasFlow.{Engine, FakeFacts, ManualClock}

  for mode <- [:timer_only, :timer_and_call] do
    test "a due round during stepping is queued: #{mode}" do
      Application.put_env(:atlas_bus, :store, "reviewer-due-round")
      :ok = AtlasBus.attach("reviewer-due-round-client")
      start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
      FakeFacts.put("maker", %{"key" => "mia"})
      FakeFacts.put("widget", %{"key" => "A", "values" => %{"title" => "A"}})
      clock = start_supervised!({ManualClock, ~U[2026-11-14 00:00:00Z]})

      engine =
        start_supervised!(
          {Engine, model: AtlasFlow.Workshop, every: 3_600_000, clock: {ManualClock, clock}}
        )

      Engine.round(engine)
      parent = self()
      ref = make_ref()

      :sys.install(
        engine,
        {fn
           0, {:in, :round_step}, _ ->
             send(parent, {ref, :held})
             receive do: ({^ref, :go} -> :ok)
             1

           n, _, _ ->
             n
         end, 0}
      )

      ManualClock.advance(clock, 3_600_000)
      assert_receive {^ref, :held}, 1_000
      FakeFacts.put("widget", %{"key" => "Z", "values" => %{"title" => "Z"}})
      send(engine, :round)
      if unquote(mode) == :timer_and_call, do: :gen_server.send_request(engine, :round)
      send(engine, {ref, :go})
      Engine.idle(engine)
      Engine.idle(engine)
      state = :sys.get_state(engine)
      assert state.round == nil
      assert FakeFacts.get("widget", "Z")["values"]["todo"] == "Tend it"
    end
  end
end
