defmodule AtlasRuntime.Work.PruneTest do
  # D2 acceptance 7: pruned work answers pruned (I7); a key never used answers not_found.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  test "a finished work past its retention is pruned; its key stays a tombstone" do
    bench = start!(%{}, retention: 0)
    work = submit!(bench, "complete and go", %{client_key: "gone"})

    assert %F.Outcome.Pruned{work_id: id, kind: :completed} =
             await(fn ->
               case F.get_work(client(), %{work_id: work.work_id}) do
                 %F.Outcome.Pruned{} = pruned -> pruned
                 _ -> nil
               end
             end)

    assert id == work.work_id
    assert %F.Outcome.Pruned{kind: :completed} = F.find_work(client(), %{client_key: "gone"})
    assert %F.Outcome.NotFound{} = F.find_work(client(), %{client_key: "never used"})
    assert %F.Outcome.NotFound{} = F.get_work(client("c2"), %{work_id: work.work_id})
    assert %F.Outcome.Works{works: []} = F.list_work(client(), %{})
    refute File.exists?(Path.join([bench.dir, "work", work.work_id <> ".json"]))

    # The key is never reused for new work.
    assert %F.Outcome.Refused{reason: :conflict} =
             F.submit(client(), request(bench, "complete and go", %{client_key: "gone"}))
  end

  defp await_pruned(id, client \\ client()) do
    await(fn ->
      case F.get_work(client, %{work_id: id}) do
        %F.Outcome.Pruned{} = pruned -> pruned
        _ -> nil
      end
    end)
  end

  test "a pruned work without a client key answers pruned too, also after a restart" do
    bench = start!(%{}, retention: 0)
    work = submit!(bench, "complete without a key")

    assert %F.Outcome.Pruned{work_id: id, kind: :completed} = await_pruned(work.work_id)
    assert id == work.work_id
    assert %F.Outcome.NotFound{} = F.get_work(client("c2"), %{work_id: work.work_id})

    assert %F.Outcome.Pruned{} =
             F.get_work(client("admin", [:read_all]), %{work_id: work.work_id})

    # The tombstone answers for the work, never for a client key.
    assert %F.Outcome.NotFound{} = F.find_work(client(), %{client_key: work.work_id})

    stop_work()
    start_work!(bench, retention: 0)
    assert %F.Outcome.Pruned{kind: :completed} = F.get_work(client(), %{work_id: work.work_id})
    assert %F.Outcome.NotFound{} = F.find_work(client(), %{client_key: work.work_id})
  end

  test "pruning is a change: a subscriber gets work_changed for it" do
    bench = start!(%{}, retention: 3600)
    work = submit!(bench, "complete then prune", %{client_key: "notify"})
    done = await_work(work.work_id, &(&1.state == :completed and hd(&1.attempts).quiescent))

    # The same store under a core that prunes at once; slow heartbeats leave time to subscribe.
    stop_work()
    start_work!(bench, retention: 0, heartbeat_ms: 500)
    assert %F.Outcome.Subscribed{} = F.subscribe(client(), %{})
    await_pruned(work.work_id)

    assert [%F.WorkChanged{revision: revision, state: :completed, sequence: sequence}] =
             for(
               %F.WorkChanged{work_id: id} = change <- notifications(),
               id == work.work_id,
               do: change
             )

    assert revision == done.revision + 1
    assert sequence > done.sequence
  end
end
