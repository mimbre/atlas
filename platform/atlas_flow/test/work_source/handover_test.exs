defmodule AtlasFlow.WorkSource.HandoverTest do
  # Plan m3 A2 acceptance 3 (decision 4): a hand-over cancels the previous supervisor's
  # work, on the supervised subject and on its children (crates under the bin, as packages
  # are under their parent). An offered lease is lost, an accepted or started one is
  # cancelled through poll, an ended one stands. After ended(cancelled) nothing is offered
  # until someone picks the run up; then the work goes only to the new supervisor's
  # Runtimes, as a new attempt. A result that arrives after the cancel request stands (B1).
  # Asserted on poll answers, fact values, casts, pins and outcomes.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Delivery, Dispatch, FakeFacts, Results, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @laptop {"laptop", "bea"}

  setup do
    dir = Path.join(System.tmp_dir!(), "handover-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    ctx
  end

  defp poll(client, holdings, offer \\ %{}) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings, offer))
  end

  defp casts do
    receive do
      {:"$gen_cast", {:reconcile, kind, key}} -> [{kind, key} | casts()]
    after
      50 -> []
    end
  end

  defp report(client, lease, revision, report),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: report})

  # F10: once Delivery answers a `:sys` request, it has handled the sweep's casts.
  defp delivered, do: :sys.get_state(Delivery)

  defp attempt(task), do: FakeFacts.get("task_attempt", "TA-#{task}-1")["values"]
  defp attempt_writes(task), do: Enum.filter(FakeFacts.sent(), &(&1["key"] == "TA-#{task}-1"))

  # Four leases of ada's: the bin's own task offered, and three crates' accepted, started
  # and ended.
  defp leases(ctx) do
    %{run: run, task: bin} = L.supervised_task("B-1", "ada", at: ~U[2026-11-17 10:00:00Z])
    c1 = L.crate_task("C-1", "B-1", at: ~U[2026-11-17 10:01:00Z])
    c2 = L.crate_task("C-2", "B-1", at: ~U[2026-11-17 10:02:00Z])
    c3 = L.crate_task("C-3", "B-1", at: ~U[2026-11-17 10:03:00Z])
    Dispatch.resync()

    assert {:polled, %{leases: granted}} = poll(@mini, [], %{"deep_coding" => 4})
    [l0, l1, l2, l3] = Enum.map(granted, & &1.lease_id)

    assert {:recorded, _} = report(@mini, l1, 1, %{state: :accepted})
    assert {:recorded, _} = report(@mini, l2, 1, %{state: :accepted})
    assert {:recorded, _} = report(@mini, l2, 2, %{state: :started})
    assert {:recorded, _} = report(@mini, l3, 1, %{state: :accepted})
    files = [{"a.txt", "a\n"}]

    assert {:recorded, %{missing: [_]}} =
             report(@mini, l3, 2, L.ended(L.change_set(files, L.base().base_id)))

    Map.merge(ctx, %{run: run, tasks: [bin, c1, c2, c3], leases: [l0, l1, l2, l3]})
  end

  test "the supervisor cleared: offered → lost, accepted and started → cancel, ended stands",
       ctx do
    %{run: run, tasks: [bin, c1, c2, c3], leases: [l0, l1, l2, l3] = all} = leases(ctx)

    L.supervise(run, nil)
    Dispatch.sweep()

    assert {:polled, %{lease_lost: [^l0], cancel: [^l1, ^l2]}} = poll(@mini, all)
    assert %{"lease_state" => "lost", "lease_end_cause" => "supervision"} = L.values(bin)

    assert %{"lease_state" => "cancel_requested", "lease_end_cause" => "supervision"} =
             L.values(c1)

    assert L.values(c2)["lease_state"] == "cancel_requested"
    assert L.values(c3)["lease_state"] == "ended"

    assert :stored =
             WorkSource.put_blob(@mini, %{
               lease_id: l3,
               sha256: L.sha256("a\n"),
               size: 2,
               content: ["a\n"]
             })

    assert L.values(c3)["result_state"] == "complete"
  end

  test "after ended(cancelled) nothing is offered until a pickup; then only to the new supervisor",
       ctx do
    %{run: run, tasks: [_, c1 | _], leases: [_, l1 | _]} = leases(ctx)

    L.supervise(run, nil)
    Dispatch.sweep()
    assert {:recorded, _} = report(@mini, l1, 2, L.ended(nil, kind: :cancelled, reason: :cancel))
    assert %{"lease_state" => "done", "lease_end_cause" => "supervision"} = L.values(c1)
    # The run gets no result (nothing is cast to the Engine): the work is offered again.
    assert :retry = Translate.outcome(FakeFacts.get("task", c1), false)
    assert casts() == []

    assert {:polled, %{leases: []}} = poll(@mini, [], %{"deep_coding" => 4})
    assert {:polled, %{leases: []}} = poll(@laptop, [], %{"deep_coding" => 4})

    L.supervise(run, "bea")
    assert {:polled, %{leases: []}} = poll(@mini, [], %{"deep_coding" => 4})
    assert {:polled, %{leases: granted}} = poll(@laptop, [], %{"deep_coding" => 4})
    assert c1 in Enum.map(granted, & &1.work.work_key)
    assert %{"attempt" => 2, "runtime" => "laptop"} = L.values(c1)
    assert FakeFacts.get("task", c1)["links"]["done_for"] == ["bea"]
  end

  # B1 (review m3-a2, plan §3.5): only returned, runtime_stop and a cancelled after the
  # cancel request are result-less. A result that arrives after cancel_requested stands:
  # the run gets it, it stays pinned, and the work is not offered again.
  describe "a result that arrives after the cancel request" do
    defp handed_over(started?) do
      %{run: run, task: task} = L.supervised_task("B-1", "ada")
      Dispatch.resync()
      assert {:polled, %{leases: [%{lease_id: lease}]}} = poll(@mini, [], %{"deep_coding" => 1})
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :accepted})
      if started?, do: assert({:recorded, _} = report(@mini, lease, 2, %{state: :started}))

      L.supervise(run, nil)
      Dispatch.sweep()
      assert {:polled, %{cancel: [^lease]}} = poll(@mini, [lease])
      assert L.values(task)["lease_state"] == "cancel_requested"
      %{run: run, task: task, lease: lease, next: if(started?, do: 3, else: 2)}
    end

    # After the pickup by bea, neither supervisor's Runtimes are offered the task again.
    defp not_offered_again(run, task) do
      L.supervise(run, "bea")

      for client <- [@laptop, @mini] do
        assert {:polled, %{leases: granted}} = poll(client, [], %{"deep_coding" => 4})
        refute task in Enum.map(granted, & &1.work.work_key)
      end

      assert %{"attempt" => 1, "lease_state" => "done"} = L.values(task)
    end

    test "ended(completed) with no change set: the result reaches the run", _ctx do
      %{run: run, task: task, lease: lease, next: next} = handed_over(true)
      assert {:recorded, %{missing: []}} = report(@mini, lease, next, L.ended(nil))

      assert %{"lease_state" => "done", "result_kind" => "completed"} = v = L.values(task)
      assert v["lease_end_cause"] == nil
      assert {:result, "completed", _} = Translate.outcome(FakeFacts.get("task", task), false)
      assert casts() == [{"bin", "B-1"}]
      not_offered_again(run, task)
    end

    test "ended(completed) with a change set: completed by put_blob, pinned, not re-offered",
         _ctx do
      %{run: run, task: task, lease: lease, next: next} = handed_over(false)
      files = [{"a.txt", "a\n"}]

      assert {:recorded, %{missing: [_]}} =
               report(@mini, lease, next, L.ended(L.change_set(files, L.base().base_id)))

      assert :stored =
               WorkSource.put_blob(@mini, %{
                 lease_id: lease,
                 sha256: L.sha256("a\n"),
                 size: 2,
                 content: ["a\n"]
               })

      assert %{"lease_state" => "done", "result_state" => "complete"} = v = L.values(task)
      assert v["lease_end_cause"] == nil
      assert {:result, "completed", _} = Translate.outcome(FakeFacts.get("task", task), false)
      assert {"bin", "B-1"} in casts()
      assert {:ok, _} = Results.manifest(task)
      not_offered_again(run, task)
      assert {:ok, _} = Results.manifest(task)
    end

    test "F10: cancel_requested ends no attempt; the Runtime's ended(completed) records it with its provenance",
         _ctx do
      %{task: task, lease: lease, next: next} = handed_over(true)
      delivered()

      assert L.values(task)["lease_state"] == "cancel_requested"
      assert %{"state" => "running"} = attempt(task)
      assert length(attempt_writes(task)) == 1

      assert {:recorded, _} = report(@mini, lease, next, L.ended(nil))

      assert %{
               "state" => "completed",
               "result_kind" => "completed",
               "lease_id" => ^lease,
               "turn_id" => "turn-1",
               "provider" => "vendor",
               "harness" => "harness"
             } = attempt(task)
    end

    test "the grant decides from the ending even when the fact still holds the cause", _ctx do
      %{run: run, task: task} = L.supervised_task("B-1", "ada")
      fact = FakeFacts.get("task", task)

      FakeFacts.put(
        "task",
        Map.merge(fact, %{
          "version" => fact["version"] + 1,
          "values" =>
            Map.merge(fact["values"], %{
              "lease_id" => "TK-B-1-1~1~old",
              "attempt" => 1,
              "lease_state" => "done",
              "lease_end_cause" => "supervision",
              "result_kind" => "completed"
            })
        })
      )

      Dispatch.resync()
      not_offered_again(run, task)
    end
  end

  test "F10: an offered lease lost to a hand-over leaves no attempt", _ctx do
    %{run: run, task: task} = L.supervised_task("B-1", "ada")
    Dispatch.resync()
    assert {:polled, %{leases: [_]}} = poll(@mini, [], %{"deep_coding" => 1})

    L.supervise(run, nil)
    Dispatch.sweep()
    delivered()

    assert %{"lease_state" => "lost", "lease_end_cause" => "supervision"} = L.values(task)
    assert attempt_writes(task) == []
  end

  test "a hand-over and a pickup by the same holder within one sweep cancel nothing", ctx do
    %{run: run, leases: all} = leases(ctx)
    L.supervise(run, nil)
    L.supervise(run, "ada")
    Dispatch.sweep()
    assert {:polled, %{lease_lost: [], cancel: []}} = poll(@mini, all)
  end

  test "a state outside the span cancels as a cleared supervisor does", ctx do
    %{tasks: [_, c1 | _], leases: [_, l1 | _] = all} = leases(ctx)
    L.run("bin", "B-1", supervisor: "ada", state: "open")
    Dispatch.sweep()
    assert {:polled, %{cancel: [^l1 | _]}} = poll(@mini, all)
    assert L.values(c1)["lease_state"] == "cancel_requested"
  end
end
