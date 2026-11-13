defmodule AtlasControl.Freshness.ReadSet do
  @moduledoc """
  What a page depended on (docs/design/page-freshness.md §1.3): the `deps` Facts said its
  answers depended on, narrowed, the position they were read at (`as_of`), the earliest
  instant a value in them changes by time alone (`until`), and per row the keys of the
  facts the row stands for (`row_keys`). Pure. Control stores deps as Facts said them and
  never works them out from the model.

  Each read of a page has a role (`AtlasControl.Pages.read_roles/2`):

    * `:rows`: its facts are the page's rows, so which facts it holds matters; its deps
      are kept as they are.
    * `:lookup`: it only resolves facts that rows point at, or that point at rows. It
      keeps a `key` dep only for those facts, and depends on what points at a row
      through the relations they use (`linked`), instead of on its whole kind. When no
      row links to any of its facts, or none of them to a row, it keeps every dep, so
      narrowing never misses a change.

  An answer that says nothing of what it depended on (an error, a reader that does not
  say) depends on every fact of the kind it read; a page with an answer that is an error
  was read at no position (`as_of` nil).
  """

  alias AtlasControl.Freshness.RowKey

  defstruct deps: [], as_of: nil, until: nil, row_keys: %{}

  @type dep :: list
  @type t :: %__MODULE__{
          deps: [dep],
          as_of: non_neg_integer | nil,
          until: String.t() | nil,
          row_keys: %{optional(String.t()) => [String.t()]}
        }

  @doc "Nothing read: no change can make it stale."
  def none, do: %__MODULE__{}

  @doc """
  The read set of a page from its reads (`[{kind, role}]`), their answers (in the same
  order) and the view model it was rendered to (its blocks).
  """
  def of(reads, answers, blocks) do
    pairs = Enum.zip(reads, answers)
    rows = for {{_kind, :rows}, answer} <- pairs, fact <- facts(answer), do: fact
    row_keys = MapSet.new(rows, & &1["key"])
    row_targets = rows |> Enum.flat_map(&targets/1) |> MapSet.new()

    {deps, joins} =
      Enum.reduce(pairs, {MapSet.new(), []}, fn {{kind, role}, answer}, {deps, joins} ->
        own = deps_of(kind, answer)

        case role do
          :lookup ->
            {narrowed, joined} = narrow(kind, own, facts(answer), rows, row_keys, row_targets)
            {MapSet.union(deps, narrowed), joined ++ joins}

          _ ->
            {MapSet.union(deps, MapSet.new(own)), joins}
        end
      end)

    %__MODULE__{
      deps: deps |> MapSet.to_list() |> Enum.sort(),
      as_of: as_of(answers),
      until: answers |> Enum.map(& &1["until"]) |> Enum.reduce(nil, &earliest/2),
      row_keys: row_keys(blocks, joins)
    }
  end

  @doc "Deps and positions of several read sets as one (a page with its header's count)."
  def union(a, b) do
    %__MODULE__{
      deps: Enum.sort(Enum.uniq(a.deps ++ b.deps)),
      as_of: lowest([a.as_of, b.as_of]),
      until: earliest(a.until, b.until),
      row_keys: Map.merge(b.row_keys, a.row_keys)
    }
  end

  # A page with an answer Facts could not give is as of no position: any change makes it
  # stale, and a reconcile reads it again.
  defp as_of(answers) do
    if Enum.any?(answers, &Map.has_key?(&1, "error")),
      do: nil,
      else: answers |> Enum.map(& &1["position"]) |> lowest()
  end

  defp deps_of(_kind, %{"deps" => deps}) when is_list(deps), do: deps
  defp deps_of(kind, _answer), do: [["kind", kind]]

  # A lookup's facts joined to a row: those a row points at, or that point at a row.
  defp narrow(kind, deps, facts, rows, row_keys, row_targets) do
    joined =
      Enum.filter(facts, fn fact ->
        fact["key"] in row_targets or Enum.any?(targets(fact), &(&1 in row_keys))
      end)

    case joined do
      [] ->
        {MapSet.new(deps), []}

      joined ->
        keep = MapSet.new(joined, & &1["key"])

        kept =
          Enum.reject(deps, fn
            ["kind", ^kind] -> true
            ["key", ^kind, key, _fields] -> key not in keep
            _ -> false
          end)

        through =
          for fact <- joined,
              {relation, keys} <- fact["links"] || %{},
              key <- List.wrap(keys),
              key in row_keys,
              do: ["linked", relation, key, "*"]

        pairs =
          for fact <- joined,
              row <- rows,
              row["key"] in targets(fact) or fact["key"] in targets(row),
              uniq: true,
              do: {fact["key"], row["key"]}

        {MapSet.new(kept ++ through), pairs}
    end
  end

  # Per row (by the path it opens): the key of the fact it opens and of the facts joined
  # into it.
  defp row_keys(blocks, joins) do
    partners =
      Enum.reduce(joins, %{}, fn {a, b}, acc ->
        acc |> Map.update(a, [b], &[b | &1]) |> Map.update(b, [a], &[a | &1])
      end)

    for %{"to" => to} <- rows(blocks),
        is_binary(to),
        key = RowKey.of(to),
        key != nil,
        into: %{},
        do: {to, Enum.uniq([key | Enum.sort(Map.get(partners, key, []))])}
  end

  @doc "Every row of a view model's blocks, wherever a block holds them."
  def rows(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &rows/1)

  def rows(%{"rows" => rows} = block) when is_list(rows),
    do: rows ++ rows(Map.delete(block, "rows"))

  def rows(%{} = block), do: block |> Map.values() |> Enum.flat_map(&rows/1)
  def rows(_), do: []

  defp facts(%{"facts" => facts}) when is_list(facts), do: facts
  defp facts(%{"fact" => %{} = fact}), do: [fact]
  defp facts(_), do: []

  defp targets(fact),
    do: for({_relation, keys} <- fact["links"] || %{}, key <- List.wrap(keys), do: key)

  defp lowest(positions) do
    case Enum.filter(positions, &is_integer/1) do
      [] -> nil
      positions -> Enum.min(positions)
    end
  end

  defp earliest(nil, b), do: b
  defp earliest(a, nil), do: a

  defp earliest(a, b) do
    case {DateTime.from_iso8601(a), DateTime.from_iso8601(b)} do
      {{:ok, x, _}, {:ok, y, _}} -> if DateTime.compare(x, y) == :gt, do: b, else: a
      _ -> a
    end
  end
end
