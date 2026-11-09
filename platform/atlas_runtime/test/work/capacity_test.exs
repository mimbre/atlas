defmodule AtlasRuntime.Work.CapacityTest do
  # D2 acceptance 3: a full Runtime answers at_capacity{full, retry_after, capacity}, and
  # capacity_available is pushed exactly once when room returns.
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness
  alias AtlasRuntime.Boundary.Work, as: F

  @moduletag capture_log: true

  setup do
    %{bench: start!()}
  end

  test "slots and buffer full: at_capacity, then capacity_available once", %{bench: bench} do
    first = submit!(bench, "hang one")
    second = submit!(bench, "hang two")
    await_launch(bench, first)
    await_launch(bench, second)
    third = submit!(bench, "hang three")
    assert work!(third.work_id).state == :buffered

    assert %F.Outcome.Capacity{slots: slots, buffer: buffer, accepting: true} =
             capacity = F.capacity(client())

    assert {slots.total, slots.busy, slots.free} == {2, 2, 0}
    assert {buffer.size, buffer.used, buffer.free} == {1, 1, 0}
    assert capacity.retry_after == 60
    assert [%F.ProfileAvailability{profile: "light_work", available: true}] = capacity.profiles

    assert %F.Outcome.AtCapacity{
             reason: :full,
             retry_after: 60,
             capacity: %F.Capacity{accepting: true}
           } =
             F.submit(client(), request(bench, "hang four"))

    assert F.subscribe(client(), %{}) == %F.Outcome.Subscribed{}
    assert %F.Outcome.Ended{} = cancel_and_wait(first)

    # The buffered work takes the freed slot; one place in the buffer is free again.
    await_launch(bench, third)
    assert %F.Outcome.Capacity{retry_after: nil, buffer: %{free: 1}} = F.capacity(client())

    for work <- [second, third], do: cancel_and_wait(work)

    available = for %F.CapacityAvailable{} = n <- notifications(300), do: n
    assert [%F.CapacityAvailable{capacity: %F.Capacity{accepting: true}}] = available
  end

  defp cancel_and_wait(work) do
    F.cancel(client(), %{work_id: work.work_id, mode: "force"})
    await_state(work.work_id, :cancelled)
    %F.Outcome.Ended{} = F.cancel(client(), %{work_id: work.work_id, mode: "graceful"})
  end
end
