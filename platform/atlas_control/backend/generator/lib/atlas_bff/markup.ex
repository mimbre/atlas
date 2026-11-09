defmodule AtlasBFF.Markup do
  @moduledoc """
  The rules of markup, as functions: part of the format, so of the generator, not of a
  contract. The server target refuses bad markup with them; the client target leaves it
  out; the TUI renders the tree. A client in another language implements the same rules;
  these functions and their tests say what they are.

  A view model is its content, a flat list of blocks with stable ids, and its markup: a
  list of entries `%{"kind" => kind, "start" => id, "end" => id, "props" => %{}}`, plus
  `"group"` on the pieces of one split entry. An entry covers the blocks from `start` to
  `end`, both included. Entries point at ids, never at positions, so inserting, deleting
  or moving a block never shifts the others' markup.

  All markup nests, of every kind, as in XML: two entries either do not share a block, or
  one covers all of the other. Entries with the same stretch nest in list order, the first
  outermost. Markup that would cross is placed as pieces that share a group (`place/3`).

  Markup says what a stretch of blocks means, never how it looks. A kind names a meaning
  (a part of a view and its role, a section, a tone); each client turns meaning into
  layout as suits its screen: boxes, columns, tabs. Ask of every new kind whether it
  names a meaning or an appearance.

  Functions take `ids`, the content's block ids in order, and `markup`.
  """

  @doc "`:ok` when `markup` is one well-formed tree over `ids`, else `{:error, why}`."
  def check(ids, markup) do
    index = index(ids)

    with :ok <- unique(ids),
         :ok <- each(markup, &stretch(&1, index)) do
      each_pair(markup, fn a, b ->
        if crossing?(span(a, index), span(b, index)),
          do: {:error, "#{describe(a)} and #{describe(b)} cross; markup must nest"},
          else: :ok
      end)
    end
  end

  @doc """
  The view model as a tree: a list of `{:block, id}` and `{:markup, entry, children}`, in
  content order. Raises on markup that `check/2` refuses.
  """
  def tree(ids, markup) do
    :ok = ok!(check(ids, markup))
    index = index(ids)

    entries =
      markup
      |> Enum.with_index()
      |> Enum.map(fn {entry, n} -> {span(entry, index), n, entry} end)
      # Outer first: earlier start, then later end, then list order.
      |> Enum.sort_by(fn {{s, e}, n, _} -> {s, -e, n} end)

    build(0, length(ids) - 1, entries, List.to_tuple(ids))
  end

  defp build(from, to, _entries, _ids) when from > to, do: []

  defp build(from, to, entries, ids) do
    case Enum.split_with(entries, fn {{s, _}, _, _} -> s == from end) do
      {[{{^from, e}, _, entry} | inner], rest} ->
        {within, after_} = Enum.split_with(rest, fn {{s, _}, _, _} -> s <= e end)
        [{:markup, entry, build(from, e, inner ++ within, ids)} | build(e + 1, to, after_, ids)]

      {[], rest} ->
        [{:block, elem(ids, from)} | build(from + 1, to, rest, ids)]
    end
  end

  @doc """
  Delete block `id`. An entry that starts or ends at it moves that boundary to its
  neighbour inside the stretch; an entry left without blocks is dropped. Returns
  `{ids, markup}`, still well formed.
  """
  def delete(ids, markup, id),
    do: {List.delete(ids, id), Enum.flat_map(markup, &shrink(&1, ids, id))}

  @doc """
  Move block `id` to position `to` (0-based, in the content after the move). The block
  keeps an entry only when it stays inside that entry's stretch; it joins the entries it
  lands inside. Markup of the block alone moves with it. Returns `{ids, markup}`, still
  well formed.
  """
  def move(ids, markup, id, to) do
    markup =
      Enum.flat_map(markup, fn entry ->
        if entry["start"] == id and entry["end"] == id,
          do: [entry],
          else: shrink(entry, ids, id)
      end)

    {ids |> List.delete(id) |> List.insert_at(to, id), markup}
  end

  # `entry` without block `id`: its boundary moves to the neighbour inside; empty, it goes.
  defp shrink(entry, ids, id) do
    {s, e} = span(entry, index(ids))

    cond do
      s == e and entry["start"] == id -> []
      entry["start"] == id -> [%{entry | "start" => Enum.at(ids, s + 1)}]
      entry["end"] == id -> [%{entry | "end" => Enum.at(ids, e - 1)}]
      true -> [entry]
    end
  end

  @doc """
  Add `entry` to well-formed `markup`. When it would cross an entry already there, it is
  placed as pieces that each nest, sharing `"group"` (the entry's own, or
  `"<start>..<end>"`). Returns the new markup.
  """
  def place(ids, markup, entry) do
    :ok = ok!(check(ids, markup))
    index = index(ids)
    :ok = ok!(stretch(entry, index))

    pieces = split([span(entry, index)], Enum.map(markup, &span(&1, index)))

    added =
      case pieces do
        [_one] ->
          [entry]

        _ ->
          group = entry["group"] || "#{entry["start"]}..#{entry["end"]}"

          for {s, e} <- pieces,
              do:
                Map.merge(entry, %{
                  "start" => Enum.at(ids, s),
                  "end" => Enum.at(ids, e),
                  "group" => group
                })
      end

    markup ++ added
  end

  defp split(pieces, spans) do
    Enum.flat_map(pieces, fn {s, e} = piece ->
      case Enum.find(spans, &crossing?(&1, piece)) do
        nil -> [piece]
        {xs, xe} when xs < s -> split([{s, xe}, {xe + 1, e}], spans)
        {xs, _xe} -> split([{s, xs - 1}, {xs, e}], spans)
      end
    end)
  end

  # Helpers

  defp index(ids), do: ids |> Enum.with_index() |> Map.new()
  defp span(entry, index), do: {index[entry["start"]], index[entry["end"]]}

  defp crossing?({as, ae}, {bs, be}),
    do: (as < bs and bs <= ae and ae < be) or (bs < as and as <= be and be < ae)

  defp unique(ids) do
    case ids -- Enum.uniq(ids) do
      [] -> :ok
      twice -> {:error, "block id #{inspect(hd(twice))} is used twice"}
    end
  end

  defp stretch(entry, index) do
    case {index[entry["start"]], index[entry["end"]]} do
      {nil, _} ->
        {:error, "#{describe(entry)} starts at unknown block #{inspect(entry["start"])}"}

      {_, nil} ->
        {:error, "#{describe(entry)} ends at unknown block #{inspect(entry["end"])}"}

      {s, e} when s > e ->
        {:error, "#{describe(entry)} ends before it starts"}

      _ ->
        :ok
    end
  end

  defp each(list, fun), do: Enum.find_value(list, :ok, &with(:ok <- fun.(&1), do: nil))

  defp each_pair(list, fun) do
    pairs =
      for {a, i} <- Enum.with_index(list), {b, j} <- Enum.with_index(list), i < j, do: {a, b}

    each(pairs, fn {a, b} -> fun.(a, b) end)
  end

  defp describe(entry), do: "#{entry["kind"]} #{entry["start"]}..#{entry["end"]}"

  defp ok!(:ok), do: :ok
  defp ok!({:error, why}), do: raise(ArgumentError, why)
end
