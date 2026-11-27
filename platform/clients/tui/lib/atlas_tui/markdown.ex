defmodule AtlasTui.Markdown do
  @moduledoc false

  # Unsupported constructs remain literal. Links are shown, never opened or executed.
  @inline ~r/(?<![\\!])(?:\*\*[^*\n]+\*\*|__[^_\n]+__|\*[^*\n]+\*|_[^_\n]+_|\[[^\]\n]+\]\([^)\s]+\)|`[^`\n]+`)/u

  def render(text, width, cell_width) do
    text = String.replace(text, ~r/[\x00-\x08\x0b-\x1f\x7f-\x9f]/u, "")
    text = String.replace(text, "\t", "    ")

    {lines, _} =
      text
      |> String.split("\n")
      |> Enum.map_reduce(nil, fn line, fence ->
        marker = Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/u, line)

        case {fence, marker} do
          {nil, [_, marks, _]} ->
            {wrap([{:dim, line}], width, cell_width), {String.first(marks), String.length(marks)}}

          {{char, size}, [_, marks, rest]} ->
            if String.first(marks) == char and String.length(marks) >= size and String.trim(rest) == "" do
              {wrap([{:dim, line}], width, cell_width), nil}
            else
              {wrap([{:plain, line}], width, cell_width), fence}
            end

          {nil, _} ->
            {render_line(line, width, cell_width), nil}

          {_, _} ->
            {wrap([{:plain, line}], width, cell_width), fence}
        end
      end)

    Enum.flat_map(lines, & &1)
  end

  defp render_line(line, width, cell_width) do
    segments =
      case Regex.run(~r/^ {0,3}(\#{1,6})\s+(.+?)\s*\#*\s*$/u, line) do
        [_, marks, content] -> [{:dim, "H#{String.length(marks)} "} | inline(content, :bold)]
        _ -> inline(line, :plain)
      end

    wrap(segments, width, cell_width)
  end

  defp inline(text, default) do
    case Regex.run(@inline, text, return: :index) do
      [{start, length}] ->
        before = binary_part(text, 0, start)
        token = binary_part(text, start, length)
        rest = binary_part(text, start + length, byte_size(text) - start - length)
        [{default, before}, inline_token(token) | inline(rest, default)]

      nil ->
        [{default, text}]
    end
  end

  defp inline_token("[" <> _ = token) do
    [_, label, destination] = Regex.run(~r/^\[([^\]]+)\]\(([^)]+)\)$/u, token)
    {:route, label <> " (" <> destination <> ")"}
  end

  defp inline_token("**" <> _ = token), do: {:bold, String.slice(token, 2..-3//1)}
  defp inline_token("__" <> _ = token), do: {:bold, String.slice(token, 2..-3//1)}
  defp inline_token("`" <> _ = token), do: {:plain, String.slice(token, 1..-2//1)}
  defp inline_token(token), do: {:bold, String.slice(token, 1..-2//1)}

  defp wrap(segments, width, cell_width) do
    chars = for {style, text} <- segments, char <- String.graphemes(text), do: {style, char}
    words = Enum.chunk_by(chars, fn {_, char} -> char == " " end)

    {rows, row, _} =
      Enum.reduce(words, {[], [], 0}, fn word, {rows, row, used} ->
        size = Enum.reduce(word, 0, fn {_, char}, n -> n + cell_width.(char) end)
        {rows, row, used} = if used > 0 and used + size > width, do: {[row | rows], [], 0}, else: {rows, row, used}

        Enum.reduce(word, {rows, row, used}, fn {style, char}, {rows, row, used} ->
          size = cell_width.(char)
          {rows, row, used} = if used > 0 and used + size > width, do: {[row | rows], [], 0}, else: {rows, row, used}
          {rows, [{style, char} | row], used + size}
        end)
      end)

    [row | rows]
    |> Enum.reverse()
    |> Enum.map(fn row ->
      row
      |> Enum.reverse()
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map(fn chars -> {elem(hd(chars), 0), Enum.map_join(chars, &elem(&1, 1))} end)
    end)
  end
end
