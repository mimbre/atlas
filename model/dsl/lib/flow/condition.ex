defmodule RelaDSL.Flow.Condition do
  @moduledoc """
  The closed grammar of a subflow's conditions (a branch's `when:`, a predicate start),
  compiled when the model compiles: comparisons of `entity.<field>` with a literal, then
  `and`, then `or`, and parentheses. A text outside the grammar does not compile.

  `quoted/2` gives the Elixir code that evaluates a condition on a map of values, so a
  running subflow never parses a condition. A field that is missing makes a comparison
  unknown: unknown is no match, `false and unknown` is false and `true or unknown` true.
  """

  @doc "The condition as a tree: `{:ok, tree}` or `{:error, :unsupported_condition}`."
  def compile(text) when is_binary(text) and byte_size(text) <= 4096 do
    with {:ok, tokens} <- tokens(text, []),
         {:ok, tree, []} <- expression(tokens, 0) do
      {:ok, tree}
    else
      _ -> {:error, :unsupported_condition}
    end
  end

  def compile(_), do: {:error, :unsupported_condition}

  @doc "The fields a condition reads."
  def fields({:field, field}), do: [field]
  def fields({_, left, right}), do: Enum.uniq(fields(left) ++ fields(right))
  def fields(_), do: []

  @doc "Code that is `true` when the condition holds on `values` (a quoted variable)."
  def quoted(tree, values),
    do: quote(do: unquote(value(tree, values)) == true)

  defp value({:field, field}, values),
    do: quote(do: Map.get(unquote(values), unquote(field), :missing))

  defp value({:literal, literal}, _values), do: Macro.escape(literal)

  defp value({op, left, right}, values) do
    quote do
      RelaDSL.Flow.Code.op(
        unquote(op),
        unquote(value(left, values)),
        unquote(value(right, values))
      )
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
