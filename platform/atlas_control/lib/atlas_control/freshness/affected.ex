defmodule AtlasControl.Freshness.Affected do
  @moduledoc """
  Which pages a batch of writes made stale (docs/design/page-freshness.md §1.1, §1.3):
  a page is stale when one of its deps matches a change stored after the position the
  page was read at. A change at or before it is shown already. Pure: deps and changes
  are matched as Facts said them, with no knowledge of what they mean.

  Changes come per position: `[{position, [change]}]`, each change as a `stored` hint's
  `changes` say it (`kind`, `key`, `op`, `fields`, `relinked`, `links`).
  """

  alias AtlasControl.Freshness.Recent

  @doc "The recent paths a batch made stale, the most recently viewed first."
  def affected(%Recent{} = recent, changes) do
    for path <- Recent.paths(recent),
        entry = Recent.get(recent, path),
        stale?(entry.deps, entry.as_of, changes),
        do: path
  end

  @doc "Whether deps read at `as_of` (nil: unknown) are made stale by `changes`."
  def stale?(deps, as_of, changes), do: first(deps, as_of, changes) != nil

  @doc "The first change that makes deps read at `as_of` stale: `{position, change}`, or nil."
  def first(deps, as_of, changes) do
    Enum.find_value(changes, fn {position, entries} ->
      if after?(position, as_of) do
        Enum.find_value(entries, fn change ->
          if Enum.any?(deps, &matches?(&1, change)), do: {position, change}
        end)
      end
    end)
  end

  defp after?(_position, nil), do: true
  defp after?(nil, _as_of), do: true
  defp after?(position, as_of), do: position > as_of

  @doc """
  Whether a change `c` can change what a dep stands for:

    * `["key", kind, key, fields]`: the fact itself, when fields it read differ (`"*"`:
      any), or it was made, deleted or relinked;
    * `["linked", relation, target, fields]`: a fact that points, or pointed, at `target`
      through `relation`, when that link moved, the fact was made or deleted, or fields
      it read differ;
    * `["kind", kind]`: any fact of the kind.
  """
  def matches?(["key", kind, key, fields], c) do
    c["kind"] == kind and c["key"] == key and
      (c["op"] != "change" or fields?(fields, c) or (c["relinked"] || []) != [])
  end

  def matches?(["linked", relation, target, fields], c) do
    target in List.wrap(get_in(c, ["links", relation])) and
      (relation in (c["relinked"] || []) or c["op"] != "change" or fields?(fields, c))
  end

  def matches?(["kind", kind], c), do: c["kind"] == kind
  def matches?(_dep, _c), do: false

  defp fields?("*", _c), do: true

  defp fields?(fields, c) when is_list(fields),
    do: Enum.any?(c["fields"] || [], &(&1 in fields))

  defp fields?(_fields, _c), do: false
end
