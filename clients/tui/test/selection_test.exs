defmodule AtlasTui.SelectionTest do
  @moduledoc """
  The selection rule (docs/design/page-freshness.md §3.1): which row is selected when a
  page replaces the list on screen, on row identities and indexes only.
  """
  use ExUnit.Case, async: true

  alias AtlasTui.Blocks.Row
  alias AtlasTui.Selection

  defp row(key), do: %Row{label: key, key: key, to: "/k/widget/#{key}"}
  defp rows(keys), do: Enum.map(keys, &row/1)

  # {case, before, rows, expected index}
  @table [
    {"1: an empty list selects nothing", {"B", 1}, [], nil},
    {"1: an empty list selects nothing, with no selection before", nil, [], nil},
    {"2: no selection before selects the first row", nil, ~w(A B C), 0},
    {"3: the key stays at its index", {"B", 1}, ~w(A B C), 1},
    {"3: the key stays, at a new index", {"B", 1}, ~w(B A C), 0},
    {"3: the key stays, moved down", {"A", 0}, ~w(B C A), 2},
    {"3: a key twice: the occurrence nearest the old index", {"A", 3}, ~w(A B C D A), 4},
    {"3: a key twice at equal distance: the lower one", {"A", 2}, ~w(A B C D A), 0},
    {"4: the key left: the row now at the same index", {"B", 1}, ~w(A C D), 1},
    {"4: the key left at the first row", {"A", 0}, ~w(B C), 0},
    {"5: the key left past the end: the last row", {"C", 2}, ~w(A B), 1},
    {"5: the key left far past the end: the last row", {"Z", 9}, ~w(A), 0},
    {"4: no identity before keeps the index", {nil, 1}, ~w(A B C), 1}
  ]

  for {name, before, keys, expected} <- @table do
    test name do
      assert Selection.after_replace(unquote(Macro.escape(before)), rows(unquote(keys))) ==
               unquote(expected)
    end
  end

  test "a row without a key is identified by the path it opens" do
    keyless = for to <- ~w(/k/kind /a /b), do: %Row{label: to, to: to}
    assert Selection.identity(hd(keyless)) == "/k/kind"
    assert Selection.after_replace({"/b", 0}, keyless) == 2
    assert Selection.after_replace({"/gone", 1}, keyless) == 1
  end

  test "a key is the identity even when the path differs" do
    before = Selection.of([%Row{label: "x", key: "W-1", to: "/k/widget/W-1"}], 0)
    assert before == {"W-1", 0}
    moved = [row("A"), %Row{label: "x", key: "W-1", to: "/k/_/W-1"}]
    assert Selection.after_replace(before, moved) == 1
  end

  test "the selection remembered of a list: its row's identity and index; none when empty" do
    assert Selection.of(rows(~w(A B)), 1) == {"B", 1}
    assert Selection.of([], 0) == nil
    assert Selection.of(rows(~w(A)), nil) == nil
  end
end
