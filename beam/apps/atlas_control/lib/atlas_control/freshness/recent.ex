defmodule AtlasControl.Freshness.Recent do
  @moduledoc """
  The pages a session sent lately, by path (docs/design/page-freshness.md §1.3): the
  path on screen and those viewed before it, at most `n` (8), the least recently viewed
  out. Pure.

  An entry: `%{route, deps, row_keys, view, as_of, until, last_sent}`, where `view` is
  the page last sent for the path. Viewing a path (`viewed/3`) makes it the most recent;
  a page pushed for a path off screen (`sent/3`) replaces its entry and keeps its place.
  """

  defstruct n: 8, order: [], entries: %{}

  @type entry :: %{
          route: term,
          deps: [list],
          row_keys: map,
          view: map,
          as_of: non_neg_integer | nil,
          until: String.t() | nil,
          last_sent: integer
        }
  @type t :: %__MODULE__{n: pos_integer, order: [String.t()], entries: %{String.t() => entry}}

  def new(n \\ 8), do: %__MODULE__{n: n}

  @doc "`path` was viewed with `entry`: the most recent now."
  def viewed(%__MODULE__{} = recent, path, entry) do
    order = [path | List.delete(recent.order, path)]
    {kept, out} = Enum.split(order, recent.n)

    %{recent | order: kept, entries: recent.entries |> Map.put(path, entry) |> Map.drop(out)}
  end

  @doc "A page for `path` was sent without viewing it: its entry, in its place."
  def sent(%__MODULE__{} = recent, path, entry) do
    if Map.has_key?(recent.entries, path),
      do: put_in(recent.entries[path], entry),
      else: recent
  end

  @doc "Forget `paths`: they are read again when they are opened again."
  def drop(%__MODULE__{} = recent, paths),
    do: %{recent | order: recent.order -- paths, entries: Map.drop(recent.entries, paths)}

  @doc "The paths, the most recently viewed first."
  def paths(%__MODULE__{order: order}), do: order

  def get(%__MODULE__{entries: entries}, path), do: Map.get(entries, path)
end
