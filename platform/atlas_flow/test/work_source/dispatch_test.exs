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
  end

  describe "long poll" do
    test "a held poll is answered early by a grant, else empty at poll_max", ctx do
      :ok = stop_supervised(Dispatch)
      L.start_dispatch(ctx.clock, poll_wait: 25_000)

      held = Task.async(fn -> poll(@mini) end)
      Process.sleep(50)
      L.supervised_task("B-1", "ada")
      Dispatch.ready("TK-B-1-1")
      assert {:polled, %{leases: [%{work: %{work_key: "TK-B-1-1"}}]}} = Task.await(held)

      held = Task.async(fn -> poll(@mini) end)
      Process.sleep(50)
      L.advance(ctx, 25)
      assert {:polled, %{leases: []}} = Task.await(held)
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
