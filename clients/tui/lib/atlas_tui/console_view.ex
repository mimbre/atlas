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

  defp tabs(shell, active, width) do
    tabs = shell["tabs"]

    segments =
      Enum.map(tabs, fn tab ->
        if tab["id"] == active,
          do: {:selected, " ▸ #{tab["label"]} "},
          else: {:dim, "   #{tab["label"]} "}
      end)

    index = Enum.find_index(tabs, &(&1["id"] == active)) || 0

    before =
      segments
      |> Enum.take(index)
      |> Enum.reduce(0, fn {_, text}, n -> n + String.length(text) end)

    active_size = segments |> Enum.at(index) |> elem(1) |> String.length()
    total = Enum.reduce(segments, 0, fn {_, text}, n -> n + String.length(text) end)
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
    used = Enum.reduce(shown, 0, fn {_, text}, n -> n + String.length(text) end)
    prefix ++ shown ++ [{:dim, String.duplicate(" ", max(available - used, 0))}] ++ suffix
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
