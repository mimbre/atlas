defmodule AtlasTui.ConsoleView do
  @moduledoc "Terminal shell framing; navigation data and order come only from boot."

  def header(model, width) do
    console = model.console
    shell = console.shell
    title = if shell, do: shell["title"], else: "Atlas Console"
    count = if model.count, do: " · " <> model.count, else: ""
    stale = if console.stale && shell, do: " · stale shell", else: ""
    # The environment segment keeps a cell either side, so it reads as a badge.
    suffix = " · #{model.env} "
    title = String.slice(title, 0, max(width - String.length(suffix) - 1, 0))
    # The shell's greeting (the viewer's name) follows the environment, before the count,
    # with the assistant line after it, faint:
    # "Atlas Console · prod · <name> · assistant: coordinator · 3 assigned to you". Both
    # are cut to the room the rest of the bar leaves, and left out when there is none.
    room = width - String.length(" #{title}" <> suffix <> "· " <> count) - 1

    greeting =
      if shell && shell["greeting"],
        do: String.slice(shell["greeting"], 0, max(room, 0)),
        else: ""

    room = room - String.length(greeting) - 3

    assistant =
      if greeting != "" && shell["assistant"] && room > 0,
        do: " · " <> String.slice(shell["assistant"], 0, room),
        else: ""

    {greeting, count} =
      if greeting == "",
        do: {"", String.trim_leading(count)},
        else: {"· " <> greeting, count}

    # Keep environment and stale state readable even in a narrow viewport.
    {title, stale} =
      if stale != "" && width < String.length(title <> suffix <> stale) + 1,
        do: {"stale shell", ""},
        else: {title, stale}

    # The bar spans the row; only a non-production environment is marked, as a badge.
    bar = [
      {:header, " #{title} ·"},
      {if(model.env == "prod", do: :header, else: :env_test), " #{model.env} "},
      {:header, greeting},
      {{:header, :muted}, assistant},
      {:header, count},
      {:pending, stale}
    ]

    bar = Enum.reject(bar, fn {_, text} -> text == "" end)

    used = Enum.reduce(bar, 0, fn {_, text}, n -> n + String.length(text) end)
    bar = bar ++ [{:header, String.duplicate(" ", max(width - used, 0))}]
    inner = max(width - 2, 0)

    # The sidebar holds the tabs when there is one; otherwise use the tab bar.
    if AtlasTui.Columns.sidebar?(model) do
      [bar]
    else
      [
        bar,
        [{:dim, "┌" <> String.duplicate("─", inner) <> "┐"}],
        [{:dim, "│"}] ++ tabs(shell, console.active, inner) ++ [{:dim, "│"}],
        [{:dim, "└" <> String.duplicate("─", inner) <> "┘"}]
      ] ++
        breadcrumb(model, width)
    end
  end

  defp breadcrumb(model, width) do
    if AtlasTui.Columns.layout(width) == :one and model.console.history != [] do
      tabs = (model.console.shell || %{})["tabs"] || []
      paths = Enum.reverse(model.console.history)

      labels =
        Enum.flat_map(paths, fn entry ->
          tab =
            Enum.find_value(tabs, fn tab ->
              if tab["to"] == entry.path do
                tab["label"]
              else
                Enum.find_value(tab["groups"] || [], fn group ->
                  if group["to"] == entry.path, do: group["label"]
                end)
              end
            end)

          cached = AtlasTui.PageCache.get(model.console.cache, entry.path)

          case tab || entry[:title] || (cached && cached["title"]) do
            label when is_binary(label) and label != "" -> [label]
            _ -> []
          end
        end)

      labels = Enum.dedup(labels ++ if(is_binary(model.title), do: [model.title], else: []))

      if length(labels) > 1 do
        text = "  " <> Enum.join(labels, " › ")

        graphemes = String.graphemes(text)

        if Enum.sum(Enum.map(graphemes, &cell_width/1)) <= width do
          [[{:dim, text}]]
        else
          {suffix, _} =
            graphemes
            |> Enum.reverse()
            |> Enum.reduce_while({[], max(width - 1, 0)}, fn grapheme, {acc, room} ->
              cells = cell_width(grapheme)

              if cells <= room,
                do: {:cont, {[grapheme | acc], room - cells}},
                else: {:halt, {acc, room}}
            end)

          [[{:dim, "…" <> Enum.join(suffix)}]]
        end
      else
        []
      end
    else
      []
    end
  end

  defp cell_width(grapheme) do
    {width, emoji} =
      for <<cp::utf8 <- grapheme>>, reduce: {0, false} do
        {width, emoji} -> {width + :prim_tty.npwcwidth(cp), emoji or cp in [0xFE0F, 0x20E3]}
      end

    if emoji, do: max(width, 2), else: width
  end

  # No tabs before boot: the status line says what the TUI waits for.
  defp tabs(nil, _active, width), do: [{:dim, String.duplicate(" ", width)}]

  # The work tabs, a separator, then the browse tabs, each with its key (as "g s").
  defp tabs(shell, active, width) do
    {work, browse} = Enum.split_with(shell["tabs"], &AtlasTui.Console.work?/1)
    separator = if work != [] and browse != [], do: [{:separator, [{:dim, " │"}]}], else: []

    groups =
      Enum.map(work, &{&1["id"], tab(&1, active)}) ++
        separator ++ Enum.map(browse, &{&1["id"], tab(&1, active)})

    segments = Enum.flat_map(groups, &elem(&1, 1))
    index = Enum.find_index(groups, &(elem(&1, 0) == active)) || 0

    size = fn segments ->
      Enum.reduce(segments, 0, fn {_, text}, n -> n + String.length(text) end)
    end

    before = groups |> Enum.take(index) |> Enum.map(&size.(elem(&1, 1))) |> Enum.sum()
    active_size = groups |> Enum.at(index) |> elem(1) |> size.()
    total = size.(segments)
    # Scroll a continuous viewport to the active tab. Both overflow markers are
    # presentation only and never become navigation destinations.
    offset = max(min(before - max(div(width - active_size, 2), 0), total - width), 0)
    left = if offset > 0 and width > 2, do: 1, else: 0
    right = if offset + width < total and width > 2, do: 1, else: 0
    available = max(width - left - right, 0)

    offset =
      if active_size <= available, do: max(offset, before + active_size - available), else: before

    shown = slice(segments, offset, available)
    prefix = if left == 1, do: [{:dim, "‹"}], else: []
    suffix = if right == 1, do: [{:dim, "›"}], else: []
    used = size.(shown)
    prefix ++ shown ++ [{:dim, String.duplicate(" ", max(available - used, 0))}] ++ suffix
  end

  defp tab(tab, active) do
    selected = tab["id"] == active

    label =
      if selected, do: {:selected, " ▸ #{tab["label"]} "}, else: {:dim, "   #{tab["label"]} "}

    hint_style = if selected, do: {:selected, :muted}, else: :muted
    hint = if tab["key"], do: [{hint_style, "#{tab["key"]} "}], else: []
    [label | hint]
  end

  defp slice(_segments, _offset, 0), do: []
  defp slice([], _offset, _width), do: []

  defp slice([{style, text} | rest], offset, width) do
    size = String.length(text)

    if offset >= size do
      slice(rest, offset - size, width)
    else
      part = String.slice(text, offset, width)
      [{style, part} | slice(rest, 0, width - String.length(part))]
    end
  end
end
