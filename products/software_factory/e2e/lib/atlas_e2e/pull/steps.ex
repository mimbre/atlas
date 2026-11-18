defmodule AtlasE2E.Pull.Steps do
  @moduledoc """
  The pull-e2e scenarios' shared moves and structural checks, over the run's context
  (`AtlasE2E.Pull.Run`). Every wait is an `AtlasE2E.Pull.Await`; every check is on fact
  fields, wire records (routes, statuses, problem `type`s where deterministic), stub
  events or files, never on wording.
  """
  alias AtlasE2E.Pull.{Await, Console, Facts, Fixture, Hub, Runtime, Stub}
  import AtlasE2E.Pull.Scenario, only: [check!: 3]

  def subject(ctx, id), do: Map.fetch!(ctx.subjects, id)
  def mark, do: Hub.mark()

  # ---- the wire -----------------------------------------------------------------------

  def wire?(%{source: :wire, data: d}, route), do: d.route == route
  def wire?(_, _), do: false

  @doc """
  Ready: an answered poll from this machine, begun after `since`, with Flow's test timing
  (`lease_ttl`, 180 s unless the core was restarted with another).
  """
  def ready(ctx, since, lease_ttl \\ AtlasE2E.Pull.Core.lease_ttl()) do
    from = if is_map(since), do: since.at, else: nil

    Await.event(
      since,
      fn e ->
        wire?(e, :poll) and e.data.status == 200 and e.data.req["runtime_id"] == ctx.hostname and
          e.data.resp["timing"]["lease_ttl"] == lease_ttl and
          (from == nil or e.data.began >= from)
      end,
      label: "an answered poll from #{ctx.hostname} with lease_ttl #{lease_ttl}"
    )
  end

  @doc """
  The first poll answered 200 that **began after** the `refused` record ended (F3): never a
  poll the stopped core answered before it went down, whatever order the records came in.
  """
  def up_after(refused, opts \\ []) do
    Await.event(
      refused,
      &(wire?(&1, :poll) and &1.data.status == 200 and &1.data.began > refused.data.ended),
      Keyword.put_new(opts, :label, "the first poll answered after Flow came back")
    )
  end

  @doc "The first poll answer after `since` that grants a lease on `s`'s task (not one of `not`)."
  def lease(s, since, opts \\ []) do
    excluded = opts[:not] || []

    event =
      Await.event(
        since,
        fn e ->
          wire?(e, :poll) and e.data.status == 200 and
            Enum.any?(
              e.data.resp["leases"] || [],
              &(&1["work"]["work_key"] == s.task and &1["lease_id"] not in excluded)
            )
        end,
        label: "a lease on #{s.task}"
      )

    lease =
      Enum.find(
        event.data.resp["leases"],
        &(&1["work"]["work_key"] == s.task and &1["lease_id"] not in excluded)
      )

    %{id: lease["lease_id"], work: lease["work"], event: event}
  end

  @doc "The first `report` record on `lease_id` in `state` after `since` (any status unless `status:`)."
  def report(lease_id, state, since, opts \\ []) do
    status = opts[:status]
    upstream = opts[:upstream]

    Await.event(
      since,
      fn e ->
        wire?(e, :report) and e.data.lease_id == lease_id and
          get_in(e.data.req || %{}, ["report", "state"]) == state and
          (status == nil or e.data.status == status) and
          (upstream == nil or e.data.upstream == upstream)
      end,
      label: "a #{state} report on #{lease_id}#{if status, do: " answered #{status}"}"
    )
  end

  @doc "The stub's `event` for `s` after `since`."
  def stub(s, event, since),
    do:
      Await.event(since, &Stub.event?(&1, event, s.token),
        label: "the stub's #{event} (#{s.token})"
      )

  def stub_events(s, event, since \\ 0), do: Hub.select(since, &Stub.event?(&1, event, s.token))

  # ---- facts --------------------------------------------------------------------------

  def task(ctx, s), do: Facts.task(ctx.rela, s.task)

  @doc "`{task fact, at}` once `check` holds for it, re-read on every event."
  def await_task(ctx, s, check, label),
    do: Await.facts(fn -> task(ctx, s) end, &(&1 != nil and check.(&1)), label: label)

  def v(fact, field), do: Facts.value(fact, field)

  @doc """
  Whether a lost lease's attempt record ended so (Main's ruling on F10: the gate asserts the
  correct outcome): `state` `lost`, `result_kind` `expired` (the task's `lease_state` and
  `lease_end_cause`), and an `ended_at`. The one place to align should Flow's fix name the
  ending in other fields.
  """
  def attempt_lost?(attempt),
    do:
      v(attempt, "state") == "lost" and v(attempt, "result_kind") == "expired" and
        v(attempt, "ended_at") not in [nil, ""]

  # ---- moves --------------------------------------------------------------------------

  @doc "Pick `s` up in the TUI and wait until the issue's run is supervised by melle."
  def pick_up(ctx, s) do
    Console.pick_up(ctx.console, s)

    Await.facts(
      fn -> Facts.run(ctx.rela, "issue", s.issue) end,
      &(Facts.links(&1, "supervised_by") == ["melle"]),
      label: "#{s.issue}'s run supervised by melle"
    )
  end

  @doc """
  The edits of a small result. With D2 in the tree: a new file and a delete (a blob to put);
  without it, only a delete, so the result needs no `put_blob` and the scenarios that are
  not about blobs do not depend on D2.
  """
  def small_edits(ctx, s) do
    if ctx.d2?,
      do: [Stub.write("README.pull", "pull-e2e #{s.token}\n"), Stub.delete("README.md")],
      else: [Stub.delete("README.md")]
  end

  @doc """
  Let the agent of `started` complete with `edits`, then: its `ended` report answered 200,
  one `put_blob` answered 200 per missing blob, and the task `done` with a `complete`
  result. Returns `%{ended: record, task: fact}`.
  """
  def complete_and_store(ctx, s, started, lease_id, edits) do
    since = mark()
    :ok = Stub.gate(ctx.run, started.data, Stub.complete(edits, "done #{s.token}"))
    ended = report(lease_id, "ended", since, status: 200)
    missing = ended.data.resp["missing"] || []

    for sha <- missing do
      Await.event(
        since,
        &(wire?(&1, :put_blob) and &1.data.lease_id == lease_id and &1.data.sha256 == sha and
            &1.data.status == 200),
        label: "put_blob #{sha} stored"
      )
    end

    {task, _} =
      await_task(
        ctx,
        s,
        &(v(&1, "lease_state") == "done" and v(&1, "result_state") == "complete"),
        "#{s.task} done and complete"
      )

    %{ended: ended, task: task, missing: missing}
  end

  @doc "A lease on `s` to the started stub and its `started` report (200)."
  def run_to_started(_ctx, s, since, opts \\ []) do
    lease = lease(s, since, opts)
    started = stub(s, "started", since)
    report(lease.id, "started", since, status: 200)
    %{lease: lease, started: started}
  end

  def base_sha(ctx), do: ctx.fixture.base_sha256
  def xorshift_sha(size, seed), do: Fixture.sha(size, seed)

  @doc "Whether `pid` is gone (`kill -0` fails, a zombie counting as gone), re-checked on every event."
  def await_gone(pid, label) do
    Await.facts(fn -> AtlasE2E.Pull.Bench.alive?(pid) end, &(&1 == false), label: label)
  end

  def runtime_restart(ctx) do
    rt = Runtime.start(ctx.rt)
    %{ctx | rt: rt}
  end

  def assert_no_lease_for(polls, s) do
    granted =
      for p <- polls,
          l <- p.data.resp["leases"] || [],
          l["work"]["work_key"] == s.task,
          do: l["lease_id"]

    check!(granted == [], "no poll answer grants a lease on #{s.task}", granted)
  end
end
