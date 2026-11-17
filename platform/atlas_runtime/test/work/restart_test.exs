defmodule AtlasRuntime.Work.RestartTest do
  # D2 acceptance 6: design §6 after a restart, and the probe or release for a turn whose
  # end was never confirmed (I1).
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Restart

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

  # §3.6: `alive` is "the process group exists", proven from one listing per heartbeat.
  test "a heartbeat's alive follows the process check, from one listing per heartbeat",
       %{bench: bench} do
    for gate <- ["gate", "gate2"], do: File.write!(Path.join(bench.dir, gate), "")
    stop_work()
    verdict = :atomics.new(1, [])
    listings = :counters.new(1, [])

    processes = fn ->
      :counters.add(listings, 1, 1)
      answer = if :atomics.get(verdict, 1) == 1, do: :alive, else: :unknown
      fn _pid, _launched -> answer end
    end

    start_work!(bench, processes: processes)
    first = submit!(bench, "wait gate")
    second = submit!(bench, "wait gate2")
    session_recorded(bench, first)
    session_recorded(bench, second)
    ids = Enum.sort([first.work_id, second.work_id])

    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}
    # A turn is not alive without proof: `ps` denied or unreadable.
    assert [false, false] = await_alive(ids)

    :atomics.put(verdict, 1, 1)
    assert [true, true] = await_alive(ids, [true, true])

    # One listing per heartbeat, whatever the number of attempts (here two), over 1 s.
    notifications()
    before = :counters.get(listings, 1)
    Process.sleep(1_000)
    taken = :counters.get(listings, 1) - before
    beats = Enum.count(notifications(), &match?(%F.Heartbeat{}, &1))
    assert beats >= 3
    assert taken <= beats + 1

    for gate <- ["gate", "gate2"], do: File.rm!(Path.join(bench.dir, gate))
    await_state(first.work_id, :completed)
    await_state(second.work_id, :completed)
  end

  @tag skip: AtlasRuntime.TestHost.missing(:process_listing)
  test "the default listing proves this VM's group alive and an absent PID gone" do
    probe = Restart.processes()
    me = String.to_integer(System.pid())
    {etime, 0} = System.cmd("ps", ["-p", System.pid(), "-o", "etime="])
    started = System.os_time(:second) - etime_seconds(String.trim(etime))
    assert probe.(me, started) == :alive
    assert {:gone, _} = probe.(4_000_000, started)
  end

  defp etime_seconds(text) do
    [clock | days] = text |> String.split("-") |> Enum.reverse()
    days = Enum.map(days, &String.to_integer/1) |> Enum.sum()
    parts = clock |> String.split(":") |> Enum.map(&String.to_integer/1)
    Enum.reduce(parts, 0, &(&2 * 60 + &1)) + days * 86_400
  end

  # The `alive` of each attempt (by work id) in the next heartbeat, or once it is `want`.
  defp await_alive(ids, want \\ nil) do
    await(fn ->
      alive =
        for %F.Heartbeat{running: running} <- notifications(300), reduce: nil do
          _ ->
            running
            |> Enum.filter(&(&1.work_id in ids))
            |> Enum.sort_by(& &1.work_id)
            |> Enum.map(& &1.alive)
        end

      if alive && length(alive) == length(ids) && (want == nil or alive == want), do: alive
    end)
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

  # S5b SB1, design §6: a Claude attempt still cancelling at a restart ends cancelled, and it
  # is quiescent only once its process group is provably gone. The probe is the group check
  # the host's group-gone probe makes (`kill -0 -PGID` on the recorded leader), so it does not
  # need a `ps` listing; it only reads, and Elixir never signals the turn (D7).
  def group(pid, _launched) do
    case System.cmd("/bin/kill", ["-0", "--", "-#{pid}"], stderr_to_stdout: true) do
      {_, 0} -> :alive
      _ -> {:gone, "test: process group #{pid} is gone"}
    end
  end

  test "Claude: a restart while cancelling ends it cancelled, not quiescent until its group is gone; the slot waits",
       %{bench: bench} do
    write_policy!(bench.dir, %{
      "slots" => ["s1"],
      "profiles" => %{
        "light_work" => %{
          "permissions" => ["read-only"],
          "cost_classes" => ["standard"],
          "options" => [
            %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-test"}
          ]
        }
      }
    })

    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000)
    work = submit!(bench, "linger across the restart")
    [%{turn_id: turn_id}] = await_launch(bench, work).attempts
    launch = Enum.find(launches(bench), &(&1["goal"] == work.request.instructions))
    assert launch["backend"] == "claude"
    file = Path.join(launch["cwd"], "linger.pid")

    child =
      await(fn ->
        with {:ok, text} <- File.read(file),
             do: String.to_integer(String.trim(text)),
             else: (_ -> nil)
      end)

    on_exit(fn -> System.cmd("/bin/kill", ["-9", "#{child}"], stderr_to_stdout: true) end)

    assert %F.Outcome.Cancelling{stage: :signalled} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    # The leader has ended on the SIGINT; its child keeps the group.
    # The fake appends to work-ends.jsonl only once it has handled the signal, so the file
    # may not exist yet: no file is no end yet, until the await's deadline.
    await(fn ->
      case File.read(Path.join(bench.dir, "work-ends.jsonl")) do
        {:ok, bytes} -> bytes =~ work.request.instructions
        {:error, :enoent} -> false
      end
    end)

    assert [%{state: :cancelling, cancel_stage: :signalled}] = work!(work.work_id).attempts

    # The Runtime dies, and the turn's helper (the fake's parent) with it before it can end the
    # group on its parent's loss: the group lives on with nobody to confirm its end.
    stop_all()
    System.cmd("/bin/kill", ["-9", "#{launch["ppid"]}"], stderr_to_stdout: true)
    bench = crash_and_restart(bench, &__MODULE__.group/2, probe: &__MODULE__.group/2)

    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.cancel_reason == :cancel
    refute attempt.quiescent
    # Left as recorded (reads show it unknown), and its child alive.
    assert turn(bench, turn_id)["state"] == "stopping"
    assert group(launch["pid"], nil) == :alive

    next = submit!(bench, "complete after the group is gone")
    Process.sleep(300)
    assert work!(next.work_id).state == :buffered
    refute hd(work!(work.work_id).attempts).quiescent

    # The test ends the child; the next heartbeat's probe finds the group gone (I1).
    System.cmd("/bin/kill", ["-9", "#{child}"], stderr_to_stdout: true)
    assert [%{quiescent: true}] = await_work(work.work_id, &hd(&1.attempts).quiescent).attempts
    await_state(next.work_id, :completed)
  end
end
