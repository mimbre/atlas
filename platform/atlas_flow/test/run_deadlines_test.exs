defmodule AtlasFlow.RunDeadlinesTest do
  # Every open run reconciles on its own deadline (UC-Atlas-03): a run's timer wakes only
  # its own subject, a run whose reconcile fails backs off alone, its back-off is kept in
  # the run (`deadlines.reconcile`) and restored after a restart, and one overdue by then
  # is reconciled at once. Time passes only on the manual clock.
  use ExUnit.Case, async: false

  alias AtlasFlow.{Engine, FakeFacts, ManualClock, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @start ~U[2026-11-12 00:00:00Z]
  @minute 60_000

  setup do
    Application.put_env(:atlas_bus, :store, "deadlines-#{System.unique_integer([:positive])}")
    start_supervised!(FakeFacts)
    for key <- ["ada", "bob"], do: FakeFacts.put("clerk", %{"key" => key})
    clock = start_supervised!({ManualClock, @start})

    # An hour's round, so whatever moves within it moved on its own deadline.
    opts = [
      every: 3_600_000,
      backoff: {@minute, 10 * @minute},
      clock: {ManualClock, clock},
      model: AtlasFlow.Depot
    ]

    %{clock: clock, opts: opts}
  end

  defp box(key), do: FakeFacts.put("box", %{"key" => key, "values" => %{"phase" => "first"}})

  defp run(key) do
    {:ok, run} =
      Store.decode(TestModel.config(), FakeFacts.get("cursor", Run.key("sort", "box", key, 1)))

    run
  end

  defp backoff(key), do: run(key)["deadlines"]["reconcile"]
  defp busy(key), do: GenServer.call(FakeFacts, {:busy, "box", key})
  defp free(key), do: GenServer.call(FakeFacts, {:free, "box", key})

  # Time passes; the engine handles the wakeups it brought, and the reconciles they queued.
  defp advance(engine, clock, ms) do
    ManualClock.advance(clock, ms)
    drained(engine)
  end

  # Until the wakeup the advance brought (behind which `:sys.get_state/1` waits) has had
  # each reconcile it queued done.
  defp drained(engine) do
    if MapSet.size(:sys.get_state(engine).queued_due) == 0, do: :ok, else: drained(engine)
  end

  defp at(minutes),
    do: DateTime.add(@start, minutes * @minute, :millisecond) |> DateTime.to_iso8601()

  test "a run's timer wakes its own subject only, without bringing the round forward", c do
    box("B-1")
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    # B-2 comes a minute later: its timer is due a minute after B-1's.
    advance(engine, c.clock, @minute)
    box("B-2")
    Engine.round(engine)
    rounds = :sys.get_state(engine).last_round

    advance(engine, c.clock, 4 * @minute)
    assert run("B-1")["entry"] == 2
    assert run("B-2")["entry"] == 1
    # No round ran: only B-1's own deadline did.
    assert :sys.get_state(engine).last_round == rounds

    advance(engine, c.clock, @minute)
    assert run("B-2")["entry"] == 2
    assert run("B-1")["entry"] == 2
    assert :sys.get_state(engine).last_round == rounds

    # A timer already taken does not wake its run again.
    writes = length(FakeFacts.stored_from_flow())
    advance(engine, c.clock, 1)
    assert length(FakeFacts.stored_from_flow()) == writes
  end

  test "a run that fails to reconcile backs off alone, durably, while the others go on", c do
    box("B-1")
    box("B-2")
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    busy("B-1")

    # Both timers are due at minute 5: B-1 cannot be read, B-2 moves on.
    advance(engine, c.clock, 5 * @minute)
    assert run("B-2")["entry"] == 2
    assert run("B-1")["entry"] == 1
    assert %{"due" => due, "failures" => 1, "reason" => reason} = backoff("B-1")
    assert due == at(6)
    assert reason =~ "Facts did not answer"

    # A round on its timer leaves B-1 to its back-off: tried, it would have failed again.
    send(engine, :round)
    Engine.idle(engine)
    assert backoff("B-1")["failures"] == 1

    # Tried again at 6 (one minute), 8 (two), 12 (four): each failure doubles the wait.
    advance(engine, c.clock, @minute)
    assert backoff("B-1") |> Map.take(~w(due failures)) == %{"due" => at(8), "failures" => 2}
    advance(engine, c.clock, @minute)
    assert backoff("B-1")["failures"] == 2
    advance(engine, c.clock, @minute)
    assert backoff("B-1") |> Map.take(~w(due failures)) == %{"due" => at(12), "failures" => 3}

    # B-2 went on meanwhile, on its own timer (due at minute 10).
    advance(engine, c.clock, 2 * @minute)
    assert run("B-2")["entry"] == 3
    assert backoff("B-2") == nil

    # B-1 recovers at its next try, its timer (overdue since minute 5) taken once, and
    # its back-off cleared in the same write.
    free("B-1")
    advance(engine, c.clock, 2 * @minute)
    assert run("B-1")["entry"] == 2
    assert backoff("B-1") == nil
  end

  test "a restart restores each run's back-off from Facts; an overdue one runs at once", c do
    box("B-1")
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    busy("B-1")
    advance(engine, c.clock, 5 * @minute)
    assert backoff("B-1")["due"] == at(6)
    stop_supervised!(Engine)

    # Restarted 30 s later, B-1 readable again: its boot round leaves it to its back-off.
    free("B-1")
    ManualClock.advance(c.clock, 30_000)
    restarted = start_supervised!({Engine, c.opts})
    Engine.idle(restarted)
    assert run("B-1")["entry"] == 1
    assert backoff("B-1")["due"] == at(6)

    # At its due time it is reconciled, without a round.
    advance(restarted, c.clock, 30_000)
    assert run("B-1")["entry"] == 2
    assert backoff("B-1") == nil

    # Failing again, then stopped, and restarted after its back-off was due: at once.
    busy("B-1")
    advance(restarted, c.clock, 5 * @minute)
    assert %{"failures" => 1} = backoff("B-1")
    entry = run("B-1")["entry"]
    stop_supervised!(Engine)
    free("B-1")
    ManualClock.advance(c.clock, 2 * @minute)
    again = start_supervised!({Engine, c.opts})
    Engine.idle(again)
    assert backoff("B-1") == nil
    assert run("B-1")["entry"] == entry + 1
  end
end
