defmodule AtlasFlow.Capacity.PolicyTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Capacity.Policy

  defp item(key, extra \\ %{}) do
    Map.merge(
      %{
        key: key,
        since: "2026-11-14T00:00:00Z",
        need: %{"backend" => ["a", "b"], "model" => "any"}
      },
      extra
    )
  end

  defp slot(key, extra \\ %{}) do
    Map.merge(
      %{
        key: key,
        machine: "host",
        busy: false,
        cannot_run: nil,
        warm: false,
        idle_since: nil,
        models: %{"a" => ["m"], "b" => ["n"]}
      },
      extra
    )
  end

  test "fit, exclusions, affinity, warm preference, idle time and stable ties" do
    for {item, slots, live, expected} <- [
          {item("x"), [slot("1"), slot("2")], ["host"], "1"},
          {item("x", %{affinity: "2"}), [slot("1", %{warm: true}), slot("2")], ["host"], "2"},
          {item("x"), [slot("1"), slot("2", %{warm: true})], ["host"], "2"},
          {item("x"), [slot("1", %{idle_since: "2026-11-13T00:00:00Z"}), slot("2")], ["host"],
           "2"},
          {item("x"), [slot("1", %{busy: true}), slot("2")], ["host"], "2"},
          {item("x"), [slot("1", %{cannot_run: "paused"})], ["host"], nil},
          {item("x"), [slot("1")], [], nil},
          {item("x", %{need: %{"backend" => ["c"], "model" => "any"}}), [slot("1")], ["host"],
           nil},
          {item("x", %{history_missing: true}), [slot("1")], ["host"], nil},
          {item("x", %{need: %{"backend" => ["b"], "model" => ["m"]}}), [slot("1")], ["host"],
           nil}
        ] do
      result = Policy.pick([item], slots, live, 0)

      assert (case result do
                [{_, slot, _, _}] -> slot.key
                [] -> nil
              end) == expected

      assert Policy.pick([item], Enum.reverse(slots), live, 0) == result
    end

    assert [{_, _, "b", "n"}] =
             Policy.pick([item("x", %{excluded_backend: "a"})], [slot("1")], ["host"], 0)

    assert [{_, %{key: "1"}, _, _}] =
             Policy.pick([item("x")], [Map.delete(slot("1"), :warm)], ["host"], 0)
  end

  test "FIFO and key ties reserve each slot once" do
    queue = [item("z"), item("a"), item("old", %{since: "2026-11-13T00:00:00Z"})]

    assert [{%{key: "old"}, %{key: "1"}, _, _}, {%{key: "a"}, %{key: "2"}, _, _}] =
             Policy.pick(queue, [slot("2"), slot("1")], ["host"], 0)

    assert [{%{key: "whole"}, _, _, _}] =
             Policy.pick(
               [
                 item("fraction", %{since: "2026-11-14T00:00:00.001Z"}),
                 item("whole", %{since: "2026-11-14T00:00:00Z"})
               ],
               [slot("1")],
               ["host"],
               0
             )
  end

  test "turn end, absent Runtime, start timeout, boot grace and manual assignments" do
    now = %{
      wall: 120_000,
      mono: 300_000,
      boot: 0,
      absent: %{"host" => 0},
      grace: 300_000,
      timeout: 120_000
    }

    picked = %{pick: "p", machine: "host", at: 0}
    manual = %{picked | pick: nil}

    for {turns, live, clock, expected} <- [
          {[], ["host"], %{now | wall: 119_999}, []},
          {[], ["host"], now, []},
          {[%{pick: "p", state: :running}], ["host"], now, []},
          {[%{pick: "p", state: :ended, quiescent: true}], ["host"], now, [picked]},
          {[%{pick: "old", state: :ended, quiescent: true}], ["host"], now, []},
          {[%{pick: "p", state: :ended}], ["host"], now, []},
          {[%{pick: "p", state: :running}], [], %{now | mono: 299_999}, []},
          {[%{pick: "p", state: :running}], [], now, []},
          {[%{pick: "p", state: :running}], [], %{now | boot: 299_999}, []}
        ] do
      assert Policy.release([picked, manual], turns, live, clock) == expected
    end
  end
end
