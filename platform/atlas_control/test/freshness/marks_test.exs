defmodule AtlasControl.Freshness.MarksTest do
  @moduledoc """
  The pending marker (docs/design/page-freshness.md §2.3, §5): a mark means "written, not
  yet settled", and only Control sets or clears it.
  """
  use ExUnit.Case, async: true

  alias AtlasControl.Freshness.{Marks, ReadSet, RowKey}

  defp changed(kind, key), do: %{"kind" => kind, "key" => key, "op" => "change"}

  # A list of widgets, each row keyed as Control sends it.
  defp list(keys) do
    rows = for key <- keys, do: %{"label" => key, "to" => "/k/widget/#{key}"}

    RowKey.put([
      %{"id" => "head", "type" => "item", "props" => %{"title" => "Widgets"}},
      %{"id" => "list", "type" => "list", "props" => %{"title" => "Widgets", "rows" => rows}}
    ])
  end

  defp flags(blocks),
    do:
      for(
        %{"props" => %{"rows" => rows}} <- blocks,
        row <- rows,
        do: {row["key"], row["pending"]}
      )

  test "a stored write marks every key it changed, side effects included" do
    marks = Marks.mark(Marks.new(), 4, [changed("widget", "W-1"), changed("part", "P-1")])
    assert marks == %{"W-1" => 4, "P-1" => 4}
    assert Marks.held?(marks)
    assert Marks.lowest(marks) == 4
  end

  test "a refusal, or a write that changed nothing, marks nothing" do
    for changes <- [[], nil] do
      marks = Marks.mark(Marks.new(), 4, changes)
      refute Marks.held?(marks)
      assert Marks.lowest(marks) == nil
    end

    assert Marks.mark(Marks.new(), nil, [changed("widget", "W-1")]) == %{}
  end

  test "a key written again is marked until the later write settles" do
    marks =
      Marks.new()
      |> Marks.mark(4, [changed("widget", "W-1")])
      |> Marks.mark(6, [changed("widget", "W-1")])

    assert Marks.settled(marks, 5) == %{"W-1" => 6}
    assert Marks.settled(marks, 6) == %{}
  end

  test "settled S ≥ P clears; S < P does not; with P1 < P2 and S between, only P1 clears" do
    marks =
      Marks.new()
      |> Marks.mark(4, [changed("widget", "W-1")])
      |> Marks.mark(7, [changed("widget", "W-2")])

    assert Marks.settled(marks, 3) == marks
    assert Marks.settled(marks, 5) == %{"W-2" => 7}
    assert Marks.lowest(Marks.settled(marks, 5)) == 7
    assert Marks.settled(marks, 7) == %{}
    # No settled position (a timeout, an answer without one): every mark stays.
    assert Marks.settled(marks, nil) == marks
  end

  test "the overlay flags the row of a marked key and no other row" do
    blocks = list(["W-1", "W-2"])
    marks = Marks.mark(Marks.new(), 4, [changed("widget", "W-1")])

    assert {flagged, ["W-1"]} = Marks.overlay(blocks, %{}, marks)
    assert flags(flagged) == [{"W-1", true}, {"W-2", nil}]
    # Everything but the flags stays as it was.
    assert hd(flagged) == hd(blocks)
    assert Marks.flagged(blocks, %{}, marks) == ["W-1"]
  end

  test "the overlay flags a row whose joined key is marked (row_keys from the read set)" do
    blocks = list(["W-1", "W-2"])

    set =
      ReadSet.of(
        [{"widget", :rows}, {"part", :lookup}],
        [
          %{
            "facts" => [%{"key" => "W-1", "links" => %{}}, %{"key" => "W-2", "links" => %{}}],
            "deps" => [["kind", "widget"]],
            "position" => 3
          },
          %{
            "facts" => [%{"key" => "P-1", "links" => %{"of_widget" => ["W-2"]}}],
            "deps" => [["kind", "part"]],
            "position" => 3
          }
        ],
        blocks
      )

    assert set.row_keys["/k/widget/W-2"] == ["W-2", "P-1"]
    marks = Marks.mark(Marks.new(), 4, [changed("part", "P-1")])
    assert {flagged, ["P-1"]} = Marks.overlay(blocks, set.row_keys, marks)
    assert flags(flagged) == [{"W-1", nil}, {"W-2", true}]
  end

  test "without marks, or once they clear, no row is flagged, one flagged before too" do
    marks = Marks.mark(Marks.new(), 4, [changed("widget", "W-1")])
    {flagged, _} = Marks.overlay(list(["W-1"]), %{}, marks)
    assert flags(flagged) == [{"W-1", true}]

    assert {cleared, []} = Marks.overlay(flagged, %{}, Marks.settled(marks, 4))
    assert flags(cleared) == [{"W-1", nil}]
    refute cleared |> List.last() |> get_in(["props", "rows"]) |> hd() |> Map.has_key?("pending")
  end

  test "a row that opens no fact, and a page without rows, are left as they are" do
    marks = Marks.mark(Marks.new(), 4, [changed("widget", "W-1")])

    blocks = [
      %{"type" => "list", "props" => %{"rows" => [%{"label" => "All", "to" => "/k/widget"}]}}
    ]

    assert Marks.overlay(blocks, %{}, marks) == {blocks, []}
    assert Marks.overlay([], %{}, marks) == {[], []}
    assert Marks.overlay(nil, %{}, marks) == {nil, []}
  end
end
