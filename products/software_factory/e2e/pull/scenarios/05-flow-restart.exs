# S3 Flow restart mid-run (plan rev 2 §9 S3; file 05: it runs after S4 and S6, and hands
# S5 a core already on the short lease_ttl): the core stops while the work runs and comes
# back with the same settings and credential; the lease survives it. Flow's downtime (the
# first refused poll to the first answered one) is kept as an artifact; over lease_ttl − 10 s
# it is environment_too_slow (exit 4), not a product failure.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Core, Facts, Hub}
alias AtlasE2E.Pull.Steps, as: S

scenario("s3", "Flow restart mid-run", [subjects: ["s3"]], fn ctx ->
  s = S.subject(ctx, "s3")
  since = Hub.mark()
  step("pick up", 30, fn -> S.pick_up(ctx, s) end)

  %{lease: lease, started: started} =
    step("grant, import and started", 120, fn -> S.run_to_started(ctx, s, since) end)

  step("the task on its lease", 30, fn ->
    {task, _} = S.await_task(ctx, s, &(S.v(&1, "lease_state") == "started"), "#{s.task} started")

    check!(
      S.v(task, "lease_id") == lease.id and S.v(task, "attempt") in [1, nil],
      "lease #{lease.id}, attempt 1",
      task
    )
  end)

  down = Hub.mark()

  # The refused record, not a mark before the stop, is where "after the restart" starts (F3).
  refused =
    step("core stop; the edge answers 502", 60, fn ->
      Core.stop(ctx.run, ctx.instance)

      Await.event(down, &(S.wire?(&1, :poll) and &1.data.upstream == :refused),
        label: "a poll refused upstream"
      )
    end)

  t_down = refused.at

  # The same credential, and the short lease_ttl S5 runs on (it runs next, so it needs no
  # restart of its own). This lease was renewed under 180 s before the stop, so the downtime
  # bound below is unchanged; from here on it is renewed under the short one.
  short = Core.short_lease_ttl()

  step("core restart (same credential, lease_ttl #{short})", 180, fn ->
    instance = Core.retime!(ctx.instance, short)
    Core.restart(ctx.run, instance, Core.credentials(ctx.hostname, "melle", ctx.rt.token))
  end)

  step("first answered poll keeps the lease", 30, fn ->
    up = S.up_after(refused)

    downtime = up.at - t_down

    File.write!(
      Path.join(ctx.run, "downtime.json"),
      JSON.encode!(%{t_down: t_down, t_up: up.at, ms: downtime})
    )

    IO.puts("    Flow's downtime: #{Float.round(downtime / 1000, 1)} s")

    if downtime > 170_000,
      do: raise(TooSlow, message: "Flow was down #{downtime} ms (> lease_ttl − 10 s)")

    holdings = Enum.map(up.data.req["holdings"] || [], & &1["lease_id"])
    check!(lease.id in holdings, "the poll holds #{lease.id}", holdings)

    check!(
      lease.id not in (up.data.resp["lease_lost"] || []),
      "#{lease.id} is not lost",
      up.data.resp
    )

    check!((up.data.resp["cancel"] || []) == [], "nothing is cancelled", up.data.resp)
  end)

  step("complete and stored", 60, fn ->
    S.complete_and_store(ctx, s, started, lease.id, S.small_edits(ctx, s))
  end)

  step("one attempt on one lease", 30, fn ->
    task = S.task(ctx, s)

    check!(
      S.v(task, "lease_id") == lease.id and S.v(task, "attempt") in [1, nil],
      "still lease #{lease.id}, attempt 1",
      task
    )

    check!(S.v(task, "result_state") == "complete", "a complete result", task)
    check!(length(S.stub_events(s, "started")) == 1, "exactly one agent started")
    check!(S.stub_events(s, "signalled") == [], "no agent was signalled")
    check!(length(Facts.attempts(ctx.rela, s.task)) == 1, "one attempt")
  end)

  # The run goes on with the core's new timing (S5 reads it).
  Map.put(ctx, :lease_ttl, short)
end)
