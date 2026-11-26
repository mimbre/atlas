defmodule AtlasControl.Steps do
  @moduledoc """
  Instructions as steps (a to-do's, shown step by step): an optional lead paragraph (its
  "Why:" taken off), then the numbered steps, each from a line that starts with a number
  and a dot (`1.`, `2.`) to the next. Within a step a line is one of three kinds: a line
  that starts with `$ ` is a command (shown and copied without the `$ `); a line that
  starts with `> ` is a route, the way to something in an app, its parts separated by
  ` > ` (`> Keychain Access > login > My Certificates`; a part in double quotes is one
  part, ` > ` inside it too, and is given without its quotes); the other lines are its
  text. Text without numbered steps is one step, all of it, with no lead. Nothing is
  refused: any text has at least one step.
  """

  @step ~r/^(\d+)\.\s+(.*)$/
  @why ~r/^why:\s*/i
  # A ` > ` with an even number of double quotes after it: one outside quotes.
  @separator ~r/\s+>\s+(?=(?:[^"]*"[^"]*")*[^"]*$)/
  @quoted ~r/^"(.*)"$/s

  @doc """
  `%{why: text | nil, steps: [%{n, text, commands, routes, lines}]}` of `text`, the steps
  numbered from 1 in their order (whatever number the text gives them). `text` is the
  step's text lines, `commands` its commands and `routes` its routes (each the list of its
  parts); `lines` is all of them in the order written: `%{kind: :text, text: text}` (the
  text between two commands or routes, its lines kept), `%{kind: :command, text: command}`
  and `%{kind: :route, parts: parts}`.
  """
  def parse(text) do
    lines = String.split(String.replace(text || "", "\r\n", "\n"), "\n")

    case Enum.split_while(lines, &(not Regex.match?(@step, &1))) do
      {_all, []} ->
        %{why: nil, steps: [step(1, lines)]}

      {lead, numbered} ->
        why = lead |> Enum.join("\n") |> String.trim() |> String.replace(@why, "")

        steps =
          numbered
          |> Enum.chunk_while(
            nil,
            fn line, chunk ->
              case Regex.run(@step, line) do
                [_, _number, first] when chunk == nil -> {:cont, [first]}
                [_, _number, first] -> {:cont, Enum.reverse(chunk), [first]}
                nil -> {:cont, [line | chunk]}
              end
            end,
            fn chunk -> {:cont, Enum.reverse(chunk), nil} end
          )
          |> Enum.with_index(1)
          |> Enum.map(fn {chunk, n} -> step(n, chunk) end)

        %{why: if(why != "", do: why), steps: steps}
    end
  end

  @doc "The step one is at, from 1: `at` (nil is the first) within 1 and one past the last (all done)."
  def current(at, steps) when is_integer(at), do: at |> max(1) |> min(length(steps) + 1)
  def current(_at, _steps), do: 1

  defp step(n, lines) do
    lines =
      lines
      |> Enum.map(&line/1)
      |> Enum.chunk_by(&(&1.kind == :text))
      |> Enum.flat_map(fn
        [%{kind: :text} | _] = run ->
          [%{kind: :text, text: run |> Enum.map_join("\n", & &1.text) |> String.trim()}]

        others ->
          others
      end)
      |> Enum.reject(&(&1[:text] == "" or &1[:parts] == []))

    %{
      n: n,
      text: Enum.join(for(%{kind: :text, text: text} <- lines, do: text), "\n"),
      commands: for(%{kind: :command, text: command} <- lines, do: command),
      routes: for(%{kind: :route, parts: parts} <- lines, do: parts),
      lines: lines
    }
  end

  defp line(line) do
    case String.trim_leading(line) do
      "$ " <> command ->
        %{kind: :command, text: String.trim(command)}

      "> " <> route ->
        parts =
          for part <- String.split(String.trim(route), @separator),
              part = unquote_part(String.trim(part)),
              part != "",
              do: part

        %{kind: :route, parts: parts}

      text ->
        %{kind: :text, text: String.trim(text)}
    end
  end

  defp unquote_part(part) do
    case Regex.run(@quoted, part) do
      [_, inner] -> String.trim(inner)
      nil -> part
    end
  end
end
