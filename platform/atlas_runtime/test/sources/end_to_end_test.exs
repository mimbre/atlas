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
  3. Local direct submits next to leases: every lease is accepted and runs; none is refused,
     whatever the direct submits get.

  Every lease names a base the puller imports from this source (A3, W5: the A4 cases rerun
  on an imported base): its blobs through `get_blob` into the source's own store, the tree
  composed from the imported baseline. No Code stand-in runs here.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{Puller, Rights}
  alias AtlasRuntime.Test.FakeSourceTarget
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work

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
         [name: @name, target: ctx.target, tick: 50, min_poll_ms: 20, retry_ms: 20],
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
    add(ctx, "task-1", "write atlas/a.txt alpha; write atlas/b.txt beta")
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

  test "local direct submits next to leases: every lease is accepted and runs, none is refused",
       ctx do
    keys = for n <- 1..4, do: "task-#{n}"
    for key <- keys, do: add(ctx, key, "complete")
    puller!(ctx)

    local =
      for n <- 1..4,
          do: B.submit(client(), request(ctx.bench, "local #{n}", %{client_key: "local-#{n}"}))

    # The direct submits do run next to the leases (what else they get is theirs).
    assert Enum.any?(local, &match?(%B.Outcome.Accepted{}, &1))

    await(fn -> Enum.all?(keys, &ended?(ctx.source, &1)) end)

    for key <- keys do
      assert [%{reports: [%S.Accepted{}, %S.Started{}, %S.Ended{result: %{kind: :completed}}]}] =
               leases(ctx.source, key)
    end

    assert length(Work.holdings(@name)) == 4
  end
end
