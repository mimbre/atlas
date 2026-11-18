defmodule AtlasRuntime.Sources.LocalTest do
  @moduledoc """
  M2 A5, the built-in local work source (decision §5.4; M2 plan A5) on W7's store: a work
  is checked against the policy when it is added; its client key is the source's (I3, I7);
  the queue is priority, then FIFO; the `local` entry's priority and `max_slots` apply; a
  local work runs through poll, report and put_blob as a remote one does, and its result is
  served from the source's own store; a restart keeps the queue, and a held lease does not
  start before its accept is recorded.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Availability
  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Model.LocalSource.QueuedWork
  alias AtlasRuntime.Sources.{Local, LocalFacade, Rights}
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  @client Rights.client("local")

  @sources %{
    "sources" => [
      %{
        "name" => "local",
        "kind" => "builtin",
        "priority" => 1,
        "max_slots" => 2,
        "max_store_bytes" => 2_147_483_648
      },
      %{
        "name" => "flow-test",
        "kind" => "remote",
        "url" => "https://flow-test.example/",
        "credential_file" => "sources/flow-test/token",
        "priority" => 2,
        "max_slots" => 2,
        "max_store_bytes" => 2_147_483_648
      }
    ]
  }

  defp folder_work(bench, instructions, extra \\ %{}),
    do: B.WorkRequest.new!(request(bench, instructions, extra))

  defp base_work(code, instructions, extra \\ []) do
    struct!(
      B.WorkRequest,
      Keyword.merge(
        [
          title: instructions,
          instructions: instructions,
          profile: "light_work",
          cost_class: :standard,
          workspace: %B.Base{base_id: code.id, permissions: :"workspace-write"}
        ],
        extra
      )
    )
  end

  # The local source alone (no puller): the queue only moves when a test polls.
  defp local!(bench, opts \\ []) do
    start_supervised!(%{id: Local, start: {Local, :start_link, [bench.dir, opts]}})
  end

  # The local source and its puller, as the service starts them, on short timers.
  defp sources!(bench) do
    start_supervised!(%{
      id: :sources,
      type: :supervisor,
      start:
        {AtlasRuntime.Sources.Supervisor, :start_link,
         [bench.dir, [puller: [tick: 50, min_poll_ms: 20, retry_ms: 20]]]}
    })
  end

  defp poll(offer, holdings \\ []) do
    Local.poll_local(%{
      runtime_id: "mini",
      incarnation: "inc-1",
      build: "test",
      policy_version: 1,
      offer: offer,
      holdings: holdings
    })
  end

  defp queued_ids, do: for(%QueuedWork{state: :queued, work_id: id} <- Local.queue(), do: id)

  defp ended(work_id) do
    await(fn ->
      case Local.get(work_id) do
        {:ok, %QueuedWork{state: :ended} = work} -> work
        _ -> nil
      end
    end)
  end

  setup do
    bench = start!(@sources)
    code = CodeStandIn.start!(bench.dir, %{"README.md" => "base\n"})
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  describe "add" do
    setup %{bench: bench} do
      local!(bench)
      :ok
    end

    test "a typo is refused at add: invalid or policy_forbids, and not_accepting", %{
      bench: bench
    } do
      assert {:refused, :policy_forbids, _} =
               Local.add(client(), folder_work(bench, "typo", %{profile: "light_wrok"}))

      assert {:refused, :invalid, _} =
               Local.add(client("c1", [:choose_slot]), folder_work(bench, "slot", %{slot: "s9"}))

      # A client without choose_path is refused a folder, as on the socket.
      assert {:refused, :not_permitted, _} =
               Local.add({"c2", [:submit, :read]}, folder_work(bench, "no path right"))

      assert :paused = Work.set_mode(:paused, "op")
      assert {:refused, :not_accepting, _} = Local.add(client(), folder_work(bench, "paused"))
      assert :open = Work.set_mode(:open, "op")

      assert Local.queue() == []
      refute File.exists?(Path.join(bench.dir, "local-source/queue"))
      assert {:added, _id} = Local.add(client(), folder_work(bench, "complete fine"))
    end

    test "I3: the same key is existing, another body conflict, a pruned key conflict", %{
      bench: bench
    } do
      work = folder_work(bench, "complete keyed", %{client_key: "k-1"})
      assert {:added, id} = Local.add(client(), work)
      assert {:existing, ^id} = Local.add(client(), work)

      other = folder_work(bench, "complete other", %{client_key: "k-1"})
      assert {:conflict, ^id} = Local.add(client(), other)
      # Another client's key is its own.
      assert {:added, _} = Local.add(client("c2"), other)

      # Ended and pruned: the key stays as a tombstone, so it can never name another work.
      assert %{leases: [%{lease_id: lease_id}]} = poll(%{"light_work" => 1})
      report(lease_id, 1, %{state: :accepted})
      report(lease_id, 2, %{state: :ended, result: ended_result(), provenance: []})
      assert :ok = Local.prune(id)
      assert {:pruned, %{work_id: ^id, final_kind: :completed}} = Local.get(id)
      assert {:conflict, ^id} = Local.add(client(), work)
    end

    test "the queue is priority, then FIFO; the offer's total is leased in that order", %{
      bench: bench
    } do
      added =
        for {n, priority} <- [{1, 2}, {2, 1}, {3, 2}, {4, 1}] do
          {:added, id} = Local.add(client(), folder_work(bench, "complete #{n}"), priority)
          {n, id}
        end

      ids = Map.new(added)
      assert queued_ids() == [ids[2], ids[4], ids[1], ids[3]]

      # O1: an offer of two is two leases, in that order, whatever the profiles it names.
      assert %{leases: leases} = poll(%{"light_work" => 2, "deep_coding" => 2})
      assert Enum.map(leases, & &1.work.work_key) == [ids[2], ids[4]]
      assert queued_ids() == [ids[1], ids[3]]
    end
  end

  test "strict priority and max_slots: the local entry's cap applies, the rest is the next one's",
       %{bench: bench} do
    write_policy!(
      bench.dir,
      put_in(@sources, ["sources", Access.at(0), "max_slots"], 1)
    )

    assert Work.offer("local") == %{"light_work" => 1}
    # While local's poll is open, flow-test (lower priority) gets only the other slot.
    assert Work.offer("flow-test") == %{"light_work" => 1}
    assert :ok = Work.offer_done("flow-test", 0)
    assert :ok = Work.offer_done("local", 0)

    # Both poll at once with nothing to offer; when slots free, local comes first.
    assert :paused = Work.set_mode(:paused, "op")
    assert Work.offer("flow-test") == %{}
    assert Work.offer("local") == %{}
    assert :open = Work.set_mode(:open, "op")
    assert Work.offer("flow-test") == %{"light_work" => 1}
    assert Work.offer("local") == %{"light_work" => 1}
  end

  test "a local work runs through poll, report and put_blob like a remote one; its result is served from the source's own store",
       %{bench: bench, code: code} do
    sources!(bench)

    assert {:added, base_id} =
             Local.add(
               client(),
               base_work(code, "write atlas/a.txt alpha; write atlas/b.txt beta")
             )

    assert {:added, folder_id} = Local.add(client(), folder_work(bench, "complete folder"))

    for id <- [base_id, folder_id] do
      assert %QueuedWork{
               state: :ended,
               lease_id: "local-lease-" <> _,
               result: %{kind: :completed}
             } =
               ended(id)
    end

    # The executor ran each under the local source's client, keyed by its lease.
    assert [_, _] = Work.holdings("local")

    assert {:ok, %{ended: ended, result_ref: %{frozen_id: ^base_id}}} = Local.result(base_id)
    assert %{result: %{kind: :completed}} = ended
    assert [%{root: "atlas", fingerprint: "csf_" <> _, entries: entries}] = ended.change_set.roots
    writes = for %{op: :write, sha256: sha} <- entries, do: sha
    assert length(writes) == 2

    await(fn -> Enum.all?(writes, &match?({:ok, _}, Local.result_blob(&1))) end)

    # C6: served from the local source's store, also once the executor's copy is gone.
    File.rm_rf!(Path.join(bench.dir, "frozen"))

    assert Enum.sort(for sha <- writes, do: elem(Local.result_blob(sha), 1)) ==
             ["alpha\n", "beta\n"]

    assert {:ok, %{ended: ^ended}} = Local.result(base_id)
    # A folder work has no frozen result: nothing to serve but its end.
    assert {:ok, %{result_ref: %{frozen_id: nil}}} = Local.result(folder_id)
  end

  test "restart: queued work stays queued, and a held lease does not start before recorded", %{
    bench: bench
  } do
    local!(bench)
    {:added, first} = Local.add(client(), folder_work(bench, "complete one"))
    {:added, second} = Local.add(client(), folder_work(bench, "complete two"))

    stop_supervised!(Local)
    local!(bench)
    assert queued_ids() == [first, second]

    assert %{leases: [lease]} = poll(%{"light_work" => 1})
    assert {:accepted, work_id} = Work.accept_lease("local", lease)
    # The core's next call is answered after the dispatch the accept led to: held, buffered,
    # in no slot, never run.
    assert [%{work_id: ^work_id, held: true, state: :buffered, ran: false}] =
             Work.holdings("local")

    assert %B.Outcome.Found{work: %{state: :buffered, attempts: [%{slot: nil}]}} =
             B.get_work(@client, %{work_id: work_id})

    assert launches(bench) == []

    # The source restarts while the lease is held; the accept is recorded after it.
    stop_supervised!(Local)
    local!(bench)
    assert {:ok, %QueuedWork{state: :leased}} = Local.get(first)
    assert %LocalFacade.Outcome.Recorded{} = report(lease.lease_id, 1, %{state: :accepted})
    assert :released = Work.release_lease(work_id)
    assert await_state(work_id, :completed, @client)
    assert queued_ids() == [second]
  end

  test "only the source local leases in the local form; any other source is refused invalid",
       %{bench: bench} do
    local!(bench)
    {:added, _} = Local.add(client(), folder_work(bench, "complete held"))
    assert %{leases: [lease]} = poll(%{"light_work" => 1})

    assert {:refused, :invalid} = Work.accept_lease("flow-test", lease)
    assert %B.Outcome.Works{works: []} = B.list_work(Rights.client("flow-test"), %{})
  end

  # Main's A6 Q1: the executor keeps the local work id. A lease lost after the executor
  # accepted it is given out again by the source; that fresh lease of the same work is
  # refused, the source ends the work failed, and it never runs twice.
  test "A6 Q1: one work id; a re-lease of the same work is refused, ends failed, never runs twice",
       %{bench: bench} do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    local!(bench, clock: fn -> Agent.get(clock, & &1) end)
    {:added, id} = Local.add(client(), folder_work(bench, "complete once"))

    assert %{leases: [first]} = poll(%{"light_work" => 1})
    assert first.work.work_key == id
    assert {:accepted, ^id} = Work.accept_lease("local", first)
    assert {:existing, ^id} = Work.accept_lease("local", first)

    # Not accepted at the source within its accept deadline: lost, and leased afresh.
    Agent.update(clock, &(&1 + 31_000))
    assert %{leases: [second]} = poll(%{"light_work" => 1})
    assert second.work.work_key == id and second.lease_id != first.lease_id

    assert {:refused, _reason} = Work.accept_lease("local", second)

    assert %LocalFacade.Outcome.Recorded{} =
             report(second.lease_id, 1, %{state: :refused, reason: :invalid})

    assert {:ok, %QueuedWork{state: :ended, result: %{kind: :failed}}} = Local.get(id)

    # One record, one attempt, still held (never released, so it cannot start).
    assert [_one] = Path.wildcard(Path.join(bench.dir, "work/work-*.json"))

    assert [%{state: :buffered, lease_hold: true} = attempt] =
             AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts

    assert is_nil(attempt.timestamps.running_at)
    assert [%{work_id: ^id, held: true}] = Work.holdings("local")
  end

  # Review dev1 finding 2 (V15): Q1 after a prune. The executor's record of a local work is
  # pruned (a tombstone is left); the source, whose lease was never recorded, leases it
  # again. That lease is refused, the work ends failed at the source, and nothing runs.
  test "A6 Q1 after a prune: a re-lease of a pruned local work is refused, ends failed, never runs",
       %{bench: bench} do
    retention = 3600
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    local!(bench, clock: fn -> Agent.get(clock, & &1) end)
    {:added, id} = Local.add(client(), folder_work(bench, "complete pruned"))

    assert %{leases: [first]} = poll(%{"light_work" => 1})
    assert {:accepted, ^id} = Work.accept_lease("local", first)

    # The held attempt is given up (cancelled, never started), and the record is pruned.
    Work.cancel(@client, %B.CancelInput{work_id: id, mode: :graceful})

    await(fn ->
      match?([%{quiescent: true}], AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts)
    end)

    stop_work()

    old =
      DateTime.utc_now()
      |> DateTime.add(-2 * retention, :second)
      |> DateTime.truncate(:millisecond)

    record = AtlasRuntime.Work.Store.read_work(bench.dir, id)

    AtlasRuntime.Work.Store.put_work!(bench.dir, %{
      record
      | attempts: Enum.map(record.attempts, &%{&1 | timestamps: %{&1.timestamps | ended_at: old}})
    })

    start_work!(bench, retention: retention)

    await(fn ->
      match?(%B.Outcome.Pruned{}, Work.get_work(@client, %B.GetWorkInput{work_id: id}))
    end)

    # The source never got `accepted`: past its accept deadline it leases the work again.
    Agent.update(clock, &(&1 + 31_000))
    assert %{leases: [second]} = poll(%{"light_work" => 1})
    assert second.work.work_key == id and second.lease_id != first.lease_id

    assert {:refused, _reason} = Work.accept_lease("local", second)
    assert match?(%B.Outcome.Pruned{}, Work.get_work(@client, %B.GetWorkInput{work_id: id}))
    assert Work.holdings("local") == []

    assert %LocalFacade.Outcome.Recorded{} =
             report(second.lease_id, 1, %{state: :refused, reason: :invalid})

    assert {:ok, %QueuedWork{state: :ended, result: %{kind: :failed}}} = Local.get(id)
    assert Path.wildcard(Path.join(bench.dir, "work/work-*.json")) == []
    assert launches(bench) == []
  end

  # Main's round 2 (1), side by side on two works that each ran once. A retry queues the
  # work again at the source: its next lease names attempt 2 of the same work id, is leased
  # within the offer (it holds one of local's max_slots), and runs. A lease of that attempt
  # that is lost and given out again is the SAME attempt: refused, the work ends failed, and
  # attempt 2 never runs.
  describe "round 2: local retry" do
    setup %{bench: bench} do
      write_policy!(bench.dir, put_in(@sources, ["sources", Access.at(0), "max_slots"], 1))
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      local!(bench, clock: fn -> Agent.get(clock, & &1) end)
      %{clock: clock}
    end

    # One lease of `id` within local's offer, accepted by the executor (held).
    defp lease!(id, attempt) do
      offer = Work.offer("local")
      assert offer == %{"light_work" => 1}
      assert %{leases: [lease]} = poll(offer)
      assert %{work_key: ^id, attempt: ^attempt} = lease.work
      assert {:accepted, ^id} = Work.accept_lease("local", lease)
      assert :ok = Work.offer_done("local", 1)
      lease
    end

    # Accepted at the source, run by the executor to its end, and that end reported.
    defp run!(lease, attempt) do
      id = lease.work.work_key
      assert %LocalFacade.Outcome.Recorded{} = report(lease.lease_id, 1, %{state: :accepted})
      assert :released = Work.release_lease(id)

      await_work(
        id,
        &(length(&1.attempts) == attempt and List.last(&1.attempts).state == :completed and
            List.last(&1.attempts).quiescent),
        @client
      )

      assert %LocalFacade.Outcome.Recorded{} =
               report(lease.lease_id, 2, %{state: :ended, result: ended_result(), provenance: []})
    end

    test "a retry is a new lease of the next attempt and runs; a lost lease of that same attempt ends failed and never runs",
         %{bench: bench, clock: clock} do
      {:added, lost} = Local.add(client(), folder_work(bench, "complete lost"))
      {:added, retried} = Local.add(client(), folder_work(bench, "complete retried"))

      for id <- [lost, retried], do: id |> lease!(1) |> run!(1)
      assert length(launches(bench)) == 2

      # The adder's retry: queued again at the source for attempt 2, the same work id.
      for id <- [lost, retried] do
        assert %B.Outcome.Accepted{work: %{work_id: ^id, attempts: [_, %{attempt: 2}]}} =
                 B.retry(client(), %{work_id: id})

        assert {:ok, %QueuedWork{state: :queued, attempt: 2}} = Local.get(id)
      end

      # `lost`: its attempt-2 lease is accepted and held; it holds local's only slot.
      first = lease!(lost, 2)
      assert Work.offer("local") == %{}
      assert :ok = Work.offer_done("local", 0)

      # Not recorded within the accept deadline: lost at the source, queued again for the
      # SAME attempt; the puller gives the held attempt up (cancelled, never started).
      Agent.update(clock, &(&1 + 31_000))
      assert %{leases: []} = poll(%{})
      assert {:ok, %QueuedWork{state: :queued, attempt: 2}} = Local.get(lost)
      B.cancel(@client, %{work_id: lost, mode: :graceful})

      offer = Work.offer("local")
      assert %{leases: [again]} = poll(offer)
      assert :ok = Work.offer_done("local", 0)
      assert %{work_key: ^lost, attempt: 2} = again.work
      assert again.lease_id != first.lease_id

      assert {:refused, _reason} = Work.accept_lease("local", again)

      assert %LocalFacade.Outcome.Recorded{} =
               report(again.lease_id, 1, %{state: :refused, reason: :invalid})

      assert {:ok, %QueuedWork{state: :ended, result: %{kind: :failed, attempt: 2}}} =
               Local.get(lost)

      # `retried`: its attempt-2 lease runs, on the same record.
      retried |> lease!(2) |> run!(2)

      assert {:ok, %QueuedWork{state: :ended, result: %{kind: :completed, attempt: 2}}} =
               Local.get(retried)

      # One record each. `lost` ran once: attempt 2 never started. `retried` ran twice.
      assert [_, _] = Path.wildcard(Path.join(bench.dir, "work/work-*.json"))
      lost_attempts = AtlasRuntime.Work.Store.read_work(bench.dir, lost).attempts

      assert [
               %{state: :completed},
               %{attempt: 2, state: :cancelled, result: %{never_started: true}}
             ] =
               lost_attempts

      assert is_nil(List.last(lost_attempts).timestamps.running_at)

      assert [%{state: :completed}, %{attempt: 2, state: :completed}] =
               AtlasRuntime.Work.Store.read_work(bench.dir, retried).attempts

      assert length(launches(bench)) == 3
    end
  end

  # Main's #330 F5 (c): a retry that meets a profile unavailable now (here: between the
  # offer and the accept) stays queued, not failed. Nothing is recorded; the lease is left
  # unanswered, the source queues the same attempt again at its accept deadline, nothing
  # offers it while the profile is unavailable, and it runs once the profile is back.
  describe "F5 (c): a retry whose profile is unavailable now" do
    setup %{bench: bench} do
      write_policy!(bench.dir, put_in(@sources, ["sources", Access.at(0), "max_slots"], 1))
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      local!(bench, clock: fn -> Agent.get(clock, & &1) end)
      %{clock: clock}
    end

    test "stays queued, not failed, and runs as attempt 2 once the profile is back",
         %{bench: bench, clock: clock} do
      {:added, id} = Local.add(client(), folder_work(bench, "complete waits"))
      id |> lease!(1) |> run!(1)
      assert %B.Outcome.Accepted{} = B.retry(client(), %{work_id: id})

      offer = Work.offer("local")
      assert offer == %{"light_work" => 1}
      assert %{leases: [lease]} = poll(offer)
      assert %{work_key: ^id, attempt: 2} = lease.work

      # The profile's only harness is quota-marked (a human's mark) before the accept.
      mark = %{
        "evidence" => %{"source" => "operator", "note" => "no credits", "resetsAt" => nil},
        "turn_id" => nil,
        "observed_at" => System.system_time(:second),
        "reenabled_at" => nil
      }

      Availability.persist(
        bench.dir,
        put_in(Availability.load(bench.dir), ["quota", "codex"], mark)
      )

      assert {:unavailable, _reason} = Work.accept_lease("local", lease)
      assert :ok = Work.offer_done("local", 0)
      assert [%{state: :completed}] = AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts
      assert {:ok, %QueuedWork{state: :leased}} = Local.get(id)

      # Unanswered past the source's accept deadline: queued again for attempt 2, not ended.
      Agent.update(clock, &(&1 + 31_000))
      assert %{leases: []} = poll(%{})
      assert {:ok, %QueuedWork{state: :queued, attempt: 2, result: nil}} = Local.get(id)
      assert Work.offer("local") == %{}
      assert :ok = Work.offer_done("local", 0)

      # The profile is back: leased again, attempt 2 runs on the same record.
      assert :cleared = Work.clear_quota_mark("codex")
      id |> lease!(2) |> run!(2)

      assert {:ok, %QueuedWork{state: :ended, result: %{kind: :completed, attempt: 2}}} =
               Local.get(id)

      assert [%{state: :completed}, %{attempt: 2, state: :completed}] =
               AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts
    end
  end

  # Main's #330 round 3, dev2's probe: one availability rule for the offer and the retry's
  # check. light_work is [codex, claude]; claude cannot serve workspace-write. With codex
  # quota-marked, light_work is offered (claude serves a read-only work), but a
  # workspace-write retry is not leased, across two accept deadlines, so it never cycles;
  # once codex can serve it again, it is leased and runs as attempt 2.
  describe "round 3: a workspace-write retry, light_work = [codex (quota-marked), claude]" do
    setup %{bench: bench} do
      options = [
        %{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"},
        %{"provider" => "anthropic", "harness" => "claude", "model" => "claude-test"}
      ]

      policy =
        @sources
        |> put_in(["sources", Access.at(0), "max_slots"], 1)
        |> Map.put("profiles", %{
          "light_work" => %{
            "permissions" => ["read-only", "workspace-write", "materialized-folder"],
            "cost_classes" => ["low", "standard"],
            "options" => options
          }
        })

      write_policy!(bench.dir, policy)
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      local!(bench, clock: fn -> Agent.get(clock, & &1) end)
      %{clock: clock}
    end

    defp quota_mark!(bench, harness) do
      mark = %{
        "evidence" => %{"source" => "operator", "note" => "no credits", "resetsAt" => nil},
        "turn_id" => nil,
        "observed_at" => System.system_time(:second),
        "reenabled_at" => nil
      }

      availability = put_in(Availability.load(bench.dir), ["quota", harness], mark)
      Availability.persist(bench.dir, availability)
    end

    # The harness each attempt's turn ran on, from its turn record.
    defp harnesses(bench, id) do
      for %{turn_id: turn_id} <- AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts do
        turn = AtlasRuntime.Work.Turns.read_turn(bench.dir, turn_id)
        AtlasRuntime.Work.Turns.option(turn)["harness"]
      end
    end

    test "the retry is not leased while no option serves it, never cycles, and runs once one does",
         %{bench: bench, code: code, clock: clock} do
      {:added, id} = Local.add(client(), base_work(code, "complete write"))
      id |> lease!(1) |> run!(1)
      assert harnesses(bench, id) == ["codex"]

      assert %B.Outcome.Accepted{} = B.retry(client(), %{work_id: id})
      quota_mark!(bench, "codex")

      # Two accept deadlines: each poll's offer names light_work (claude serves read-only),
      # and the retry is not leased; nothing is recorded, and it stays queued for attempt 2.
      for _deadline <- 1..2 do
        offer = Work.offer("local")
        assert offer == %{"light_work" => 1}
        assert %{leases: []} = poll(offer)
        assert :ok = Work.offer_done("local", 0)
        assert {:ok, %QueuedWork{state: :queued, attempt: 2, lease_id: nil}} = Local.get(id)
        assert [%{state: :completed}] = AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts
        Agent.update(clock, &(&1 + 31_000))
      end

      # The same profile still leases a read-only work, which claude serves.
      {:added, read} = Local.add(client(), folder_work(bench, "complete read"))
      read |> lease!(1) |> run!(1)
      assert harnesses(bench, read) == ["claude"]
      assert {:ok, %QueuedWork{state: :queued, attempt: 2}} = Local.get(id)

      # Codex can serve it again: leased, and attempt 2 runs on the same record.
      assert :cleared = Work.clear_quota_mark("codex")
      id |> lease!(2) |> run!(2)

      assert [%{state: :completed}, %{attempt: 2, state: :completed}] =
               AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts

      assert harnesses(bench, id) == ["codex", "codex"]
    end
  end

  # Review dev1 finding 2 (V16): a retry's lease (attempt 2) delivered again is the same
  # lease: `existing`, still one attempt 2, and it runs once.
  describe "round 2: a retry lease delivered twice" do
    setup %{bench: bench} do
      write_policy!(bench.dir, put_in(@sources, ["sources", Access.at(0), "max_slots"], 1))
      local!(bench)
      :ok
    end

    test "an attempt-2 lease delivered again is existing: one attempt 2, and it runs once",
         %{bench: bench} do
      {:added, id} = Local.add(client(), folder_work(bench, "complete delivered twice"))
      id |> lease!(1) |> run!(1)

      assert %B.Outcome.Accepted{} = B.retry(client(), %{work_id: id})
      lease = lease!(id, 2)
      assert {:existing, ^id} = Work.accept_lease("local", lease)

      assert [%{state: :completed}, %{attempt: 2, state: :buffered, lease_hold: true}] =
               AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts

      run!(lease, 2)

      assert {:ok, %QueuedWork{state: :ended, result: %{kind: :completed, attempt: 2}}} =
               Local.get(id)

      assert [%{state: :completed}, %{attempt: 2, state: :completed}] =
               AtlasRuntime.Work.Store.read_work(bench.dir, id).attempts

      assert length(launches(bench)) == 2
    end
  end

  # Main's Deviation 1: a local lease carries the local request, and a folder, a repository,
  # a slot and resume_from are taken from `local` only. Each form, in the local lease form
  # from another source (also with an input it imported), is refused, and nothing is
  # admitted: no record, no launch. The same lease from `local` is then accepted, so the
  # refusal is the source's, not the request's.
  describe "Deviation 1: the local forms from another source" do
    setup %{bench: bench} do
      # light_work also allows a repository here (as in source_rights_test).
      profile = %{
        "permissions" => [
          "read-only",
          "workspace-write",
          "materialized-folder",
          "dedicated-repository"
        ],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      }

      write_policy!(bench.dir, Map.put(@sources, "profiles", %{"light_work" => profile}))
      :ok
    end

    defp local_form(request),
      do: %{
        lease_id: "lease-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower),
        expires_at: DateTime.utc_now(),
        work: %{
          work_key: "work-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          request: request
        }
      }

    defp work_files(bench), do: Path.wildcard(Path.join(bench.dir, "work/work-*.json"))

    defp assert_refused_from_other(bench, request) do
      lease = local_form(request)
      before = work_files(bench)
      imported = %{baseline_id: "sha256:" <> String.duplicate("a", 64), change_set: nil}

      for source <- ["flow-test", "other"], imported <- [nil, imported] do
        assert {:refused, _reason} = Work.accept_lease(source, lease, imported)
      end

      assert work_files(bench) == before
      assert %B.Outcome.Works{works: []} = B.list_work(Rights.client("flow-test"), %{})

      # From local the same lease is taken (held: it starts only once recorded).
      assert {:accepted, id} = Work.accept_lease("local", lease)
      assert id == lease.work.work_key
    end

    test "folder", %{bench: bench} do
      assert_refused_from_other(bench, folder_work(bench, "complete folder"))
      assert launches(bench) == []
    end

    test "repository", %{bench: bench} do
      request =
        B.WorkRequest.new!(
          request(bench, "complete repository", %{
            workspace: %{
              kind: "repository",
              url: "https://example.invalid/r.git",
              branch: "task/x",
              base: "develop"
            }
          })
        )

      assert %B.Repository{} = request.workspace
      assert_refused_from_other(bench, request)
      assert launches(bench) == []
    end

    test "slot", %{bench: bench, code: code} do
      request = base_work(code, "complete slot", slot: "s1")
      assert request.slot == "s1"
      assert_refused_from_other(bench, request)
      assert launches(bench) == []
    end

    test "resume_from", %{bench: bench} do
      # A turn to continue: a local lease run to its end first (M2 A7: no direct submit).
      assert {:accepted, first} =
               Work.accept_lease("local", local_form(folder_work(bench, "complete first")))

      assert :released = Work.release_lease(first)
      [%{turn_id: turn}] = await_state(first, :completed, @client).attempts

      request = folder_work(bench, "complete first", %{resume_from: turn})
      assert_refused_from_other(bench, request)
    end
  end

  # Re-review 3 finding 1 (M3b): a local lease's attempt is released by the accept's answer
  # (`Work.release_lease/1` answers `:released`, as a local lease imports nothing), so the
  # age check before that release is the only guard. The local source's own target, but the
  # `accepted` report answers only after the puller's injected clock moved by `by` on the
  # wall clock (the machine slept while it was sent).
  defmodule SlowAccept do
    @behaviour AtlasRuntime.Sources.Puller.Target

    alias AtlasRuntime.Sources.Local

    def new(clock, by) do
      {Local.Target, inner} = Local.Target.new()
      {__MODULE__, %{inner: inner, clock: clock, by: by}}
    end

    @impl true
    def poll(ref, input), do: Local.Target.poll(ref.inner, input)

    @impl true
    def send_report(ref, input) do
      answer = Local.Target.send_report(ref.inner, input)

      if input.report.state == :accepted,
        do: Agent.update(ref.clock, fn {mono, wall} -> {mono, wall + ref.by} end)

      answer
    end

    @impl true
    def uploader(ref, revision), do: Local.Target.uploader(ref.inner, revision)

    @impl true
    def get_blob(ref, lease_id, sha256), do: Local.Target.get_blob(ref.inner, lease_id, sha256)
  end

  describe "round 4: a local accept recorded at lease_ttl +/- 1 ms" do
    # The local source's lease_ttl (900 s), as its puller takes it from `timing`.
    @local_ttl 900_000

    for {offset, expired?} <- [{1, true}, {-1, false}] do
      @offset offset
      @expired expired?
      test "recorded at lease_ttl #{if offset > 0, do: "+", else: "-"} 1 ms: #{if expired?, do: "fenced, never running, nothing launched", else: "released and running"}",
           %{bench: bench} do
        local!(bench)
        {:ok, clock} = Agent.start_link(fn -> {0, 0} end)

        puller =
          start_supervised!(
            {AtlasRuntime.Sources.Puller,
             name: "local",
             target: SlowAccept.new(clock, @local_ttl + @offset),
             clock: fn -> Agent.get(clock, & &1) end,
             tick: :manual,
             polling: :manual}
          )

        assert {:added, _} = Local.add(client(), folder_work(bench, "complete one"))
        assert :polled = AtlasRuntime.Sources.Puller.poll_now(puller)

        assert [{lease_id, %{work_id: work_id, phase: phase, stamp: {0, 0}}}] =
                 Map.to_list(AtlasRuntime.Sources.Puller.leases(puller))

        if @expired do
          assert phase == :fenced

          assert %B.Outcome.Found{
                   work: %{
                     attempts: [%{result: %{never_started: true}, timestamps: timestamps}]
                   }
                 } = B.get_work(@client, %{work_id: work_id})

          assert is_nil(timestamps.running_at)
          assert launches(bench) == []
        else
          # Released, not fenced. `poll_now/1` answers once what the accept led to has ended
          # too (the `started` report, and the `ended` upload once the attempt is terminal and
          # quiescent), so how far the lease got by then depends on how fast the launch ran.
          assert phase in [:released, :started, :done]

          assert [%{timestamps: %{running_at: running_at}}] =
                   await_work(
                     work_id,
                     &match?([%{state: :completed, quiescent: true}], &1.attempts),
                     @client
                   ).attempts

          refute is_nil(running_at)
          assert [_one] = launches(bench)

          # Whatever the poll left, one check sends the rest: the lease ends done (its `ended`
          # uploaded), never fenced or lost.
          assert :ok = AtlasRuntime.Sources.Puller.check_now(puller)
          assert %{^lease_id => %{phase: :done}} = AtlasRuntime.Sources.Puller.leases(puller)
        end
      end
    end
  end

  defp report(lease_id, revision, report),
    do:
      LocalFacade.report({"local", [:lease]}, %{
        lease_id: lease_id,
        revision: revision,
        report: report
      })

  defp ended_result, do: %{kind: :completed, retryable: false, never_started: false}
end
