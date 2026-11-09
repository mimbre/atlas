defmodule AtlasControl.Freshness.Marks do
  @moduledoc """
  A session's pending marks (docs/design/page-freshness.md §2.3): the facts a write of
  this session changed that Flow has not yet settled, each with the position of the
  latest such write (`key => position`). Pure.

  A key is marked only once Facts has stored the write, from what the `stored` said it
  changed (`changes`, side effects included), so a mark never claims anything that did
  not happen, and it never says how the write turns out: only that it is still being
  processed. A mark goes once Flow reports a settled position at or past its write;
  never by time.

  `overlay/3` puts the marks on a page: every row that stands for a marked fact (the
  fact it opens, or one joined into it: the page's `row_keys`) gets `"pending" => true`,
  every other row has no `pending`.
  """

  @type t :: %{optional(String.t()) => non_neg_integer}

  def new, do: %{}

  @doc "The keys a write stored at `position` changed, marked: `changes` as `stored` says them."
  def mark(marks, position, changes) when is_integer(position) do
    for %{"key" => key} <- List.wrap(changes), is_binary(key), reduce: marks do
      marks -> Map.update(marks, key, position, &max(&1, position))
    end
  end

  def mark(marks, _position, _changes), do: marks

  @doc "Flow settled up to `settled`: every mark of a write at or before it goes."
  def settled(marks, settled) when is_integer(settled),
    do: Map.reject(marks, fn {_key, position} -> position <= settled end)

  def settled(marks, _settled), do: marks

  def held?(marks), do: marks != %{}

  @doc "The position of the earliest write still marked, or nil."
  def lowest(marks) when marks == %{}, do: nil
  def lowest(marks), do: marks |> Map.values() |> Enum.min()

  @doc """
  `blocks` with each row flagged by `marks`, and the marked keys the flags stand for
  (sorted). `row_keys`: per row path (`to`), the keys of the facts the row stands for; a
  row without an entry stands for the fact it opens (`key`).
  """
  def overlay(blocks, row_keys, marks) when is_list(blocks) do
    {blocks, flagged} =
      Enum.map_reduce(blocks, MapSet.new(), fn block, flagged ->
        case block do
          %{"props" => %{"rows" => rows} = props} when is_list(rows) ->
            {rows, flagged} = Enum.map_reduce(rows, flagged, &row(&1, &2, row_keys, marks))
            {%{block | "props" => %{props | "rows" => rows}}, flagged}

          block ->
            {block, flagged}
        end
      end)

    {blocks, flagged |> MapSet.to_list() |> Enum.sort()}
  end

  def overlay(blocks, _row_keys, _marks), do: {blocks, []}

  @doc "The marked keys `overlay/3` would flag on `blocks`."
  def flagged(blocks, row_keys, marks), do: blocks |> overlay(row_keys, marks) |> elem(1)

  defp row(%{} = row, flagged, row_keys, marks) do
    keys = Map.get(row_keys, row["to"]) || List.wrap(row["key"])

    case Enum.filter(keys, &Map.has_key?(marks, &1)) do
      [] -> {Map.delete(row, "pending"), flagged}
      marked -> {Map.put(row, "pending", true), MapSet.union(flagged, MapSet.new(marked))}
    end
  end

  defp row(row, flagged, _row_keys, _marks), do: {row, flagged}
end
