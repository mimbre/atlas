defmodule AtlasControl.Freshness.RowKey do
  @moduledoc """
  A row's `key` (contract 0.15.0, docs/design/page-freshness.md §2.3): the key of the fact
  the row opens, taken from its `to` path. A client keeps its selection on it when a page
  replaces the list (§3.1), as an opaque identity. A row that opens no fact (a kind's
  list, a form) has none. Pure.
  """

  @doc "The key of the fact a page path opens, or nil."
  def of(to) when is_binary(to) do
    case AtlasControl.Pages.route(to) do
      {:item, _kind, key} -> key
      _ -> nil
    end
  end

  def of(_to), do: nil

  @doc "The blocks of a view model, each row given the key of the fact it opens."
  def put(blocks) when is_list(blocks), do: Enum.map(blocks, &block/1)

  defp block(%{"props" => %{"rows" => rows} = props} = block) when is_list(rows),
    do: %{block | "props" => %{props | "rows" => Enum.map(rows, &row/1)}}

  defp block(block), do: block

  defp row(%{"to" => to} = row) do
    case of(to) do
      nil -> row
      key -> Map.put(row, "key", key)
    end
  end

  defp row(row), do: row
end
