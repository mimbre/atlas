defmodule AtlasRuntime.Sources.EndToEndTest do
  @moduledoc """
  M2 A4, in-BEAM end to end (M2 plan A4; no production code): the in-test source, the real
  executor and the fake harness, with the puller on its own timers (`polling: :auto`, a short
  check interval).

  1. A lease is polled, run to completed, and its result uploaded: the source holds the
     change set and every blob it writes.
  2. Two Runtimes on one source: the first loses the source, self-fences on its own clock and
     sends nothing more of the lease; after `lease_ttl + grace` the second takes a fresh
     lease of the same work; a stale report under the first lease is `lease_lost` and lands
     nothing.
  3. Local works next to leases (M2 A7: no direct submit; the CLI's work comes as the
     built-in local source's leases): every lease of both sources is accepted and runs, and
     none is refused.

  Every lease names a base the puller imports from this source (A3, W5: the A4 cases rerun
  on an imported base): its blobs through `get_blob` into the source's own store, the tree
  composed from the imported baseline. No Code stand-in runs here.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{Local, Puller, Rights, StoreLock}
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work
  alias AtlasTestAwait, as: Await

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)
  @laptop {"laptop", [:lease]}

  setup do
    bench =
      start!(%{
        "sources" => [
          %{
            "name" => @name,
            "kind" => "remote",
            "url" => "https://flow-test.example/",
            "credential_file" => "sources/flow-test/token",
            "priority" => 1,
            "max_slots" => 2,
            "max_store_bytes" => 2_147_483_648
          }
        ]
      })

    source = Source.start(name: @name)
    Source.use(source)
    %{bench: bench, source: source, target: FakeSourceTarget.new(source)}
  end

  defp add(ctx, key, instructions) do
    Source.add_base_work(ctx.source, %{
      work_key: key,
      title: key,
      instructions: instructions,
      profile: "light_work",
      cost_class: :standard,
      input: %{
        permissions: :"workspace-write"
      }
    })
  end

  defp puller!(ctx, opts \\ []) do
    start_supervised!(
      {Puller,
       Keyword.merge(
         [
           name: @name,
           target: ctx.target,
           tick: 50,
           min_poll_ms: 20,
           retry_ms: 20,
           import: [git: Source.git(ctx.source)]
         ],
         opts
       )}
    )
  end

  defp leases(source, key) do
    Agent.get(source, fn s ->
      s.leases |> Map.values() |> Enum.filter(&(&1.work.work_key == key)) |> Enum.sort_by(& &1.id)
    end)
  end

  defp ended?(source, key),
    do: Enum.any?(leases(source, key), &match?([_ | _], for(%S.Ended{} <- &1.reports, do: 1)))

  test "a lease is polled, run to completed, and its result uploaded", ctx do
    add(ctx, "task-1", "write a.txt alpha; write b.txt beta")
    puller!(ctx)

    await(fn -> ended?(ctx.source, "task-1") end)

    assert [%{reports: [%S.Accepted{}, %S.Started{}, %S.Ended{} = ended]}] =
             leases(ctx.source, "task-1")

    assert %S.Result{kind: :completed} = ended.result

    assert [%S.ChangeRoot{root: "atlas", fingerprint: "csf_" <> _, entries: entries}] =
             ended.change_set.roots

    writes = for %{op: :write, sha256: sha} <- entries, do: sha
    assert Enum.sort(writes) == Enum.sort([Source.sha256("alpha\n"), Source.sha256("beta\n")])
    # The blobs follow the recorded ended.
    await(fn -> Enum.all?(writes, &Map.has_key?(Source.blobs(ctx.source), &1)) end)
    for sha <- writes, do: assert(Source.sha256(Source.blobs(ctx.source)[sha]) == sha)
  end

  test "two Runtimes: the lost one self-fences and lands nothing; the other takes a fresh lease",
       ctx do
    add(ctx, "task-1", "hang")
    # Supervised, so it outlives the puller at the test's end.
    clock = start_supervised!({Agent, fn -> {0, 0} end})
    puller = puller!(ctx, clock: fn -> Agent.get(clock, & &1) end)

    await(fn -> match?([%{reports: [_, %S.Started{}]}], leases(ctx.source, "task-1")) end)
    [%{id: stale}] = leases(ctx.source, "task-1")
    assert %B.Outcome.Works{works: [%{work_id: work_id}]} = B.list_work(@client, %{})

    # The first Runtime loses the source and sleeps past lease_ttl (wall clock on, monotonic
    # still). Its own checks fence the lease.
    FakeSourceTarget.hook(ctx.target, :poll, fn _call, _input -> {:error, :unreachable} end)
    Agent.update(clock, fn {m, s} -> {m, s + 900_000} end)
    work = await_work(work_id, &(&1.state == :cancelled and hd(&1.attempts).quiescent), @client)
    assert hd(work.attempts).cancel_reason == :cancel
    assert Puller.leases(puller)[stale].phase == :fenced

    # The source re-leases only after lease_ttl + grace: the second Runtime takes the work.
    Source.advance(ctx.source, 900 + 120)

    assert %S.Outcome.Polled{leases: [%S.Lease{lease_id: fresh, work: %{work_key: "task-1"}}]} =
             S.poll(@laptop, %{
               runtime_id: "laptop",
               incarnation: "inc-l",
               build: "test",
               policy_version: 1,
               offer: %{"light_work" => 1},
               holdings: []
             })

    assert fresh != stale
    assert Source.current(ctx.source, "task-1") == fresh

    # The first Runtime reaches the source again: it sends nothing of the stale lease, and a
    # stale report is lease_lost.
    FakeSourceTarget.hook(ctx.target, :poll, nil)

    # The event: a poll answered (so sent after the hook was cleared), then a check with its
    # tasks ended. The poll held nothing, and no report of the stale lease was sent.
    assert await(fn -> Puller.poll_now(puller) == :polled end)
    assert :ok = Puller.check_now(puller)
    assert %{holdings: []} = List.last(FakeSourceTarget.calls(ctx.target, :poll))

    assert [%{id: ^stale, reports: [%S.Accepted{}, %S.Started{}]}, %{id: ^fresh, reports: []}] =
             leases(ctx.source, "task-1")

    stale_ended = %{
      lease_id: stale,
      revision: 3,
      report: %{
        state: :ended,
        result: %{kind: :cancelled, retryable: false, never_started: false},
        provenance: []
      }
    }

    assert %S.Outcome.LeaseLost{} = S.report({"mini", [:lease]}, stale_ended)
    assert [%{reports: [_, _]}, %{reports: []}] = leases(ctx.source, "task-1")
    assert %B.Outcome.Works{works: [_one]} = B.list_work(@client, %{})
  end

  test "local works next to leases: every lease of both sources is accepted and runs, none is refused",
       ctx do
    # The policy names the local source too, after flow-test; its puller runs beside.
    write_policy!(ctx.bench.dir, %{
      "sources" => [
        %{
          "name" => @name,
          "kind" => "remote",
          "url" => "https://flow-test.example/",
          "credential_file" => "sources/flow-test/token",
          "priority" => 1,
          "max_slots" => 2,
          "max_store_bytes" => 2_147_483_648
        },
        %{
          "name" => "local",
          "kind" => "builtin",
          "priority" => 2,
          "max_slots" => 2,
          "max_store_bytes" => 2_147_483_648
        }
      ]
    })

    start_supervised!(%{id: Local, start: {Local, :start_link, [ctx.bench.dir, []]}})

    start_supervised!(
      {Puller,
       name: "local",
       target: Local.Target.new(),
       register: Local.puller_name(),
       tick: 50,
       min_poll_ms: 20,
       retry_ms: 20},
      id: :local_puller
    )

    keys = for n <- 1..4, do: "task-#{n}"
    for key <- keys, do: add(ctx, key, "complete")
    puller!(ctx)

    local =
      for n <- 1..4 do
        assert %B.Outcome.Accepted{work: work} =
                 B.submit(
                   client(),
                   request(ctx.bench, "complete local #{n}", %{client_key: "local-#{n}"})
                 )

        work
      end

    await(fn -> Enum.all?(keys, &ended?(ctx.source, &1)) end)

    for key <- keys do
      assert [%{reports: [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}]}] =
               leases(ctx.source, key)
    end

    # The executor's record completes first; the local source records the end once the
    # puller's report (sent off the puller) reaches it, so that is awaited too.
    for work <- local do
      assert [%{state: :completed}] = await_state(work.work_id, :completed).attempts

      await(
        fn ->
          match?({:ok, %{state: :ended, result: %{kind: :completed}}}, Local.get(work.work_id))
        end,
        "the local source records #{work.work_id} ended, completed"
      )
    end

    assert length(Work.holdings(@name)) == 4
    assert length(Work.holdings("local")) == 4
  end

  # CI's "local works next to leases" failed "cannot store blob" when two leases on one base
  # were imported at once: the second import's store scan removed the temporary file the
  # first was still writing. Here that moment is made certain: the first lease's first blob
  # is held after its bytes, before its end, until the second lease's import has either
  # queued for the source's store lock or (with no lock) scanned the store and fetched.
  test "two leases on one base imported at once: the second waits for the first one's writes; both run",
       ctx do
    test = self()
    once = start_supervised!({Agent, fn -> true end}, id: :first_blob)

    FakeSourceTarget.hook(ctx.target, :get_blob, fn real, {lease_id, _sha256} ->
      with {:ok, blob} <- real.() do
        if Agent.get_and_update(once, &{&1, false}) do
          hold =
            Stream.flat_map([nil], fn _ ->
              send(test, {:writing, lease_id, self()})
              receive do: (:go -> [])
            end)

          {:ok, %{blob | content: Stream.concat(blob.content, hold)}}
        else
          {:ok, blob}
        end
      end
    end)

    keys = ["task-1", "task-2"]
    add(ctx, "task-1", "complete")
    puller!(ctx)

    # The second lease is offered only now, so its import's scan comes after the first
    # import's temporary file is open (polled in one batch, both scans could come first).
    assert_receive {:writing, first, writer}
    add(ctx, "task-2", "complete")
    %{home: home} = Work.runtime()
    {FakeSourceTarget, %{hooks: hooks}} = ctx.target

    Await.until(
      fn ->
        StoreLock.waiting(home, @name) != [] or
          Enum.any?(FakeSourceTarget.calls(ctx.target, :get_blob), &(elem(&1, 0) != first))
      end,
      wake: [{:trace, StoreLock}, {:trace, hooks}]
    )

    send(writer, :go)
    await(fn -> Enum.all?(keys, &ended?(ctx.source, &1)) end)

    for key <- keys do
      assert [%{reports: [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}]}] =
               leases(ctx.source, key)
    end
  end
end
