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

  ## Claude (S5b SB1): `stop_confirmed` is the host's group-gone probe. A Claude attempt
  ## leaves `cancelling` only on the host's `runtime.process_ended`, which follows the reap
  ## of the leader and the end of every member of its process group; the Service records it
  ## on the turn as `termination.confirmed_at`, and the attempt is then quiescent (I1).

  @claude %{
    "light_work" => %{
      "permissions" => ["read-only", "workspace-write", "materialized-folder"],
      "cost_classes" => ["low", "standard"],
      "options" => [%{"provider" => "anthropic", "harness" => "claude", "model" => "claude-test"}]
    }
  }

  defp claude!(bench, limits \\ nil) do
    profiles =
      if limits, do: put_in(@claude, ["light_work", "limits"], limits), else: @claude

    write_policy!(bench.dir, %{"profiles" => profiles})
  end

  # The fake's launch of `work`, which must be a Claude launch.
  defp claude_launch(bench, work) do
    launch = Enum.find(launches(bench), &(&1["goal"] == work.request.instructions))
    assert launch["backend"] == "claude"
    launch
  end

  defp leader_ended?(bench, work) do
    case File.read(Path.join(bench.dir, "work-ends.jsonl")) do
      {:ok, bytes} ->
        bytes
        |> String.split("\n", trim: true)
        |> Enum.map(&JSON.decode!/1)
        |> Enum.any?(&(&1["goal"] == work.request.instructions))

      {:error, :enoent} ->
        false
    end
  end

  defp alive?(pid),
    do: match?({_, 0}, System.cmd("/bin/kill", ["-0", "#{pid}"], stderr_to_stdout: true))

  defp confirmed_at(bench, turn_id),
    do: get_in(turn(bench, turn_id), ["termination", "confirmed_at"])

  test "Claude: a graceful cancel is signalled, then cancelled once the host confirms the group gone, as the turn records",
       %{bench: bench} do
    claude!(bench)
    work = submit!(bench, "hang until cancelled", %{slot: "s1"}, client("c1", [:choose_slot]))
    [%{turn_id: turn_id}] = await_launch(bench, work).attempts
    claude_launch(bench, work)

    assert %F.Outcome.Cancelling{stage: :signalled, work: %{state: :cancelling}} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.cancel_reason == :cancel
    assert attempt.cancel_stage == :signalled
    assert attempt.result.kind == :cancelled
    assert attempt.result.native_outcome == :stopped
    assert attempt.quiescent

    assert %{cancel_requested_at: %DateTime{}, signalled_at: %DateTime{}, ended_at: %DateTime{}} =
             attempt.timestamps

    # The confirmation recorded on the turn: "confirmed" in §3.7.
    assert %{"state" => "stopped", "termination" => %{"confirmed_at" => confirmed}} =
             turn(bench, turn_id)

    assert is_binary(confirmed)

    next = submit!(bench, "complete after", %{slot: "s1"}, client("c1", [:choose_slot]))
    assert [%{slot: "s1"}] = await_state(next.work_id, :completed).attempts
  end

  test "Claude: a stop is confirmed only once the group is gone; a member that ignores it holds cancelling until forced",
       %{bench: bench} do
    claude!(bench)
    work = submit!(bench, "linger past the stop")
    [%{turn_id: turn_id}] = await_launch(bench, work).attempts
    launch = claude_launch(bench, work)
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

    # Sample until the work ends. Each sample reads the turn's confirmation, then the child,
    # then the work: the Service records the confirmation before the core hears of it, so a
    # confirmation read first must find the child already gone, and the end read last must
    # find the confirmation and no child.
    samples =
      Stream.repeatedly(fn ->
        confirmed = confirmed_at(bench, turn_id)

        sample = %{
          confirmed: confirmed,
          child: alive?(child),
          leader_ended: leader_ended?(bench, work)
        }

        [attempt] = work!(work.work_id).attempts
        sample = Map.put(sample, :attempt, attempt)

        if attempt.state == :cancelled do
          Map.merge(sample, %{confirmed: confirmed_at(bench, turn_id), child: alive?(child)})
        else
          Process.sleep(10)
          sample
        end
      end)
      |> Enum.reduce_while([], fn sample, seen ->
        cond do
          sample.attempt.state == :cancelled -> {:halt, Enum.reverse([sample | seen])}
          length(seen) > 1_000 -> flunk("the work did not end")
          true -> {:cont, [sample | seen]}
        end
      end)

    {before, [ended]} = Enum.split(samples, -1)

    # Until the end the attempt is not terminal: still cancelling, with no result (designer
    # decision Q-A1 (b); `quiescent` is read only with terminal, `settled?`, so a live
    # attempt's value is not asserted), and nothing confirmed the stop while a member of the
    # group lived.
    for sample <- before do
      assert sample.attempt.state == :cancelling
      refute sample.attempt.result

      if sample.confirmed,
        do: refute(sample.child, "confirmed while the group still had a member")
    end

    # The leader ended on the SIGINT, and only its child held the group: still signalled.
    assert Enum.any?(
             before,
             &(&1.attempt.cancel_stage == :signalled and &1.leader_ended and &1.child and
                 is_nil(&1.confirmed))
           ),
           "no sample while only the lingering child held the group"

    # The first `cancelled`: the group is gone and the turn records the confirmation.
    refute ended.child
    assert is_binary(ended.confirmed)
    assert ended.attempt.cancel_stage == :forced
    assert ended.attempt.result.native_outcome == :killed
    assert ended.attempt.quiescent
    assert %{signalled_at: %DateTime{}, forced_at: %DateTime{}} = ended.attempt.timestamps
    assert turn(bench, turn_id)["state"] == "killed"
  end

  test "Claude: a force on a group that ignores SIGINT goes straight to forced, then cancelled",
       %{bench: bench} do
    claude!(bench)
    work = submit!(bench, "stubborn under force")
    [%{turn_id: turn_id}] = await_launch(bench, work).attempts
    claude_launch(bench, work)

    assert %F.Outcome.Cancelling{stage: :forced} =
             F.cancel(client(), %{work_id: work.work_id, mode: "force"})

    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.cancel_stage == :forced
    assert attempt.result.native_outcome == :killed
    assert attempt.quiescent
    assert %{forced_at: %DateTime{}, signalled_at: nil} = attempt.timestamps

    assert %{"state" => "killed", "termination" => %{"confirmed_at" => confirmed}} =
             turn(bench, turn_id)

    assert is_binary(confirmed)
  end

  # The host's group check (`kill -0 -PGID` on the recorded leader), as the core's probe: it
  # only reads, and needs no `ps` listing.
  def group(pid, _launched) do
    case System.cmd("/bin/kill", ["-0", "--", "-#{pid}"], stderr_to_stdout: true) do
      {_, 0} -> :alive
      _ -> {:gone, "test: process group #{pid} is gone"}
    end
  end

  # Designer decision Q-A1 (required row), with its Codex variant (Q-A1b): a helper
  # SIGKILLed mid-cancel ends the agent with `{:claude_failed, 137, nil}` (or
  # `{:codex_failed, 137, nil}`, `host/native.ex`) while a member of its group still lives.
  # No group-gone result is recorded, so the terminal write leaves the attempt not quiescent,
  # whatever the error text says, and the slot stays held until the probe sees the group gone.
  test "Claude: a cancelled attempt is quiescent only once its group is gone; the terminal write takes it from the group-gone result",
       %{bench: bench} do
    lost_helper_mid_cancel(bench, @claude, "claude")
  end

  test "Codex: a cancelled attempt is quiescent only once its group is gone; the terminal write takes it from the group-gone result",
       %{bench: bench} do
    lost_helper_mid_cancel(bench, nil, "codex")
  end

  defp lost_helper_mid_cancel(bench, profiles, backend) do
    policy =
      if profiles, do: %{"slots" => ["s1"], "profiles" => profiles}, else: %{"slots" => ["s1"]}

    write_policy!(bench.dir, policy)
    stop_work()
    start_work!(bench, cancel_grace_ms: 60_000, probe: &__MODULE__.group/2)
    work = submit!(bench, "linger with its helper lost")
    [%{turn_id: turn_id}] = await_launch(bench, work).attempts
    launch = Enum.find(launches(bench), &(&1["goal"] == work.request.instructions))
    assert launch["backend"] == backend
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

    await(fn -> leader_ended?(bench, work) end)
    assert [%{state: :cancelling, cancel_stage: :signalled}] = work!(work.work_id).attempts

    # The helper dies before the group is gone: nothing confirms the stop, and the turn ends
    # without it. The attempt reaches terminal on that end, not quiescent.
    System.cmd("/bin/kill", ["-9", "#{launch["ppid"]}"], stderr_to_stdout: true)
    [attempt] = await_state(work.work_id, :cancelled).attempts
    assert attempt.cancel_reason == :cancel
    assert attempt.result.kind == :cancelled
    refute attempt.quiescent
    assert %{"state" => "failed", "error" => error} = turn = turn(bench, turn_id)
    assert error =~ "#{backend}_failed"
    refute get_in(turn, ["termination", "confirmed_at"])
    assert alive?(child)

    # Not settled (I1): the slot does not take the next work while the group lives.
    next = submit!(bench, "complete after the group is gone")
    Process.sleep(300)
    assert work!(next.work_id).state == :buffered
    refute hd(work!(work.work_id).attempts).quiescent

    # The group ends (the test, never Elixir, kills its member, D7): only now is the attempt
    # quiescent, and the slot takes the next work.
    System.cmd("/bin/kill", ["-9", "#{child}"], stderr_to_stdout: true)

    assert [%{quiescent: true, state: :cancelled}] =
             await_work(work.work_id, &hd(&1.attempts).quiescent).attempts

    await_state(next.work_id, :completed)
  end

  test "Claude: a time-limit cancel ends failed: time_limit, not retryable", %{bench: bench} do
    claude!(bench, %{"max_duration" => 1})
    work = submit!(bench, "hang past the limit")
    await_launch(bench, work)
    claude_launch(bench, work)
    [attempt] = await_state(work.work_id, :failed).attempts
    assert attempt.cancel_reason == :time_limit
    assert attempt.result.reason == :time_limit
    refute attempt.result.retryable
    assert attempt.quiescent
  end
end
