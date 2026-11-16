defmodule AtlasRuntime.Work.NotificationsTest do
  # The notification window and the visibility filter (design §3.2, §3.6).
  use ExUnit.Case, async: true

  alias AtlasRuntime.Boundary.Work, as: F
  alias AtlasRuntime.Work.Notifications

  defp change(sequence, id),
    do: %F.WorkChanged{sequence: sequence, work_id: id, revision: 1, state: :buffered}

  defp received do
    receive do
      {:atlas_runtime_work, notification} -> [notification | received()]
    after
      0 -> []
    end
  end

  test "inside the window, a subscriber gets what it missed; behind it or ahead of it, reset" do
    window = Notifications.new(10, 3)

    window =
      Enum.reduce(11..14, window, &Notifications.work_changed(&2, change(&1, "w#{&1}"), "c1"))

    # 11 fell out of a window of three: positions before 11 cannot be served.
    assert {{:reset, 14}, _} = Notifications.subscribe(window, self(), {"c1", [:read]}, 10, 14)
    assert {{:reset, 14}, _} = Notifications.subscribe(window, self(), {"c1", [:read]}, 15, 14)
    assert received() == []

    assert {:subscribed, _} = Notifications.subscribe(window, self(), {"c1", [:read]}, 12, 14)
    assert Enum.map(received(), & &1.sequence) == [13, 14]
  end

  test "without read_all a subscriber sees only its own work; capacity is global" do
    window = Notifications.new(0)
    {:subscribed, window} = Notifications.subscribe(window, self(), {"c2", [:read]}, nil, 0)
    window = Notifications.work_changed(window, change(1, "theirs"), "c1")
    window = Notifications.work_changed(window, change(2, "mine"), "c2")

    capacity = %F.Capacity{
      slots: %F.SlotCounts{total: 1, busy: 0, free: 1},
      buffer: %F.BufferCounts{size: 1, used: 0, free: 1},
      profiles: [],
      accepting: true,
      policy_version: 1,
      runtime_build: "test",
      incarnation: "i"
    }

    window =
      Notifications.capacity_available(window, %F.CapacityAvailable{
        sequence: 3,
        capacity: capacity
      })

    assert [%F.WorkChanged{work_id: "mine"}, %F.CapacityAvailable{}] = received()

    running = [
      {"c1", %F.RunningAttempt{work_id: "theirs", attempt: 1, state: :running, alive: true}},
      {"c2", %F.RunningAttempt{work_id: "mine", attempt: 1, state: :running, alive: true}}
    ]

    Notifications.heartbeat(window, DateTime.utc_now(), capacity, running)
    assert [%F.Heartbeat{running: [%{work_id: "mine"}]}] = received()

    {:subscribed, window} =
      Notifications.subscribe(window, self(), {"admin", [:read, :read_all]}, 0, 3)

    assert Enum.map(received(), &Map.get(&1, :work_id)) == ["theirs", "mine", nil]
    _ = window
  end
end
