# S4 Runtime crash mid-run (plan rev 2 §9 S4, with the re-review's note N4): the service's
# group is KILLed while the agent runs. The host helper is a Port child in a session of its
# own, so it survives the group's KILL, sees its stdin end and SIGINTs the turn: the agent
# reports `signalled` (expected). The restarted Runtime reports the attempt `interrupted`,
# Flow offers the work again as attempt 2, and that one completes. `events --follow` does
# not end on a crash: it prints one `reachable: false` line and reconnects by itself.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Bench, Facts, Hub, Runtime}
alias AtlasE2E.Pull.Steps, as: S

scenario("s4", "Runtime crash mid-run", [subjects: ["s4"]], fn ctx ->
  s = S.subject(ctx, "s4")
  since = Hub.mark()
  step("pick up", 30, fn -> S.pick_up(ctx, s) end)

  %{lease: lease, started: started} =
    step("grant, import and started", 120, fn -> S.run_to_started(ctx, s, since) end)

  agent = started.data["pid"]

  crash = Hub.mark()

  step("crash: KILL the service's group", 10, fn ->
    Runtime.crash(ctx.rt, ctx.own.pgid)

    Await.event(crash, &(&1.source == :rt and &1.data["reachable"] == false),
      label: "the journal follower losing the Runtime"
    )

    S.await_gone(ctx.rt.group.pid, "the Runtime's BEAM gone")
  end)

  step("the orphaned turn is stopped by its helper", 30, fn -> S.stub(s, "signalled", crash) end)

  restarted = Hub.mark()
  ctx = step("warm Runtime start", 90, fn -> S.runtime_restart(ctx) end)

  step("first poll: a new incarnation holding the lease", 30, fn ->
    Await.event(
      restarted,
      fn e ->
        S.wire?(e, :poll) and e.data.status == 200 and
          e.data.req["incarnation"] not in [nil, ctx.incarnation0] and
          lease.id in Enum.map(e.data.req["holdings"] || [], & &1["lease_id"])
      end,
      label: "a poll of the new incarnation holding #{lease.id}"
    )
  end)

  step("interrupted", 30, fn ->
    ended = S.report(lease.id, "ended", restarted, status: 200)

    check!(
      get_in(ended.data.req, ["report", "result", "kind"]) == "interrupted",
      "the ending is interrupted",
      ended.data.req
    )

    # The attempt record is stable; the task fact moves on to the next lease as soon as Flow
    # offers the work again, so it is checked only while it still holds this one.
    Await.facts(
      fn -> Facts.attempts(ctx.rela, s.task) end,
      &match?([%{"values" => %{"result_kind" => "interrupted"}} | _], &1),
      label: "#{s.task}'s attempt 1 interrupted"
    )

    task = S.task(ctx, s)

    if S.v(task, "lease_id") == lease.id do
      check!(
        {S.v(task, "lease_state"), S.v(task, "lease_end_cause"), S.v(task, "result_state")} ==
          {"done", "interrupted", nil},
        "the lease done, ended interrupted, no result",
        task
      )
    end
  end)

  %{lease: again, started: started2} =
    step("offered again: attempt 2", 90, fn ->
      S.run_to_started(ctx, s, restarted, not: [lease.id])
    end)

  step("complete and stored", 60, fn ->
    S.complete_and_store(ctx, s, started2, again.id, S.small_edits(ctx, s))
  end)

  step("two attempts, two launches, the first agent gone", 30, fn ->
    attempts = Facts.attempts(ctx.rela, s.task)

    check!(
      Enum.map(attempts, &{S.v(&1, "lease_id"), S.v(&1, "result_kind")}) == [
        {lease.id, "interrupted"},
        {again.id, "completed"}
      ],
      "attempts: #{lease.id} interrupted, #{again.id} completed",
      attempts
    )

    check!(length(S.stub_events(s, "started")) == 2, "exactly two launches")
    check!(not Bench.alive?(agent), "the first agent (pid #{agent}) is gone")
  end)

  ctx
end)
