defmodule AtlasRuntime.Work.LeaseAdmissionTest do
  @moduledoc """
  M2 A1, the executor's lease admission (decision §5.3 items 1 and 5; M2 plan C2, C3):
  `Work.accept_lease/3` keys the work by the lease, holds its attempt until
  `Work.release_lease/1`, across a restart too, and never answers `at_capacity`;
  `Queue.offer/4` shares the free slots by strict priority with caps; and `Work.offer/1`
  reserves what it offers until `Work.offer_done/2`, so a direct submit between an offer and
  its accept never takes the offered slot.

  Main's decisions: the offer is the total of free slots and the profiles available (O1);
  only the sources polling right now share the free slots, and nothing is held for a source
  beyond its poll (O2).
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Sources.Rights
  alias AtlasRuntime.Test.ImportedBase
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work
  alias AtlasRuntime.Work.{Queue, Store}

  @moduletag capture_log: true

  @source "flow-prod"
  @client Rights.client(@source)

  # The base the leases name, imported for @source as its puller would (M2 A3): `id` is the
  # source's own base_id, `imported` what the puller hands the executor.
  defp imported_base!(bench),
    do: %{id: "base-1", imported: ImportedBase.import!(bench.dir, @source)}

  defp accept(code, lease), do: Work.accept_lease(@source, lease, code.imported)

  # A lease as the work source contract's Elixir target gives it.
  defp lease(code, lease_id, work_key, instructions, extra \\ []) do
    %S.Lease{
      lease_id: lease_id,
      expires_at: ~U[2026-11-17 13:00:00Z],
      work:
        struct!(
          S.OfferedWork,
          Keyword.merge(
            [
              work_key: work_key,
              title: instructions,
              instructions: instructions,
              profile: "light_work",
              cost_class: :standard,
              input: %S.WorkInput{
                base: %S.BaseRef{base_id: code.id, manifest: String.duplicate("0", 64)},
                permissions: :"read-only"
              }
            ],
            extra
          )
        )
    }
  end

  # Decision §5.5's example, with a third remote source behind flow-prod.
  @sources %{
    "sources" => [
      %{
        "name" => "local",
        "kind" => "builtin",
        "priority" => 1,
        "max_slots" => 6,
        "max_store_bytes" => 2_147_483_648
      },
      %{
        "name" => "flow-prod",
        "kind" => "remote",
        "url" => "https://flow.example/",
        "credential_file" => "sources/flow-prod/token",
        "priority" => 2,
        "max_slots" => 4,
        "max_store_bytes" => 2_147_483_648
      },
      %{
        "name" => "flow-test",
        "kind" => "remote",
        "url" => "https://flow-test.example/",
        "credential_file" => "sources/flow-test/token",
        "priority" => 3,
        "max_slots" => 4,
        "max_store_bytes" => 2_147_483_648
      }
    ]
  }

  # The example's sources with some fields changed (`local`'s max_slots 0: its share, first by
  # priority, would otherwise take every slot here, where it has no puller yet).
  defp sources(changes) do
    Map.update!(@sources, "sources", fn entries ->
      Enum.map(entries, fn entry -> Map.merge(entry, changes[entry["name"]] || %{}) end)
    end)
  end

  defp record(bench, id), do: Store.read_work(bench.dir, id)

  # The harness's light_work profile, to name a second profile like it.
  defp light_work do
    %{
      "permissions" => ["read-only", "workspace-write", "materialized-folder"],
      "cost_classes" => ["low", "standard"],
      "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
    }
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  defp work_count(bench),
    do: bench.dir |> Path.join("work/work-*.json") |> Path.wildcard() |> length()

  describe "accept_lease" do
    setup do
      bench = start!()
      %{bench: bench, code: imported_base!(bench)}
    end

    test "persists the work under the source's client, keyed by lease_id, held", %{
      bench: bench,
      code: code
    } do
      test = self()
      stop_work()
      start_work!(bench, after_write: &send(test, {:written, &1}))

      assert {:accepted, id} =
               accept(code, lease(code, "lease-1", "wk-1", "complete"))

      # Persisted before the answer (I2).
      assert_received {:written, %M.WorkRecord{work_id: ^id}}

      assert %M.WorkRecord{
               client: "source:flow-prod",
               client_key: "lease-1",
               idempotency_key: "wk-1",
               attempts: [%M.Attempt{state: :buffered, lease_hold: true}]
             } = record(bench, id)
    end

    test "re-delivered lease maps to the same work; a fresh attempt's new lease is a new work",
         %{bench: bench, code: code} do
      first = lease(code, "lease-1", "wk-1", "complete once")
      assert {:accepted, id} = accept(code, first)
      assert {:existing, ^id} = accept(code, first)
      assert [_one] = record(bench, id).attempts

      # The source's next attempt of the same work comes with a new lease: a new work.
      assert {:accepted, other} =
               accept(code, lease(code, "lease-2", "wk-1", "complete once"))

      assert other != id
      assert work_count(bench) == 2
    end

    test "held attempt does not start before recorded, and starts on release_lease", %{
      bench: bench,
      code: code
    } do
      assert {:accepted, id} =
               accept(code, lease(code, "lease-1", "wk-1", "complete held"))

      Process.sleep(300)
      assert %F.Outcome.Found{work: %{state: :buffered}} = F.get_work(@client, %{work_id: id})
      assert launches(bench) == []

      assert :released = Work.release_lease(id)
      assert %{attempts: [%{result: %{kind: :completed}}]} = await_state(id, :completed, @client)
      assert %M.Attempt{lease_hold: nil} = hd(record(bench, id).attempts)
    end

    test "held after restart: the persisted hold keeps the attempt from starting", %{
      bench: bench,
      code: code
    } do
      assert {:accepted, id} =
               accept(code, lease(code, "lease-1", "wk-1", "complete restart"))

      stop_work()
      start_work!(bench)
      Process.sleep(300)
      assert %F.Outcome.Found{work: %{state: :buffered}} = F.get_work(@client, %{work_id: id})
      assert launches(bench) == []

      assert :released = Work.release_lease(id)
      assert await_state(id, :completed, @client)
    end

    test "refusals are the work source contract's and create no record", %{
      bench: bench,
      code: code
    } do
      assert {:refused, :policy_forbids} =
               accept(code, lease(code, "l-p", "wk-p", "x", profile: "deep_coding"))

      change_set = %S.ChangeSetRef{manifest: String.duplicate("1", 64), fingerprints: []}
      with_change = lease(code, "l-c", "wk-c", "x")
      with_change = put_in(with_change.work.input.change_set, change_set)
      # Its change set was not imported (M2 A3): invalid.
      assert {:refused, :invalid} = accept(code, with_change)

      assert work_count(bench) == 0
      assert :not_found = Work.release_lease("work-none")
    end

    test "no lease path ever returns at_capacity: random offer/accept/submit/release runs",
         %{bench: bench, code: code} do
      # Two slots and a buffer of one: local submits fill the Runtime fast.
      write_policy!(bench.dir, sources(%{"local" => %{"max_slots" => 0}}))
      :rand.seed(:exsss, {7, 11, 13})

      Enum.reduce(1..40, %{leases: [], accepted: []}, fn n, acc ->
        case :rand.uniform(5) do
          # An offer, as many accepts as it offers, and its end.
          5 ->
            %F.Outcome.Capacity{slots: %{free: free}} = F.capacity(client())
            offer = Work.offer(@source)
            assert is_map(offer)
            # O1: one total, the same under each available profile.
            assert length(Enum.uniq(Map.values(offer))) <= 1
            used = offer |> Map.values() |> Enum.max(fn -> 0 end)
            assert used <= free

            leases =
              for k <- 1..used//1, do: lease(code, "lease-#{n}-#{k}", "wk-#{n}-#{k}", "o #{n}")

            ids = for l <- leases, do: elem({:accepted, _} = accept(code, l), 1)
            assert :ok = Work.offer_done(@source, used)
            %{acc | leases: leases ++ acc.leases, accepted: ids ++ acc.accepted}

          1 ->
            outcome = F.submit(client(), request(bench, "local #{n}"))

            assert match?(%F.Outcome.Accepted{}, outcome) or
                     match?(%F.Outcome.AtCapacity{}, outcome)

            acc

          2 when acc.accepted != [] ->
            assert Work.release_lease(Enum.random(acc.accepted)) in [:released]
            acc

          3 when acc.leases != [] ->
            again = Enum.random(acc.leases)
            assert {:existing, _} = accept(code, again)
            acc

          _ ->
            next = lease(code, "lease-#{n}", "wk-#{n}", "lease #{n}")
            assert {:accepted, id} = accept(code, next)
            %{acc | leases: [next | acc.leases], accepted: [id | acc.accepted]}
        end
      end)

      # Also when paused: a lease is still recorded (held), never at_capacity.
      assert :paused = Work.set_mode(:paused, "op")
      assert {:accepted, _} = accept(code, lease(code, "lease-p", "wk-p", "paused"))
      Work.set_mode(:open, "op")
    end
  end

  describe "offer" do
    setup do
      bench = start!(sources(%{"local" => %{"max_slots" => 0}}))
      %{bench: bench, code: imported_base!(bench)}
    end

    test "an offer is reserved for its poll only: once answered, another source gets the slots",
         %{bench: bench} do
      assert Work.offer(@source) == %{"light_work" => 2}
      # While flow-prod's poll is open, its offer is flow-prod's.
      assert Work.offer("flow-test") == %{}
      # A new offer to the same source replaces its own reservation.
      assert Work.offer(@source) == %{"light_work" => 2}
      # O2: answered, nothing is held for flow-prod, though its priority is higher.
      assert :ok = Work.offer_done(@source, 0)
      assert Work.offer("flow-test") == %{"light_work" => 2}
      assert :ok = Work.offer_done("flow-test", 0)

      # A source the policy does not name, and a core that is not open, are offered nothing.
      assert Work.offer("elsewhere") == %{}
      assert :paused = Work.set_mode(:paused, "op")
      assert Work.offer(@source) == %{}
      assert :open = Work.set_mode(:open, "op")
      assert :ok = Work.offer_done(@source, 0)

      # max_slots caps the offer.
      write_policy!(
        bench.dir,
        sources(%{"local" => %{"max_slots" => 0}, @source => %{"max_slots" => 1}})
      )

      assert Work.offer(@source) == %{"light_work" => 1}
      assert Work.offer("flow-test") == %{"light_work" => 1}
    end

    test "O2: priority orders only the sources polling at the same moment" do
      # flow-prod (priority 2) and flow-test (3) both poll while the core is paused: both
      # are offered nothing, and both polls stay open.
      assert :paused = Work.set_mode(:paused, "op")
      assert Work.offer(@source) == %{}
      assert Work.offer("flow-test") == %{}
      assert :open = Work.set_mode(:open, "op")

      # Slots are free again. flow-test asks first, but flow-prod polls at this moment too
      # and comes first: flow-test is offered nothing yet.
      assert Work.offer("flow-test") == %{}
      assert Work.offer(@source) == %{"light_work" => 2}

      # Once flow-prod's poll is answered, flow-test polling alone gets the slots.
      assert :ok = Work.offer_done(@source, 0)
      assert Work.offer("flow-test") == %{"light_work" => 2}
    end

    test "O2: a source that does not poll is held nothing; a puller that ends holds nothing",
         %{bench: bench} do
      # local (priority 1) has no puller here and is not polling: the lower priorities get
      # every free slot (local's max_slots is back at 6).
      write_policy!(bench.dir, @sources)
      assert Work.offer(@source) == %{"light_work" => 2}
      assert :ok = Work.offer_done(@source, 0)

      # A process takes an offer and ends without offer_done: its slots are free again.
      test = self()

      pid =
        spawn(fn ->
          send(test, {:offered, Work.offer(@source)})
        end)

      assert_receive {:offered, %{"light_work" => 2}}
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, _, _}
      # The core handles the end before the next call (its mailbox is in order only for one
      # sender, so wait until the slots are free again, bounded).
      assert eventually(fn -> Work.offer("flow-test") == %{"light_work" => 2} end)
    end

    test "O1: two profiles are offered the same total, and the source leases that many in all",
         %{bench: bench, code: code} do
      write_policy!(
        bench.dir,
        sources(%{"local" => %{"max_slots" => 0}})
        |> Map.put("profiles", %{
          "light_work" => light_work(),
          "deep_coding" => light_work()
        })
      )

      assert Work.offer(@source) == %{"light_work" => 2, "deep_coding" => 2}

      source = AtlasRuntime.Test.FakeWorkSource.start(name: @source)
      AtlasRuntime.Test.FakeWorkSource.use(source)

      for {key, profile} <- [{"a", "deep_coding"}, {"b", "light_work"}, {"c", "deep_coding"}] do
        AtlasRuntime.Test.FakeWorkSource.add_work(source, %{
          work_key: key,
          title: key,
          instructions: "complete",
          profile: profile,
          cost_class: :standard,
          input: %{
            base: %{base_id: code.id, manifest: String.duplicate("0", 64)},
            permissions: :"read-only"
          }
        })
      end

      assert %S.Outcome.Polled{leases: leases} =
               S.poll({"mini", [:lease]}, %{
                 runtime_id: "mini",
                 incarnation: "inc-1",
                 build: "test",
                 policy_version: 1,
                 offer: Work.offer(@source),
                 holdings: []
               })

      # Two slots free: two leases, not two per profile; first in, first out.
      assert Enum.map(leases, & &1.work.work_key) == ["a", "b"]
      assert :ok = Work.offer_done(@source, 0)
    end

    test "local submit between offer and accept does not take the reserved slot", %{
      bench: bench,
      code: code
    } do
      # One slot and a buffer of one: the local work may wait, the lease must not.
      write_policy!(
        bench.dir,
        Map.put(sources(%{"local" => %{"max_slots" => 0}}), "slots", ["s1"])
      )

      assert Work.offer(@source) == %{"light_work" => 1}

      local = submit!(bench, "hang local")
      Process.sleep(300)
      assert work!(local.work_id).state == :buffered

      assert {:accepted, id} =
               accept(code, lease(code, "lease-1", "wk-1", "hang lease"))

      assert :ok = Work.offer_done(@source, 1)
      Process.sleep(300)
      assert work!(local.work_id).state == :buffered
      assert launches(bench) == []

      # Recorded: the lease takes the slot it was offered; the local work waits behind it.
      assert :released = Work.release_lease(id)
      assert %{attempts: [%{slot: "s1"}]} = await_state(id, :running, @client)
      assert work!(local.work_id).state == :buffered

      F.cancel(@client, %{work_id: id, mode: "force"})
      await_state(id, :cancelled, @client)
      await_launch(bench, local)
      F.cancel(client(), %{work_id: local.work_id, mode: "force"})
      await_state(local.work_id, :cancelled)
    end
  end

  describe "Queue" do
    defp held_record(id, client, state \\ :buffered, hold \\ true) do
      M.WorkRecord.new!(
        work_id: id,
        client: client,
        idempotency_key: id,
        revision: 1,
        sequence: 1,
        request:
          M.Request.new!(
            title: "t",
            instructions: "i",
            profile: "light_work",
            cost_class: :standard,
            workspace: M.Base.new!(base_id: "b", permissions: :read_only)
          ),
        attempts: [
          M.Attempt.new!(
            attempt: 1,
            state: state,
            slot: if(state == :running, do: "s1"),
            timestamps: M.Timestamps.new!(received_at: DateTime.utc_now()),
            quiescent: false,
            lease_hold: hold
          )
        ]
      )
    end

    @sources [
      %{name: "flow-prod", priority: 2, max_slots: 4},
      %{name: "local", priority: 1, max_slots: 6}
    ]

    test "a held attempt is buffered but never startable" do
      works = %{
        "w1" => held_record("w1", "source:flow-prod"),
        "w2" => held_record("w2", "c1", :buffered, nil)
      }

      assert [{"w1", _}, {"w2", _}] = Enum.sort(Queue.buffered(works))
      assert [{"w2", _}] = Queue.startable(works)
    end

    test "one free slot and two sources polling: the higher priority gets it" do
      assert Queue.offer(%{}, ["s1"], @sources, %{}) == %{"local" => 1, "flow-prod" => 0}

      assert Queue.offer(%{}, ["s1", "s2", "s3"], @sources, %{}) == %{
               "local" => 3,
               "flow-prod" => 0
             }
    end

    test "max_slots caps the offer, and the next source polling gets the rest" do
      sources = [
        %{name: "local", priority: 1, max_slots: 1},
        %{name: "flow-prod", priority: 2, max_slots: 4}
      ]

      assert Queue.offer(%{}, ["s1", "s2", "s3"], sources, %{}) == %{
               "local" => 1,
               "flow-prod" => 2
             }

      # What a source holds counts against its own cap.
      works = %{"w1" => held_record("w1", "source:local", :running, nil)}

      assert Queue.offer(works, ["s1", "s2", "s3"], sources, %{}) == %{
               "local" => 0,
               "flow-prod" => 2
             }
    end

    test "a source polling alone gets the free slots, whatever its priority (O2)" do
      assert Queue.offer(
               %{},
               ["s1", "s2"],
               [%{name: "flow-prod", priority: 2, max_slots: 4}],
               %{}
             ) ==
               %{"flow-prod" => 2}
    end

    test "never more than the free slots minus held attempts and outstanding reservations" do
      works = %{"w1" => held_record("w1", "source:flow-prod")}
      assert Queue.offer(works, ["s1", "s2"], @sources, %{}) == %{"local" => 1, "flow-prod" => 0}

      assert Queue.offer(works, ["s1", "s2"], @sources, %{"local" => 1}) == %{
               "local" => 0,
               "flow-prod" => 0
             }

      assert Queue.offer(works, ["s1"], @sources, %{"flow-prod" => 3}) == %{
               "local" => 0,
               "flow-prod" => 0
             }
    end
  end
end
