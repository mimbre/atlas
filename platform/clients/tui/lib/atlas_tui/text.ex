defmodule AtlasTui.Text do
  @moduledoc """
  Long text: wrapping it to a width, and editing text of several lines with a cursor.
  Pure; counts graphemes, not bytes.

  A cursor is `{line, column}`: the line of the text (split at line breaks) and the
  column within it, from 0. `nil` means the end of the text.
  """

  @doc """
  Where the wrapped rows of `line` start and how long they are: `[{start, length}]`.
  Breaks after a space when a word fits no more, inside a word only when it is longer
  than a row. The first row is `first` wide, the others `rest` (for a hanging indent).
  """
  def rows(line, first, rest \\ nil) do
    graphemes = String.graphemes(line)
    rows(graphemes, length(graphemes), 0, max(first, 1), max(rest || first, 1), [])
  end

  defp rows(_graphemes, total, at, width, _rest, acc) when total - at <= width,
    do: Enum.reverse([{at, total - at} | acc])

  defp rows(graphemes, total, at, width, rest, acc) do
    window = Enum.slice(graphemes, at, width + 1)

    # The row ends after the last space that still fits (a space may hang over the edge).
    cut =
      case window |> Enum.with_index() |> Enum.filter(&(elem(&1, 0) == " ")) |> List.last() do
        {_, i} when i > 0 -> i + 1
        _ -> width
      end

    rows(graphemes, total, at + cut, rest, rest, [{at, cut} | acc])
  end

  @doc """
  `text` wrapped to `width` for reading: line breaks and blank lines stay; a list item
  (`- `, `* `, `1. `) and an indented line continue under their own text.
  """
  def wrap(text, width) do
    width = max(width, 10)

    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      hang = String.duplicate(" ", hanging(line, width))

      line
      |> rows(width, width - String.length(hang))
      |> Enum.with_index()
      |> Enum.map(fn {{start, len}, i} ->
        row = line |> String.slice(start, len) |> String.trim_trailing()
        if i == 0, do: row, else: hang <> row
      end)
    end)
  end

  defp hanging(line, width) do
    case Regex.run(~r/^\s*(?:[-*•]\s+|\d+[.)]\s+)?/u, line) do
      [prefix] -> min(String.length(prefix), div(width, 2))
      _ -> 0
    end
  end

  # Editing

  def lines(text), do: String.split(text, "\n")

  @doc "The cursor, made to fit `text`; `nil` is the end."
  def cursor(text, nil) do
    lines = lines(text)
    {length(lines) - 1, String.length(List.last(lines))}
  end

  def cursor(text, {line, column}) do
    lines = lines(text)
    line = line |> max(0) |> min(length(lines) - 1)
    {line, column |> max(0) |> min(String.length(Enum.at(lines, line)))}
  end

  @doc """
  A key on `text` with the cursor at `cursor`: `{:ok, text, cursor}`, or `{:leave, :up}`
  or `{:leave, :down}` when an arrow moves past the first or last line, or `:ignore`.
  """
  def key(text, cursor, key) do
    lines = lines(text)
    {l, c} = cursor(text, cursor)
    line = Enum.at(lines, l)
    size = String.length(line)
    last = length(lines) - 1

    case key do
      {:char, char} ->
        edit(lines, l, insert(line, c, char), {l, c + String.length(char)})

      :enter ->
        {before, rest} = String.split_at(line, c)
        lines = List.replace_at(lines, l, before) |> List.insert_at(l + 1, rest)
        {:ok, Enum.join(lines, "\n"), {l + 1, 0}}

      :backspace when c > 0 ->
        {before, rest} = String.split_at(line, c)
        edit(lines, l, String.slice(before, 0..-2//1) <> rest, {l, c - 1})

      :backspace when l > 0 ->
        previous = Enum.at(lines, l - 1)
        lines = lines |> List.replace_at(l - 1, previous <> line) |> List.delete_at(l)
        {:ok, Enum.join(lines, "\n"), {l - 1, String.length(previous)}}

      :left when c > 0 ->
        {:ok, text, {l, c - 1}}

      :left when l > 0 ->
        {:ok, text, {l - 1, String.length(Enum.at(lines, l - 1))}}

      :right when c < size ->
        {:ok, text, {l, c + 1}}

      :right when l < last ->
        {:ok, text, {l + 1, 0}}

      :up when l > 0 ->
        {:ok, text, {l - 1, min(c, String.length(Enum.at(lines, l - 1)))}}

      :up ->
        {:leave, :up}

      :down when l < last ->
        {:ok, text, {l + 1, min(c, String.length(Enum.at(lines, l + 1)))}}

      :down ->
        {:leave, :down}

      :home ->
        {:ok, text, {l, 0}}

      :end ->
        {:ok, text, {l, size}}

      _ ->
        :ignore
    end
  end

  defp insert(line, at, char) do
    {before, rest} = String.split_at(line, at)
    before <> char <> rest
  end

  defp edit(lines, l, line, cursor),
    do: {:ok, lines |> List.replace_at(l, line) |> Enum.join("\n"), cursor}
end
