defmodule AtlasControl.ReadFirstTest do
  use ExUnit.Case, async: true
  alias AtlasControl.ReadFirst

  # Made-up kinds: a box rests on memos; a memo elaborates another; kept habits and limits
  # hold for every box.
  @d %{
    "read_first" => %{
      "title" => "Read these memos first.",
      "through" => "rests_on",
      "then" => "elaborates",
      "standing" => %{
        "title" => "Habits and limits that hold",
        "when" => %{"status" => ["kept"], "sort" => ["habit", "limit"]}
      },
      "tags" => ["sort", "status"],
      "text" => "rule"
    },
    "entities" => %{
      "box" => %{"plural" => "boxes"},
      "memo" => %{
        "plural" => "memos",
        "primary" => "title",
        "properties" => %{"status" => %{"labels" => %{"kept" => "Kept"}}}
      }
    },
    "relations" => %{
      "rests_on" => %{"label" => "rests on", "from" => ["box"], "to" => ["memo"]},
      "elaborates" => %{"label" => "elaborates", "from" => ["memo"], "to" => ["memo"]}
    }
  }

  defp memo(key, values, links \\ %{}),
    do: %{"key" => key, "values" => Map.put(values, "title", "Title #{key}"), "links" => links}

  defp read(box, memos) do
    fn
      "box", %{"key" => "B-1"} -> %{"fact" => box}
      "memo", %{"key" => key} -> %{"fact" => Enum.find(memos, &(&1["key"] == key))}
      "memo", %{"linked" => %{}} -> %{"facts" => memos}
    end
  end

  defp memos do
    [
      memo(
        "M-3",
        %{"sort" => "direction", "status" => "replaced", "rule" => "Ship in crates."},
        %{
          "elaborates" => ["M-1"]
        }
      ),
      memo("M-1", %{"sort" => "direction", "status" => "kept", "rule" => "Ship safely."}),
      memo("M-2", %{"sort" => "habit", "status" => "kept", "rule" => "Label  every\nbox."}),
      memo("M-4", %{"sort" => "limit", "status" => "kept", "rule" => "Never over 20 kg."}),
      memo("M-5", %{"sort" => "habit", "status" => "dropped", "rule" => "Use tape."})
    ]
  end

  test "its anchors, what they follow from, then what holds for all work, one line each" do
    box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-3"]}}

    assert ReadFirst.text(@d, "box", "B-1", read(box, memos())) ==
             """
             Read these memos first.
             Rests on:
             - M-3 Title M-3 (direction, replaced): Ship in crates.
               elaborates M-1 Title M-1 (direction, Kept): Ship safely.
             Habits and limits that hold:
             - M-2 Title M-2 (habit, Kept): Label every box.
             - M-4 Title M-4 (limit, Kept): Never over 20 kg.\
             """
  end

  test "groups in order, each fact once; a first group (kept pledges) comes before the anchors" do
    d =
      put_in(@d, ["read_first", "standing"], [
        %{
          "title" => "Pledges",
          "first" => true,
          "when" => %{"status" => ["kept"], "sort" => ["pledge"]}
        },
        @d["read_first"]["standing"]
      ])

    memos =
      memos() ++
        [
          memo("M-6", %{"sort" => "pledge", "status" => "kept", "rule" => "Never lose a box."}),
          memo("M-7", %{"sort" => "pledge", "status" => "replaced", "rule" => "Old pledge."}),
          memo("M-8", %{"sort" => "pledge", "status" => "proposed", "rule" => "New pledge."})
        ]

    box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-3"]}}
    text = ReadFirst.text(d, "box", "B-1", read(box, memos))

    assert [
             "Read these memos first.",
             "Pledges:",
             "- M-6 Title M-6 (pledge, Kept): Never lose a box.",
             "Rests on:" | _
           ] =
             String.split(text, "\n")

    assert text =~ "Habits and limits that hold:\n- M-2"
    refute text =~ "M-7"
    refute text =~ "M-8"
  end

  test "without anchors only what holds for all work; nothing at all is nil" do
    box = %{"key" => "B-1", "links" => %{}}
    text = ReadFirst.text(@d, "box", "B-1", read(box, memos()))
    refute text =~ "Rests on"
    assert text =~ "- M-2"
    # An anchor that is also a standing rule is shown once, as an anchor.
    anchored = %{"key" => "B-1", "links" => %{"rests_on" => ["M-2"]}}
    text = ReadFirst.text(@d, "box", "B-1", read(anchored, memos()))
    assert length(Regex.scan(~r/^- M-2 /m, text)) == 1

    assert ReadFirst.text(@d, "box", "B-1", read(box, [])) == nil
    assert ReadFirst.text(Map.delete(@d, "read_first"), "box", "B-1", read(box, memos())) == nil
  end

  test "a long text is shortened; a read that fails leaves its part out" do
    long =
      memo("M-9", %{"sort" => "habit", "status" => "kept", "rule" => String.duplicate("a", 400)})

    box = %{"key" => "B-1", "links" => %{"rests_on" => ["M-404"]}}
    [_, _, line] = ReadFirst.text(@d, "box", "B-1", read(box, [long])) |> String.split("\n")
    assert String.length(line) < 320 and String.ends_with?(line, "…")

    failing = fn
      "box", _ -> %{"error" => "rela is not reachable"}
      "memo", _ -> %{"error" => "rela is not reachable"}
    end

    assert ReadFirst.text(@d, "box", "B-1", failing) == nil
  end
end
