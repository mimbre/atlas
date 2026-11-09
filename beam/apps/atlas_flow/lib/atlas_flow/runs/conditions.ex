defmodule AtlasFlow.Runs.Conditions do
  @moduledoc "Closed grammar: comparisons before conjunction before disjunction."

  def compile(text) when is_binary(text) and byte_size(text) <= 4096 do
    with {:ok, tokens} <- tokens(text, []),
         {:ok, tree, []} <- expression(tokens, 0) do
      {:ok, tree}
    else
      _ -> {:error, :unsupported_condition}
    end
  end

  def compile(_), do: {:error, :unsupported_condition}

  def fields({:field, field}), do: [field]
  def fields({_, left, right}), do: Enum.uniq(fields(left) ++ fields(right))
  def fields(_), do: []

  def matches?(text, values) do
    case compile(text) do
      {:ok, tree} -> evaluate(tree, values) == true
      _ -> false
    end
  end

  def evaluate({:field, field}, values), do: Map.get(values, field, :missing)
  def evaluate({:literal, value}, _), do: value

  def evaluate({op, left, right}, values) do
    a = evaluate(left, values)
    b = evaluate(right, values)

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

  defp tokens("", acc), do: {:ok, Enum.reverse(acc)}

  defp tokens(text, acc) do
    case Regex.run(
           ~r/\A\s*(entity\.[a-zA-Z_][a-zA-Z0-9_]*|'[^'\\]*'|-?\d+(?:\.\d+)?|true\b|false\b|and\b|or\b|==|!=|>=|<=|>|<|\(|\))/,
           text
         ) do
      [all, token] ->
        tokens(binary_part(text, byte_size(all), byte_size(text) - byte_size(all)), [token | acc])

      _ ->
        if String.trim(text) == "",
          do: {:ok, Enum.reverse(acc)},
          else: {:error, :unsupported_condition}
    end
  end

  defp expression(_, depth) when depth > 64, do: {:error, :unsupported_condition}

  defp expression(tokens, depth) do
    with {:ok, left, rest} <- conjunction(tokens, depth + 1),
         do: chain(left, rest, "or", &conjunction/2, depth)
  end

  defp conjunction(tokens, depth) do
    with {:ok, left, rest} <- comparison(tokens, depth + 1),
         do: chain(left, rest, "and", &comparison/2, depth)
  end

  defp chain(left, [op | rest], op, parser, depth) do
    with {:ok, right, tail} <- parser.(rest, depth + 1),
         do: chain({op, left, right}, tail, op, parser, depth)
  end

  defp chain(left, rest, _, _, _), do: {:ok, left, rest}

  defp comparison(["(" | rest], depth) do
    case expression(rest, depth + 1) do
      {:ok, tree, [")" | tail]} -> {:ok, tree, tail}
      _ -> {:error, :unsupported_condition}
    end
  end

  defp comparison(["entity." <> field, op, token | rest], _) when op in ~w(== != > >= < <=) do
    case literal(token) do
      {:ok, value} -> {:ok, {op, {:field, field}, {:literal, value}}, rest}
      _ -> {:error, :unsupported_condition}
    end
  end

  defp comparison(_, _), do: {:error, :unsupported_condition}
  defp literal("'" <> text), do: {:ok, String.trim_trailing(text, "'")}
  defp literal("true"), do: {:ok, true}
  defp literal("false"), do: {:ok, false}

  defp literal(text) do
    case Float.parse(text) do
      {value, ""} -> {:ok, value}
      _ -> {:error, :unsupported_condition}
    end
  end
end
