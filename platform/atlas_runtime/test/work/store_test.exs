defmodule AtlasRuntime.Work.StoreTest do
  # D2 acceptance 9: a store the core cannot read is a logged refusal at boot, never a
  # crash loop or a silent migration.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  import ExUnit.CaptureLog
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  test "a hand-corrupted format_version: the core refuses to start and says why; nothing crashes" do
    bench = start!()
    work = submit!(bench, "complete stored", %{client_key: "stored"})
    await_state(work.work_id, :completed)
    stop_work()

    path = Path.join([bench.dir, "work", work.work_id <> ".json"])

    File.write!(
      path,
      path |> File.read!() |> JSON.decode!() |> Map.put("format_version", 99) |> JSON.encode!()
    )

    log =
      capture_log(fn ->
        assert {:error, {:store, why}} =
                 AtlasRuntime.Work.start_link(bench.dir, service: bench.service)

        assert why =~ work.work_id
        assert why =~ "format_version"
      end)

    assert log =~ "not started"
    assert Process.alive?(bench.service)
    # The facade still answers, with "not running" outcomes.
    assert %F.Outcome.AtCapacity{reason: :not_accepting} =
             F.submit(client(), request(bench, "complete"))

    assert %F.Outcome.NotFound{} = F.find_work(client(), %{client_key: "stored"})
  end

  test "records, index and sequence survive a reload; a lost index entry is repaired from its record" do
    bench = start!()
    work = submit!(bench, "complete kept", %{client_key: "kept"})
    done = await_state(work.work_id, :completed)
    stop_work()

    assert {:ok, loaded} = Store.load(bench.dir)
    assert loaded.sequence >= done.sequence
    assert Map.keys(loaded.works) == [work.work_id]
    assert %{work_id: id, pruned: false} = loaded.index[{"c1", "kept"}]
    assert id == work.work_id

    File.rm!(Path.join([bench.dir, "work", "index.json"]))
    File.write!(Path.join([bench.dir, "work", "sequence"]), "1")
    assert {:ok, repaired} = Store.load(bench.dir)
    assert repaired.index[{"c1", "kept"}].work_id == work.work_id
    # The sequence is never below a record's, even with the sequence file set back.
    assert repaired.sequence >= done.sequence
  end
end
