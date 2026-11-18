# S5 Fence and expiry; a stale result is refused (plan rev 2 §9 S5; review round 1). It runs
# last (file 06), on the short lease_ttl (15 s, Main's duration ruling;
# `Core.short_lease_ttl/0`) S3 restarted the core with, so it waits the product's timers,
# not the run's 180 s.
# The edge holds Lb's report and refuses everything else, so the Runtime cannot renew: it
# fences itself at lease_ttl + ≤ 10 s (La's agent is signalled), and Flow, with no timer of
# the test's, writes both leases expired, then lost at expiry + grace (120 s, prod's, not
# settable). The switch back is on that event. Lb's held `ended`, released after its lease
# was lost, is refused 410. Each lost lease's attempt must end lost (expired): Main's ruling
# on F10; it fails until Flow's fix for it lands.
import AtlasE2E.Pull.Scenario
alias AtlasE2E.Pull.{Await, Core, Edge, Facts, Hub, Stub}
alias AtlasE2E.Pull.Steps, as: S

scenario(
  "s5",
  "Fence and expiry; a stale result is refused",
  [subjects: ["s5a", "s5b"]],
  fn ctx ->
    a = S.subject(ctx, "s5a")
    b = S.subject(ctx, "s5b")
    ttl = Core.short_lease_ttl()
    retimed = Hub.mark()

    # S3 (just before) leaves the core on it; alone (`pull-e2e s5`) S5 restarts it itself.
    if Map.get(ctx, :lease_ttl) != ttl do
      step("core restart with lease_ttl #{ttl}", 180, fn ->
        instance = Core.retime!(ctx.instance, ttl)
        Core.restart(ctx.run, instance, Core.credentials(ctx.hostname, "melle", ctx.rt.token))
      end)
    end

    step("ready on lease_ttl #{ttl}", 30, fn -> S.ready(ctx, retimed, ttl) end)
    since = Hub.mark()

    step("pick up both", 60, fn ->
      S.pick_up(ctx, a)
      S.pick_up(ctx, b)
    end)

    {la, _sa, lb, sb} =
      step("grants, imports and started", 120, fn ->
        %{lease: la, started: sa} = S.run_to_started(ctx, a, since)
        %{lease: lb, started: sb} = S.run_to_started(ctx, b, since)
        {la, sa, lb, sb}
      end)

    lb_report? = fn summary -> summary.route == :report and summary.lease_id == lb.id end
    manifests0 = Map.keys(Facts.store(ctx.results).manifests)
    Edge.mode(ctx.edge, {:hold, lb_report?, :refuse})
    t_hold = Hub.mark()

    step("Lb's ended report is held", 30, fn ->
      :ok = Stub.gate(ctx.run, sb.data, Stub.complete(S.small_edits(ctx, b), "done #{b.token}"))
      S.report(lb.id, "ended", t_hold, upstream: :held)
    end)

    # The plan's deadlines, from t_hold (F10): fenced by ttl + 10 + 30 s, lost by ttl + 120 + 30 s.
    left = fn s -> max(div(t_hold.at + s * 1000 - Hub.now(), 1000), 1) end

    signalled =
      step("the Runtime fences itself", left.(ttl + 10 + 30), fn ->
        signalled = S.stub(a, "signalled", t_hold)

        Await.event(
          t_hold,
          fn
            %{source: :rt, data: data} ->
              text = JSON.encode!(data)

              text =~ "cancel" and
                (String.contains?(text, la.id) or String.contains?(text, a.task))

            _ ->
              false
          end,
          label: "the journal showing La's attempt cancelled"
        )

        signalled
      end)

    step(
      "Flow expires and loses both leases",
      left.(ttl + 120 + 30),
      fn ->
        lost? = fn lease ->
          &(S.v(&1, "lease_id") == lease.id and S.v(&1, "lease_state") == "lost" and
              S.v(&1, "lease_end_cause") == "expired")
        end

        {_, a_lost_at} = S.await_task(ctx, a, lost?.(la), "#{la.id} lost (expired)")

        # Ordering: the Runtime fenced (La's agent signalled) before Flow wrote La lost.
        check!(
          signalled.at < a_lost_at,
          "La's agent was signalled (#{signalled.at}) before La was seen lost (#{a_lost_at})"
        )

        S.await_task(ctx, b, lost?.(lb), "#{lb.id} lost (expired)")
      end
    )

    switch = Hub.mark()
    Edge.mode(ctx.edge, {:hold, lb_report?, :pass})

    {la2, sa2, lb2, sb2} =
      step("offered again: attempt 2 of both", 120, fn ->
        %{lease: la2, started: sa2} = S.run_to_started(ctx, a, switch, not: [la.id])
        %{lease: lb2, started: sb2} = S.run_to_started(ctx, b, switch, not: [lb.id])

        for old <- [la.id, lb.id] do
          held =
            Hub.select(
              switch,
              &(S.wire?(&1, :poll) and &1.data.status == 200 and
                  old in Enum.map(&1.data.req["holdings"] || [], fn h -> h["lease_id"] end))
            )

          if held != [],
            do:
              check!(
                Enum.any?(held, &(old in (&1.data.resp["lease_lost"] || []))),
                "a poll holding #{old} is told it is lost"
              )
        end

        # Attempt 1 of each is the lost lease, and nothing completed it (F10): Flow writes
        # lost/expired on the task, and leaves the attempt as its last report did.
        for {s, old} <- [{a, la.id}, {b, lb.id}] do
          [first | _] = Facts.attempts(ctx.rela, s.task)
          check!(S.v(first, "lease_id") == old, "attempt 1 of #{s.task} is #{old}", first)

          # Main's ruling on F10: the correct outcome, not today's. A lost lease's attempt
          # ends lost, for its expiry (`Steps.attempt_lost?/1`). Until Flow's fix lands
          # (a separate package, before the gate run) this check fails, as expected.
          check!(S.attempt_lost?(first), "attempt 1 of #{s.task} ended lost (expired)", first)
        end

        {la2, sa2, lb2, sb2}
      end)

    step("the stale result is refused 410", 30, fn ->
      release = Hub.mark()
      n = Edge.release(ctx.edge, lb_report?)
      check!(n >= 1, "Lb's ended report was held", n)

      {released, _} =
        Await.facts(
          fn ->
            Hub.select(
              release,
              &(S.wire?(&1, :report) and &1.data.lease_id == lb.id and
                  &1.data.upstream in [:released, :closed])
            )
          end,
          &(length(&1) >= n),
          label: "every held report of #{lb.id} answered"
        )

      check!(
        Enum.all?(released, &(&1.data.status == 410 and &1.data.type == "lease-lost")),
        "each answered 410 lease-lost",
        Enum.map(released, &{&1.data.status, &1.data.type})
      )

      task = S.task(ctx, b)

      check!(
        S.v(task, "lease_id") == lb2.id and S.v(task, "result_manifest") in [nil, ""],
        "Lb′ holds the task, no manifest",
        task
      )

      check!(
        Map.keys(Facts.store(ctx.results).manifests) -- manifests0 == [],
        "no manifest from Lb's ended"
      )
    end)

    Edge.mode(ctx.edge, :pass)

    step("both complete; only the new manifests", 90, fn ->
      ra = S.complete_and_store(ctx, a, sa2, la2.id, S.small_edits(ctx, a))
      rb = S.complete_and_store(ctx, b, sb2, lb2.id, S.small_edits(ctx, b))
      new = Map.keys(Facts.store(ctx.results).manifests) -- manifests0
      wanted = Enum.uniq([S.v(ra.task, "result_manifest"), S.v(rb.task, "result_manifest")])

      check!(
        Enum.sort(new) == Enum.sort(wanted),
        "the store's new manifests are La′'s and Lb′'s",
        %{new: new, wanted: wanted}
      )
    end)
  end
)
