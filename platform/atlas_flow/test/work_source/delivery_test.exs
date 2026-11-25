defmodule AtlasFlow.WorkSource.DeliveryTest do
  # Plan m3 A2: Delivery of reports and results, through AtlasFlow.WorkSource. The M1
  # report and result-upload cases (platform/atlas_runtime/test/work_source/fencing_test.exs)
  # ported by structure, plus Flow's own: the expiry fence's Delivery half (acceptance 4),
  # results, pins and retention (7), get_blob's scope (8). FakeFacts, FakeCode behind Bases,
  # the result store on a tmp dir and a manual clock; asserted on outcome tags, fact values,
  # pins and casts, never on wording.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Bases, Delivery, Dispatch, FakeCode, FakeFacts, Results, WorkSource}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Translate

  @mini {"mini", "ada"}
  @laptop {"laptop", "bea"}
  @day 86_400
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

  defp watched(chunks), do: Stream.map(chunks, &(send(self(), {:read, &1}) && &1))

  defp put(client, lease, bytes, opts \\ []) do
    WorkSource.put_blob(client, %{
      lease_id: lease,
      sha256: Keyword.get(opts, :sha256, L.sha256(bytes)),
      size: Keyword.get(opts, :size, byte_size(bytes)),
      content: Keyword.get(opts, :content, watched([bytes]))
    })
  end

  defp held?(bytes), do: Results.blob(L.sha256(bytes)) != :not_found

  defp casts do
    receive do
      {:"$gen_cast", {:reconcile, kind, key}} -> [{kind, key} | casts()]
    after
      50 -> []
    end
  end

  # Waits until the result store handled what was sent to it (its casts).
  defp settle, do: :sys.get_state(Results)

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
    test "expired by the sweep: reports and put_blob are lease_lost, get_blob not_found", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      L.advance(ctx, 900)
      Dispatch.sweep()
      assert L.values(ctx.task)["lease_state"] == "expired"

      assert :lease_lost = report(@mini, ctx.lease, 4, state(:started))
      assert :lease_lost = put(@mini, ctx.lease, "a\n")
      refute_received {:read, _}
      refute held?("a\n")

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

    test "another Runtime: report and put_blob lease_lost, get_blob not_found; the holder's own lands",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert :lease_lost = put(@laptop, ctx.lease, "a\n")
      assert :lease_lost = report(@laptop, ctx.lease, 4, state(:started))

      assert :not_found =
               WorkSource.get_blob(@laptop, %{lease_id: ctx.lease, sha256: L.sha256("a\n")})

      assert :stored = put(@mini, ctx.lease, "a\n")
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

  describe "result upload (fencing_test.exs)" do
    test "ended answers the missing blobs; put_blob stores each, and a replay answers fewer",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}, {"README.md", @readme}])
      assert Enum.sort(ctx.missing) == Enum.sort([L.sha256("a\n"), L.sha256(@readme)])

      assert :stored = put(@mini, ctx.lease, "a\n")

      assert {:recorded, %{missing: [readme]}} =
               report(@mini, ctx.lease, 3, ended([{"a.txt", "a\n"}, {"README.md", @readme}]))

      assert readme == L.sha256(@readme)
      assert :stored = put(@mini, ctx.lease, "a\n")
    end

    test "a stale put_blob gets lease_lost, and none of its bytes is read", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      L.advance(ctx, 900)
      Dispatch.sweep()
      assert :lease_lost = put(@mini, ctx.lease, "a\n")
      refute_received {:read, _}
      refute held?("a\n")
    end

    test "a lease lost while its put_blob streams gets lease_lost, and the blob is not stored",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])

      expiring =
        Stream.map(watched(["a\n"]), fn chunk ->
          L.advance(ctx, 900)
          Dispatch.sweep()
          chunk
        end)

      assert :lease_lost = put(@mini, ctx.lease, "a\n", content: expiring)
      assert_received {:read, "a\n"}
      refute held?("a\n")
    end

    test "an unreferenced put_blob is refused: not in the ended manifest, or before ended", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert :not_referenced = put(@mini, ctx.lease, "b\n")

      other = grant(ctx, bin: "B-2")
      assert {:recorded, _} = report(@mini, other.lease, 1, state(:accepted))
      assert :not_referenced = put(@mini, other.lease, "a\n")

      refute_received {:read, _}
      refute held?("b\n")
    end

    test "bytes that do not match their sha256 or size are rejected and not stored", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert {:rejected, :digest_mismatch} = put(@mini, ctx.lease, "a\n", content: ["b\n"])

      assert {:rejected, :digest_mismatch} =
               put(@mini, ctx.lease, "a\n", size: 1, content: ["a\n"])

      refute held?("a\n")
    end
  end

  describe "the caps (§3.4; fencing_test.exs)" do
    setup ctx do
      :ok = stop_supervised(Results)

      opts = [
        dir: ctx.dir,
        clock: ctx.clock,
        sweep_ms: @day * 1000,
        pins: fn -> [] end,
        result_cap: 10,
        store_cap: 1_000
      ]

      start_supervised!(Supervisor.child_spec({Results, opts}, id: Results))
      :ok
    end

    test "over the per-lease cap: by its size before reading, while it streams, and counting what the result holds",
         ctx do
      big = String.duplicate("x", 11)
      ctx = ended_lease!(ctx, [{"big.bin", big}, {"small.bin", "12345678"}, {"c.txt", "abc"}])

      assert :too_large = put(@mini, ctx.lease, big)
      refute_received {:read, _}

      stream = watched(["xxxxxx", "xxxxx", "never read"])
      assert :too_large = put(@mini, ctx.lease, big, size: 5, content: stream)
      assert_received {:read, "xxxxxx"}
      assert_received {:read, "xxxxx"}
      refute_received {:read, "never read"}
      refute held?(big)

      assert :stored = put(@mini, ctx.lease, "12345678")
      # 8 bytes of the lease's result are held: 3 more do not fit its 10.
      assert :too_large = put(@mini, ctx.lease, "abc")
    end

    test "a result over a cap is too_large: unpinned, cast, and the run's outcome stuck", ctx do
      ctx = ended_lease!(ctx, [{"big.bin", String.duplicate("x", 11)}])
      assert :too_large = put(@mini, ctx.lease, String.duplicate("x", 11))

      fact = FakeFacts.get("task", ctx.task)
      assert %{"result_state" => "too_large", "lease_state" => "done"} = fact["values"]
      assert {:result, "stuck", %{"reason" => "too_large"}} = Translate.outcome(fact, false)
      assert casts() == [{"bin", "B-1"}]
      settle()
      assert Results.manifest(ctx.task) == :not_found
    end
  end

  describe "the store cap (fencing_test.exs)" do
    test "it counts every blob the store holds, not only this result's", ctx do
      held = ended_lease!(ctx, [{"held.bin", String.duplicate("h", 30)}])
      assert :stored = put(@mini, held.lease, String.duplicate("h", 30))
      big = String.duplicate("c", 21)
      fits = String.duplicate("d", 20)
      ctx = ended_lease!(ctx, [{"c.bin", big}, {"d.bin", fits}], bin: "B-2")

      # What the store holds now (every blob and manifest file), plus 20 bytes of room. Its
      # own temp dir is left out by its place in the store, not by a "/tmp" anywhere in the
      # path: the store dir itself sits under the host's temp dir (`/tmp/…` on Linux CI).
      used =
        for path <- Path.wildcard(Path.join(ctx.dir, "**")),
            hd(Path.split(Path.relative_to(path, ctx.dir))) != "tmp",
            File.regular?(path),
            reduce: 0,
            do: (acc -> acc + File.stat!(path).size)

      restart_results(ctx, store_cap: used + 20)

      assert :too_large = put(@mini, ctx.lease, big)
      assert :stored = put(@mini, ctx.lease, fits)
      assert held?(String.duplicate("h", 30))
    end
  end

  # IS-Atlas-112: the completion write on put_done(:stored) is refused by Facts (every try),
  # once; the result stays ended/incomplete with its lease live until something decides again.
  defp completion_missed(ctx) do
    ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
    :ok = GenServer.call(FakeFacts, {:refuse_write, "task", ctx.task})
    assert :stored = put(@mini, ctx.lease, "a\n")
    :ok = GenServer.call(FakeFacts, {:allow_write, "task", ctx.task})

    assert %{"lease_state" => "ended", "result_state" => "incomplete"} = L.values(ctx.task)
    assert held?("a\n")
    assert casts() == []
    ctx
  end

  # Recorded complete, cast to the run once, and no new lease for the task: not now, and
  # not once the lease's TTL is past.
  defp completed_once!(ctx) do
    assert %{"lease_state" => "done", "result_state" => "complete", "lease_id" => lease} =
             L.values(ctx.task)

    assert lease == ctx.lease
    assert casts() == [{"bin", "B-1"}]
    assert {:polled, %{leases: []}} = poll(@mini)
    L.advance(ctx, 900)
    Dispatch.sweep()
    assert {:polled, %{leases: []}} = poll(@mini)
    assert %{"lease_state" => "done", "lease_id" => ^lease} = L.values(ctx.task)
  end

  describe "a completion write Facts missed (IS-Atlas-112)" do
    test "the next put_done completes it", ctx do
      ctx = completion_missed(ctx)
      assert :stored = put(@mini, ctx.lease, "a\n")
      completed_once!(ctx)
    end

    test "the next report (the ended again) completes it", ctx do
      ctx = completion_missed(ctx)

      assert {:recorded, %{missing: []}} =
               report(@mini, ctx.lease, 3, ended([{"a.txt", "a\n"}]))

      completed_once!(ctx)
    end

    test "the next sweep completes it, before the lease expires", ctx do
      ctx = completion_missed(ctx)
      Dispatch.sweep()
      :sys.get_state(Delivery)
      completed_once!(ctx)
    end

    test "the sweep leaves an ended result whose blobs are not all held incomplete", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}, {"b.txt", "b\n"}])
      assert :stored = put(@mini, ctx.lease, "a\n")
      Dispatch.sweep()
      :sys.get_state(Delivery)
      assert %{"lease_state" => "ended", "result_state" => "incomplete"} = L.values(ctx.task)
      assert casts() == []
    end
  end

  describe "completion (acceptance 7)" do
    test "complete only with every blob held and every csf_ recomputed; then cast and pinned",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}, {"b.txt", "b\n"}])
      assert L.values(ctx.task)["result_state"] == "incomplete"
      assert {:ok, _} = Results.manifest(ctx.task)

      assert :stored = put(@mini, ctx.lease, "a\n")
      assert L.values(ctx.task)["result_state"] == "incomplete"
      assert casts() == []

      assert :stored = put(@mini, ctx.lease, "b\n")
      v = L.values(ctx.task)

      assert %{
               "result_state" => "complete",
               "lease_state" => "done",
               "result_kind" => "completed"
             } = v

      assert [%{"root" => "repo", "fingerprint" => "csf_" <> _}] =
               JSON.decode!(v["result_fingerprints"])

      assert casts() == [{"bin", "B-1"}]
      assert {:ok, %{"roots" => [root]}} = Results.manifest(ctx.task)
      # Stored plain (fix path b): the fingerprints are the task fact's, not the manifest's.
      assert Map.keys(root) |> Enum.sort() == ~w(entries root)
      assert {:result, "completed", _} = Translate.outcome(FakeFacts.get("task", ctx.task), false)
    end

    test "a csf_ that does not recompute is invalid: unpinned and cast", ctx do
      ctx =
        ended_lease!(ctx, [{"a.txt", "a\n"}], fingerprint: "csf_" <> String.duplicate("0", 64))

      assert :stored = put(@mini, ctx.lease, "a\n")
      assert L.values(ctx.task)["result_state"] == "invalid"
      assert casts() == [{"bin", "B-1"}]
      settle()
      assert Results.manifest(ctx.task) == :not_found

      assert {:result, "stuck", %{"reason" => "invalid"}} =
               Translate.outcome(FakeFacts.get("task", ctx.task), false)
    end

    test "an ended whose blobs are all held already completes at once", ctx do
      first = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert :stored = put(@mini, first.lease, "a\n")
      casts()

      second = ended_lease!(ctx, [{"a.txt", "a\n"}], bin: "B-2")
      assert second.missing == []
      assert L.values(second.task)["result_state"] == "complete"
      assert {:ok, %{"roots" => [root]}} = Results.manifest(second.task)
      assert Map.keys(root) |> Enum.sort() == ~w(entries root)
      assert AtlasChangeset.validate(elem(Results.manifest(second.task), 1)) == :ok
      assert casts() == [{"bin", "B-2"}]
    end

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
      test "#{name}: unpinned, and the work is offered again as a fresh attempt", ctx do
        ctx = grant(ctx)
        assert {:recorded, _} = report(@mini, ctx.lease, 1, state(:accepted))
        change_set = L.change_set([{"a.txt", "a\n"}], L.base().base_id)

        assert {:recorded, %{missing: []}} =
                 report(@mini, ctx.lease, 2, L.ended(change_set, unquote(Macro.escape(ending))))

        assert %{"lease_state" => "done", "lease_end_cause" => unquote(cause)} =
                 L.values(ctx.task)

        settle()
        assert Results.manifest(ctx.task) == :not_found
        assert :retry = Translate.outcome(FakeFacts.get("task", ctx.task), true)
        assert casts() == []

        assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini, [ctx.lease])
        assert L.values(ctx.task)["attempt"] == 2
        assert fresh != ctx.lease
      end
    end

    test "a later attempt's accepted unpins the earlier result", ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert {:ok, _} = Results.manifest(ctx.task)

      # The first lease is lost by expiry (a silent turn); once its run counted it, the
      # work is leased again.
      L.advance(ctx, 900)
      Dispatch.sweep()
      L.advance(ctx, 120)
      Dispatch.sweep()
      :ok = L.retried(AtlasFlow.Runs.Run.key("watch", "bin", "B-1", 1), [1])
      assert {:polled, %{leases: [%{lease_id: fresh}]}} = poll(@mini)
      assert {:ok, _} = Results.manifest(ctx.task)

      assert {:recorded, _} = report(@mini, fresh, 1, state(:accepted))
      settle()
      assert Results.manifest(ctx.task) == :not_found
      assert L.values(ctx.task)["result_manifest"] == nil
    end

    test "after a store restart, only complete, non-abandoned results are pinned again", ctx do
      done = ended_lease!(ctx, [{"a.txt", "a\n"}])
      assert :stored = put(@mini, done.lease, "a\n")
      waiting = ended_lease!(ctx, [{"w.txt", "w\n"}], bin: "B-2")
      abandoned = ended_lease!(ctx, [{"z.txt", "z\n"}], bin: "B-3")
      assert :stored = put(@mini, abandoned.lease, "z\n")

      FakeFacts.put(
        "task",
        put_in(FakeFacts.get("task", abandoned.task), ["values", "state"], "abandoned")
      )

      restart_results(ctx)

      assert {:ok, _} = Results.manifest(done.task)
      assert Results.manifest(waiting.task) == :not_found
      assert Results.manifest(abandoned.task) == :not_found
    end

    test "restart mid-upload: the remaining blobs complete it, pinned again; 14 days + 1 later it is all there",
         ctx do
      ctx = ended_lease!(ctx, [{"a.txt", "a\n"}, {"b.txt", "b\n"}])
      assert :stored = put(@mini, ctx.lease, "a\n")

      restart_results(ctx)
      :ok = stop_supervised(Delivery)
      start_supervised!({Delivery, model: L.Model, clock: ctx.clock, engine: self()})
      assert Results.manifest(ctx.task) == :not_found

      assert :stored = put(@mini, ctx.lease, "b\n")
      assert L.values(ctx.task)["result_state"] == "complete"

      L.advance(ctx, 14 * @day + 1)
      settle()
      assert {:ok, manifest} = Results.manifest(ctx.task)

      for sha <- Translate.references(manifest),
          do: assert({:ok, _, _} = Results.blob(sha))
    end
  end

  defp restart_results(ctx, caps \\ []) do
    :ok = stop_supervised(Results)

    opts = [
      dir: ctx.dir,
      clock: ctx.clock,
      sweep_ms: @day * 1000,
      pins: &AtlasFlow.Application.result_pins/0
    ]

    opts = Keyword.merge(opts, caps)

    start_supervised!(Supervisor.child_spec({Results, opts}, id: Results))
    settle()
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

    test "a result blob the store holds for another task is not served", ctx do
      other = ended_lease!(ctx, [{"a.txt", "a\n"}], bin: "B-2")
      assert :stored = put(@mini, other.lease, "a\n")
      %{lease: lease} = grant(ctx, base: ctx.base)
      assert :not_found = fetch(@mini, lease, L.sha256("a\n"))
    end
  end
end
