defmodule AtlasRuntime.Sources.UploadWiringTest do
  @moduledoc """
  M2 A3, the result upload's wiring (decision §5.2 "Result upload"; W6's seam over M1's
  in-BEAM target, `AtlasRuntime.Sources.InBeamTarget`): a lease from a work source is
  offered, accepted, recorded and run by the executor, and its result uploaded through the
  `work_source` contract. The source then holds a complete result: the change set with each
  root's `csf_` fingerprint, which it can recompute, and every blob the change set writes,
  with its sha256; a repeat uploads nothing again; a lost lease and a rejected report stop
  the upload with nothing stored.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Sources.{InBeamTarget, Rights, Upload}
  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.Test.ImportedBase
  alias AtlasRuntime.Test.WorkSourceFacade, as: S
  alias AtlasRuntime.Work

  @moduletag capture_log: true

  @name "flow-test"
  @client Rights.client(@name)
  # The Runtime as the source knows it (its per-Runtime credential).
  @runtime {"mini", [:lease]}
  @files %{"README.md" => "base\n", "old.md" => "old\n"}

  @sources %{
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
  }

  setup do
    bench = start!(@sources)
    # The base the lease names, imported from this source as its puller would (M2 A3).
    code = %{id: "base-1", imported: ImportedBase.import!(bench.dir, @name, @files)}
    source = Source.start(name: @name)
    Source.use(source)
    %{bench: bench, code: code, source: source}
  end

  defp poll(offer, holdings \\ []) do
    S.poll(@runtime, %{
      runtime_id: "mini",
      incarnation: "inc-1",
      build: "test",
      policy_version: 1,
      offer: offer,
      holdings: holdings
    })
  end

  defp report(lease_id, revision, report),
    do: S.report(@runtime, %{lease_id: lease_id, revision: revision, report: report})

  # Offered, leased, accepted (revision 1), recorded, started (revision 2) and run to its
  # quiescent end: the lease id and the work.
  defp leased_and_ended!(code, source, instructions) do
    Source.add_work(source, %{
      work_key: "task-1",
      title: instructions,
      instructions: instructions,
      profile: "light_work",
      cost_class: :standard,
      input: %{
        base: %{base_id: code.id, manifest: String.duplicate("0", 64)},
        permissions: :"workspace-write"
      }
    })

    assert %{"light_work" => 2} = offer = Work.offer(@name)
    assert %S.Outcome.Polled{leases: [%S.Lease{lease_id: lease_id} = lease]} = poll(offer)
    assert {:accepted, work_id} = Work.accept_lease(@name, lease, code.imported)
    assert :ok = Work.offer_done(@name, 1)

    assert %S.Outcome.Recorded{} = report(lease_id, 1, %{state: :accepted})
    assert :released = Work.release_lease(work_id)
    assert %S.Outcome.Recorded{} = report(lease_id, 2, %{state: :started})

    work =
      await_work(work_id, &(&1.state == :completed and hd(&1.attempts).quiescent), @client)

    {lease_id, work}
  end

  defp target(revision), do: {InBeamTarget, %{facade: S, client: @runtime, revision: revision}}

  defp json(entries),
    do: entries |> Enum.map(&Map.from_struct/1) |> JSON.encode!() |> JSON.decode!()

  defp reports(source, lease_id), do: Agent.get(source, & &1.leases[lease_id].reports)

  @two "write atlas/a.txt alpha; write atlas/b.txt beta; delete atlas/old.md"

  test "a leased work's result reaches the source complete: change set, csf_ and every blob",
       %{bench: bench, code: code, source: source} do
    {lease_id, work} = leased_and_ended!(code, source, @two)

    assert {:ok, %{uploaded: uploaded, skipped: []}} =
             Upload.run(@client, target(3), lease_id, work.work_id)

    assert [_accepted, _started, %S.Ended{} = ended] = reports(source, lease_id)
    assert %S.Result{kind: :completed, never_started: false} = ended.result
    assert [%S.Provenance{profile: "light_work", slot: slot}] = ended.provenance
    assert is_binary(slot)
    # Nothing of this machine's Runtime home crosses the contract (D44).
    refute inspect(ended, limit: :infinity) =~ Path.expand(bench.dir)

    # The source recomputes each root's csf_ from the base and the entries, as JSON has them.
    frozen = B.get_frozen(@client, %{work_id: work.work_id})

    assert [%S.ChangeRoot{root: "atlas", fingerprint: "csf_" <> _} = root] =
             ended.change_set.roots

    assert root.fingerprint ==
             AtlasChangeset.fingerprint(frozen.base, root.root, json(root.entries))

    assert root.fingerprint == hd(frozen.roots).fingerprint

    writes = for %{op: :write, sha256: sha} <- root.entries, do: sha
    blobs = Source.blobs(source)
    assert Enum.sort(uploaded) == Enum.sort(writes)
    assert Enum.sort(writes) == Enum.sort([Source.sha256("alpha\n"), Source.sha256("beta\n")])
    for sha <- writes, do: assert(Source.sha256(blobs[sha]) == sha)

    # A repeat (after a restart): the same report again, nothing uploaded twice.
    assert {:ok, %{uploaded: []}} = Upload.run(@client, target(3), lease_id, work.work_id)
    assert length(reports(source, lease_id)) == 3
  end

  test "a lost lease stops the upload at once: nothing is stored", %{code: code, source: source} do
    {lease_id, work} = leased_and_ended!(code, source, "write atlas/a.txt lost")
    # Not renewed for lease_ttl + grace: the source has lost the lease.
    Source.advance(source, 900 + 121)
    assert %S.Outcome.Polled{} = poll(%{})

    assert {:stopped, :lease_lost} = Upload.run(@client, target(3), lease_id, work.work_id)
    refute Map.has_key?(Source.blobs(source), Source.sha256("lost\n"))
  end

  test "a rejected report (a revision conflict) stops the upload: nothing is stored", %{
    code: code,
    source: source
  } do
    {lease_id, work} = leased_and_ended!(code, source, "write atlas/a.txt rejected")

    assert {:stopped, :lease_lost} = Upload.run(@client, target(7), lease_id, work.work_id)
    assert length(reports(source, lease_id)) == 2
    refute Map.has_key?(Source.blobs(source), Source.sha256("rejected\n"))
  end
end
