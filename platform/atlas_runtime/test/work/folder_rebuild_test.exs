defmodule AtlasRuntime.Work.FolderRebuildTest do
  @moduledoc """
  S5a P7a, B30 (design §3.9 RQ7): a fresh retry of a `base` work rebuilds its one folder
  from the base, only once every earlier attempt is terminal and quiescent. The old folder
  is moved aside into `<home>/scratch/rebuild-<work_id>.<n>` and removed; a crash in
  between leaves that tree, which boot removes before any attempt starts.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness

  import AtlasRuntime.CodeStandIn,
    only: [submit_base!: 2, submit_base!: 3, expected_folder: 2, private_attempt: 3]

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.CodeStandIn

  @moduletag capture_log: true

  setup context do
    bench = start!(%{}, Map.get(context, :work_options, []))
    code = CodeStandIn.start!(bench.dir)
    on_exit(fn -> CodeStandIn.stop(code, bench.dir) end)
    %{bench: bench, code: code}
  end

  defp rebuilds(bench), do: Path.wildcard(Path.join([bench.dir, "scratch", "rebuild-*"]))

  defp inode(path) do
    {:ok, %{inode: inode}} = File.lstat(path)
    inode
  end

  test "a fresh retry rebuilds the folder from the base: the agent's file is gone, the record names the base",
       %{bench: bench, code: code} do
    test = self()

    hook = fn stage ->
      aside = rebuilds(bench)
      send(test, {:hook, stage, aside, Enum.map(aside, &File.exists?(Path.join(&1, "a.txt")))})
    end

    stop_work()
    start_work!(bench, prepare_hook: hook)
    work = submit_base!(code, "complete then rebuild")
    await_state(work.work_id, :completed)
    folder = expected_folder(bench.dir, work.work_id)
    File.write!(Path.join(folder, "a.txt"), "agent\n")

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    done = await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert [%{state: :completed}, %{state: :completed}] = done.attempts

    # Moved aside first (attempt 2's name), then removed.
    rebuild = Path.join([bench.dir, "scratch", "rebuild-#{work.work_id}.2"])
    assert_received {:hook, :moved_aside, [aside], [true]}
    assert Path.basename(aside) == Path.basename(rebuild)
    assert rebuilds(bench) == []

    refute File.exists?(Path.join(folder, "a.txt"))
    assert File.read!(Path.join([folder, "atlas", "README.md"])) == "base\n"
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]

    record =
      Path.join([bench.dir, "materializations", "#{sha(folder)}.json"])
      |> File.read!()
      |> JSON.decode!()

    assert record["destination"] == folder
    assert record["snapshot_id"] == code.id
    start = Path.join(folder, "atlas")
    assert Enum.map(launches(bench), & &1["cwd"]) == [start, start]
    # Attempt 1's frozen result does not depend on the folder (P7b reads it once it lands).
  end

  test "a read-only folder is rebuilt too: the sealed tree is removed", %{
    bench: bench,
    code: code
  } do
    work = submit_base!(code, "complete read only twice", "read-only")
    await_state(work.work_id, :completed)
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    await_work(work.work_id, &match?([_, %{state: :completed}], &1.attempts))
    assert rebuilds(bench) == []
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]
  end

  test "the folder is rebuilt only after the earlier attempt is quiescent", %{
    bench: bench,
    code: code
  } do
    gate = Path.join(bench.dir, "gate")
    File.write!(gate, "")
    work = submit_base!(code, "wait gate")
    [%{turn_id: turn}] = await_launch(bench, work).attempts
    await(fn -> turn(bench, turn)["session_id"] end)
    folder = expected_folder(bench.dir, work.work_id)
    File.write!(Path.join(folder, "a.txt"), "agent\n")
    before = inode(folder)

    verdict = :atomics.new(1, [])

    probe = fn _pid, _launched ->
      if :atomics.get(verdict, 1) == 1, do: {:gone, "test"}, else: :alive
    end

    stop_all()
    bench = %{bench | service: start_service!(bench, fn _pid, _launched -> :alive end)}
    start_work!(bench, probe: probe)

    [attempt] = await_state(work.work_id, :interrupted).attempts
    refute attempt.quiescent
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    heartbeats(5)
    assert [%{state: :interrupted}, %{state: :buffered}] = work!(work.work_id).attempts
    assert File.read!(Path.join(folder, "a.txt")) == "agent\n"
    assert inode(folder) == before
    assert CodeStandIn.archives(code) == ["atlas"]

    File.rm!(gate)
    :atomics.put(verdict, 1, 1)
    await_work(work.work_id, &match?([%{quiescent: true}, %{state: :completed}], &1.attempts))
    refute File.exists?(Path.join(folder, "a.txt"))
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]
  end

  test "a crash after the move-aside: boot removes the rebuild tree, the attempt is interrupted, the next fresh retry prepares a new folder",
       %{bench: bench, code: code} do
    test = self()

    hook = fn :moved_aside ->
      send(test, {:moved, self()})

      receive do
        :never -> :ok
      end
    end

    work = submit_base!(code, "complete then crash")
    await_state(work.work_id, :completed)
    folder = expected_folder(bench.dir, work.work_id)
    File.write!(Path.join(folder, "a.txt"), "agent\n")

    stop_work()
    start_work!(bench, prepare_hook: hook)
    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    assert_receive {:moved, preparer}, 10_000
    assert [_] = rebuilds(bench)
    refute File.exists?(folder)

    stop_work()
    Process.exit(preparer, :kill)
    start_work!(bench, prepare_hook: nil)

    assert [_, %{state: :interrupted} = second] =
             await_work(work.work_id, &match?([_, %{state: :interrupted}], &1.attempts)).attempts

    assert second.result.retryable
    assert second.quiescent
    assert rebuilds(bench) == []
    assert %{preparing: false, prepare_pid: nil} = private_attempt(bench.dir, work.work_id, 2)
    assert CodeStandIn.archives(code) == ["atlas"]

    assert %F.Outcome.Accepted{} = F.retry(client(), %{work_id: work.work_id})
    await_work(work.work_id, &match?([_, _, %{state: :completed}], &1.attempts))
    assert File.read!(Path.join([folder, "atlas", "README.md"])) == "base\n"
    refute File.exists?(Path.join(folder, "a.txt"))
    assert CodeStandIn.archives(code) == ["atlas", "atlas"]
  end

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
