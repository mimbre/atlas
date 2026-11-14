defmodule AtlasFlow.RoundTest do
  # The engine's round, planned in one message and taken one step per message
  # (AtlasFlow.Engine): what comes while it steps is handled between two steps, a restart
  # mid-round converges, and nothing is written twice for one change. The engine is held
  # at a chosen step through `:sys.install/2`, so no time passes but the manual clock's.
  use ExUnit.Case, async: false

  alias AtlasBus.Envelope
  alias AtlasFlow.{Engine, FakeFacts, ManualClock, Settled, Talk, TestModel}
  alias AtlasFlow.Runs.{Run, Store}

  @every 3_600_000
  # Widgets, so a round takes this many steps to reconcile them and as many to project.
  @widgets for n <- 1..40, do: "W-" <> String.pad_leading("#{n}", 2, "0")

  setup do
    Application.put_env(:atlas_bus, :store, "round-#{System.unique_integer([:positive])}")
    :ok = AtlasBus.attach("tester-#{System.unique_integer([:positive])}")
    start_supervised!({FakeFacts, description: AtlasFlow.Workshop.description()})
    FakeFacts.put("maker", %{"key" => "mia"})
    clock = start_supervised!({ManualClock, ~U[2026-11-12 00:00:00Z]})
    %{clock: clock, opts: [every: @every, clock: {ManualClock, clock}, model: AtlasFlow.Workshop]}
  end

  defp widget(key), do: FakeFacts.put("widget", %{"key" => key, "values" => %{"title" => key}})
  defp todo(key), do: FakeFacts.get("widget", key)["values"]["todo"]

  defp stale(key),
    do: FakeFacts.put("widget", put_in(FakeFacts.get("widget", key), ["values", "todo"], "stale"))

  defp run_key(key), do: Run.key("tend", "widget", key, 1)

  # Flow's writes on `key` (a widget's, or a run's) since `from` of them.
  defp writes(key, from),
    do: Enum.count(Enum.drop(FakeFacts.stored_from_flow(), from), &(&1["key"] == key))

  # Hold the engine before each of `steps` (the round's step messages, counted from now),
  # until `go/1`: `ref`; the test gets `{ref, :held, n}` at each.
  defp hold_at(engine, steps) do
    test = self()
    ref = make_ref()

    hold = fn
      n, {:in, :round_step}, _state ->
        n = n + 1

        if n in steps do
          send(test, {ref, :held, n})
          receive do: ({^ref, :go} -> :ok)
        end

        n

      n, _event, _state ->
        n
    end

    :ok = :sys.install(engine, {hold, 0})
    ref
  end

  defp go(engine, ref), do: send(engine, {ref, :go})

  defp ask(position) do
    request = %{Envelope.new("request", "_settled") | address: "flow"}
    :ok = AtlasBus.send(request, %{"position" => position})
    request.id
  end

  test "a `_settled` request, and its hint, that come while a round steps are answered before it ends",
       c do
    for key <- @widgets, do: widget(key)
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    for key <- @widgets, do: stale(key)
    from = length(FakeFacts.stored_from_flow())

    # The round: 40 reconcile steps, then 40 projections, W-01 to W-40. Held at the 50th
    # (W-10's projection) and the 60th (W-20's).
    ref = hold_at(engine, [50, 60])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 50}, 1_000
    assert todo("W-09") == "Tend it" and todo("W-10") == "stale"

    # A part made under W-40, whose step is far off, and the writer asking after it.
    {:stored, p} =
      Talk.put("part", %{"op" => "create", "key" => "P-1", "links" => %{"of_widget" => ["W-40"]}})

    id = ask(p)
    go(engine, ref)

    # Ten steps on, the round still steps; the request was answered, and the hint applied.
    assert_receive {^ref, :held, 60}, 1_000
    assert_received {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}}
    assert settled >= p
    assert todo("W-40") == "Tend it"
    assert todo("W-30") == "stale"
    go(engine, ref)

    Engine.idle(engine)
    assert Enum.all?(@widgets, &(todo(&1) == "Tend it"))
    # W-40 written once: by the hint, and not again by its step.
    assert writes("W-40", from) == 1
    assert Enum.all?(@widgets, &(writes(&1, from) == 1))
  end

  test "a subject is never written twice for one change, whether its step came or not", c do
    for key <- @widgets, do: widget(key)
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    from = length(FakeFacts.stored_from_flow())

    # Held at the 10th reconcile step (W-10's): W-03's step passed, W-30's is ahead.
    ref = hold_at(engine, [10])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 10}, 1_000

    for key <- ["W-03", "W-30"] do
      {:stored, _} =
        Talk.put("widget", %{"op" => "change", "key" => key, "values" => %{"state" => "done"}})
    end

    go(engine, ref)
    Engine.idle(engine)
    # And once more: nothing changed since.
    Engine.round(engine)

    config = TestModel.config()

    for key <- ["W-03", "W-30"] do
      {:ok, run} = Store.decode(config, FakeFacts.get("cursor", run_key(key)))
      assert run["status"] == "completed"
      assert todo(key) == nil
      # One write of the run (its completion) and one of the widget (its todo cleared).
      assert writes(run_key(key), from) == 1
      assert writes(key, from) == 1
    end

    assert writes(run_key("W-04"), from) == 0
  end

  test "an engine restarted mid-round converges, each run made once", c do
    widget("W-00")

    first =
      start_supervised!(Supervisor.child_spec({Engine, c.opts}, id: :first, restart: :temporary))

    Engine.round(first)
    # Widgets no hint told of: only a round gives them runs.
    for key <- @widgets, do: widget(key)
    from = length(FakeFacts.stored_from_flow())

    ref = hold_at(first, [20])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 20}, 1_000
    made = for key <- @widgets, FakeFacts.get("cursor", run_key(key)), do: key
    assert length(made) in 1..39

    monitor = Process.monitor(first)
    Process.exit(first, :kill)
    assert_receive {:DOWN, ^monitor, _, _, _}, 1_000

    # The restarted engine plans a round of its own at once.
    again = start_supervised!(Supervisor.child_spec({Engine, c.opts}, id: :again))
    Engine.idle(again)

    for key <- @widgets do
      assert {:ok, %{"entry" => 1, "status" => "active"}} =
               Store.decode(TestModel.config(), FakeFacts.get("cursor", run_key(key)))

      assert FakeFacts.get("cursor", Run.key("tend", "widget", key, 2)) == nil
      assert todo(key) == "Tend it"
      # Made once, before or after the restart; its widget presented once.
      assert writes(run_key(key), from) == 1
      assert writes(key, from) == 1
    end
  end

  test "a failed round keeps an earlier hint held until a successful round", c do
    widget("W-00")
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    GenServer.call(FakeFacts, {:busy, "widget", "W-01"})

    {:stored, p} =
      Talk.put("widget", %{"op" => "create", "key" => "W-01", "values" => %{}})

    id = ask(p)
    Engine.round(engine)
    # Planning succeeded, but W-01's step failed: ending that round releases nothing.
    assert Settled.value(:sys.get_state(engine).settled) < p
    refute_received {:atlas_bus, %Envelope{id: ^id, class: "answer"}, _}
    assert FakeFacts.get("cursor", run_key("W-01")) == nil

    GenServer.call(FakeFacts, {:free, "widget", "W-01"})
    Engine.round(engine)
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}}
    assert settled >= p

    assert {:ok, %{"status" => "active"}} =
             Store.decode(TestModel.config(), FakeFacts.get("cursor", run_key("W-01")))
  end

  test "a hint that fails between steps is not released by the round already stepping", c do
    for key <- @widgets, do: widget(key)
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)

    # W-01 was reconciled before the hint arrived; this round cannot cover its failure.
    ref = hold_at(engine, [10, 11])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 10}, 1_000
    GenServer.call(FakeFacts, {:busy, "widget", "W-01"})

    {:stored, p} =
      Talk.put("widget", %{"op" => "change", "key" => "W-01", "values" => %{"state" => "done"}})

    id = ask(p)
    go(engine, ref)
    assert_receive {^ref, :held, 11}, 1_000
    GenServer.call(FakeFacts, {:free, "widget", "W-01"})
    go(engine, ref)
    Engine.idle(engine)

    assert Settled.value(:sys.get_state(engine).settled) < p
    refute_received {:atlas_bus, %Envelope{id: ^id, class: "answer"}, _}

    assert {:ok, %{"status" => "active"}} =
             Store.decode(TestModel.config(), FakeFacts.get("cursor", run_key("W-01")))

    Engine.round(engine)
    assert_receive {:atlas_bus, %Envelope{id: ^id, class: "answer"}, %{"settled" => settled}}
    assert settled >= p

    assert {:ok, %{"status" => "completed"}} =
             Store.decode(TestModel.config(), FakeFacts.get("cursor", run_key("W-01")))

    assert todo("W-01") == nil
  end

  test "timer notifications coalesce without a synchronous round request", c do
    widget("A")
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)
    from = length(FakeFacts.stored_from_flow())

    # The first round has two steps. Hold the queued round after its plan too,
    # so another missed start can detect an unintended third round.
    # The third mailbox step ends the first round; the fourth is after the
    # follow-up plan has captured A and Z.
    ref = hold_at(engine, [1, 2, 4])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 1}, 1_000
    widget("Z")
    for _ <- 1..5, do: send(engine, :round)
    go(engine, ref)
    assert_receive {^ref, :held, 2}, 1_000
    assert todo("Z") == nil
    go(engine, ref)
    assert_receive {^ref, :held, 4}, 1_000
    widget("later")
    go(engine, ref)
    Engine.idle(engine)
    Engine.idle(engine)

    assert todo("Z") == "Tend it"
    assert todo("later") == nil
    assert writes("Z", from) == 1
    assert writes(run_key("Z"), from) == 1
  end

  test "a round asked for while one steps is planned after it ends", c do
    for key <- @widgets, do: widget(key)
    engine = start_supervised!({Engine, c.opts})
    Engine.round(engine)

    ref = hold_at(engine, [5, 6])
    ManualClock.advance(c.clock, @every)
    assert_receive {^ref, :held, 5}, 1_000
    # Not stepping yet: a widget the stepping round did not plan for, and one more due.
    widget("W-99")
    send(engine, :round)
    # Enqueued before the engine resumes, rather than racing a separate task's call.
    request = :gen_server.send_request(engine, :round)
    go(engine, ref)
    assert_receive {^ref, :held, 6}, 1_000
    assert :gen_server.wait_response(request, 0) == :timeout
    assert todo("W-99") == nil
    go(engine, ref)
    assert :gen_server.receive_response(request, 5_000) == {:reply, :ok}

    assert todo("W-99") == "Tend it"
    assert :sys.get_state(engine).round == nil
  end
end
