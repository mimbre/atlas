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
    # Keep environment and stale state readable even in a narrow viewport.
    {title, stale} =
      if stale != "" && width < String.length(title <> suffix <> stale) + 1,
        do: {"stale shell", ""},
        else: {title, stale}

    # The bar spans the row; only production marks its environment name, as a badge.
    bar = [
      {:header, " #{title} ·"},
      {if(model.env == "prod", do: :prod, else: :header), " #{model.env} "},
      {:header, String.trim_leading(count)},
      {:pending, stale}
    ]

    bar = Enum.reject(bar, fn {_, text} -> text == "" end)

    used = Enum.reduce(bar, 0, fn {_, text}, n -> n + String.length(text) end)

    [
      bar ++ [{:header, String.duplicate(" ", max(width - used, 0))}],
      [{:dim, "┌" <> String.duplicate("─", max(width - 2, 0)) <> "┐"}],
      [{:dim, "│"}] ++ tabs(shell, console.active, max(width - 2, 0)) ++ [{:dim, "│"}],
      [{:dim, "└" <> String.duplicate("─", max(width - 2, 0)) <> "┘"}]
    ]
  end

  defp tabs(nil, _active, width), do: [{:dim, fit(" Waiting for Console boot…", width)}]

  # The work tabs, a separator, then the browse tabs, each with its key ("Scenes g s").
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

  defp fit(text, width), do: String.pad_trailing(String.slice(text, 0, width), width)
end
