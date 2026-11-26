defmodule AtlasControl.Steps do
  @moduledoc """
  Instructions as steps (a to-do's, shown step by step): an optional lead paragraph (its
  "Why:" taken off), then the numbered steps, each from a line that starts with a number
  and a dot (`1.`, `2.`) to the next. Within a step, a line that starts with `$ ` is a
  command (shown and copied without the `$ `); the other lines are its text. Text without
  numbered steps is one step, all of it, with no lead. Nothing is refused: any text has
  at least one step.
  """

  @step ~r/^(\d+)\.\s+(.*)$/
  @why ~r/^why:\s*/i

  @doc """
  `%{why: text | nil, steps: [%{n, text, commands}]}` of `text`, the steps numbered from
  1 in their order (whatever number the text gives them).
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
    {commands, text} =
      Enum.split_with(lines, &String.starts_with?(String.trim_leading(&1), "$ "))

    %{
      n: n,
      text: text |> Enum.map(&String.trim/1) |> Enum.join("\n") |> String.trim(),
      commands:
        for(
          line <- commands,
          command = line |> String.trim_leading() |> String.slice(2..-1//1) |> String.trim(),
          command != "",
          do: command
        )
    }
  end
end
