defmodule AtlasFlow.WorkSource.DeliveryTest do
  # Plan m3 A2: Delivery of reports and results, through AtlasFlow.WorkSource. The M1
  # report and result-upload cases (platform/atlas_runtime/test/work_source/fencing_test.exs)
  # ported by structure, plus Flow's own: the expiry fence's Delivery half (acceptance 4),
  # results over Git and retention (7), get_blob's scope (8). FakeFacts, FakeCode behind
  # Bases and a manual clock; asserted on outcome tags, fact values and casts, never on
  # wording. A result travels over Git (IS-Atlas-100): no blob is ever asked for or put.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @laptop {"laptop", "bea"}
  @readme "# hello\n"

  setup do
    dir = Path.join(System.tmp_dir!(), "delivery-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    ctx
  end

  defp grant(ctx, opts \\ []) do
    key = Keyword.get(opts, :bin, "B-1")
    %{task: task} = L.supervised_task(key, "ada", opts)
    Dispatch.resync()
    {:polled, %{leases: [%{lease_id: lease}]}} = poll(@mini)
    Map.merge(ctx, %{task: task, lease: lease})
  end

  defp poll(client, holdings \\ []) do
    {id, _} = client
    WorkSource.poll(client, L.poll_input(id, holdings))
  end

  defp report(client, lease, revision, report),
    do: WorkSource.report(client, %{lease_id: lease, revision: revision, report: report})

  defp state(atom), do: %{state: atom}

  defp ended(files, opts \\ []), do: L.ended(L.change_set(files, L.base().base_id, opts), opts)

  # A lease accepted, started and ended with these files in its change set.
  defp ended_lease!(ctx, files, opts \\ []) do
    ctx = grant(ctx, opts)
    assert {:recorded, %{missing: []}} = report(@mini, ctx.lease, 1, state(:accepted))
    assert {:recorded, %{missing: []}} = report(@mini, ctx.lease, 2, state(:started))
    assert {:recorded, %{missing: missing}} = report(@mini, ctx.lease, 3, ended(files, opts))
    Map.put(ctx, :missing, missing)
  end

  defp casts do
    receive do
      {:"$gen_cast", {:reconcile, kind, key}} -> [{kind, key} | casts()]
    after
      50 -> []
    end
  end

  describe "reports (fencing_test.exs)" do
    test "another Runtime's report gets lease_lost; the leaseholder's still lands", ctx do
      %{lease: lease, task: task} = grant(ctx)
      assert :lease_lost = report(@laptop, lease, 1, state(:accepted))
      assert {:recorded, %{missing: []}} = report(@mini, lease, 1, state(:accepted))
      assert :lease_lost = report(@laptop, lease, 2, state(:started))
      assert L.values(task)["lease_id"] == lease
    end

    test "reports are idempotent by (lease, revision); any other revision is a conflict", ctx do
      %{lease: lease} = grant(ctx)
      assert {:recorded, _} = report(@mini, lease, 1, state(:accepted))
      assert {:recorded, _} = report(@mini, lease, 1, state(:accepted))
      assert {:rejected, :conflict} = report(@mini, lease, 1, state(:started))
      assert {:rejected, :conflict} = report(@mini, lease, 3, state(:started))
      assert {:recorded, _} = report(@mini, lease, 2, state(:started))
    end

    test "the order is accepted | refused, then started, then ended; or accepted then ended",
         ctx do
      %{lease: lease} = grant(ctx)
      assert {:rejected, :conflict} = report(@mini, lease, 1, state(:started))
      assert {:rejected, :conflict} = report(@mini, lease, 1, ended([]))
      assert {:recorded, _} = report(@mini, lease, 1, state(:accepted))
      assert {:rejected, :conflict} = report(@mini, lease, 2, state(:accepted))
      assert {:recorded, _} = report(@mini, lease, 2, ended([]))
      assert {:rejected, :conflict} = report(@mini, lease, 3, state(:started))
    end

    test "a lease id that names no lease is lease_lost; a malformed input is invalid" do
      assert :lease_lost = report(@mini, "TK-B-1-1~1~AAAAAAAAAAAAAAAAAAAAAA", 1, state(:accepted))
      assert :lease_lost = report(@mini, "flow-test-lease-1", 1, state(:accepted))
      assert {:rejected, :invalid} = report(@mini, "x", 1, %{state: :maybe})
    end
  end

  describe "the expiry fence, Delivery's half (acceptance 4)" do
    test "expired by the sweep: reports are lease_lost, get_blob not_found", ctx do
      ctx = grant(ctx)
      assert {:recorded, _} = report(@mini, ctx.lease, 1, state(:accepted))
      assert {:recorded, _} = report(@mini, ctx.lease, 2, state(:started))
      L.advance(ctx, 900)
      Dispatch.sweep()
      assert L.values(ctx.task)["lease_state"] == "expired"

      assert :lease_lost = report(@mini, ctx.lease, 3, ended([]))

      assert :not_found =
               WorkSource.get_blob(@mini, %{lease_id: ctx.lease, sha256: L.base().manifest})
    end

    test "a Delivery write racing the sweep's expired write is refused, and answered lease_lost",
         ctx do
      %{lease: lease, task: task} = grant(ctx)

      FakeFacts.hook("task", task, "flow/delivery", :before, fn fact ->
        put_in(fact, ["values", "lease_state"], "expired")
      end)

      assert :lease_lost = report(@mini, lease, 1, state(:accepted))
      assert L.values(task)["lease_state"] == "expired"
      assert L.values(task)["lease_revision"] == nil
    end

    test "before the sweep ran, a report on a lease expired in memory is still recorded (≤ one sweep)",
         ctx do
      %{lease: lease, task: task} = grant(ctx)
      assert {:recorded, _} = report(@mini, lease, 1, state(:accepted))
      L.advance(ctx, 900)
      assert {:recorded, _} = report(@mini, lease, 2, state(:started))
      Dispatch.sweep()
      assert L.values(task)["lease_state"] == "expired"
      assert :lease_lost = report(@mini, lease, 3, ended([]))
    end

    test "another Runtime: report lease_lost, get_blob not_found; the holder's own lands", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert :lease_lost = report(@laptop, ctx.lease, 4, state(:started))

      assert :not_found =
               WorkSource.get_blob(@laptop, %{lease_id: ctx.lease, sha256: L.base().manifest})

      assert {:recorded, %{missing: []}} = report(@mini, ctx.lease, 3, ended([{"a.txt", "a\n"}]))
    end

    test "Delivery never reads a lease's expiry" do
      source = File.read!(Path.join([__DIR__, "..", "..", "lib", "atlas_flow", "delivery.ex"]))
      refute source =~ "expires_at"
    end
  end

  # F10: Dispatch fences the lease and casts it to Delivery, which is stopped before it
  # handles the cast (it is suspended meanwhile): the crash window the repair at init closes.
  defp fenced_unrecorded(ctx) do
    ctx = grant(ctx)
    assert {:recorded, _} = report(@mini, ctx.lease, 1, state(:accepted))
    assert {:recorded, _} = report(@mini, ctx.lease, 2, state(:started))
    :sys.suspend(Delivery)
    L.advance(ctx, 900)
    Dispatch.sweep()
    :ok = stop_supervised(Delivery)

    assert L.values(ctx.task)["lease_state"] == "expired"
    assert %{"state" => "running"} = attempt(ctx.task)
    ctx
  end

  defp start_delivery(ctx),
    do: start_supervised({Delivery, model: L.Model, clock: ctx.clock, engine: self()})

  defp attempt(task), do: FakeFacts.get("task_attempt", "TA-#{task}-1")["values"]

  describe "fenced attempts at init (F10)" do
    test "a fenced lease whose notice was lost: its attempt ends lost at the next start, with no ended_at",
         ctx do
      ctx = fenced_unrecorded(ctx)
      assert {:ok, _} = start_delivery(ctx)

      assert %{"state" => "lost", "result_kind" => "expired", "lease_id" => lease} =
               v = attempt(ctx.task)

      assert lease == ctx.lease
      refute Map.has_key?(v, "ended_at")
    end

    test "Facts does not answer the repair's read: Delivery starts and serves; the next start repairs",
         ctx do
      L.supervised_task("B-2", "ada")
      ctx = fenced_unrecorded(ctx)

      :ok = GenServer.call(FakeFacts, {:block_read, "task", %{"plain" => true}})
      assert {:ok, _} = start_delivery(ctx)
      :ok = GenServer.call(FakeFacts, {:allow_read, "task", %{"plain" => true}})

      Dispatch.resync()
      assert {:polled, %{leases: [%{lease_id: other}]}} = poll(@mini, [ctx.lease])
      assert {:recorded, _} = report(@mini, other, 1, state(:accepted))
      assert %{"state" => "running"} = attempt(ctx.task)

      :ok = stop_supervised(Delivery)
      assert {:ok, _} = start_delivery(ctx)
      assert %{"state" => "lost", "result_kind" => "expired"} = attempt(ctx.task)
    end
  end

  describe "results over Git (IS-Atlas-100)" do
    test "an ended is recorded in one write and asks for no blob; a change set is not read",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}, {"b.txt", "b\n"}])
      assert ctx.missing == []
      values = L.values(ctx.task)
      assert values["lease_state"] == "done"

      for field <- ~w(result_state result_manifest result_fingerprints),
          do: refute(Map.has_key?(values, field), field)

      assert casts() == [{"bin", "B-1"}]
      assert {:result, "completed", _} = Translate.outcome(FakeFacts.get("task", ctx.task), false)

      # The same ended again is recorded again, and still asks for nothing.
      assert {:recorded, %{missing: []}} =
               report(@mini, ctx.lease, 3, ended([{"a.txt", "a\n"}, {"b.txt", "b\n"}]))
    end

    test "the work source has no put_blob" do
      refute function_exported?(WorkSource, :put_blob, 2)
      refute function_exported?(WorkSource, :put_blob, 3)
    end
  end

  describe "completion (acceptance 7)" do
    test "refused: done, cast, the run stuck with the reason", ctx do
      %{lease: lease, task: task} = grant(ctx)
      assert {:recorded, _} = report(@mini, lease, 1, %{state: :refused, reason: :policy_forbids})
      assert %{"lease_state" => "done", "result_kind" => "refused"} = L.values(task)
      assert casts() == [{"bin", "B-1"}]

      assert {:result, "stuck", %{"reason" => "refused: policy_forbids"}} =
               Translate.outcome(FakeFacts.get("task", task), false)

      assert FakeFacts.get("task_attempt", "TA-#{task}-1")["values"]["state"] == "refused"
    end

    test "one task_attempt per lease, with its provenance, never overwritten", ctx do
      FakeFacts.put("robot", %{"key" => "mini"})
      ctx = ended_lease!(ctx, [])
      attempt = FakeFacts.get("task_attempt", "TA-#{ctx.task}-1")

      assert %{
               "state" => "completed",
               "turn_id" => "turn-1",
               "configured_model" => "model-a",
               "lease_id" => lease
             } =
               attempt["values"]

      assert lease == ctx.lease
      assert attempt["links"] == %{"attempt_of" => [ctx.task], "ran_on" => ["mini"]}
      refute Map.has_key?(attempt["values"], "selection_reason")

      writes = Enum.filter(FakeFacts.sent(), &(&1["key"] == "TA-#{ctx.task}-1"))
      assert length(writes) == 2
      assert {:recorded, _} = report(@mini, ctx.lease, 3, ended([]))
      assert length(Enum.filter(FakeFacts.sent(), &(&1["key"] == "TA-#{ctx.task}-1"))) == 2
    end
  end

  describe "retention (acceptance 7)" do
    # A Runtime stop, a crash or machine restart (interrupted, no reason), and a restart
    # during the after-check (completed, its check without an exit status): each is
    # result-less, so the same step runs again under a fresh lease (D-0102).
    for {name, ending, cause} <- [
          {"a Runtime stop", [kind: :interrupted, reason: :runtime_stop], "interrupted"},
          {"a crash or restart", [kind: :interrupted], "interrupted"},
          {"a restart during the after-check",
           [check: %{command: ["bin/check"], timed_out: false, duration_ms: 5, output_tail: ""}],
           "check_interrupted"}
        ] do
      test "#{name}: the work is offered again as a fresh attempt", ctx do
        ctx = grant(ctx)
        assert {:recorded, _} = report(@mini, ctx.lease, 1, state(:accepted))
        change_set = L.change_set([{"a.txt", "a\n"}], L.base().base_id)

        assert {:recorded, %{missing: []}} =
                 report(@mini, ctx.lease, 2, L.ended(change_set, unquote(Macro.escape(ending))))

        assert %{"lease_state" => "done", "lease_end_cause" => unquote(cause)} =
                 L.values(ctx.task)

        assert :retry = Translate.outcome(FakeFacts.get("task", ctx.task), true)
        assert casts() == []

        assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini, [ctx.lease])
        assert L.values(ctx.task)["attempt"] == 2
        assert fresh != ctx.lease
      end
    end
  end

  describe "get_blob (acceptance 8; fencing_test.exs input blobs)" do
    setup ctx do
      fake = start_supervised!({FakeCode, %{}}, id: :fake)
      FakeCode.put(fake, "example.org/acme/repo", "develop", "rev_1", %{"README.md" => @readme})
      start_supervised!({Bases, client: FakeCode.client(fake), clock: ctx.clock})
      :ok = Bases.request("example.org/acme/repo", "develop", {self(), :base})
      assert_receive :base
      {:ok, base} = Bases.cached("example.org/acme/repo", "develop")
      %{base: base}
    end

    defp fetch(client, lease, sha) do
      case WorkSource.get_blob(client, %{lease_id: lease, sha256: sha}) do
        {:blob, %{content: content, sha256: ^sha}} ->
          {:ok, IO.iodata_to_binary(Enum.to_list(content))}

        :not_found ->
          :not_found
      end
    end

    test "it serves only the current lease's names, to its own Runtime; anything else is not_found",
         ctx do
      %{lease: lease} = grant(ctx, base: ctx.base)
      manifest = ctx.base.manifest

      assert {:ok, bytes} = fetch(@mini, lease, manifest)
      assert L.sha256(bytes) == manifest
      assert {:ok, @readme} = fetch(@mini, lease, L.sha256(@readme))

      assert :not_found = fetch(@mini, lease, L.sha256("other"))
      assert :not_found = fetch(@laptop, lease, manifest)
      assert :not_found = fetch(@mini, "TK-B-1-1~1~AAAAAAAAAAAAAAAAAAAAAA", manifest)

      # Lost by a missed accept deadline, once the sweep wrote it (rev2 note r3).
      L.advance(ctx, 31)
      Dispatch.sweep()
      assert :not_found = fetch(@mini, lease, manifest)
    end

    test "a blob of a change set another task reported is not served", ctx do
      ended_lease!(ctx, [{"a.txt", "a\n"}], bin: "B-2")
      %{lease: lease} = grant(ctx, base: ctx.base)
      assert :not_found = fetch(@mini, lease, L.sha256("a\n"))
    end
  end
end
