defmodule RelaDSL.Runtime.ModelTest do
  use ExUnit.Case, async: true

  alias RelaDSL.Workshop

  describe "the turn and its agent" do
    test "the turn's names are the model's, with the kinds its on relation leads to" do
      turn = Workshop.turn()

      assert Map.drop(turn, ["items", "on_kinds"]) ==
               %{
                 "kind" => "run",
                 "key" => "R-{on}-{n}",
                 "on" => "run_on",
                 "by" => "run_by",
                 "state" => "status",
                 "running" => "going",
                 "ended" => "over",
                 "machine" => "host",
                 "lease" => "until",
                 "activity" => "last",
                 "why" => "reason",
                 "ended_at" => "done_at",
                 "outcome" => "result",
                 "attempt" => "try",
                 "title" => "about",
                 "model" => "engine"
               }

      assert turn["on_kinds"] == ["card"]
    end

    test "a turn works on what flows write on: on's one kind, or the flow's own kinds" do
      # Whether one is open, and whether a handover waits, is Facts' presentation's.
      assert Workshop.turn()["items"] == [
               %{"kind" => "card", "owner_relation" => "owned_by"},
               %{"kind" => "crate", "owner_relation" => "owned_by"}
             ]
    end

    test "the agent is the one kind the turn is by, with the field that says it cannot run" do
      assert Workshop.agent() == %{"kind" => "clerk", "cannot_run" => "stuck"}
    end

    test "the guidance records are the model's, by role" do
      guidance = Workshop.guidance()

      assert %{"execution" => %{"kind" => "log"}, "interaction" => %{"kind" => "note"}} =
               guidance

      assert guidance["receipt"]["kind"] == "stamp"
      assert guidance["execution"]["fields"]["attempt"] == "attempt"
    end

    test "a model that runs no turns says so" do
      assert Workshop.Bare.turn() == nil
      assert Workshop.Bare.agent() == nil
      assert Workshop.Bare.guidance() == nil
      assert Workshop.Bare.read_first(%{"key" => "B-1"}, fn _, _ -> flunk("no read") end) == nil
    end
  end

  # Made-up kinds: a box rests on memos; a memo elaborates another; kept habits and limits
  # hold for every box, and kept pledges come first.
  describe "what a worker reads first" do
    defp memo(key, values, links \\ %{}),
      do: %{"key" => key, "values" => Map.put(values, "title", "Title #{key}"), "links" => links}

    defp lookup(memos) do
      fn
        "memo", %{"key" => key} -> %{"fact" => Enum.find(memos, &(&1["key"] == key))}
        "memo", %{"linked" => %{}} -> %{"facts" => memos}
      end
    end

    defp memos do
      [
        memo(
          "M-3",
          %{"sort" => "direction", "status" => "replaced", "rule" => "Ship in crates."},
          %{"elaborates" => ["M-1"]}
        ),
        memo("M-1", %{"sort" => "direction", "status" => "kept", "rule" => "Ship safely."}),
        memo("M-2", %{"sort" => "habit", "status" => "kept", "rule" => "Label  every\nbox."}),
        memo("M-4", %{"sort" => "limit", "status" => "kept", "rule" => "Never over 20 kg."}),
        memo("M-5", %{"sort" => "habit", "status" => "dropped", "rule" => "Use tape."})
      ]
    end

    test "its anchors, what they follow from, then what holds for all work, one line each" do
      box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-3"]}}

      assert Workshop.read_first(box, lookup(memos())) ==
               """
               Read these memos first.
               Rests on:
               - M-3 Title M-3 (direction, Replaced): Ship in crates.
                 elaborates M-1 Title M-1 (direction, Kept): Ship safely.
               Habits and limits that hold:
               - M-2 Title M-2 (habit, Kept): Label every box.
               - M-4 Title M-4 (limit, Kept): Never over 20 kg.\
               """
    end

    test "groups in order, each fact once; a first group comes before the anchors" do
      memos =
        memos() ++
          [
            memo("M-6", %{"sort" => "pledge", "status" => "kept", "rule" => "Never lose a box."}),
            memo("M-7", %{"sort" => "pledge", "status" => "replaced", "rule" => "Old pledge."}),
            memo("M-8", %{"sort" => "pledge", "status" => "proposed", "rule" => "New pledge."})
          ]

      box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-3"]}}
      text = Workshop.read_first(box, lookup(memos))

      assert ["Read these memos first.", "Pledges:", "- M-6 " <> _, "Rests on:" | _] =
               String.split(text, "\n")

      assert text =~ "Habits and limits that hold:\n- M-2"
      refute text =~ "M-7"
      refute text =~ "M-8"
    end

    test "without anchors only what holds for all work; nothing at all is nil" do
      box = %{"key" => "B-1", "links" => %{}}
      text = Workshop.read_first(box, lookup(memos()))
      refute text =~ "Rests on"
      assert text =~ "- M-2"

      # An anchor that is also a standing fact is shown once, as an anchor.
      anchored = %{"key" => "B-1", "links" => %{"rests_on" => ["M-2"]}}
      text = Workshop.read_first(anchored, lookup(memos()))
      assert length(Regex.scan(~r/^- M-2 /m, text)) == 1

      assert Workshop.read_first(box, lookup([])) == nil
    end

    test "a long text is shortened; a read that fails leaves its part out" do
      long =
        memo("M-9", %{"sort" => "habit", "status" => "kept", "rule" => String.duplicate("a", 400)})

      box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-404"]}}
      [_, _, line] = Workshop.read_first(box, lookup([long])) |> String.split("\n")
      assert String.length(line) < 320 and String.ends_with?(line, "…")

      failing = fn "memo", _ -> %{"error" => "not reachable"} end
      assert Workshop.read_first(%{box | "links" => %{"rests_on" => ["M-1"]}}, failing) == nil
    end
  end
end
