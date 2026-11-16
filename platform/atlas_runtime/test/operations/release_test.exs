defmodule AtlasRuntime.Operations.ReleaseTest do
  # release_slot through the facade (design §13.1 Q8, O1 1–5): refused while the slot's
  # process is alive; otherwise the latch is cleared, a turn left unknown is marked gone,
  # and its attempt becomes quiescent with who and when, on disk before the answer.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Operations, as: F
  alias AtlasRuntime.Boundary.Work, as: W
  alias AtlasRuntime.Persistence.History
  alias AtlasRuntime.Work.Store
  alias AtlasRuntimeBoundary.Generator.NotPermitted

  @moduletag capture_log: true
  @operator {"local:op", [:inspect, :operate]}

  def alive(_pid, _launched), do: :alive
  # What the probe answers when it cannot list processes: nothing is proven either way.
  def unknown(_pid, _launched), do: :unknown

  setup do
    %{bench: start!(%{"slots" => ["s1"]})}
  end

  # A turn on s1 the Runtime lost: Service and core restart, and the probe proves nothing
  # (or proves the process alive); the attempt is interrupted but not quiescent.
  defp lost_turn(bench, probe, work_options \\ []) do
    work = submit!(bench, "hang until released")
    [%{turn_id: turn}] = await_launch(bench, work).attempts
    await(fn -> turn(bench, turn)["session_id"] end)

    stop_all()
    bench = %{bench | service: start_service!(bench, probe)}
    start_work!(bench, Keyword.merge([probe: probe], work_options))
    [attempt] = await_state(work.work_id, :interrupted).attempts
    refute attempt.quiescent
    {bench, work, turn}
  end

  # Everything the release may write: work records, latches and turn records.
  defp disk(bench) do
    for folder <- ["work", "workers", "turns"],
        path <- Path.wildcard(Path.join([bench.dir, folder, "**", "*"])),
        File.regular?(path),
        into: %{},
        do: {path, :crypto.hash(:sha256, File.read!(path))}
  end

  test "an unknown slot: quiescent with who and when on disk, the turn gone, the next work starts",
       %{bench: bench} do
    {bench, work, turn} = lost_turn(bench, &__MODULE__.unknown/2)
    next = submit!(bench, "complete after the release")
    Process.sleep(300)
    assert work!(next.work_id).state == :buffered
    assert W.subscribe(client(), %{}) == %W.Outcome.Subscribed{}

    assert %F.Outcome.Released{slot: "s1"} = F.release_slot(@operator, %{slot: "s1"})

    # On disk when the answer came.
    stored = Store.read_work(bench.dir, work.work_id)

    assert [%{quiescent: true, released_by: "local:op", released_at: %DateTime{}}] =
             stored.attempts

    assert turn(bench, turn)["state"] == "failed"

    # The change went out, and the slot takes the buffered work.
    assert Enum.any?(
             notifications(1_000),
             &match?(%W.WorkChanged{revision: r} when r == stored.revision, &1)
           )

    assert [%{slot: "s1"}] = await_state(next.work_id, :completed).attempts
    # Who released it stays private.
    refute Map.has_key?(Map.from_struct(hd(work!(work.work_id).attempts)), :released_by)
  end

  test "a crash between the write and the answer: no answer, and the release is on disk",
       %{bench: bench} do
    # The core dies right after it wrote the released attempt, before anything mentions it.
    crash = fn record ->
      if Enum.any?(record.attempts, & &1.released_by), do: Process.exit(self(), :kill)
    end

    {bench, work, _turn} = lost_turn(bench, &__MODULE__.unknown/2, after_write: crash)

    assert {:killed, _} = catch_exit(F.release_slot(@operator, %{slot: "s1"}))

    assert [%{quiescent: true, released_by: "local:op"}] =
             Store.read_work(bench.dir, work.work_id).attempts
  end

  test "a slot whose process the probe finds alive is busy, and nothing is written", %{
    bench: bench
  } do
    {bench, work, turn} = lost_turn(bench, &__MODULE__.alive/2)
    before = disk(bench)

    assert %F.Outcome.Refused{reason: :slot_busy, detail: detail} =
             F.release_slot(@operator, %{slot: "s1"})

    assert detail =~ "s1"
    assert disk(bench) == before
    assert turn(bench, turn)["state"] == "running"
    refute hd(work!(work.work_id).attempts).quiescent
  end

  test "a slot whose turn runs in this incarnation is busy", %{bench: bench} do
    work = submit!(bench, "hang while released")
    await_launch(bench, work)
    before = disk(bench)

    assert %F.Outcome.Refused{reason: :slot_busy} = F.release_slot(@operator, %{slot: "s1"})
    assert disk(bench) == before
    assert work!(work.work_id).state == :running
    W.cancel(client(), %{work_id: work.work_id, mode: "force"})
  end

  test "a slot the policy does not name is not found", %{bench: bench} do
    before = disk(bench)

    for slot <- ["s2", "", "../s1", "S1"] do
      assert %F.Outcome.NotFound{} = F.release_slot(@operator, %{slot: slot})
    end

    assert disk(bench) == before
  end

  test "nothing to release, twice: released, and no record changes", %{bench: bench} do
    work = submit!(bench, "complete before")
    done = await_state(work.work_id, :completed)
    before = disk(bench)

    for _ <- 1..2 do
      assert %F.Outcome.Released{slot: "s1"} = F.release_slot(@operator, %{slot: "s1"})
    end

    assert %{revision: revision, sequence: sequence} = work!(work.work_id)
    assert {revision, sequence} == {done.revision, done.sequence}
    assert disk(bench) == before
  end

  test "a latch on a turn that is not unknown: only the latch is cleared", %{bench: bench} do
    work = submit!(bench, "complete then latched")
    done = await_state(work.work_id, :completed)
    [%{turn_id: turn}] = done.attempts
    History.latch!(bench.dir, "s1", turn, DateTime.to_iso8601(DateTime.utc_now()))

    assert %F.Outcome.Released{slot: "s1"} = F.release_slot(@operator, %{slot: "s1"})

    refute History.latch(bench.dir, "s1")
    assert work!(work.work_id).revision == done.revision

    assert [%{released_by: nil, released_at: nil}] =
             Store.read_work(bench.dir, work.work_id).attempts

    assert turn(bench, turn)["state"] == "finished"
  end

  test "operate is the right it needs; without the core it raises", %{bench: _bench} do
    assert %NotPermitted{capability: :release_slot, right: :operate} =
             F.release_slot({"remote:x", [:inspect]}, %{slot: "s1"})

    stop_work()

    assert_raise AtlasRuntime.Operations.NotRunning, fn ->
      F.release_slot(@operator, %{slot: "s1"})
    end
  end
end
