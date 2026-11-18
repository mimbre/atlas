# S1 Supervisor filter (plan rev 2 §9 S1). The core runs with adrienne's credential for this
# machine's Runtime; melle picks the issue up, so its task is never offered here. Then the
# core restarts with melle's credential (the real rotation path) and the task is offered,
# accepted, started and completed.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Core, Facts, Hub}
alias AtlasE2E.Pull.Steps, as: S

scenario("s1", "Supervisor filter", [subjects: ["s1"]], fn ctx ->
  s = S.subject(ctx, "s1")

  step("issue and package (seeded)", 30, fn ->
    check!(
      Facts.get(ctx.rela, "packages", s.package) != nil,
      "the package #{s.package} is in rela"
    )
  end)

  step("pick up in the TUI as melle", 30, fn -> S.pick_up(ctx, s) end)

  _ =
    step("a version-2 intent for the task", 30, fn ->
      Await.facts(
        fn -> Facts.run(ctx.rela, "package", s.package) end,
        &match?(%{"version" => 2, "key" => _}, get_in(&1 || %{}, ["values", "pending", "task"])),
        label: "#{s.package}'s run holds its task intent"
      )
    end)

  # The negative's mark is now, after the intent was seen (F8): never before it was written.
  c = Hub.now()
  run = Facts.run(ctx.rela, "package", s.package)

  check!(
    get_in(run, ["values", "pending", "task", "key"]) == s.task,
    "the intent is #{s.task}",
    get_in(run, ["values", "pending"])
  )

  step("negative: not offered to adrienne's Runtime", 30, fn ->
    # Two answered polls with a free slot on offer, both begun a resync after the intent.
    polls =
      Await.polls(2, c + 5_000,
        match: &(map_size(&1.req["offer"] || %{}) > 0),
        label: "two answered polls with an offer"
      )

    S.assert_no_lease_for(polls, s)
    check!(S.v(S.task(ctx, s), "lease_id") in [nil, ""], "#{s.task} has no lease", S.task(ctx, s))
    check!(S.stub_events(s, "started") == [], "no agent started for #{s.token}")
  end)

  since = Hub.mark()

  step("core restart with melle's credential", 180, fn ->
    Core.restart(ctx.run, ctx.instance, Core.credentials(ctx.hostname, "melle", ctx.rt.token))
  end)

  # Ready on a poll begun after the restart returned: the new core's (F8). The grant is
  # searched from before the restart: the old core (adrienne's credential) cannot make it.
  restarted = Hub.mark()
  step("ready", 30, fn -> S.ready(ctx, restarted) end)

  lease = step("granted to melle's Runtime", 30, fn -> S.lease(s, since) end)

  step("accepted", 30, fn ->
    S.report(lease.id, "accepted", since, status: 200)

    {task, _} =
      S.await_task(ctx, s, &(S.v(&1, "lease_id") == lease.id), "#{s.task} on #{lease.id}")

    check!(Facts.links(task, "done_for") == ["melle"], "done for melle", task)
    check!(S.v(task, "runtime") == ctx.hostname, "held by this Runtime", task)
    check!(S.v(task, "lease_state") in ["accepted", "started"], "the lease is accepted", task)
  end)

  started =
    step("import and started", 60, fn ->
      started = S.stub(s, "started", since)
      S.report(lease.id, "started", since, status: 200)
      started
    end)

  step("complete and stored", 60, fn ->
    S.complete_and_store(ctx, s, started, lease.id, S.small_edits(ctx, s))
  end)

  step("completion facts", 30, fn ->
    task = S.task(ctx, s)

    check!(
      S.v(task, "result_state") == "complete" and S.v(task, "lease_state") == "done",
      "complete and done",
      task
    )

    attempts = Facts.attempts(ctx.rela, s.task)

    check!(
      Enum.map(attempts, &{S.v(&1, "lease_id"), S.v(&1, "result_kind")}) == [
        {lease.id, "completed"}
      ],
      "one completed attempt on #{lease.id}",
      attempts
    )
  end)
end)
