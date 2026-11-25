defmodule AtlasFlow.WorkSource.DispatchTest do
  # Plan m3 A2: Dispatch, the only granter. The M1 fencing cases of poll and accept
  # (platform/atlas_runtime/test/work_source/fencing_test.exs), ported by structure to
  # Flow's source; the supervisor filter (acceptance 1), the accept deadline (5), boot (6),
  # decision 2's expiry and re-lease (4), and process isolation. FakeFacts, the result
  # store in a tmp dir, an injected manual clock; asserted on outcome tags, fact values and
  # lease ids, never on wording.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Delivery, Dispatch, FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L

  @mini {"mini", "ada"}
  @mini2 {"mini-2", "ada"}
  @laptop {"laptop", "bea"}

  setup do
    dir = Path.join(System.tmp_dir!(), "dispatch-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    ctx
  end

  defp poll(client, holdings \\ [], offer \\ %{"deep_coding" => 1}) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings, offer))
  end

  defp lease!(client) do
    assert {:polled, %{leases: [%{lease_id: id}]}} = poll(client)
    id
  end

  defp report(client, lease, revision, state),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: %{state: state}})

  defp ready(ctx) do
    Dispatch.resync()
    ctx
  end

  # F10: Dispatch casts a fence to Delivery before its sweep answers; once Delivery
  # answers a `:sys` request after that, it has handled the cast.
  defp delivered, do: :sys.get_state(Delivery)

  defp attempt(task, n \\ 1), do: FakeFacts.get("task_attempt", "TA-#{task}-#{n}")["values"]

  defp attempt_writes(task, n \\ 1),
    do: Enum.filter(FakeFacts.sent(), &(&1["key"] == "TA-#{task}-#{n}"))

  defp started(ctx, key) do
    %{task: task} = L.supervised_task(key, "ada")
    ready(ctx)
    lease = lease!(@mini)
    assert {:recorded, _} = report(@mini, lease, 1, :accepted)
    assert {:recorded, _} = report(@mini, lease, 2, :started)
    assert %{"state" => "running"} = attempt(task)
    {task, lease}
  end

  describe "accept (§5.3 item 1; fencing_test.exs accept)" do
    test "an accepted within the deadline is recorded; the lease's work is the offer", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)

      assert {:polled,
              %{
                leases: [%{lease_id: lease, work: %{work_key: ^task}}],
                timing: %{lease_ttl: 900, poll_max: 25}
              }} = poll(@mini)

      L.advance(ctx, 30)
      assert {:recorded, %{missing: []}} = report(@mini, lease, 1, :accepted)
      assert L.values(task)["lease_state"] == "accepted"
    end

    test "a late accept gets lease_lost, and the work is offered again as a fresh lease", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)

      L.advance(ctx, 31)
      assert :lease_lost = report(@mini, lease, 1, :accepted)
      assert :lease_lost = report(@mini, lease, 1, :accepted)

      assert {:polled, %{leases: [%{lease_id: fresh}], lease_lost: [^lease]}} =
               poll(@mini, [lease])

      assert fresh != lease
      assert L.values(task)["lease_id"] == fresh
      assert L.values(task)["attempt"] == 2
    end
  end

  describe "fencing (§5.3 items 2-4)" do
    test "poll renews only current, unexpired holdings of this Runtime; any other is lease_lost",
         ctx do
      L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)

      L.advance(ctx, 899)
      assert {:polled, %{lease_lost: []}} = poll(@mini, [lease], %{})
      L.advance(ctx, 899)
      Dispatch.sweep()
      assert {:recorded, _} = report(@mini, lease, 2, :started)

      assert {:polled, %{lease_lost: ["lease-unknown"]}} =
               poll(@mini, [lease, "lease-unknown"], %{})

      # Another Runtime of the same holder does not hold it, and renews nothing of it.
      assert {:polled, %{lease_lost: [^lease]}} = poll(@mini2, [lease], %{})
      assert {:polled, %{lease_lost: [^lease]}} = poll(@laptop, [lease], %{})
      L.advance(ctx, 2)
      Dispatch.sweep()
      assert {:polled, %{lease_lost: []}} = poll(@mini, [lease], %{})
    end

    test "a cancel comes through poll; the lease stays current until its work ends", ctx do
      %{run: run, task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)

      L.supervise(run, nil)
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "cancel_requested"
      assert {:polled, %{cancel: [^lease], lease_lost: []}} = poll(@mini, [lease], %{})

      assert {:recorded, _} =
               WorkSource.report(@mini, %{
                 lease_id: lease,
                 revision: 2,
                 report: L.ended(nil, kind: :cancelled)
               })
    end
  end

  describe "the Engine's cancel (F2-P: an answer moved the run on)" do
    # The Engine casts the cancel before it stores the run that no longer holds the task;
    # its store then writes the task fact's `state: cancelled`. The bench does both by
    # hand (`stored/2`).
    defp stored(key, task) do
      L.run("bin", key, supervisor: "ada")
      fact = FakeFacts.get("task", task)

      FakeFacts.put(
        "task",
        Map.merge(fact, %{
          "values" => Map.put(fact["values"], "state", "cancelled"),
          "version" => (fact["version"] || 0) + 1
        })
      )
    end

    defp accepted(ctx, key) do
      %{task: task} = L.supervised_task(key, "ada")
      ready(ctx)
      lease = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)
      {task, lease}
    end

    defp cancel_requested?(task),
      do:
        {L.values(task)["lease_state"], L.values(task)["lease_end_cause"]} ==
          {"cancel_requested", "answer"}

    test "a task free to be offered again (its lease lost) is not offered once cancelled", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      # A late accept: the lease is lost, and the task would be offered again.
      L.advance(ctx, 31)
      assert :lease_lost = report(@mini, lease, 1, :accepted)

      Dispatch.cancel(task, "answer")
      # No resync between the cancel and the poll: nothing is offered.
      assert {:polled, %{leases: []}} = poll(@mini, [lease])

      # Stored without it: no run holds it, so a resync never makes it ready again.
      stored("B-1", task)
      ready(ctx)
      assert {:polled, %{leases: []}} = poll(@mini)
    end

    test "a task whose fact says cancelled is never leased, even while the ready set still holds it",
         ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      L.advance(ctx, 31)
      assert :lease_lost = report(@mini, lease, 1, :accepted)

      # No cast reached Dispatch, and the run still holds the intent when it resyncs; the
      # task fact already says cancelled.
      stored("B-1", task)
      L.run("bin", "B-1", supervisor: "ada", intent: L.intent(task))
      ready(ctx)
      assert {:polled, %{leases: []}} = poll(@mini, [lease])
      assert L.values(task)["attempt"] == 1
    end

    test "store first, then cancel: an accepted lease is cancel_requested once the task fact says cancelled, until its work ends",
         ctx do
      {task, lease} = accepted(ctx, "B-1")

      Dispatch.cancel(task, "answer")
      # Not stored yet: nothing durable says so, the lease is untouched.
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "accepted"
      assert {:polled, %{cancel: [], lease_lost: []}} = poll(@mini, [lease], %{})

      stored("B-1", task)
      Dispatch.sweep()
      assert cancel_requested?(task)
      assert {:polled, %{cancel: [^lease], lease_lost: []}} = poll(@mini, [lease], %{})
      # Named again on the next poll, until the work ends.
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease], %{})

      assert {:recorded, _} =
               WorkSource.report(@mini, %{
                 lease_id: lease,
                 revision: 2,
                 report: L.ended(nil, kind: :cancelled)
               })
    end

    test "an offered lease of a cancelled task is lost", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)

      Dispatch.cancel(task, "answer")
      stored("B-1", task)
      Dispatch.sweep()

      assert {L.values(task)["lease_state"], L.values(task)["lease_end_cause"]} ==
               {"lost", "answer"}

      assert {:polled, %{leases: [], lease_lost: [^lease]}} = poll(@mini, [lease])
    end

    test "F10: an offered lease of a cancelled task is lost and leaves no attempt", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      _lease = lease!(@mini)

      Dispatch.cancel(task, "answer")
      stored("B-1", task)
      Dispatch.sweep()
      delivered()

      assert %{"lease_state" => "lost", "lease_end_cause" => "answer"} = L.values(task)
      assert attempt_writes(task) == []
    end

    test "F10: a started lease of a cancelled task stays running until it ends; silent, it ends lost at expiry, once",
         ctx do
      {task, lease} = started(ctx, "B-1")
      Dispatch.cancel(task, "answer")
      stored("B-1", task)
      Dispatch.sweep()
      delivered()

      assert cancel_requested?(task)
      assert %{"state" => "running"} = attempt(task)
      assert length(attempt_writes(task)) == 1

      # The Runtime never answers: the cause is the fence's that ended the lease (expiry).
      L.advance(ctx, 900)
      Dispatch.sweep()
      delivered()
      assert %{"lease_state" => "expired", "lease_end_cause" => "expired"} = L.values(task)

      assert %{"state" => "lost", "result_kind" => "expired", "lease_id" => ^lease} =
               attempt(task)

      L.advance(ctx, 120)
      Dispatch.sweep()
      delivered()
      assert L.values(task)["lease_state"] == "lost"
      assert length(attempt_writes(task)) == 2
    end

    test "Facts unavailable during the carry-out: the cancel happens once Facts is back", ctx do
      {task, lease} = accepted(ctx, "B-1")
      Dispatch.cancel(task, "answer")
      stored("B-1", task)

      :ok = GenServer.call(FakeFacts, {:busy, "task", task})
      Dispatch.sweep()
      :ok = GenServer.call(FakeFacts, {:free, "task", task})
      assert L.values(task)["lease_state"] == "accepted"

      Dispatch.sweep()
      assert cancel_requested?(task)
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease], %{})
    end

    test "the cancel write refused (the fact read fine): tried again on the next sweep", ctx do
      {task, lease} = accepted(ctx, "B-1")
      Dispatch.cancel(task, "answer")
      stored("B-1", task)

      :ok = GenServer.call(FakeFacts, {:refuse_write, "task", task})
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "accepted"
      :ok = GenServer.call(FakeFacts, {:allow_write, "task", task})

      Dispatch.sweep()
      assert cancel_requested?(task)
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease], %{})
    end

    test "Dispatch restarted after the store: the cancel still happens", ctx do
      {task, lease} = accepted(ctx, "B-1")
      Dispatch.cancel(task, "answer")
      stored("B-1", task)
      assert L.values(task)["lease_state"] == "accepted"

      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock)

      Dispatch.sweep()
      assert cancel_requested?(task)
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease], %{})
    end

    test "the sweep timer carries the cancel out", ctx do
      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock, sweep_ms: 1_000)
      {task, _lease} = accepted(ctx, "B-1")
      Dispatch.cancel(task, "answer")
      stored("B-1", task)
      assert L.values(task)["lease_state"] == "accepted"

      # The manual clock's advance sends the tick; the sweep it starts runs off Dispatch's
      # own process (IS-Atlas-110), and answers Dispatch once it ran.
      L.advance(ctx, 1)
      AtlasTestAwait.until(fn -> cancel_requested?(task) end, wake: {:trace, Dispatch})
    end

    test "a cancel whose run is never stored without the task (its store failed) cancels nothing",
         ctx do
      {task, lease} = accepted(ctx, "B-1")

      Dispatch.cancel(task, "answer")
      # The Engine follows the task again and asks for it: the task fact was never cancelled.
      Dispatch.ready(task)
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "accepted"
      assert {:polled, %{cancel: []}} = poll(@mini, [lease], %{})
    end

    test "a cancel of another task moves no lease", ctx do
      {task, lease} = accepted(ctx, "B-1")

      Dispatch.cancel("TK-other-1", "answer")
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "accepted"
      assert {:polled, %{cancel: [], lease_lost: []}} = poll(@mini, [lease], %{})
    end
  end

  describe "the supervisor filter (acceptance 1)" do
    test "no supervisor, another holder, or a state outside the span: never offered", ctx do
      L.supervised_task("B-1", nil)
      L.supervised_task("B-2", "bea")
      L.supervised_task("B-3", "ada", state: "open")
      ready(ctx)

      assert {:polled, %{leases: []}} = poll(@mini)
      assert {:polled, %{leases: [%{work: %{work_key: "TK-B-2-1"}}]}} = poll(@laptop)
    end

    test "a child subject's work goes to its parent run's supervisor", ctx do
      L.supervised_task("B-1", "ada", intent: nil)
      task = L.crate_task("C-1", "B-1")
      ready(ctx)

      assert {:polled, %{leases: []}} = poll(@laptop)
      assert {:polled, %{leases: [%{work: %{work_key: ^task}}]}} = poll(@mini)
      assert FakeFacts.get("task", task)["links"]["done_for"] == ["ada"]
    end

    test "only version-2 intents are offered; today's runs are left alone", ctx do
      FakeFacts.put("bin", %{"key" => "B-9", "values" => %{}})
      old = %{"version" => 1, "key" => "TK-B-9-1", "request" => %{"profile" => "deep_coding"}}
      L.run("bin", "B-9", intent: old, supervisor: "ada")
      L.task("TK-B-9-1", "B-9")
      ready(ctx)

      assert {:polled, %{leases: []}} = poll(@mini)
      assert L.values("TK-B-9-1")["lease_id"] == nil
    end

    test "oldest intent first, and only within the offered profiles", ctx do
      L.supervised_task("B-2", "ada", at: ~U[2026-11-17 11:00:00Z])
      L.supervised_task("B-1", "ada", at: ~U[2026-11-17 11:30:00Z])
      L.supervised_task("B-3", "ada", profile: "independent_review", at: ~U[2026-11-17 10:00:00Z])
      ready(ctx)

      assert {:polled,
              %{leases: [%{work: %{work_key: "TK-B-2-1"}}, %{work: %{work_key: "TK-B-1-1"}}]}} =
               poll(@mini, [], %{"deep_coding" => 2})

      assert {:polled, %{leases: []}} = poll(@mini, [], %{"deep_coding" => 1})
    end

    # IS-Atlas-113: the Runtime offers each profile its total of free slots; the profiles
    # share them, so a poll is never granted more leases than that total.
    test "two profiles sharing N slots: at most N leases, oldest first across both", ctx do
      L.supervised_task("B-1", "ada", at: ~U[2026-11-17 11:00:00Z])
      L.supervised_task("B-2", "ada", at: ~U[2026-11-17 11:10:00Z])
      L.supervised_task("B-3", "ada", profile: "independent_review", at: ~U[2026-11-17 10:00:00Z])
      L.supervised_task("B-4", "ada", profile: "independent_review", at: ~U[2026-11-17 12:00:00Z])
      ready(ctx)

      shared = %{"deep_coding" => 2, "independent_review" => 2}

      assert {:polled,
              %{leases: [%{work: %{work_key: "TK-B-3-1"}}, %{work: %{work_key: "TK-B-1-1"}}]}} =
               poll(@mini, [], shared)

      # A profile's own count still bounds it: one slot, and the next oldest goes.
      assert {:polled, %{leases: [%{work: %{work_key: "TK-B-2-1"}}]}} =
               poll(@mini, [], %{"deep_coding" => 1, "independent_review" => 1})

      assert {:polled, %{leases: [%{work: %{work_key: "TK-B-4-1"}}]}} =
               poll(@mini, [], shared)
    end
  end

  describe "the lease on the task fact" do
    test "a grant writes the lease fenced on the previous lease_id, with its input", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)

      grant = Enum.find(FakeFacts.sent(), &(&1["key"] == task and &1["op"] == "change"))
      assert grant["was"]["lease_id"] == nil
      assert grant["version"] == 0
      assert Map.keys(grant["values"]) -- Map.keys(grant["was"]) == []

      v = L.values(task)

      assert %{
               "lease_id" => ^lease,
               "runtime" => "mini",
               "attempt" => 1,
               "lease_state" => "offered"
             } = v

      assert {:ok, ^task, 1} = AtlasFlow.WorkSource.Leases.parse(lease)
      assert v["base_id"] == L.base().base_id
      assert v["granted_at"] == DateTime.to_iso8601(L.now(ctx))
      assert v["expires_at"] == DateTime.to_iso8601(DateTime.add(L.now(ctx), 900))
    end
  end

  describe "decision 2: expiry, grace and re-lease (acceptance 4)" do
    test "expired after lease_ttl without renewal; offered again at + grace to the same holder only",
         ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)

      L.advance(ctx, 900)
      Dispatch.sweep()
      assert %{"lease_state" => "expired", "lease_end_cause" => "expired"} = L.values(task)
      assert :lease_lost = report(@mini, lease, 2, :started)

      # Not yet at + grace: nobody gets it.
      L.advance(ctx, 119)
      assert {:polled, %{leases: []}} = poll(@mini2)

      L.advance(ctx, 1)
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "lost"

      # Lost work goes only to the same holder's Runtimes, never to another holder's.
      assert {:polled, %{leases: []}} = poll(@laptop)

      assert {:polled, %{leases: [%{lease_id: fresh}], lease_lost: [^lease]}} =
               poll(@mini2, [lease])

      assert fresh != lease
      assert {:recorded, _} = report(@mini2, fresh, 1, :accepted)
      assert :lease_lost = report(@mini, lease, 2, :started)
    end

    test "F10: a started lease's attempt ends lost at expiry, from Delivery, and once",
         ctx do
      {task, lease} = started(ctx, "B-1")

      # The next attempt write is Delivery's: it marks a fact only when it comes from there.
      :ok =
        FakeFacts.hook(
          "task_attempt",
          "TA-#{task}-1",
          "flow/delivery",
          :after,
          fn _ -> %{"key" => "from-delivery"} end,
          {"clerk", "from-delivery"}
        )

      L.advance(ctx, 900)
      Dispatch.sweep()
      delivered()

      assert %{"state" => "lost", "result_kind" => "expired", "lease_id" => ^lease} =
               v = attempt(task)

      assert v["ended_at"] == DateTime.to_iso8601(L.now(ctx))
      assert FakeFacts.get("clerk", "from-delivery") != nil

      # The grace step's lost writes the attempt no more: one write after started.
      L.advance(ctx, 120)
      Dispatch.sweep()
      delivered()
      assert L.values(task)["lease_state"] == "lost"
      assert length(attempt_writes(task)) == 2
      assert attempt(task)["ended_at"] == v["ended_at"]
    end

    test "with no other Runtime of the holder, it waits", ctx do
      L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      L.advance(ctx, 900)
      Dispatch.sweep()
      L.advance(ctx, 120)
      Dispatch.sweep()
      assert {:polled, %{leases: []}} = poll(@laptop)
      assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini, [lease])
      assert fresh != lease
    end

    test "lost work follows the supervisor of the moment after a hand-over", ctx do
      %{run: run} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      L.advance(ctx, 1020)
      Dispatch.sweep()
      Dispatch.sweep()
      L.supervise(run, "bea")
      assert {:polled, %{leases: [], lease_lost: [^lease]}} = poll(@mini, [lease])
      assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@laptop)
      assert FakeFacts.get("task", "TK-B-1-1")["links"]["done_for"] == ["bea"]
      assert fresh != lease
    end
  end

  describe "the accept deadline (acceptance 5)" do
    test "counts from the durable granted_at, across a Dispatch restart", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)

      L.advance(ctx, 20)
      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock)

      L.advance(ctx, 11)
      Dispatch.sweep()
      assert %{"lease_state" => "lost", "lease_end_cause" => "late_accept"} = L.values(task)
      assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini)
      assert fresh != lease
    end
  end

  describe "boot (acceptance 6)" do
    test "a restarted Dispatch counts live leases as renewed and loses no ready intent", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      L.supervised_task("B-2", "ada")
      ready(ctx)
      lease = lease!(@mini)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)

      L.advance(ctx, 800)
      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock)

      # Renewed at boot: past the granted expiry it is still live.
      L.advance(ctx, 800)
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "accepted"

      assert {:polled, %{lease_lost: [], leases: [%{work: %{work_key: "TK-B-2-1"}}]}} =
               poll(@mini, [lease])
    end

    test "Facts down at boot: no holding is lost meanwhile, and a silent lease still expires once Facts is back",
         ctx do
      {task, lease} = started(ctx, "B-1")
      leases_read = {:block_read, "task", %{"plain" => true}}

      :ok = stop_supervised(Dispatch)
      :ok = GenServer.call(FakeFacts, leases_read)
      L.start_dispatch(ctx.clock)

      # The Runtime's running work is not cancelled by a Dispatch that could not read the leases.
      assert {:polled, %{lease_lost: []}} = poll(@mini, [lease])

      :ok = GenServer.call(FakeFacts, put_elem(leases_read, 0, :allow_read))
      Dispatch.sweep()

      # Its Runtime gone silent, the lease ends and the task is offered again.
      L.advance(ctx, 900)
      Dispatch.sweep()
      L.advance(ctx, 120)
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "lost"
      assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini)
      assert fresh != lease
    end
  end

  # Once Dispatch holds the task's poll: the task waits in its call, which Dispatch then
  # has handled (a `:sys` request is answered only after it).
  defp held_by_dispatch(%Task{pid: pid}) do
    AtlasTestAwait.until(
      fn ->
        {:current_stacktrace, stack} = Process.info(pid, :current_stacktrace)
        Enum.any?(stack, &match?({:gen, :do_call, _, _}, &1))
      end,
      wake: {:trace, Dispatch}
    )

    :sys.get_state(Dispatch)
  end

  describe "long poll" do
    test "a held poll is answered early by a grant, else empty at poll_max", ctx do
      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock, poll_wait: 25_000)

      held = Task.async(fn -> poll(@mini) end)
      held_by_dispatch(held)
      L.supervised_task("B-1", "ada")
      Dispatch.ready("TK-B-1-1")
      assert {:polled, %{leases: [%{work: %{work_key: "TK-B-1-1"}}]}} = Task.await(held)

      held = Task.async(fn -> poll(@mini) end)
      held_by_dispatch(held)
      L.advance(ctx, 25)
      assert {:polled, %{leases: []}} = Task.await(held)
    end
  end

  # IS-Atlas-110: the sweep reads every lease's task fact (up to 6 s each on a throttled
  # core); a poll never waits for it. Each read of a task fact here takes 250 ms (below
  # Talk's 2 s retry), so the sweep of 12 leases takes some 3 s.
  describe "a slow Facts (IS-Atlas-110)" do
    @slow 250

    defp leases!(n) do
      for i <- 1..n, do: L.supervised_task("B-#{i}", "ada")
      Dispatch.resync()

      assert {:polled, %{leases: granted}} = poll(@mini, [], %{"deep_coding" => n})
      ids = granted |> Enum.map(& &1.lease_id) |> Enum.sort()
      assert length(ids) == n
      for id <- ids, do: assert({:recorded, _} = report(@mini, id, 1, :accepted))
      ids
    end

    defp timed_poll(client, holdings, offer \\ %{"deep_coding" => 1}) do
      {us, answer} = :timer.tc(fn -> poll(client, holdings, offer) end)
      {div(us, 1000), answer}
    end

    defp expires_at(id),
      do: Enum.find(Dispatch.status().leases, &(&1.lease_id == id)).expires_at

    test "polls are answered within poll_max during a sweep, with their renewals and grants; the sweep still fences the expired leases",
         ctx do
      ids = leases!(12)
      {renewed, silent} = Enum.split(ids, 6)
      late = List.last(silent)

      # The first six are renewed a second before the others expire. With a free slot, the
      # poll reads each task fact Delivery changed since (the accepts) once: nothing to grant.
      L.advance(ctx, 899)
      assert {:polled, %{lease_lost: [], leases: []}} = poll(@mini, renewed)
      L.advance(ctx, 1)

      L.supervised_task("B-13", "ada")
      Dispatch.resync()
      :ok = GenServer.call(FakeFacts, {:slow_read, "task", @slow})

      sweep = Task.async(fn -> Dispatch.sweep() end)

      AtlasTestAwait.until(fn -> :sys.get_state(Dispatch).sweep != nil end,
        wake: {:trace, Dispatch}
      )

      # Answered while the sweep reads: the renewals applied (one of them of a lease the
      # sweep found due) and the waiting task granted. poll_max is 25 s; each poll here
      # takes a grant's one slow read at most.
      assert {ms,
              {:polled,
               %{lease_lost: [], cancel: [], leases: [%{work: %{work_key: "TK-B-13-1"}}]}}} =
               timed_poll(@mini, renewed ++ [late])

      assert ms < 25_000 and ms < 2_000
      assert {ms, {:polled, %{lease_lost: [], leases: []}}} = timed_poll(@mini, renewed ++ [late])
      assert ms < 2_000
      assert {ms, {:polled, %{leases: []}}} = timed_poll(@laptop, [])
      assert ms < 2_000

      for id <- renewed ++ [late],
          do: assert(expires_at(id) == DateTime.add(L.now(ctx), 900))

      # The sweep was still running all along: it reads 12 slow task facts.
      assert Task.yield(sweep, 0) == nil
      assert :ok = Task.await(sweep, 30_000)
      :ok = GenServer.call(FakeFacts, {:fast_read, "task"})
      delivered()

      # The silent leases are fenced; the renewed ones, and the one renewed during the
      # sweep, are not.
      for id <- silent -- [late] do
        {:ok, task, 1} = WorkSource.Leases.parse(id)
        assert %{"lease_state" => "expired", "lease_end_cause" => "expired"} = L.values(task)
      end

      for id <- renewed ++ [late] do
        {:ok, task, 1} = WorkSource.Leases.parse(id)
        assert L.values(task)["lease_state"] == "accepted"
      end

      # And still lost at + grace; the one renewed during the sweep expires once silent.
      L.advance(ctx, 120)
      Dispatch.sweep()

      for id <- silent -- [late] do
        {:ok, task, 1} = WorkSource.Leases.parse(id)
        assert L.values(task)["lease_state"] == "lost"
      end

      L.advance(ctx, 780)
      Dispatch.sweep()
      {:ok, task, 1} = WorkSource.Leases.parse(late)
      assert L.values(task)["lease_state"] == "expired"
    end
  end

  describe "process isolation (Flow plan decision 11)" do
    test "Delivery suspended: Dispatch still grants and renews", ctx do
      L.supervised_task("B-1", "ada")
      L.supervised_task("B-2", "ada")
      ready(ctx)
      lease = lease!(@mini)
      :sys.suspend(Delivery)

      try do
        assert {:polled, %{leases: [_], lease_lost: []}} = poll(@mini, [lease])
      after
        :sys.resume(Delivery)
      end
    end

    test "F10: Delivery suspended, a sweep that fences a lease still answers", ctx do
      {task, _lease} = started(ctx, "B-1")
      :sys.suspend(Delivery)

      try do
        L.advance(ctx, 900)
        %Task{ref: ref} = Task.async(fn -> Dispatch.sweep() end)
        assert_receive {^ref, :ok}
        Process.demonitor(ref, [:flush])
        assert L.values(task)["lease_state"] == "expired"
      after
        :sys.resume(Delivery)
      end

      delivered()
      assert %{"state" => "lost", "result_kind" => "expired"} = attempt(task)
    end

    test "Dispatch gone: Delivery still records", ctx do
      %{task: task} = L.supervised_task("B-1", "ada")
      ready(ctx)
      lease = lease!(@mini)
      :ok = stop_supervised(Dispatch)
      assert {:recorded, _} = report(@mini, lease, 1, :accepted)
      assert L.values(task)["lease_state"] == "accepted"
    end
  end

  describe "invalid input" do
    test "a poll whose runtime_id is not the credential's, or malformed, is rejected" do
      assert {:rejected, :invalid} = WorkSource.poll(@mini, L.poll_input("laptop"))
      assert {:rejected, :invalid} = WorkSource.poll(@mini, %{runtime_id: "mini"})

      assert {:rejected, :invalid} =
               WorkSource.report(@mini, %{lease_id: "x", revision: 0, report: %{state: :accepted}})
    end
  end
end
