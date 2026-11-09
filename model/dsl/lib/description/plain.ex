defmodule RelaDSL.Description.Plain do
  @moduledoc """
  A model's values as the targets hold them: atoms become strings (but `true`, `false`
  and `nil`), keyword lists and maps become objects with string keys, other lists stay
  lists. `of/1` gives maps (for targets whose keys are written sorted); `ordered/1`
  gives `{:ordered, [{key, value}]}`, keeping the order written.
  """

  @doc "The plain value, objects as maps."
  def of(value), do: convert(value, :map)

  @doc "The plain value, objects as `{:ordered, pairs}` in the order written."
  def ordered(value), do: convert(value, :ordered)

  defp convert(v, _) when is_boolean(v) or is_nil(v) or is_binary(v) or is_number(v), do: v
  defp convert(v, _) when is_atom(v), do: Atom.to_string(v)
  defp convert([], _), do: []

  defp convert(list, mode) when is_list(list) do
    if Keyword.keyword?(list), do: object(list, mode), else: Enum.map(list, &convert(&1, mode))
  end

  defp convert(map, mode) when is_map(map),
    do: object(Enum.sort_by(Map.to_list(map), &key(elem(&1, 0))), mode)

  defp convert(v, _), do: raise(ArgumentError, "#{inspect(v)} has no plain form")

  defp object(pairs, mode) do
    keys = Enum.map(pairs, &key(elem(&1, 0)))

    if keys != Enum.uniq(keys),
      do: raise(ArgumentError, "a key is given twice in #{inspect(pairs)}")

    converted = for {k, v} <- pairs, do: {key(k), convert(v, mode)}
    if mode == :map, do: Map.new(converted), else: {:ordered, converted}
  end

  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k) when is_binary(k), do: k
  defp key(k), do: raise(ArgumentError, "#{inspect(k)} is not a key")

  @doc "An ordered value as maps."
  def unorder({:ordered, pairs}), do: Map.new(pairs, fn {k, v} -> {k, unorder(v)} end)
  def unorder(list) when is_list(list), do: Enum.map(list, &unorder/1)
  def unorder(v), do: v
end
