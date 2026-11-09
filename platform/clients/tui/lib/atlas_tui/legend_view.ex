defmodule AtlasTui.LegendView do
  @moduledoc "Terminal presentation of actual legend markup: vertical aligned rows and a bounded viewport."
  alias AtlasTui.{Legend, Text}

  def affordance(model) do
    case Legend.opener(model) do
      nil ->
        []

      action ->
        [
          [
            {:dim,
             " " <> Enum.join(action["props"]["keys"], ", ") <> " " <> action["props"]["label"]}
          ]
        ]
    end
  end

  def geometry(model, width, body_room) do
    box = min(max(width - 2, 1), 88)
    inner = max(box - 4, 1)
    groups = Legend.groups(model)

    keys =
      for %{actions: actions} <- groups,
          action <- actions,
          do: String.length(Enum.join(action["props"]["keys"], ", "))

    key_width = min(Enum.max(keys, fn -> 1 end), max(div(inner, 3), 1))
    label_width = max(inner - key_width - 2, 1)

    lines =
      Enum.flat_map(groups, fn %{markup: markup, actions: actions} ->
        title = wrap(markup["props"]["title"], inner) |> Enum.map(&[{:bold, &1}])
        rows = Enum.flat_map(actions, &action_lines(&1, key_width, label_width))
        title ++ rows ++ [[]]
      end)
      |> Enum.drop(-1)

    # One row each for title border, overflow/status and bottom border.
    room = max(body_room - 3, 1)
    %{box: box, inner: inner, lines: lines, room: room, max_scroll: max(length(lines) - room, 0)}
  end

  def render(model, width, body_room) do
    g = geometry(model, width, body_room)
    offset = min(model.console.legend.scroll, g.max_scroll)
    shown = Enum.slice(g.lines, offset, g.room)
    left = String.duplicate(" ", max(div(width - g.box, 2), 0))
    title = " " <> Legend.title(model) <> " "

    close =
      case Legend.closer(model) do
        nil ->
          ""

        action ->
          keys = Enum.join(action["props"]["keys"], ", ")
          full = keys <> " " <> action["props"]["label"]
          text = if String.length(full <> title) + 2 <= g.box - 2, do: full, else: keys
          " " <> text <> " "
      end

    close = String.slice(close, 0, max(g.box - 2, 0))
    title = String.slice(title, 0, max(g.box - 2 - String.length(close), 0))

    top = [
      {:dim, left <> "┌"},
      {:bold, title},
      {:dim, String.duplicate("─", max(g.box - 2 - String.length(title <> close), 0))},
      {:dim, close <> "┐"}
    ]

    content =
      Enum.map(shown, fn segments ->
        used = Enum.reduce(segments, 0, fn {_, text}, n -> n + String.length(text) end)

        [{:dim, left <> "│ "}] ++
          segments ++ [{:dim, String.duplicate(" ", max(g.inner - used, 0)) <> " │"}]
      end)

    above = if offset > 0, do: "↑ #{offset} above", else: ""

    below =
      if length(g.lines) > offset + length(shown),
        do: "↓ #{length(g.lines) - offset - length(shown)} below",
        else: ""

    status = Enum.reject([above, below], &(&1 == "")) |> Enum.join(" · ")

    tail = [
      [{:dim, left <> "│ " <> pad(status, g.inner) <> " │"}],
      [{:dim, left <> "└" <> String.duplicate("─", max(g.box - 2, 0)) <> "┘"}]
    ]

    frame = Enum.take([top] ++ content ++ tail, body_room)
    padding = List.duplicate([], max(div(body_room - length(frame), 2), 0))
    padding ++ frame
  end

  defp action_lines(action, key_width, label_width) do
    p = action["props"]
    keys = wrap(Enum.join(p["keys"], ", "), key_width)
    label = if p["available"], do: p["label"], else: p["label"] <> " · unavailable"
    label = if !p["available"] && p["reason"], do: label <> ": " <> p["reason"], else: label
    labels = wrap(label, label_width)

    for index <- 0..(max(length(keys), length(labels)) - 1) do
      [
        {if(p["available"], do: :info, else: :dim), pad(Enum.at(keys, index, ""), key_width)},
        {:plain, "  "},
        {if(p["available"], do: :plain, else: :dim), Enum.at(labels, index, "")}
      ]
    end
  end

  defp pad(text, width), do: text |> String.slice(0, width) |> String.pad_trailing(width)

  defp wrap(text, width) do
    String.split(text, "\n")
    |> Enum.flat_map(fn line ->
      Text.rows(line, max(width, 1))
      |> Enum.map(fn {from, count} ->
        line |> String.slice(from, count) |> String.trim_trailing()
      end)
    end)
  end
end
