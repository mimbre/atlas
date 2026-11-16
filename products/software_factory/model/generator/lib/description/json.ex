defmodule RelaDSL.Description.Json do
  @moduledoc """
  JSON as the description's files have always been written (Python's `json.dumps`,
  `ensure_ascii` off): two-space `pretty` blocks, `inline` objects and lists on one
  line (`, ` and `: `), or `compact` ones (`,` and `:`). Maps are written with sorted
  keys; `{:ordered, pairs}` in the order given. Text is escaped as Python escapes it:
  quotes, backslashes and control characters only.

  `write/2` takes a layout: a function from a value's path (its keys, and indexes as
  integers) to `:pretty`, `:inline` or `:compact`; what a value inside an inline or
  compact one is laid out as follows it.
  """

  @doc "The text of `value`, laid out by `layout`, with a final newline."
  def write(value, layout \\ fn _ -> :pretty end),
    do: IO.iodata_to_binary([pretty(value, [], "", layout), "\n"])

  @doc "The layout of `flow-runtime.json`: flags, reviews and choices inline, each migration compact."
  def flow_runtime_layout(["flow_runtime", "flags", _]), do: :inline
  def flow_runtime_layout(["flow_runtime", "reviews", _]), do: :inline

  def flow_runtime_layout(["flow_runtime", "selection", _, k])
      when k in ["choices", "choice_states"],
      do: :inline

  def flow_runtime_layout(["flow_runtime", "selection", _, "migrations", i]) when is_integer(i),
    do: :compact

  def flow_runtime_layout(_path), do: :pretty

  defp pretty(value, path, indent, layout) do
    case layout.(path) do
      :pretty -> block(value, path, indent, layout)
      style -> line(value, style)
    end
  end

  defp block(value, path, indent, layout) do
    case pairs(value) do
      {:object, []} ->
        "{}"

      {:object, pairs} ->
        inner = indent <> "  "

        lines =
          for {k, v} <- pairs, do: [inner, string(k), ": ", pretty(v, path ++ [k], inner, layout)]

        ["{\n", Enum.intersperse(lines, ",\n"), "\n", indent, "}"]

      {:list, []} ->
        "[]"

      {:list, list} ->
        inner = indent <> "  "

        lines =
          for {v, i} <- Enum.with_index(list), do: [inner, pretty(v, path ++ [i], inner, layout)]

        ["[\n", Enum.intersperse(lines, ",\n"), "\n", indent, "]"]

      {:scalar, v} ->
        scalar(v)
    end
  end

  defp line(value, style) do
    {item, key} = if style == :inline, do: {", ", ": "}, else: {",", ":"}

    case pairs(value) do
      {:object, pairs} ->
        [
          "{",
          Enum.map_intersperse(pairs, item, fn {k, v} -> [string(k), key, line(v, style)] end),
          "}"
        ]

      {:list, list} ->
        ["[", Enum.map_intersperse(list, item, &line(&1, style)), "]"]

      {:scalar, v} ->
        scalar(v)
    end
  end

  defp pairs({:ordered, pairs}), do: {:object, pairs}
  defp pairs(map) when is_map(map), do: {:object, Enum.sort_by(Map.to_list(map), &elem(&1, 0))}
  defp pairs(list) when is_list(list), do: {:list, list}
  defp pairs(v), do: {:scalar, v}

  defp scalar(true), do: "true"
  defp scalar(false), do: "false"
  defp scalar(nil), do: "null"
  defp scalar(n) when is_integer(n), do: Integer.to_string(n)
  defp scalar(n) when is_float(n), do: Float.to_string(n)
  defp scalar(s) when is_binary(s), do: string(s)
  defp scalar(v), do: raise(ArgumentError, "#{inspect(v)} has no JSON form")

  @doc "A JSON string as Python writes it with `ensure_ascii` off."
  def string(s) when is_binary(s), do: [?", escape(s, []), ?"]

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20,
    do: escape(rest, [:io_lib.format("\\u~4.16.0b", [c]) | acc])

  defp escape(<<c::utf8, rest::binary>>, acc), do: escape(rest, [<<c::utf8>> | acc])
end
