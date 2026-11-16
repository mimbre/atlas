defmodule AtlasTui.PageCache do
  @moduledoc """
  The newest page Control sent for each path (docs/design/page-freshness.md §3), so back
  and a tab switch show a page at once. Pure; it holds pages as they arrived.

  A page replaces the cached one for its path unless it is older: both have a
  `position` and the new one is lower. A page without a position (a worker or failure
  page) always replaces, and is always replaced. At most `@limit` paths are kept, the
  least recently stored out. Positions are global, so the cache outlives a reconnect.
  """

  @limit 16

  defstruct pages: %{}, order: []

  def new, do: %__MODULE__{}

  @doc "The cache with `page` stored for its path, unless the cached one is newer."
  def put(cache, %{"path" => path} = page) when is_binary(path) do
    if older?(page, cache.pages[path]) do
      cache
    else
      order = [path | List.delete(cache.order, path)]
      {kept, dropped} = Enum.split(order, @limit)
      %{cache | pages: cache.pages |> Map.drop(dropped) |> Map.put(path, page), order: kept}
    end
  end

  def put(cache, _page), do: cache

  @doc "The page cached for `path`, or nil."
  def get(cache, path), do: cache.pages[path]

  @doc "The paths cached, the most recently stored first."
  def paths(cache), do: cache.order

  defp older?(%{"position" => new}, %{"position" => old})
       when is_integer(new) and is_integer(old),
       do: new < old

  defp older?(_page, _cached), do: false
end
