defmodule RelaDSL.Flow.Code do
  @moduledoc """
  The few functions the compiled subflows call while they run: a comparison with unknown
  values and the filling of a text. Pure; it knows no kind and no field by name.
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
end
