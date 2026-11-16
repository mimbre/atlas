defmodule AtlasTui.Selection do
  @moduledoc """
  Which row is selected when a page replaces the list on screen
  (docs/design/page-freshness.md §3.1). A pure rule over row identities and indexes: it
  knows nothing of what changed or why.

  A selection is remembered as `{identity, index}`. A row's identity is its `key` (the
  fact it opens, as Control names it), else its `to`; either is opaque here.
  """

  @type before :: {String.t() | nil, non_neg_integer} | nil

  @doc "A row's identity: its key, else the path it opens."
  def identity(nil), do: nil
  def identity(%{key: key}) when is_binary(key), do: key
  def identity(%{to: to}), do: to

  @doc "The selection to remember for `rows` with `index` selected; nil when none is."
  def of(rows, index) when is_integer(index) do
    case Enum.at(rows, index) do
      nil -> nil
      row -> {identity(row), index}
    end
  end

  def of(_rows, _index), do: nil

  @doc """
  The index to select in `rows` (in display order) after they replace a list whose
  selection was `before`:

    1. no rows: nil, nothing is selected;
    2. no selection before (another path, a first open): the first row;
    3. the identity is still there: its index; more than once, the one nearest the old
       index, the lower on a tie;
    4. it left, and the old index is still a row: the row now at that index;
    5. it left, past the end: the last row.
  """
  @spec after_replace(before, list) :: non_neg_integer | nil
  def after_replace(_before, []), do: nil
  def after_replace(nil, _rows), do: 0

  def after_replace({identity, index}, rows) do
    index = max(index || 0, 0)

    found =
      for {row, at} <- Enum.with_index(rows), identity != nil, identity(row) == identity, do: at

    case found do
      [] -> min(index, length(rows) - 1)
      found -> Enum.min_by(found, &{abs(&1 - index), &1})
    end
  end
end
