defmodule AtlasRuntime.Work.RestartTest do
  # D2 acceptance 6: design §6 after a restart, and the probe or release for a turn whose
  # end was never confirmed (I1).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  @gone &__MODULE__.gone/2
  def gone(_pid, _launched), do: {:gone, "test: the process is gone"}
  def alive(_pid, _launched), do: :alive

  # The Runtime dies mid-turn: core, Service and helpers (whose groups end with them).
  defp crash_and_restart(bench, service_probe, work_options \\ []) do
    stop_all()
    bench = %{bench | service: start_service!(bench, service_probe)}
    start_work!(bench, work_options)
    bench
  end

  defp session_recorded(bench, work) do
    [%{turn_id: turn}] = await_launch(bench, work).attempts
    await(fn -> turn(bench, turn)["session_id"] end)
    turn
  end

  test "a running attempt becomes interrupted with its resume point; resume runs on its slot",
       %{bench: bench} do
    File.write!(Path.join(bench.dir, "gate"), "")
    work = submit!(bench, "wait gate")
    session_recorded(bench, work)
    before = F.capacity(client())

    bench = crash_and_restart(bench, @gone)
    [attempt] = await_state(work.work_id, :interrupted).attempts
    assert attempt.quiescent
    assert attempt.result.retryable
    assert %F.ResumePoint{turn_id: turn, conversation_id: session} = attempt.resume_point
    assert turn == attempt.turn_id

    # A new incarnation; the sequence went on.
    after_restart = F.capacity(client())
    refute after_restart.incarnation == before.incarnation

    File.rm!(Path.join(bench.dir, "gate"))
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})

    [_, second] =
      await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts)).attempts

    assert second.slot == attempt.slot
    assert List.last(launches(bench))["resumed"]
    assert List.last(launches(bench))["session_id"] == session
  end

  test "a restart during a time-limit cancel ends it failed: time_limit", %{bench: bench} do
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

    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000)
    work = submit!(bench, "stubborn past the limit")
    await_launch(bench, work)

    await_work(
      work.work_id,
      &match?([%{state: :cancelling, cancel_stage: :signalled}], &1.attempts)
    )

    crash_and_restart(bench, @gone)
    [attempt] = await_state(work.work_id, :failed).attempts
    assert attempt.result.reason == :time_limit
    assert attempt.cancel_reason == :time_limit
  end

  test "a restart during a time-limit cancel whose turn may still run ends it failed: time_limit, not quiescent",
       %{bench: bench} do
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

    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000)
    work = submit!(bench, "stubborn past the limit")
    await_launch(bench, work)

    await_work(
      work.work_id,
      &match?([%{state: :cancelling, cancel_stage: :signalled}], &1.attempts)
    )

    crash_and_restart(bench, &__MODULE__.alive/2, probe: &__MODULE__.alive/2)
    [attempt] = await_state(work.work_id, :failed).attempts
    assert attempt.result.reason == :time_limit
    assert attempt.cancel_reason == :time_limit
    refute attempt.quiescent
  end

  test "when only the core restarts, a running attempt keeps its turn and ends as it does",
       %{bench: bench} do
    File.write!(Path.join(bench.dir, "gate"), "")
    work = submit!(bench, "wait gate")
    turn = session_recorded(bench, work)

    stop_work()
    start_work!(bench)
    Process.sleep(300)
    assert [%{state: :running, turn_id: ^turn}] = work!(work.work_id).attempts

    File.rm!(Path.join(bench.dir, "gate"))
    assert [%{turn_id: ^turn}] = await_state(work.work_id, :completed).attempts
    assert length(launches(bench)) == 1
  end

  test "an attempt whose turn names no model still commits a configured model", %{bench: bench} do
    File.write!(Path.join(bench.dir, "gate"), "")
    work = submit!(bench, "wait gate")
    turn = session_recorded(bench, work)

    stop_all()
    path = Path.join([bench.dir, "turns", turn, "turn.json"])
    record = path |> File.read!() |> JSON.decode!()
    File.write!(path, JSON.encode!(Map.drop(record, ["selection", "model", "requested_model"])))
    bench = %{bench | service: start_service!(bench, @gone)}
    start_work!(bench)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    stored = AtlasRuntime.Work.Store.read_work(bench.dir, work.work_id)
    assert [%{provenance: %{configured_model: "unknown"}}] = stored.attempts
    assert attempt.provenance.configured_model == "unknown"
  end

  test "a superseded attempt still cancelling behind its successor ends at restart; the successor waits for its quiescence",
       %{bench: bench} do
    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000)
    work = submit!(bench, "stubborn superseded")
    session_recorded(bench, work)
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    assert [%{state: :cancelling}, %{state: :buffered}] = work!(work.work_id).attempts

    # Its turn is unknown after the restart: n ends cancelled, but not quiescent, so n+1 waits.
    verdict = :atomics.new(1, [])

    probe = fn _pid, _launched ->
      if :atomics.get(verdict, 1) == 1, do: {:gone, "test"}, else: :alive
    end

    crash_and_restart(bench, &__MODULE__.alive/2, probe: probe)

    [first, second] =
      await_work(work.work_id, &match?([%{state: :cancelled}, _], &1.attempts)).attempts

    assert first.result.reason == :superseded
    refute first.quiescent
    Process.sleep(300)
    assert [_, %{state: :buffered}] = work!(work.work_id).attempts
    assert second.state == :buffered

    :atomics.put(verdict, 1, 1)
    await_work(work.work_id, &match?([%{quiescent: true}, %{state: :running}], &1.attempts))
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
  end

  test "an unknown turn holds its slot until the probe finds its process gone", %{bench: bench} do
    write_policy!(bench.dir, %{"slots" => ["s1"]})
    work = submit!(bench, "hang until restart")
    session_recorded(bench, work)

    verdict = :atomics.new(1, [])

    probe = fn _pid, _launched ->
      if :atomics.get(verdict, 1) == 1, do: {:gone, "test"}, else: :alive
    end

    crash_and_restart(bench, &__MODULE__.alive/2, probe: probe)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    refute attempt.quiescent
    next = submit!(bench, "complete after the probe")
    Process.sleep(300)
    assert work!(next.work_id).state == :buffered

    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}
    :atomics.put(verdict, 1, 1)
    assert [%{quiescent: true}] = await_work(work.work_id, &hd(&1.attempts).quiescent).attempts
    await_state(next.work_id, :completed)

    assert Enum.any?(
             notifications(),
             &match?(%F.WorkChanged{work_id: id, state: :interrupted} when id == work.work_id, &1)
           )
  end

  test "an unknown turn holds its slot until a human releases it", %{bench: bench} do
    write_policy!(bench.dir, %{"slots" => ["s1"]})
    work = submit!(bench, "hang until released")
    session_recorded(bench, work)
    bench = crash_and_restart(bench, &__MODULE__.alive/2, probe: &__MODULE__.alive/2)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    refute attempt.quiescent
    next = submit!(bench, "complete after release")
    Process.sleep(300)
    assert work!(next.work_id).state == :buffered

    assert {%{worker_id: "s1"}, false} =
             GenServer.call(bench.service, %{"command" => "release", "worker_id" => "s1"})

    await_state(next.work_id, :completed)
    assert [%{quiescent: true}] = work!(work.work_id).attempts
  end

  test "after a human releases an unknown turn, retry with resume continues its conversation",
       %{bench: bench} do
    write_policy!(bench.dir, %{"slots" => ["s1"]})
    File.write!(Path.join(bench.dir, "gate"), "")
    work = submit!(bench, "wait gate")
    turn = session_recorded(bench, work)
    session = turn(bench, turn)["session_id"]
    bench = crash_and_restart(bench, &__MODULE__.alive/2, probe: &__MODULE__.alive/2)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    refute attempt.quiescent
    assert turn(bench, turn)["state"] == "running"

    assert {%{worker_id: "s1"}, false} =
             GenServer.call(bench.service, %{"command" => "release", "worker_id" => "s1"})

    assert [%{quiescent: true}] = await_work(work.work_id, &hd(&1.attempts).quiescent).attempts
    assert turn(bench, turn)["state"] == "failed"

    File.rm!(Path.join(bench.dir, "gate"))
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id, resume: true})

    [_, second] =
      await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts)).attempts

    assert second.slot == "s1"
    assert List.last(launches(bench))["resumed"]
    assert List.last(launches(bench))["session_id"] == session
  end

  test "subscribers resuming across a restart get reset; within the window they get what they missed",
       %{bench: bench} do
    first = submit!(bench, "complete before")
    done = await_state(first.work_id, :completed)

    bench = crash_and_restart(bench, @gone)

    assert %F.Outcome.Reset{current_sequence: current} =
             F.subscribe(client(), %{from: done.sequence})

    assert current >= done.sequence

    second = submit!(bench, "complete after")
    await_state(second.work_id, :completed)
    assert %F.Outcome.Subscribed{} = F.subscribe(client(), %{from: current})

    missed =
      for %F.WorkChanged{work_id: id} = n <- notifications(200), id == second.work_id, do: n.state

    assert List.first(missed) == :buffered
    assert List.last(missed) == :completed
    assert %F.Outcome.Reset{} = F.subscribe(client(), %{from: current + 10_000})
  end
end
