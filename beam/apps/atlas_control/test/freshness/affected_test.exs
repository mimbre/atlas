defmodule AtlasControl.Freshness.Change do
  @moduledoc "A change as a `stored` hint says it (for the table below, built as it compiles)."
  def change(kind, key, op, fields \\ [], relinked \\ [], links \\ %{}),
    do: %{
      "kind" => kind,
      "key" => key,
      "op" => op,
      "fields" => fields,
      "relinked" => relinked,
      "links" => links
    }
end

defmodule AtlasControl.Freshness.AffectedTest do
  # Which pages a write made stale: deps as Facts said them, matched against the changes
  # a `stored` says (docs/design/page-freshness.md §1.1, §5). Neutral kinds: widgets,
  # their parts (`of_widget`), and who made them (`made_by`).
  use ExUnit.Case, async: true

  alias AtlasControl.Freshness.{Affected, ReadSet, Recent}

  import AtlasControl.Freshness.Change

  @w1 ["key", "widget", "W-1", "*"]
  @w1_title ["key", "widget", "W-1", ["title"]]
  @parts_of_w1 ["linked", "of_widget", "W-1", "*"]
  @parts_of_w1_phase ["linked", "of_widget", "W-1", ["phase"]]
  @widgets ["kind", "widget"]

  for {name, dep, change, match?} <- [
        # key
        {"a field of the fact", @w1, change("widget", "W-1", "change", ["title"]), true},
        {"the fact made", @w1, change("widget", "W-1", "create", ["title"]), true},
        {"the fact deleted", @w1, change("widget", "W-1", "delete", ["title"]), true},
        {"another fact", @w1, change("widget", "W-2", "change", ["title"]), false},
        {"a fact of another kind, same key", @w1, change("part", "W-1", "change", ["title"]),
         false},
        {"a field it read", @w1_title, change("widget", "W-1", "change", ["title", "x"]), true},
        {"a field it did not read", @w1_title, change("widget", "W-1", "change", ["shade"]),
         false},
        {"a field it did not read, but relinked", @w1_title,
         change("widget", "W-1", "change", ["shade"], ["made_by"]), true},
        {"made, whatever its fields", @w1_title, change("widget", "W-1", "create", ["shade"]),
         true},
        # linked
        {"a part of it changed", @parts_of_w1,
         change("part", "P-1", "change", ["phase"], [], %{"of_widget" => ["W-1"]}), true},
        {"a part moved to it", @parts_of_w1,
         change("part", "P-1", "change", [], ["of_widget"], %{"of_widget" => ["W-1", "W-2"]}),
         true},
        {"a part moved away from it", @parts_of_w1,
         change("part", "P-1", "change", [], ["of_widget"], %{"of_widget" => ["W-1", "W-2"]}),
         true},
        {"a part made under it", @parts_of_w1,
         change("part", "P-9", "create", ["title"], ["of_widget"], %{"of_widget" => ["W-1"]}),
         true},
        {"a part of another widget", @parts_of_w1,
         change("part", "P-2", "change", ["phase"], [], %{"of_widget" => ["W-2"]}), false},
        {"through another relation", @parts_of_w1,
         change("part", "P-1", "change", ["phase"], [], %{"made_by" => ["W-1"]}), false},
        {"a part field it read", @parts_of_w1_phase,
         change("part", "P-1", "change", ["phase"], [], %{"of_widget" => ["W-1"]}), true},
        {"a part field it did not read", @parts_of_w1_phase,
         change("part", "P-1", "change", ["title"], [], %{"of_widget" => ["W-1"]}), false},
        {"a part field it did not read, the link moved", @parts_of_w1_phase,
         change("part", "P-1", "change", ["title"], ["of_widget"], %{"of_widget" => ["W-1"]}),
         true},
        # kind
        {"any fact of the kind", @widgets, change("widget", "W-7", "change", ["notes"]), true},
        {"a fact of another kind", @widgets, change("part", "P-7", "create", ["title"]), false},
        {"a dep it does not know", ["other", "widget"], change("widget", "W-1", "create"), false}
      ] do
    test "#{name}: #{if match?, do: "stale", else: "not stale"}" do
      assert Affected.matches?(unquote(dep), unquote(Macro.escape(change))) == unquote(match?)
    end
  end

  test "a change at or before the position a page was read at is shown already" do
    deps = [@w1]
    changed = [change("widget", "W-1", "change", ["title"])]
    refute Affected.stale?(deps, 5, [{4, changed}, {5, changed}])
    assert Affected.stale?(deps, 5, [{5, changed}, {6, changed}])
    assert Affected.first(deps, 5, [{5, changed}, {6, changed}]) == {6, hd(changed)}
    # Read at no known position: nothing is shown yet.
    assert Affected.stale?(deps, nil, [{1, changed}])
  end

  test "the recent paths a batch made stale, the most recently viewed first" do
    entry = fn deps, as_of -> %{route: nil, deps: deps, as_of: as_of, row_keys: %{}} end

    recent =
      Recent.new()
      |> Recent.viewed("/k/widget/W-1", entry.([@w1], 3))
      |> Recent.viewed("/k/part", entry.([["kind", "part"]], 3))
      |> Recent.viewed("/", entry.([@widgets], 3))
      |> Recent.viewed("/k/widget/W-2", entry.([["key", "widget", "W-2", "*"]], 3))

    changes = [{4, [change("widget", "W-1", "change", ["title"])]}]
    assert Affected.affected(recent, changes) == ["/", "/k/widget/W-1"]
    assert Affected.affected(recent, [{3, [change("widget", "W-1", "change", ["title"])]}]) == []
    assert Affected.affected(recent, [{4, [change("tag", "T-1", "create")]}]) == []
  end

  describe "a lookup read is narrowed to the facts the rows point at, or that point at them" do
    # The rows: widgets made by M-1. The lookup: every part, to say which part a row has.
    @reads [{"widget", :rows}, {"part", :lookup}]

    defp answers(parts) do
      [
        %{
          "facts" => [%{"key" => "W-1", "links" => %{"made_by" => ["M-1"]}}],
          "deps" => [@w1, ["linked", "made_by", "M-1", "*"]],
          "position" => 7
        },
        %{
          "facts" => parts,
          "deps" =>
            Enum.sort(
              [["kind", "part"], ["kind", "tag"]] ++
                for(p <- parts, do: ["key", "part", p["key"], "*"])
            ),
          "position" => 7
        }
      ]
    end

    @p1 %{"key" => "P-1", "links" => %{"of_widget" => ["W-1"]}}
    @p2 %{"key" => "P-2", "links" => %{"of_widget" => ["W-2"]}}
    @blocks [
      %{"type" => "list", "props" => %{"rows" => [%{"id" => "W-1", "to" => "/k/widget/W-1"}]}}
    ]

    test "it keeps the joined facts, what points at a row, and what the model read" do
      set = ReadSet.of(@reads, answers([@p1, @p2]), @blocks)

      assert set.deps == [
               ["key", "part", "P-1", "*"],
               @w1,
               ["kind", "tag"],
               ["linked", "made_by", "M-1", "*"],
               @parts_of_w1
             ]

      assert set.as_of == 7
      assert set.row_keys == %{"/k/widget/W-1" => ["W-1", "P-1"]}

      # A part of another widget changes nothing on the page; one of W-1, or one made
      # under it, does.
      p2 = change("part", "P-2", "change", ["phase"], [], %{"of_widget" => ["W-2"]})
      p1 = change("part", "P-1", "change", ["phase"], [], %{"of_widget" => ["W-1"]})
      new = change("part", "P-3", "create", ["phase"], ["of_widget"], %{"of_widget" => ["W-1"]})
      refute Affected.stale?(set.deps, 7, [{8, [p2]}])
      assert Affected.stale?(set.deps, 7, [{8, [p1]}])
      assert Affected.stale?(set.deps, 7, [{8, [new]}])
    end

    test "with nothing joined it keeps every dep, so it never misses a change" do
      set = ReadSet.of(@reads, answers([@p2]), @blocks)
      assert ["kind", "part"] in set.deps
      assert ["key", "part", "P-2", "*"] in set.deps
      assert set.row_keys == %{"/k/widget/W-1" => ["W-1"]}
    end

    test "a rows read is never narrowed" do
      set = ReadSet.of([{"widget", :rows}, {"part", :rows}], answers([@p1, @p2]), @blocks)
      assert ["kind", "part"] in set.deps
      assert ["key", "part", "P-2", "*"] in set.deps
    end
  end

  test "an answer that says nothing of what it depended on depends on its whole kind" do
    set =
      ReadSet.of(
        [{"widget", :rows}, {"part", :lookup}],
        [%{"error" => "Facts did not answer"}, %{"facts" => []}],
        []
      )

    assert set.deps == [["kind", "part"], @widgets]
    assert set.as_of == nil
  end

  test "until is the earliest instant a value in the page changes by time" do
    set =
      ReadSet.of(
        [{"widget", :rows}, {"part", :rows}],
        [
          %{"facts" => [], "deps" => [], "until" => "2999-01-02T00:00:00Z", "position" => 2},
          %{"facts" => [], "deps" => [], "until" => "2999-01-01T00:00:00Z", "position" => 2}
        ],
        []
      )

    assert set.until == "2999-01-01T00:00:00Z"
  end
end
