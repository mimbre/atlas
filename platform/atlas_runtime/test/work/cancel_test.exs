defmodule AtlasRuntime.Work.CancelTest do
  # D2 acceptance 4: every row of design §3.7.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.WorkHarness.SlowStart

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  test "buffered: cancelled never started, and it never starts", %{bench: bench} do
    busy = for n <- 1..2, do: submit!(bench, "hang #{n}")
    for work <- busy, do: await_launch(bench, work)
    waiting = submit!(bench, "complete never")

    assert %F.Outcome.Ended{work: %{state: :cancelled, attempts: [attempt]}} =
             F.cancel(client(), %{work_id: waiting.work_id, mode: "graceful"})

    assert attempt.result.never_started
    assert attempt.result.kind == :cancelled
    assert attempt.quiescent
    refute attempt.timestamps.started_at

    # A slot frees; the cancelled work still never launches.
    F.cancel(client(), %{work_id: hd(busy).work_id, mode: "force"})
    await_state(hd(busy).work_id, :cancelled)
    later = submit!(bench, "complete later")
    await_state(later.work_id, :completed)
    refute Enum.any?(launches(bench), &(&1["goal"] == "complete never"))
    F.cancel(client(), %{work_id: List.last(busy).work_id, mode: "force"})
  end

  test "running: requested, signalled, then cancelled once the group is gone; the slot is reused",
       %{bench: bench} do
    work = submit!(bench, "hang until cancelled", %{slot: "s1"}, client("c1", [:choose_slot]))
    await_launch(bench, work)

    assert %F.Outcome.Cancelling{stage: :signalled, work: %{state: :cancelling}} =
             F.cancel(client(), %{
               work_id: work.work_id,
               mode: "graceful",
               reason: "no longer needed"
             })

    done = await_state(work.work_id, :cancelled)
    [attempt] = done.attempts
    assert attempt.cancel_reason == :cancel
    assert attempt.result.kind == :cancelled
    assert attempt.result.native_outcome == :stopped
    refute attempt.result.never_started
    assert attempt.quiescent

    assert %{cancel_requested_at: %DateTime{}, signalled_at: %DateTime{}, ended_at: %DateTime{}} =
             attempt.timestamps

    # The stop's admission latch is lifted by the core: the slot takes the next work.
    next = submit!(bench, "complete after", %{slot: "s1"}, client("c1", [:choose_slot]))
    assert [%{slot: "s1"}] = await_state(next.work_id, :completed).attempts
  end

  test "a cancel during a start the Service has not answered stops the turn it started, and ends",
       %{bench: bench} do
    stop_work()
    {:ok, slow} = GenServer.start(SlowStart, {bench.service, self()})
    on_exit(fn -> Process.exit(slow, :kill) end)
    start_work!(%{bench | service: slow}, heartbeat_ms: 60_000, start_timeout_ms: 1_000)

    work =
      submit!(bench, "hang though slow to start", %{slot: "s1"}, client("c1", [:choose_slot]))

    assert_receive :start_held, 5_000
    # The core gives up waiting for the start; the cancel reaches it while it is unanswered.
    Process.sleep(1_200)

    assert %F.Outcome.Cancelling{stage: :requested, work: %{state: :cancelling}} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    # Now the Service starts the turn; the cancel finds it and stops it.
    send(slow, :go)
    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.cancel_reason == :cancel
    assert attempt.result.native_outcome == :stopped
    assert attempt.quiescent
    assert turn(bench, attempt.turn_id)["state"] == "stopped"

    # The only turn of the request: the Service started it once.
    assert [_] =
             for(
               id <- File.ls!(Path.join(bench.dir, "turns")),
               turn(bench, id)["assignment"] == work.request.instructions,
               do: id
             )

    next = submit!(bench, "complete after", %{slot: "s1"}, client("c1", [:choose_slot]))
    assert [%{slot: "s1"}] = await_state(next.work_id, :completed).attempts
  end

  test "a slot latched by a turn not of the core holds its work buffered, unchanged, until released",
       %{bench: bench} do
    at = DateTime.utc_now() |> DateTime.to_iso8601()
    AtlasRuntime.Persistence.History.latch!(bench.dir, "s1", "turn-not-the-cores", at)
    work = submit!(bench, "complete once released", %{slot: "s1"}, client("c1", [:choose_slot]))

    # Several heartbeats (100 ms) pass: the work waits, without a new revision each time.
    Process.sleep(800)
    held = work!(work.work_id)
    assert held.state == :buffered
    assert held.revision <= 3

    {:ok, _} =
      AtlasRuntime.Work.Turns.command(bench.service, %{
        "command" => "release",
        "worker_id" => "s1"
      })

    assert [%{slot: "s1"}] = await_state(work.work_id, :completed).attempts
  end

  test "a group that ignores the stop is forced after the grace, and a force escalates at once",
       %{bench: bench} do
    stubborn = submit!(bench, "stubborn one")
    await_launch(bench, stubborn)

    assert %F.Outcome.Cancelling{stage: :signalled} =
             F.cancel(client(), %{work_id: stubborn.work_id, mode: "graceful"})

    [attempt] = await_state(stubborn.work_id, :cancelled).attempts
    assert attempt.cancel_stage == :forced
    assert attempt.result.native_outcome == :killed
    assert %{forced_at: %DateTime{}} = attempt.timestamps

    other = submit!(bench, "stubborn two")
    await_launch(bench, other)

    assert %F.Outcome.Cancelling{stage: :signalled} =
             F.cancel(client(), %{work_id: other.work_id, mode: "graceful"})

    assert %F.Outcome.Cancelling{stage: :forced} =
             F.cancel(client(), %{work_id: other.work_id, mode: "force"})

    await_state(other.work_id, :cancelled)
  end

  test "terminal: ended, unchanged", %{bench: bench} do
    work = submit!(bench, "complete quickly")
    done = await_state(work.work_id, :completed)

    assert %F.Outcome.Ended{work: ^done} =
             F.cancel(client(), %{work_id: work.work_id, mode: "force"})

    assert %F.Outcome.NotFound{} =
             F.cancel(client(), %{work_id: "work-0000000000000000", mode: "force"})
  end

  test "a result that arrives while the cancel is still requested wins: completed", %{
    bench: bench
  } do
    gate = Path.join(bench.dir, "gate")
    File.write!(gate, "")
    work = submit!(bench, "wait gate")
    [%{turn_id: turn}] = await_launch(bench, work).attempts

    # The cancel reaches the core before it hears of the result: requested is written, and
    # the stop finds the turn already finished.
    core = GenServer.whereis(AtlasRuntime.Work.Server)
    :sys.suspend(core)
    cancel = Task.async(fn -> F.cancel(client(), %{work_id: work.work_id, mode: "graceful"}) end)

    await(fn ->
      match?({:message_queue_len, n} when n > 0, Process.info(core, :message_queue_len))
    end)

    File.rm!(gate)
    await(fn -> turn(bench, turn)["state"] == "finished" end)
    :sys.resume(core)

    assert %F.Outcome.Ended{work: %{state: :completed, attempts: [attempt]}} = Task.await(cancel)
    assert attempt.cancel_stage == :requested
    assert attempt.result.answer == "done: wait gate"
  end

  test "max_duration: a time-limit cancel ends failed: time_limit, not retryable", %{bench: bench} do
    write_policy!(bench.dir, %{
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only"],
          "cost_classes" => ["standard"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}],
          "limits" => %{"max_duration" => 1}
        }
      }
    })

    work = submit!(bench, "hang past the limit")
    [attempt] = await_state(work.work_id, :failed).attempts
    assert attempt.cancel_reason == :time_limit
    assert attempt.result.reason == :time_limit
    refute attempt.result.retryable
  end
end
