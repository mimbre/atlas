defmodule AtlasRuntime.Work.CapacityTest do
  # D2 acceptance 3, after the cut-over (M2 A7): work reaches the executor only as a lease
  # within its free slots, so a full Runtime never answers a start `at_capacity`: the work
  # waits queued at the local source, and the executor's buffer stays unused. When a slot
  # frees, the queued work is leased into it. (The `at_capacity` outcome and
  # `capacity_available` themselves go in M5.)
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Sources.Local
  alias AtlasRuntime.Work.Store

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  test "slots full: the work waits at the local source, never at_capacity; a freed slot takes it",
       %{bench: bench} do
    first = submit!(bench, "hang one")
    second = submit!(bench, "hang two")
    await_launch(bench, first)
    await_launch(bench, second)

    [third, fourth] = for goal <- ["hang three", "hang four"], do: submit!(bench, goal)

    for work <- [third, fourth] do
      assert work.state == :buffered
      assert {:ok, %{state: :queued}} = Local.get(work.work_id)
      assert Store.read_work(bench.dir, work.work_id) == nil
      assert work!(work.work_id).state == :buffered
    end

    assert %F.Outcome.Capacity{slots: slots, buffer: buffer, accepting: true} =
             capacity = F.capacity(client())

    assert {slots.total, slots.busy, slots.free} == {2, 2, 0}
    assert {buffer.used} == {0}
    assert [%F.ProfileAvailability{profile: "light_work", available: true}] = capacity.profiles

    # A freed slot is offered to the local source, which leases the first queued work.
    cancel_and_wait(first)
    await_launch(bench, third)
    assert {:ok, %{state: :queued}} = Local.get(fourth.work_id)

    for work <- [second, third], do: cancel_and_wait(work)
    await_launch(bench, fourth)
    cancel_and_wait(fourth)
  end

  defp cancel_and_wait(work) do
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
    %F.Outcome.Ended{} = F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})
  end
end
