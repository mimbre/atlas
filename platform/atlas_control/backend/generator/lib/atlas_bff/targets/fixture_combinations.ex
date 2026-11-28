defmodule AtlasBFF.Targets.FixtureCombinations do
  @moduledoc """
  Lazy Cartesian combinations of the schema's field presence and finite representative
  values, including independently varied nested models and collection members. Lists and
  maps use 0, 1 and 3 members. Recursive model expansion is bounded by `max_depth` and can
  be requested again at a larger depth. No semantic domains are inferred from strings.
  """

  alias AtlasBFF.Targets.FixtureVariants

  @doc """
  Stream block, markup, or model specimens from a schema. `max_depth` bounds nested model
  expansion (default 8); the stream is lazy, but traversing a large offset still costs time.
  """
  def stream(schema, kind, name, opts \\ []) when kind in [:block, :markup, :model] do
    entries = Map.fetch!(schema, %{block: :blocks, markup: :markup, model: :models}[kind])

    entry =
      Enum.find(entries, &(to_string(&1.name) == to_string(name))) ||
        raise ArgumentError, "unknown #{kind} #{inspect(name)}"

    depth = Keyword.get(opts, :max_depth, 8)

    unless is_integer(depth) and depth >= 0,
      do: raise(ArgumentError, "max_depth must be nonnegative")

    models = Map.new(schema.models, &{&1.name, &1.fields})

    objects(entry.fields, models, depth)
    |> Stream.map(fn props ->
      case kind do
        :block ->
          %{"id" => "b1", "type" => to_string(entry.name), "props" => props}

        :markup ->
          %{"kind" => to_string(entry.name), "start" => "b1", "end" => "b1", "props" => props}

        :model ->
          props
      end
    end)
  end

  defp objects(fields, models, depth) do
    Enum.reduce(Enum.reverse(fields), [%{}], fn field, prior ->
      Stream.flat_map(prior, fn object ->
        values = values(field, models, depth)
        choices = if field.required, do: values, else: Stream.concat([[:absent], values])

        Stream.map(choices, fn
          :absent -> object
          value -> Map.put(object, to_string(field.name), value)
        end)
      end)
    end)
  end

  defp values(%{type: {:list, inner}} = field, models, depth) do
    element = Map.put(field, :type, inner)
    Stream.concat(for n <- [0, 1, 3], do: sequence(n, fn -> values(element, models, depth) end))
  end

  defp values(%{type: {:map, inner}} = field, models, depth) do
    element = Map.put(field, :type, inner)

    Stream.concat(
      for n <- [0, 1, 3] do
        sequence(n, fn -> values(element, models, depth) end)
        |> Stream.map(fn values ->
          values |> Enum.with_index(1) |> Map.new(fn {v, i} -> {"key#{i}", v} end)
        end)
      end
    )
  end

  defp values(%{type: type}, models, depth) when is_map_key(models, type) do
    if depth == 0, do: [], else: objects(Map.fetch!(models, type), models, depth - 1)
  end

  defp values(field, _models, _depth), do: FixtureVariants.scalar_examples(field)

  defp sequence(0, _values), do: [[]]

  defp sequence(n, values) do
    Stream.flat_map(values.(), fn value ->
      Stream.map(sequence(n - 1, values), &[value | &1])
    end)
  end
end
