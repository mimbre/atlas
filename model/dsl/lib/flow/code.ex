defmodule RelaDSL.Flow.Code do
  @moduledoc """
  The few functions the compiled subflows and legacy flows call while they run: a
  comparison with unknown values, the filling of a text, and the facts a legacy state's
  conditions read. Pure; it knows no kind and no field by name.
  """

  @doc "One step of a condition: `op` on two values, `:missing` when it cannot be known."
  def op(op, a, b) do
    case {op, a, b} do
      {"and", false, _} -> false
      {"and", _, false} -> false
      {"or", true, _} -> true
      {"or", _, true} -> true
      {_, :missing, _} -> :missing
      {_, _, :missing} -> :missing
      {"and", a, b} when is_boolean(a) and is_boolean(b) -> a and b
      {"or", a, b} when is_boolean(a) and is_boolean(b) -> a or b
      {"==", a, b} -> a == b
      {"!=", a, b} -> a != b
      {">", a, b} when is_number(a) and is_number(b) -> a > b
      {">=", a, b} when is_number(a) and is_number(b) -> a >= b
      {"<", a, b} when is_number(a) and is_number(b) -> a < b
      {"<=", a, b} when is_number(a) and is_number(b) -> a <= b
      _ -> :missing
    end
  end

  @doc """
  A text with its `{name}`s filled from `vars` (`parts` as the model compiled them: text
  and `{:var, name}`). A name with no plain value leaves its place empty; the text is
  trimmed, and a colon left at its end goes.
  """
  def fill(parts, vars) do
    parts
    |> Enum.map(fn
      {:var, name} -> scalar(Map.get(vars, name))
      text -> text
    end)
    |> IO.iodata_to_binary()
    |> String.trim()
    |> String.trim_trailing(":")
  end

  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: to_string(value)

  defp scalar(_), do: ""

  @doc "The fact's own plain values, which a legacy state's text may name."
  def own_vars(fact) do
    for {name, value} <- fact["values"] || %{},
        is_binary(value) or is_number(value) or is_boolean(value),
        into: %{},
        do: {name, value}
  end

  @doc "Each of `allowed` (field to values) holds of the fact's values."
  def values?(fact, allowed),
    do: Enum.all?(allowed, fn {name, values} -> fact["values"][name] in List.wrap(values) end)

  @doc """
  The newest fact about the association `relation` removed it, and no fact came under the
  fact since (through one of `parents`): `%{"note" => cause}`, else nil.
  """
  def reopened(fact, children, parents, relation) do
    case get_in(fact, ["origins", relation]) do
      %{"keys" => [], "position" => at} = origin when is_integer(at) ->
        if at > newest_under(children, parents), do: %{"note" => origin["cause"] || ""}

      _ ->
        nil
    end
  end

  @doc """
  Nothing points at the fact through `relation`, one of `parents` (by which facts belong
  under its kind) or of `pointing` (associations that end at its kind); never for another.
  """
  def empty?(relation, children, parents, pointing) do
    (relation in parents or relation in pointing) and
      not Enum.any?(children, &((get_in(&1, ["links", relation]) || []) != []))
  end

  defp newest_under(children, parents) do
    children
    |> Enum.flat_map(fn child ->
      for relation <- parents,
          at = get_in(child, ["origins", relation, "position"]),
          is_integer(at),
          do: at
    end)
    |> Enum.max(fn -> 0 end)
  end
end
