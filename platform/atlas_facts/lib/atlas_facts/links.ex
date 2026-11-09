defmodule AtlasFacts.Links do
  @moduledoc """
  The fact that set each link, on disk in Facts' data folder: when, by whom and why.

  A link in rela has no attributes; what Facts knows about it comes from the fact that
  set it. So when a stored fact names links (a create, or a change that sets or removes
  them), Facts records, per fact and relation, `%{"keys", "since", "by", "cause",
  "position"}`: the keys it points at afterwards (`[]` when the fact removed them), the
  moment and position Facts stored it, who sent it and why. Every entry is kept, newest
  last: the history of the link.

  A read answers the newest entry only while it still holds: when rela's links are the
  keys it recorded. A link someone set behind Facts' back has no origin.
  """

  def open(dir) do
    File.mkdir_p!(dir)
    file = dir |> Path.join("links.dets") |> String.to_charlist()
    {:ok, table} = :dets.open_file(make_ref(), file: file, type: :set)
    # DETS hashes the complete {kind, key, relation} key. Matching a partial
    # tuple scans the entire history table for every returned fact. Keep just
    # the relation names indexed in memory, rebuilt from the unchanged disk file.
    try do
      index = :ets.new(__MODULE__, [:bag, :protected])

      try do
        :ok =
          :dets.foldl(
            fn {{kind, key, relation}, _entries}, :ok ->
              true = :ets.insert(index, {{kind, key}, relation})
              :ok
            end,
            :ok,
            table
          )

        %{disk: table, index: index}
      catch
        kind, reason ->
          :ets.delete(index)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    catch
      kind, reason ->
        :dets.close(table)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def close(%{disk: disk, index: index}) do
    :ok = :dets.close(disk)
    :ets.delete(index)
    :ok
  end

  @doc "Record that the fact `key` of `kind` now points at `keys` through `relation`."
  def record(%{disk: disk, index: index} = table, kind, key, relation, keys, about) do
    entry = Map.put(about, "keys", Enum.sort(keys))

    :ok =
      :dets.insert(disk, {{kind, key, relation}, history(table, kind, key, relation) ++ [entry]})

    :ok = :dets.sync(disk)
    true = :ets.insert(index, {{kind, key}, relation})
    :ok
  end

  @doc "Every entry for one link, oldest first."
  def history(%{disk: disk}, kind, key, relation) do
    case :dets.lookup(disk, {kind, key, relation}) do
      [{_, entries}] -> entries
      [] -> []
    end
  end

  @doc "All entries of a fact: `%{relation => entries}`."
  def all(%{index: index} = table, kind, key) do
    Map.new(:ets.lookup(index, {kind, key}), fn {_, relation} ->
      {relation, history(table, kind, key, relation)}
    end)
  end

  @doc """
  The origin of each of a fact's links that still holds: `%{relation => entry}`. `links`
  are the fact's links as rela has them now; a relation with no link counts as `[]`.
  """
  def origins(table, kind, key, links) do
    for {relation, entries} <- all(table, kind, key),
        entry = List.last(entries),
        entry["keys"] == Enum.sort(links[relation] || []),
        into: %{},
        do: {relation, entry}
  end

  @doc "Forget a deleted fact's links."
  def forget(%{disk: disk, index: index}, kind, key) do
    for {_, relation} <- :ets.lookup(index, {kind, key}),
        do: :ok = :dets.delete(disk, {kind, key, relation})

    :ok = :dets.sync(disk)
    :ets.delete(index, {kind, key})
    :ok
  end
end
