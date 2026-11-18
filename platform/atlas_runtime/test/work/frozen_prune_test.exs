defmodule AtlasRuntime.Work.FrozenPruneTest do
  @moduledoc """
  S5a P8 (design §3.9 "Retention", §4; s5a-plan B12): a frozen result is retained while its
  own work record exists, or while another existing work's `source` or `based_on` names it.
  After that it becomes a tombstone (fingerprints kept, entries dropped), both reads answer
  `pruned`, and the blobs no retained result names are deleted; a shared blob stays.

  A work is made due for pruning by ageing its stored attempt ends while the core is
  stopped, then restarting the core with a retention of one hour, so only that work goes.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import AtlasRuntime.CodeStandIn, only: [submit_base!: 2]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.{FrozenStore, Store}

  @moduletag capture_log: true

  @retention 3600

  setup do
    bench = start!(%{}, retention: @retention)
    code = CodeStandIn.start!(bench.dir, %{"README.md" => "base\n"})
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp entry(%F.Outcome.Frozen{roots: [root]}, path),
    do: Enum.find(root.entries, &(&1.path == path))

  defp done!(code, instructions) do
    work = submit_base!(code, instructions)

    await_work(
      work.work_id,
      &(&1.state == :completed and Enum.all?(&1.attempts, fn a -> a.quiescent end))
    )

    %F.Outcome.Frozen{} = frozen = F.get_frozen(client(), %{work_id: work.work_id})
    {work, frozen}
  end

  # With the core stopped: `change` applied to each stored record, then the core restarted.
  defp edit_and_restart!(bench, changes) do
    stop_work()

    for {id, change} <- changes,
        do: Store.put_work!(bench.dir, change.(Store.read_work(bench.dir, id)))

    start_work!(bench, retention: @retention)
  end

  defp aged(record) do
    old =
      DateTime.add(DateTime.utc_now(), -2 * @retention, :second)
      |> DateTime.truncate(:millisecond)

    %{
      record
      | attempts:
          Enum.map(record.attempts, fn a -> %{a | timestamps: %{a.timestamps | ended_at: old}} end)
    }
  end

  # The executor pruned its record of the work (it was aged above). The local source keeps
  # its own copy of the work (C6); the frozen reads are the executor's.
  defp await_pruned(bench, id), do: await(fn -> is_nil(Store.read_work(bench.dir, id)) end)

  defp blob?(bench, sha256), do: File.regular?(FrozenStore.blob_path(bench.dir, sha256))

  test "pruning a work no other names: both reads answer pruned, its own blobs go, a shared blob stays",
       %{bench: bench, code: code} do
    {one, first} = done!(code, "write atlas/shared.txt same; write atlas/only-one.txt one")
    {two, second} = done!(code, "write atlas/shared.txt same; write atlas/only-two.txt two")
    shared = entry(first, "shared.txt").sha256
    only_one = entry(first, "only-one.txt").sha256
    only_two = entry(second, "only-two.txt").sha256
    assert shared == entry(second, "shared.txt").sha256
    [%{fingerprint: fingerprint}] = first.roots

    edit_and_restart!(bench, [{one.work_id, &aged/1}])
    await_pruned(bench, one.work_id)

    assert %F.Outcome.Pruned{work_id: id, kind: :completed} =
             F.get_frozen(client(), %{work_id: one.work_id})

    assert id == one.work_id
    assert %F.Outcome.Pruned{} = F.get_frozen(client(), %{work_id: one.work_id, attempt: 1})

    for sha256 <- [shared, only_one],
        do:
          assert(
            %F.Outcome.Pruned{work_id: ^id} =
              F.get_frozen_blob(client(), %{work_id: one.work_id, attempt: 1, sha256: sha256})
          )

    # Visibility stays the key tombstone's: another client is told nothing.
    assert %F.Outcome.NotFound{} = F.get_frozen(client("c2"), %{work_id: one.work_id})

    refute blob?(bench, only_one)
    assert blob?(bench, shared) and blob?(bench, only_two)

    # The second work's result is untouched, its shared blob still streams.
    assert ^second = F.get_frozen(client(), %{work_id: two.work_id})
    blob = F.get_frozen_blob(client(), %{work_id: two.work_id, attempt: 1, sha256: shared})
    assert blob.content |> Enum.to_list() |> IO.iodata_to_binary() == "same\n"

    # The tombstone keeps every root's fingerprint and drops the entries, across a restart.
    assert %{pruned: true, roots: [%{root: "atlas", fingerprint: ^fingerprint, entries: []}]} =
             FrozenStore.get(bench.dir, one.work_id, 1)

    stop_work()
    start_work!(bench, retention: @retention)
    assert %F.Outcome.Pruned{} = F.get_frozen(client(), %{work_id: one.work_id})
  end

  for {name, reference} <- [source: :source, based_on: :based_on] do
    test "a frozen result another work's #{name} names outlives its work record, until that work goes too",
         %{bench: bench, code: code} do
      {one, first} = done!(code, "write atlas/kept.txt kept")
      {two, _second} = done!(code, "write atlas/other.txt other")
      kept = entry(first, "kept.txt").sha256
      [%{fingerprint: fingerprint}] = first.roots

      edit_and_restart!(bench, [
        {one.work_id, &aged/1},
        {two.work_id, &refer(&1, unquote(reference), one.work_id, fingerprint)}
      ])

      await_pruned(bench, one.work_id)

      # Retained: frozen is answered, the default attempt from the store, the blob streams.
      assert ^first = F.get_frozen(client(), %{work_id: one.work_id})

      assert ^first =
               F.get_frozen(client(), %{
                 work_id: one.work_id,
                 attempt: 1,
                 fingerprint: fingerprint
               })

      assert ^first = F.get_frozen(client("admin", [:read_all]), %{work_id: one.work_id})
      assert %F.Outcome.NotFound{} = F.get_frozen(client("c2"), %{work_id: one.work_id})

      assert %F.Outcome.Blob{} =
               F.get_frozen_blob(client(), %{work_id: one.work_id, attempt: 1, sha256: kept})

      assert blob?(bench, kept)
      assert %{pruned: false} = FrozenStore.get(bench.dir, one.work_id, 1)

      # Pruning the work that named it as well: now it is a tombstone.
      edit_and_restart!(bench, [{two.work_id, &aged/1}])
      await_pruned(bench, two.work_id)

      await(fn ->
        match?(%F.Outcome.Pruned{}, F.get_frozen(client(), %{work_id: one.work_id}))
      end)

      assert %F.Outcome.Pruned{} =
               F.get_frozen_blob(client(), %{work_id: one.work_id, attempt: 1, sha256: kept})

      assert %{pruned: true, roots: [%{fingerprint: ^fingerprint, entries: []}]} =
               FrozenStore.get(bench.dir, one.work_id, 1)

      refute blob?(bench, kept)
    end
  end

  test "at boot, a work deleted before its frozen result was pruned (a crash) is pruned then",
       %{bench: bench, code: code} do
    {one, first} = done!(code, "write atlas/crash.txt crash")
    sha256 = entry(first, "crash.txt").sha256
    record = Store.read_work(bench.dir, one.work_id)
    stop_work()

    # The work's pruning wrote the tombstone and deleted the record, then the core died.
    {:ok, loaded} = Store.load(bench.dir)

    tombstone =
      M.KeyIndexEntry.new!(
        client: record.client,
        client_key: one.work_id,
        work_id: one.work_id,
        final_kind: :completed,
        pruned: true
      )

    Store.put_index!(bench.dir, Map.put(loaded.index, {:pruned, one.work_id}, tombstone))
    Store.delete_work!(bench.dir, one.work_id)
    assert %{pruned: false} = FrozenStore.get(bench.dir, one.work_id, 1)

    start_work!(bench, retention: @retention)
    assert %F.Outcome.Pruned{} = F.get_frozen(client(), %{work_id: one.work_id})
    assert %{pruned: true} = FrozenStore.get(bench.dir, one.work_id, 1)
    refute blob?(bench, sha256)
  end

  test "a frozen result whose work record is missing without a key tombstone is kept",
       %{bench: bench, code: code} do
    {one, first} = done!(code, "write atlas/lost.txt lost")
    sha256 = entry(first, "lost.txt").sha256
    stop_work()
    Store.delete_work!(bench.dir, one.work_id)
    start_work!(bench, retention: @retention)

    # Nothing names the work any longer, so nobody reads it; the store is not guessed at.
    assert %F.Outcome.NotFound{} = F.get_frozen(client(), %{work_id: one.work_id})
    assert %{pruned: false} = FrozenStore.get(bench.dir, one.work_id, 1)
    assert blob?(bench, sha256)
  end

  defp refer(record, :source, id, _fingerprint),
    do: %{record | source: M.Source.new!(work_id: id, attempt: 1)}

  defp refer(record, :based_on, id, fingerprint) do
    based_on =
      M.BasedOn.new!(
        work_id: id,
        attempt: 1,
        fingerprints: [M.RootFingerprint.new!(root: "atlas", fingerprint: fingerprint)]
      )

    [attempt] = record.attempts
    product = %{attempt.result.work_product | based_on: based_on}
    %{record | attempts: [%{attempt | result: %{attempt.result | work_product: product}}]}
  end
end
