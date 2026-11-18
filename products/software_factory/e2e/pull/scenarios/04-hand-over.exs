# S6 Hand-over cancel (plan rev 2 §9 S6): melle hands the running issue over to adrienne in
# the TUI. Flow cancels the lease (the agent is signalled, the attempt ends), clears the
# supervisor and gives adrienne a To-Do; nothing is offered while nobody supervises it.
# melle picks it up again and attempt 2 completes.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Console, Facts, Hub}
alias AtlasE2E.Pull.Steps, as: S

scenario("s6", "Hand-over cancel", [subjects: ["s6"]], fn ctx ->
  s = S.subject(ctx, "s6")
  since = Hub.mark()
  step("pick up", 30, fn -> S.pick_up(ctx, s) end)

  %{lease: lease} =
    step("grant, import and started", 120, fn -> S.run_to_started(ctx, s, since) end)

  handed = Hub.mark()

  step("hand over to adrienne in the TUI", 30, fn ->
    Console.hand_over(ctx.console, s, "Adrienne")
  end)

  cancel =
    step("cancel → signalled → ended", 30, fn ->
      cancel =
        Await.event(
          handed,
          &(S.wire?(&1, :poll) and &1.data.status == 200 and
              lease.id in (&1.data.resp["cancel"] || [])),
          label: "a poll answer cancelling #{lease.id}"
        )

      S.stub(s, "signalled", handed)
      S.report(lease.id, "ended", handed, status: 200)
      cancel
    end)

  step("facts: no supervisor, adrienne's To-Do, ended for supervision", 30, fn ->
    Await.facts(
      fn -> Facts.run(ctx.rela, "issue", s.issue) end,
      &(Facts.links(&1, "supervised_by") == []),
      label: "#{s.issue} unsupervised"
    )

    {to_dos, _} =
      Await.facts(
        fn -> Facts.to_dos_for(ctx.rela, "adrienne") end,
        &Enum.any?(&1, fn t -> String.contains?(JSON.encode!(t["values"]), s.issue) end),
        label: "a To-Do for adrienne naming #{s.issue}"
      )

    check!(to_dos != [], "adrienne has the hand-over's To-Do")
    [first | _] = Facts.attempts(ctx.rela, s.task)
    check!(S.v(first, "lease_id") == lease.id, "attempt 1 is #{lease.id}", first)
    task = S.task(ctx, s)

    # Unconditional (F9): while nobody supervises the issue nothing moves the task to another lease.
    check!(
      S.v(task, "lease_id") == lease.id and S.v(task, "lease_end_cause") == "supervision",
      "the lease #{lease.id} ended for supervision",
      task
    )
  end)

  step("negative: nothing offered while unsupervised", 30, fn ->
    polls = Await.polls(2, cancel.at + 5_000, label: "two answered polls after the cancel")
    S.assert_no_lease_for(polls, s)
  end)

  again = Hub.mark()
  step("melle picks it up again", 30, fn -> S.pick_up(ctx, s) end)

  %{lease: lease2, started: started2} =
    step("attempt 2: grant, import, started", 120, fn ->
      S.run_to_started(ctx, s, again, not: [lease.id])
    end)

  step("complete and stored", 60, fn ->
    S.complete_and_store(ctx, s, started2, lease2.id, S.small_edits(ctx, s))
  end)
end)
