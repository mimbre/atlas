defmodule AtlasRuntime.Work.AfterCheckStopTest do
  @moduledoc """
  S5a P10b (design §5 `checking`, §6 step 2; s5a-plan B9, B19–B21, F6): the after-check is a
  sub-stage of `running`. A `cancel`, a late `max_duration` deadline and a Runtime restart
  during it all end the attempt `completed`, never `cancelling`, `cancelled`, `failed` or
  `interrupted`; after a restart the check is not run again, and the attempt is quiescent, and
  its scratch removed, only once the probe finds the check's group gone. A `retry` that
  supersedes a checking attempt cancels it as a `cancel` does, and while the check runs a
  heartbeat's `alive` is its group's. Attempts that end `failed`, `crashed`, `cancelled` or
  `interrupted` run no check.

  As in `AtlasRuntime.Work.AfterCheckTest`, the core runs the stand-in `fake-native hostcheck`
  (I-H3 as amended), which logs every launch to `check-launches.jsonl`.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [base_request: 4, expected_folder: 2, private_attempt: 3]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.{CodeStandIn, FakeNative}
  alias AtlasRuntime.Work.{Check, FrozenStore}

  @moduletag capture_log: true

  @files %{"README.md" => "base\n"}
  @held {__MODULE__, :group_gone}
  @group {__MODULE__, :check_group}

  ## The bench (as AfterCheckTest's)

  defp bench!(policy \\ %{}, options \\ []) do
    test = self()

    options =
      Keyword.merge(
        [
          check_helper: {FakeNative.path(), ["hostcheck"]},
          after_write: fn record -> send(test, {:written, record}) end
        ],
        options
      )

    bench = start!(policy, options)
    code = CodeStandIn.start!(bench.dir, @files)

    on_exit(fn ->
      stop_work()
      settled = fn -> length(jsonl(bench, "check-ends.jsonl")) >= length(checks(bench)) end
      Enum.find(1..250, fn _ -> settled.() || (Process.sleep(20) && false) end)
      CodeStandIn.stop(code, bench.dir)
    end)

    {bench, code}
  end

  defp submit_check!(code, goal, check) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(
               client(),
               base_request(code, goal, "workspace-write", %{after_check: check})
             )

    work
  end

  defp checks(bench), do: jsonl(bench, "check-launches.jsonl")

  defp check!(work_id) do
    [attempt | _] = Enum.reverse(await_state(work_id, :completed).attempts)
    attempt.result.work_product.check
  end

  # The check has started: the core holds its helper and has recorded the check's group.
  defp await_checking(bench, work_id) do
    await(fn ->
      attempt = private_attempt(bench.dir, work_id, 1)
      attempt != nil and attempt.checking == true and is_integer(attempt.check_pgid) and attempt
    end)
  end

  # Attempt `n` of the work (`await_checking/2` for any attempt).
  defp await_checking_n(bench, work_id, n) do
    await(fn ->
      attempt = private_attempt(bench.dir, work_id, n)
      attempt != nil and attempt.checking == true and is_integer(attempt.check_pgid) and attempt
    end)
  end

  defp attempt!(work_id, n), do: Enum.find(work!(work_id).attempts, &(&1.attempt == n))

  # The check result of attempt `n`, once that attempt has ended completed.
  defp await_check(work_id, n) do
    await(fn ->
      attempt = attempt!(work_id, n)
      attempt && attempt.state == :completed && attempt.result.work_product.check
    end)
  end

  # Every state attempt 1 of `work_id` was written with, in order.
  defp written_states(work_id) do
    receive do
      {:written, %{work_id: ^work_id} = record} ->
        [hd(record.attempts).state | written_states(work_id)]

      {:written, _other} ->
        written_states(work_id)
    after
      0 -> []
    end
  end

  # The probe of the restart case: every process and group is alive until the test says gone.
  def held_probe(_pid, _launched) do
    if :persistent_term.get(@held, false),
      do: {:gone, "test: the group is gone"},
      else: :alive
  end

  def gone(_pid, _launched), do: {:gone, "test: the process is gone"}

  # The probe of the heartbeat case: `{:only, pgid}` proves only the check's group alive,
  # `{:except, pgid}` every process but it (the ended turn's included).
  def group_probe(pid, _launched) do
    case :persistent_term.get(@group, nil) do
      {:only, ^pid} -> :alive
      {:except, other} when other != pid -> :alive
      _ -> {:gone, "test: not proven alive"}
    end
  end

  # The first heartbeat entry for attempt 1 of `work_id` whose `alive` is `alive`.
  defp await_running(work_id, alive) do
    await(fn ->
      Enum.find_value(notifications(), fn
        %F.Heartbeat{running: running} ->
          Enum.find(running, &(&1.work_id == work_id and &1.attempt == 1 and &1.alive == alive))

        _ ->
          nil
      end)
    end)
  end

  ## cancel during checking (B19, B20)

  test "cancel during the check: cancelling(signalled) while running; a check ignoring SIGINT is killed after cancel_grace; it ends completed with check.cancelled" do
    {bench, code} = bench!()

    work =
      submit_check!(code, "complete before an obstinate check", %{
        command: ["sh", "-c", "trap '' INT; : > atlas/trapped; sleep 30"],
        timeout: 60
      })

    await_checking(bench, work.work_id)
    # SIGINT is ignored from here on (the marker is written after the trap).
    trapped = Path.join(expected_folder(bench.dir, work.work_id), "atlas/trapped")
    await(fn -> File.exists?(trapped) end)

    assert %F.Outcome.Cancelling{stage: :signalled, work: %F.Work{attempts: [seen]}} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    assert seen.state == :running and seen.result == nil
    assert seen.cancel_stage == :signalled and seen.timestamps.signalled_at

    # A second cancel answers cancelling again and does not move the stage back.
    assert %F.Outcome.Cancelling{stage: stage} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    assert stage in [:signalled, :forced]

    assert %F.CheckResult{
             cancelled: true,
             interrupted: false,
             timed_out: false,
             exit_status: nil,
             signal: "SIGKILL",
             error: nil
           } = check = check!(work.work_id)

    assert check.duration_ms < 10_000

    [attempt] = work!(work.work_id).attempts
    assert attempt.state == :completed and attempt.result.kind == :completed
    assert attempt.result.work_product.frozen
    assert attempt.quiescent
    assert attempt.cancel_reason == :cancel and attempt.cancel_stage == :forced
    t = attempt.timestamps
    assert t.cancel_requested_at && t.signalled_at && t.forced_at
    assert DateTime.compare(t.cancel_requested_at, t.signalled_at) != :gt
    # The core's kill after cancel_grace (300 ms here), not only the helper's own grace.
    assert DateTime.diff(t.forced_at, t.signalled_at, :millisecond) >= 250
    assert DateTime.compare(t.forced_at, t.check_ended_at) != :gt

    # It never passed through cancelling, cancelled or failed.
    states = written_states(work.work_id)
    assert :completed in states
    refute Enum.any?(states, &(&1 in [:cancelling, :cancelled, :failed, :interrupted]))
    assert length(checks(bench)) == 1
  end

  test "a force cancel during the check kills its group at once: cancelling(forced), completed with check.cancelled" do
    {bench, code} = bench!()
    work = submit_check!(code, "complete before a long check", %{command: ["sleep", "30"]})
    await_checking(bench, work.work_id)

    assert %F.Outcome.Cancelling{stage: :forced, work: %F.Work{attempts: [%{state: :running}]}} =
             F.cancel(client(), %{work_id: work.work_id, mode: "force"})

    assert %F.CheckResult{cancelled: true, signal: "SIGKILL", exit_status: nil} =
             check!(work.work_id)

    [attempt] = work!(work.work_id).attempts
    assert attempt.state == :completed and attempt.cancel_stage == :forced
    assert attempt.timestamps.forced_at && is_nil(attempt.timestamps.signalled_at)
    refute Enum.any?(written_states(work.work_id), &(&1 in [:cancelling, :cancelled]))
  end

  ## retry during checking (B20; review S2)

  # M2 A7: a retry is the local source's next lease of an ended attempt (Main's round 2), so
  # nothing supersedes a check: a retry while it runs is refused and changes nothing.
  test "a retry during the check is refused and changes nothing, also after a cancel; once attempt 1 ended completed, attempt 2 starts after it" do
    {bench, code} = bench!()
    obstinate = ["sh", "-c", "trap '' INT; : > atlas/trapped; sleep 30"]

    # A retry alone: refused, the check runs on.
    plain = submit_check!(code, "complete before a long check", %{command: ["sleep", "30"]})
    await_checking(bench, plain.work_id)
    assert %F.Outcome.Refused{reason: :conflict} = F.retry(client(), %{work_id: plain.work_id})

    assert %{state: :running, checking: true, cancel_stage: nil} =
             private_attempt(bench.dir, plain.work_id, 1)

    assert [%{state: :running}] = work!(plain.work_id).attempts
    F.cancel(client(), %{work_id: plain.work_id, mode: "force"})
    await_check(plain.work_id, 1)

    # A cancel first, then the retry: refused; the cancel is neither reset nor renamed.
    work = submit_check!(code, "complete before an obstinate check", %{command: obstinate})
    await_checking(bench, work.work_id)
    trapped = Path.join(expected_folder(bench.dir, work.work_id), "atlas/trapped")
    await(fn -> File.exists?(trapped) end)

    assert %F.Outcome.Cancelling{stage: :signalled} =
             F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})

    cancelled = private_attempt(bench.dir, work.work_id, 1)
    assert %F.Outcome.Refused{reason: :conflict} = F.retry(client(), %{work_id: work.work_id})

    retried = private_attempt(bench.dir, work.work_id, 1)
    assert retried.state == :running and retried.checking == true
    assert retried.cancel_reason == :cancel
    assert retried.timestamps.cancel_requested_at == cancelled.timestamps.cancel_requested_at
    assert [_] = work!(work.work_id).attempts

    assert %F.CheckResult{cancelled: true, signal: "SIGKILL", interrupted: false} =
             await_check(work.work_id, 1)

    first = attempt!(work.work_id, 1)
    assert first.state == :completed and first.result.kind == :completed
    assert first.cancel_reason == :cancel and first.cancel_stage == :forced
    t = first.timestamps
    assert t.cancel_requested_at == cancelled.timestamps.cancel_requested_at
    assert t.signalled_at == cancelled.timestamps.signalled_at
    assert DateTime.diff(t.forced_at, t.signalled_at, :millisecond) >= 250
    refute Enum.any?(written_states(work.work_id), &(&1 in [:cancelling, :cancelled, :failed]))

    # Ended: the retry is attempt 2, which starts only once attempt 1 has ended.
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    await_checking_n(bench, work.work_id, 2)
    second = attempt!(work.work_id, 2)
    assert DateTime.compare(second.timestamps.started_at, t.ended_at) != :lt
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_check(work.work_id, 2)
  end

  ## The heartbeat during checking (§3.6, B21; review S1)

  test "a heartbeat's alive during the check follows the check's group, not the ended turn" do
    :persistent_term.put(@group, nil)
    on_exit(fn -> :persistent_term.erase(@group) end)
    {bench, code} = bench!(%{}, probe: &__MODULE__.group_probe/2)

    work =
      submit_check!(code, "complete before a long check", %{command: ["sleep", "30"], timeout: 60})

    %{check_pgid: pgid} = await_checking(bench, work.work_id)
    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}

    # Only the check's group is proven alive (the ended turn's process is not): alive.
    :persistent_term.put(@group, {:only, pgid})
    assert %{alive: true, state: :running} = await_running(work.work_id, true)

    # Everything but the check's group is proven alive (the ended turn's too): not alive.
    :persistent_term.put(@group, {:except, pgid})
    assert %{alive: false, state: :running} = await_running(work.work_id, false)

    # Both were heartbeats of the check: it still runs.
    assert private_attempt(bench.dir, work.work_id, 1).checking == true
    :persistent_term.put(@group, nil)

    assert %F.Outcome.Cancelling{} =
             F.cancel(client(), %{work_id: work.work_id, mode: "force"})

    assert %F.CheckResult{cancelled: true} = check!(work.work_id)
  end

  ## max_duration during checking (B20)

  test "a max_duration deadline message that reaches the core during the check is ignored" do
    {bench, code} = bench!()
    work = submit_check!(code, "complete before a short check", %{command: ["sleep", "1"]})
    await_checking(bench, work.work_id)

    # The race: the timer fired just before checking cancelled it.
    send(GenServer.whereis(AtlasRuntime.Work.Server), {:deadline, work.work_id, 1})

    assert %F.CheckResult{exit_status: 0, cancelled: false, timed_out: false, signal: nil} =
             check!(work.work_id)

    [attempt] = work!(work.work_id).attempts
    assert attempt.state == :completed and attempt.result.reason == nil
    assert attempt.cancel_reason == nil and attempt.cancel_stage == nil
    assert attempt.timestamps.cancel_requested_at == nil
  end

  ## Restart during checking (B9, B21, B24)

  test "a restart during the check: completed with check.interrupted at boot time, frozen result kept, not re-run; quiescent and scratch removed only once the group is gone" do
    :persistent_term.put(@held, false)
    on_exit(fn -> :persistent_term.erase(@held) end)
    {bench, code} = bench!(%{}, probe: &__MODULE__.held_probe/2)
    # The old helper, at stdin EOF, stops the group but cannot confirm it gone: the scratch stays.
    File.write!(Path.join(bench.dir, "check-fault"), "group_kept")

    work =
      submit_check!(code, "write a.txt kept", %{command: ["sleep", "30"], timeout: 60})

    checking = await_checking(bench, work.work_id)
    scratch = Check.scratch(bench.dir, work.work_id, 1)
    assert File.dir?(scratch)
    frozen = FrozenStore.get(bench.dir, work.work_id, 1)
    assert frozen && checking.result.work_product.frozen

    boot = DateTime.utc_now()
    stop_work()
    start_work!(bench)

    # The boot ends the check; it never starts a second helper for it.
    await(fn ->
      length(checks(bench)) > 1 or private_attempt(bench.dir, work.work_id, 1).state == :completed
    end)

    assert length(checks(bench)) == 1

    assert %F.CheckResult{
             interrupted: true,
             cancelled: false,
             timed_out: false,
             exit_status: nil,
             signal: nil,
             error: nil
           } = check!(work.work_id)

    [attempt] = work!(work.work_id).attempts
    assert attempt.state == :completed and attempt.result.kind == :completed
    assert DateTime.compare(attempt.timestamps.check_ended_at, boot) != :lt
    assert attempt.timestamps.ended_at == attempt.timestamps.check_ended_at
    assert DateTime.compare(attempt.timestamps.check_started_at, boot) == :lt

    # The frozen record is kept (B9), and the work product still names it.
    assert FrozenStore.get(bench.dir, work.work_id, 1) == frozen
    shown = attempt.result.work_product.frozen
    kept = checking.result.work_product.frozen
    assert shown.base == kept.base

    assert Enum.map(shown.fingerprints, &{&1.root, &1.fingerprint}) ==
             Enum.map(kept.fingerprints, &{&1.root, &1.fingerprint})

    stored = private_attempt(bench.dir, work.work_id, 1)
    assert stored.checking == false and stored.check_pgid == checking.check_pgid
    refute stored.quiescent
    assert File.dir?(scratch)

    # Heartbeats go by; the group is not proven gone, so nothing settles or is removed.
    heartbeats(6)
    refute private_attempt(bench.dir, work.work_id, 1).quiescent
    assert [%{quiescent: false}] = work!(work.work_id).attempts
    assert File.dir?(scratch)

    # The probe finds the group gone: quiescent, and only now the scratch is removed.
    :persistent_term.put(@held, true)
    assert await_work(work.work_id, &hd(&1.attempts).quiescent)
    refute File.exists?(scratch)

    # The check ran once: it was not run again after the restart.
    assert length(checks(bench)) == 1
    refute Enum.any?(written_states(work.work_id), &(&1 in [:interrupted, :cancelled, :failed]))
  end

  ## No check for other ends (F6)

  test "no host check for a failed, crashed or cancelled attempt" do
    {bench, code} = bench!()
    failed = submit_check!(code, "fail", %{command: ["true"]})
    await_state(failed.work_id, :failed)

    cancelled = submit_check!(code, "hang to cancel", %{command: ["true"]})
    await_launch(bench, cancelled)

    assert %F.Outcome.Cancelling{} =
             F.cancel(client(), %{work_id: cancelled.work_id, mode: "force"})

    await_state(cancelled.work_id, :cancelled)

    # The Service's native process dies under the turn: the attempt is crashed.
    crashed = submit_check!(code, "hang to crash", %{command: ["true"]})
    await_launch(bench, crashed)

    for pid <- Process.list(),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        dictionary[:"$initial_call"] == {AtlasRuntime.Agent.Native, :init, 1},
        do: Process.exit(pid, :kill)

    # From the store: a check started for it would leave the attempt running, never crashed.
    await(fn ->
      checks(bench) != [] or private_attempt(bench.dir, crashed.work_id, 1).state == :crashed
    end)

    assert checks(bench) == []
    await_state(crashed.work_id, :crashed)
    heartbeats(3)
    assert checks(bench) == []

    for work <- [failed, cancelled, crashed] do
      [attempt] = work!(work.work_id).attempts
      assert attempt.timestamps.check_started_at == nil
      refute attempt.result.work_product && attempt.result.work_product.check
    end
  end

  test "no host check for an attempt a restart interrupted" do
    {bench, code} = bench!()
    File.write!(Path.join(bench.dir, "gate-p10b"), "")
    work = submit_check!(code, "wait gate-p10b", %{command: ["true"]})
    [%{turn_id: turn}] = await_launch(bench, work).attempts
    await(fn -> turn(bench, turn)["session_id"] end)

    # The Runtime dies mid-turn: core, Service and helpers.
    stop_all()
    bench = %{bench | service: start_service!(bench, &__MODULE__.gone/2)}
    start_work!(bench)
    [attempt] = await_state(work.work_id, :interrupted).attempts
    File.rm(Path.join(bench.dir, "gate-p10b"))
    heartbeats(3)
    assert checks(bench) == []
    assert attempt.timestamps.check_started_at == nil
  end
end
