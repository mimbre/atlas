defmodule AtlasTui.View do
  @moduledoc """
  Draws the model as lines for a terminal of `width` × `height`. Pure, so tests can read
  the screen. Each line is a list of `{style, text}` segments; `to_ansi/1` adds colour.
  """

  alias AtlasTui.Blocks.{
    Box,
    Confirm,
    Fallback,
    Form,
    Highlight,
    Input,
    Item,
    Panel,
    PanelItem,
    Part,
    Plan,
    Section,
    SingleChoice,
    Steps
  }

  alias AtlasTui.Blocks.List, as: ListBlock
  alias AtlasTui.{Model, Text}

  @label_width 16
  # Beside the label of a row Control marks pending (docs/design/page-freshness.md §2.3).
  @pending_mark "  ⋯ being processed"
  # How such a row looks: muted (faint), muted inside the highlight when selected; the
  # mark itself keeps the pending colour, so the eye still catches it.
  @pending_style :muted
  # Where a row's work stands (Control's `tone`): a dot before the id, in the colour of its
  # meaning (`AtlasTui.Palette`'s `:tone_*`), beside the row's own words, which say it too.
  @dot "●"
  @tone_styles %{
    "attention" => :tone_attention,
    "active" => :tone_active,
    "waiting" => :tone_waiting,
    "done" => :tone_done
  }
  # A title keeps at least this many cells (or all of its own) before the age column goes.
  @title_floor 40
  # A multi-line input that does not have the focus shows at most this many rows.
  @resting_rows 8
  # A focused one never shows fewer than this, however small the screen.
  @least_rows 3
  # Markup says what a stretch of a page means; how it looks is this view's choice. A page
  # in parts shows them side by side from this width; narrower, one above the other.
  @side_by_side 120
  # One column of page content reads best at most this wide; wider, it is centred.
  @measure 100
  # From this width a page's details stand beside it: one column, a gap, and the details
  # at least this wide (growing to one column's width).
  @gap 4
  @side_least 40
  @beside @measure + @gap + @side_least

  @doc """
  The contract's names this view knows: the blocks it draws, and the kinds of markup it
  draws or, for now, passes through. A test fails when the contract has one it does not.
  """
  def known,
    do: %{
      blocks: ~w(list groups item single_choice panel steps form confirm plan console_action),
      markup: ~w(part section highlight legend)
    }

  @doc "The screen: exactly `height` lines of plain segments."
  def render(%Model{} = model, width, height, reconcile_seconds) do
    {rows, _model} = frame(model, width, height, reconcile_seconds)
    rows
  end

  @doc "Render a frame and retain its pane bounds for subsequent paging operations."
  def frame(%Model{} = model, width, height, reconcile_seconds) do
    width = max(width, 1)
    height = max(height, 1)
    header = AtlasTui.ConsoleView.header(model, width)
    help = footer_help(model)
    room = max(height - length(header) - 3 - length(help), 1)
    measure = body_width(model, width)
    margin = String.duplicate(" ", div(width - measure, 2))
    {lines, _long, viewports} = laid_out(model, measure, room)
    {body, viewport} = window(lines, model, room)
    body = if margin == "", do: body, else: Enum.map(body, &[{:plain, margin} | &1])
    viewports = if viewport, do: Map.put(viewports, nil, viewport), else: viewports

    body = body ++ Elixir.List.duplicate([], room - length(body))

    footer =
      help ++
        [
          [{:dim, String.duplicate("─", width)}],
          console_notice(model),
          status(model, reconcile_seconds)
        ]

    rows = Enum.map(Enum.take(header ++ body ++ footer, height), &fit(&1, width))
    {rows, %{model | viewports: viewports}}
  end

  @doc "The screen as plain text, for tests and evidence."
  def plain(lines),
    do:
      Enum.map_join(lines, "\n", fn line ->
        line |> Enum.map_join(&elem(&1, 1)) |> String.trim_trailing()
      end)

  @doc "The screen as ANSI, ready to write from the top-left corner."
  def to_ansi(lines, theme) do
    base = AtlasTui.Palette.ansi(:plain, theme)

    rows =
      Enum.map(lines, fn line ->
        [
          base,
          Enum.map(line, fn {style, text} -> [AtlasTui.Palette.ansi(style, theme), text] end),
          base,
          "\e[K"
        ]
      end)

    ["\e[H", Enum.intersperse(rows, "\r\n"), base, "\e[J"]
  end

  # Body

  # Closed by Control: why, in full, in place of a page that is no longer current (a build
  # too old for Control says what is true and what to do, IS-Atlas-76).
  defp body(%Model{connected: false, closed: true, notice: %{text: text}}, width, _room),
    do: [[] | Enum.map(AtlasTui.Text.wrap(text, width - 2), &[{:error, " " <> &1}])]

  # Waiting for a page that is not shown yet; a page kept for it (back, a tab) shows.
  defp body(%Model{console: %{expected: target, restoring: false}, path: path}, _width, _room)
       when target != nil and target != path,
       do: [[], [{:pending, " Loading…"}]]

  defp body(%Model{console: %{legend: legend}} = model, width, room) when legend != nil,
    do: AtlasTui.LegendView.render(model, width, room)

  defp body(%Model{connected: false, closed: false}, _width, _room) do
    [
      [],
      [{:error, " Not connected to Control. Retrying…"}],
      [{:dim, " Nothing old is shown as if it were current."}]
    ]
  end

  # The agent's plan shows over the page; the page stays underneath and follows hints.
  defp body(%Model{plan: %Plan{}} = model, width, room) do
    block = Model.step_form(model) || %{model.plan | steps: Model.plan_steps(model)}
    block(block, 0, model, width, room)
  end

  defp body(%Model{blocks: []}, _width, _room), do: [[], [{:dim, " Waiting for Control…"}]]

  defp body(model, width, room), do: nodes(content(model), model, width, room)

  @doc """
  How wide the page's body is drawn, centred in the terminal: one column of at most
  #{@measure} cells; from #{@beside} wide, a page with details has them in a column beside
  it (#{@gap} cells apart, #{@side_least} to #{@measure} wide, growing with the room); parts
  side by side take the full width. The chrome (tabs, title, footer, status) always spans
  the terminal (docs/design/apple-clients.md, Page width).
  """
  def body_width(model, width) do
    cond do
      width >= @side_by_side and in_parts?(model) -> width
      width >= @beside and details_part(model) != nil -> min(width, 2 * @measure + @gap)
      true -> min(width, @measure)
    end
  end

  defp page_shown?(model) do
    model.connected and model.blocks != [] and model.plan == nil and
      model.console.legend == nil and
      (model.console.expected in [nil, model.path] or model.console.restoring)
  end

  defp in_parts?(model), do: page_shown?(model) and Model.parts(model) != []

  # The page's details (a part of role details among blocks in no part), when shown.
  defp details_part(model) do
    if page_shown?(model) and Model.parts(model) == [],
      do: Enum.find(content(model), &details?/1)
  end

  defp details?({:markup, %{"value" => %Part{role: "details"}}, _}), do: true
  defp details?(_node), do: false

  # The body's lines, and whether it is longer than its room. A page in parts fills its
  # room exactly, each part scrolled on its own; a part that is cut says so itself. Wider
  # than one column: the details beside the rest, both scrolled as one.
  defp laid_out(model, width, room) do
    cond do
      in_parts?(model) -> parts(content(model), model, width, room)
      width > @measure -> beside(model, width, room)
      true -> plain_layout(model, width, room)
    end
  end

  defp beside(model, width, room) do
    {details, main} = Enum.split_with(content(model), &details?/1)
    main = nodes(main, model, @measure, room)
    side = nodes(details, model, width - @measure - @gap, room)
    gap = [{:plain, String.duplicate(" ", @gap)}]

    lines =
      for row <- 0..(max(length(main), length(side)) - 1) do
        pad_line(fit(Enum.at(main, row) || [], @measure), @measure) ++
          gap ++ (Enum.at(side, row) || [])
      end

    {lines, length(lines) > room, %{}}
  end

  defp plain_layout(model, width, room) do
    lines = body(model, width, room)
    {lines, length(lines) > room, %{}}
  end

  # The view model as a tree, top down: blocks (with where their rows start in the page's
  # one selection), and markup around them.
  defp content(%Model{markup: []} = model),
    do: Enum.map(with_offsets(model), fn {_id, block, at} -> {:block, block, at} end)

  defp content(model) do
    by_id = Map.new(with_offsets(model), fn {id, block, at} -> {id, {block, at}} end)

    model.ids
    |> AtlasBFF.Markup.tree(model.markup)
    |> blocks_in(by_id)
  end

  # A list inside a folded section is not drawn and holds no part of the selection.
  defp with_offsets(model) do
    hidden = Model.folded(model)

    {placed, _} =
      model.ids
      |> Enum.zip(model.blocks)
      |> Enum.map_reduce(0, fn
        {id, %ListBlock{rows: rows} = block}, at ->
          if MapSet.member?(hidden, id),
            do: {{id, block, -1}, at},
            else: {{id, block, at}, at + length(rows || [])}

        {id, block}, at ->
          {{id, block, at}, at}
      end)

    placed
  end

  defp blocks_in(tree, by_id) do
    Enum.map(tree, fn
      {:block, id} ->
        {block, at} = Map.fetch!(by_id, id)
        {:block, block, at}

      {:markup, entry, children} ->
        {:markup, entry, blocks_in(children, by_id)}
    end)
  end

  # A page in parts: side by side when the terminal is wide enough (the first part the
  # wider), else one above the other, each given the room it needs as far as there is
  # room. Each part scrolls on its own; the one with the focus has a bright frame.
  defp parts(parts, model, width, room) do
    focus = Model.part(model)

    drawn =
      parts
      |> Enum.with_index()
      |> Enum.map(fn {node, i} -> {i, node} end)

    if width >= @side_by_side do
      first = div(width * 3, 5)
      widths = [first | List.duplicate(width - first, length(parts) - 1)]

      columns =
        for {{i, node}, w} <- Enum.zip(drawn, widths),
            do: {part(node, model, i == focus, model.scrolls[i], w, room), w, i}

      lines =
        for row <- 0..(room - 1) do
          Enum.flat_map(columns, fn {{lines, _cut, _viewport}, w, _i} ->
            line = Enum.at(lines, row) || []
            pad_line(fit(line, w), w)
          end)
        end

      viewports = Map.new(columns, fn {{_, _, viewport}, _, i} -> {i, viewport} end)
      {lines, Enum.any?(columns, fn {{_, cut, _}, _, _} -> cut end), viewports}
    else
      needs = for {_i, node} <- drawn, do: length(part_lines(node, model, width)) + 2
      heights = share(needs, room, todo_part(parts) || related_part(parts) || lists_part(model))

      drawn =
        for {{i, node}, h} <- Enum.zip(drawn, heights),
            do: {part(node, model, i == focus, model.scrolls[i], width, h), i}

      lines = Enum.flat_map(drawn, fn {{lines, _, _}, _} -> lines end)
      viewports = Map.new(drawn, fn {{_, _, viewport}, i} -> {i, viewport} end)
      {Enum.take(lines, room), Enum.any?(drawn, fn {{_, cut, _}, _} -> cut end), viewports}
    end
  end

  # Room for parts one above the other: each its need when all fit. Else the part with
  # the lists first, so long content never pushes them away, while every other part keeps
  # a third of the room (or what it needs, when less); the rest is shared equally.
  defp share(needs, room, first) do
    cond do
      Enum.sum(needs) <= room ->
        needs

      first == nil ->
        equal(needs, room, List.duplicate(0, length(needs)))

      true ->
        others = List.delete_at(needs, first)
        kept = others |> Enum.map(&min(&1, max(div(room, 3), 5))) |> Enum.sum()
        need = Enum.at(needs, first)
        top = need |> min(room - kept) |> max(min(need, 3))
        given = equal(others, room - top, List.duplicate(0, length(others)))
        List.insert_at(given, first, top)
    end
  end

  defp equal(needs, room, given) do
    open = for {need, i} <- Enum.with_index(needs), Enum.at(given, i) < need, do: i
    left = room - Enum.sum(given)

    if open == [] or left <= 0 do
      given
    else
      each = max(div(left, length(open)), 1)

      given =
        Enum.reduce(open, given, fn i, given ->
          left = room - Enum.sum(given)
          add = Enum.min([each, Enum.at(needs, i) - Enum.at(given, i), left])
          List.update_at(given, i, &(&1 + max(add, 0)))
        end)

      if room - Enum.sum(given) == left, do: given, else: equal(needs, room, given)
    end
  end

  # The owner's part (what to do, IS-Atlas-54), if any: given room first, before the lists.
  defp todo_part(parts),
    do: Enum.find_index(parts, &match?({:markup, %{"value" => %Part{role: "todo"}}, _}, &1))

  # The part whose role is related (what the page links to), if any: given room first.
  defp related_part(parts) do
    Enum.find_index(parts, &match?({:markup, %{"value" => %Part{role: "related"}}, _}, &1))
  end

  # The part that holds the page's lists, if any.
  defp lists_part(model) do
    lists = for {id, %ListBlock{}} <- Enum.zip(model.ids, model.blocks), do: id
    Enum.find_index(Model.parts(model), fn ids -> Enum.any?(ids, &(&1 in lists)) end)
  end

  # What a part holds, at the width inside its frame.
  defp part_lines({:markup, %{"value" => %Part{}}, children}, model, width),
    do: nodes(children, model, width - 4, :all)

  defp part_lines(node, model, width), do: nodes([node], model, width, :all)

  # One part, `height` lines: its frame and title, and its lines from where it is
  # scrolled to (by hand, or to keep its selected row in sight). When it holds more than
  # fits, its last line says how much more there is.
  defp part(node, model, focused, scrolled, width, height) do
    title =
      case node do
        {:markup, %{"value" => %Part{title: title}}, _} -> title
        _ -> nil
      end

    inner = width - 4
    lines = part_lines(node, model, width)
    room = max(height - 2, 1)
    total = length(lines)
    cut = total > room
    shown = if cut, do: room - 1, else: room
    last = max(total - shown, 0)
    selected = Enum.find_index(lines, &selected_line?/1)

    start =
      cond do
        not cut -> 0
        scrolled != nil -> min(scrolled, last)
        selected != nil -> (selected - div(shown, 2)) |> min(last) |> max(0)
        true -> 0
      end

    visible = Enum.slice(lines, start, shown)
    below = total - start - length(visible)

    more =
      [
        start > 0 && "↑ #{count(start, "line")} above",
        below > 0 && "… #{count(below, "more line")}"
      ]
      |> Enum.filter(& &1)

    body =
      visible ++
        if(cut, do: [[{:dim, "   " <> Enum.join(more, " · ")}]], else: []) ++
        List.duplicate([], max(room - length(visible) - if(cut, do: 1, else: 0), 0))

    style = if focused, do: :bold, else: :dim
    label = if title, do: "─ " <> title <> " ", else: ""
    top = " ┌" <> label <> String.duplicate("─", max(inner - String.length(label), 0)) <> "┐"

    framed =
      for line <- body do
        line = fit(line, inner)
        [{style, " │"} | pad_line(line, inner)] ++ [{style, "│"}]
      end

    lines =
      ([[{style, top}]] ++ framed ++ [[{style, " └" <> String.duplicate("─", inner) <> "┘"}]])
      |> Enum.take(height)

    {lines, cut, %{start: start, last: last, step: max(shown - 1, 1)}}
  end

  defp count(n, noun), do: "#{n} #{noun}#{if n == 1, do: "", else: "s"}"

  defp pad_line(line, width) do
    used = Enum.reduce(line, 0, fn {_, text}, used -> used + display_width(text) end)
    line ++ [{:plain, String.duplicate(" ", max(width - used, 0))}]
  end

  defp nodes(tree, model, width, room) do
    tree
    |> Enum.map(fn
      {:block, block, at} -> block(block, at, model, width, room)
      {:markup, %{"value" => value}, children} -> markup(value, children, model, width, room)
    end)
    |> Enum.intersperse([[]])
    |> Enum.concat()
  end

  # Parts frame content; Console highlights retain the supplied semantic tone as
  # a text badge as well as a color, without inferring status from entity text.
  # A collapsible section is folded until the page's sections are unfolded: its heading
  # alone, marked ▸; unfolded, ▾ above its blocks.
  defp markup(%Section{title: title, collapsible: true}, children, model, width, room) do
    mark = if model.unfolded, do: "▾ ", else: "▸ "
    rule = String.duplicate("─", max(width - String.length(title) - 5, 0))
    heading = [[{:bold, " " <> mark <> title}, {:dim, " " <> rule}]]

    if model.unfolded,
      do: heading ++ [[]] ++ nodes(children, model, width, room),
      else: heading
  end

  defp markup(%Section{title: title}, children, model, width, room) do
    rule = String.duplicate("─", max(width - String.length(title) - 3, 0))
    [[{:bold, " " <> title}, {:dim, " " <> rule}], []] ++ nodes(children, model, width, room)
  end

  # The page's details: compact, under a heading, whether beside the page or under it.
  defp markup(%Part{role: "details", title: title}, children, model, width, room),
    do: markup(%Section{title: title}, children, model, width, room)

  defp markup(%Part{title: title}, children, model, width, room) do
    inner = width - 4
    label = if title, do: "─ " <> title <> " ", else: ""
    top = " ┌" <> label <> String.duplicate("─", max(inner - String.length(label), 0)) <> "┐"

    lines =
      for line <- nodes(children, model, inner, room) do
        line = fit(line, inner)
        used = Enum.reduce(line, 0, fn {_, text}, used -> used + display_width(text) end)
        [{:dim, " │"} | line] ++ [{:plain, String.duplicate(" ", inner - used)}, {:dim, "│"}]
      end

    [[{:dim, top}]] ++ lines ++ [[{:dim, " └" <> String.duplicate("─", inner) <> "┘"}]]
  end

  defp markup(%Highlight{tone: tone}, children, model, width, room) do
    {style, label} =
      case tone do
        "ok" -> {:ok, "OK"}
        "pending" -> {:pending, "Pending"}
        "error" -> {:error, "Error"}
        "info" -> {:info, "Info"}
        other -> {:dim, other || "Status"}
      end

    badge = for line <- list_wrap("[#{label}]", width), do: [{style, line}]
    badge ++ nodes(children, model, width, max(room - length(badge), 1))
  end

  # One physical line per item; titles take priority over inline metadata.
  defp block(%ListBlock{} = list, at, model, width, _room) do
    rows = list.rows || []

    heading =
      if list.title do
        title = list.title <> " · #{length(rows)}"

        if width >= 5 do
          inner = width - 4

          lines =
            for line <- list_wrap(title, inner),
                do: [
                  {:border, "│ "},
                  {:bold, line},
                  {:border, String.duplicate(" ", inner - String.length(line)) <> " │"}
                ]

          [[{:border, "┌" <> String.duplicate("─", width - 2) <> "┐"}]] ++
            lines ++ [[{:border, "└" <> String.duplicate("─", width - 2) <> "┘"}]]
        else
          for line <- list_wrap(title, width), do: [{:bold, line}]
        end
      else
        []
      end

    now = model.now || DateTime.utc_now()

    prepared =
      Enum.map(rows, fn row ->
        {single_line(row.id), single_line(row.label), row_summary(row.detail)}
      end)

    pending = Enum.map(rows, &(&1.pending == true))
    tones = Enum.map(rows, & &1.tone)
    ages = Enum.map(rows, &age(&1.since, now))

    {ids, titles, summaries} =
      Enum.reduce(prepared, {0, 0, 0}, fn {id, title, summary}, {ids, titles, summaries} ->
        {max(ids, display_width(id)), max(titles, display_width(title)),
         max(summaries, display_width(summary))}
      end)

    marker_room = if width >= 3, do: 3, else: 1
    available = max(width - marker_room, 0)

    dot_room =
      if Enum.any?(tones, &Map.has_key?(@tone_styles, &1)) and available >= 8, do: 2, else: 0

    available = available - dot_room
    id_room = min(ids, min(div(available, 3), max(available - 3, 0)))
    id_gap = if id_room > 0, do: 2, else: 0
    available = max(available - id_room - id_gap, 0)
    # Control marks a row whose fact a write changed and Flow has not yet settled; the
    # mark goes beside the label, and the row's values stay as Control sent them.
    pending_room =
      if Enum.any?(pending) and available >= display_width(@pending_mark) + 8,
        do: display_width(@pending_mark),
        else: 0

    available = available - pending_room
    # How long each row has been where it stands, right-aligned before the title; a narrow
    # list drops it before it cuts a title (below `@title_floor`).
    age_width = ages |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)

    age_room =
      with true <- age_width > 0,
           {_, _, title_room} = columns(available - age_width - 2, titles, summaries),
           true <- title_room >= min(titles, @title_floor) do
        age_width + 2
      else
        _ -> 0
      end

    {summary_room, _summary_gap, title_room} = columns(available - age_room, titles, summaries)

    content =
      [prepared, pending, tones, ages]
      |> Enum.zip()
      |> Enum.with_index()
      |> Enum.map(fn {{{id, title, summary}, pending?, tone, age}, i} ->
        style = if at + i == model.selected, do: :selected, else: :bold
        marker = if style == :selected, do: "›", else: " "
        marker = if marker_room == 3, do: " " <> marker <> " ", else: marker
        identity = if id_room > 0, do: cell_pad(id, id_room) <> "  ", else: ""
        metadata = cell_cut(summary, summary_room)

        # A pending row is muted, its mark in the pending colour; a done one is muted too.
        {label_style, mark_style, detail} =
          cond do
            pending? -> pending_styles(style)
            tone == "done" -> {muted(style), style, :muted}
            true -> {style, style, :dim}
          end

        # The dot keeps its own cell in its tone's colours on every row, the selected one
        # included, so the selection bar runs around it and it still says where it stands.
        dot =
          cond do
            dot_room == 0 -> []
            not Map.has_key?(@tone_styles, tone) -> [{label_style, "  "}]
            true -> [{@tone_styles[tone], @dot}, {label_style, " "}]
          end

        aged =
          if age_room > 0,
            do: [
              {if(style == :selected, do: label_style, else: detail),
               String.pad_leading(age, age_width) <> "  "}
            ],
            else: []

        mark =
          cond do
            pending_room == 0 -> []
            pending? -> [{mark_style, @pending_mark}]
            metadata == "" -> []
            true -> [{style, String.duplicate(" ", pending_room)}]
          end

        coalesce(
          [{label_style, marker}] ++
            dot ++
            [{label_style, identity}] ++
            aged ++
            [{label_style, cell_pad(title, title_room)}] ++
            mark ++ if(metadata == "", do: [], else: [{detail, "  " <> metadata}])
        )
      end)

    indent = String.duplicate(" ", min(3, max(width - 1, 0)))

    empty =
      for line <- list_wrap(list.empty || "Nothing here.", width - String.length(indent)),
          do: [{:dim, indent <> line}]

    heading ++ if(rows == [], do: empty, else: content)
  end

  # The page's groups as a filter row, each with its count, the one shown highlighted
  # (`:active`, drawn as the selection but not the selected row the page follows);
  # Control binds the keys that move between them. Wraps where the row is too wide.
  defp block(%AtlasTui.Blocks.Groups{groups: groups}, _at, _model, width, _room) do
    groups
    |> Enum.map(fn group ->
      {if(group.active, do: :active, else: :dim), " #{single_line(group.label)} #{group.count} "}
    end)
    |> Enum.reduce([], fn {_, text} = segment, lines ->
      case lines do
        [line | done] ->
          used = Enum.reduce(line, 0, fn {_, t}, used -> used + display_width(t) end)

          if used + 1 + display_width(text) <= width,
            do: [line ++ [{:dim, "·"}, segment] | done],
            else: [[segment], line | done]

        [] ->
          [[segment]]
      end
    end)
    |> Enum.reverse()
  end

  # Control's single choice, as a panel that asks for a decision: the question in a bar,
  # why the recommendation, the options one line each in Control's order (the one Enter
  # answers marked ▸ and selected), what the selected one means in a box under them, and
  # the keys there are. A narrow panel drops the labels before it cuts an option's text.
  defp block(%SingleChoice{} = choice, _at, model, width, _room) do
    content = max(width - 5, 1)
    at = Model.chosen(choice, model.choice)

    why =
      case single_line(choice.rationale) do
        "" -> []
        text -> [[]] ++ hanging("Why: ", text, content, :dim, :dim)
      end

    rows =
      choice.options
      |> Enum.with_index()
      |> Enum.map(fn {option, i} ->
        label =
          cond do
            option.id == choice.recommended -> {:ok, "★ recommended"}
            option.note -> {:warning, "decline · note"}
            true -> nil
          end

        {Model.option_key(option, i), option.text, label}
      end)

    detail = choice_detail(Enum.at(choice.options, at), content)
    keys = choice_keys(choice, at, model, content)

    body =
      why ++
        [[]] ++
        choice_rows(rows, at, content) ++
        if(detail == [], do: [], else: [[]] ++ detail) ++
        if(keys == [], do: [], else: [[]] ++ keys)

    decision_frame("YOUR DECISION", choice.question, nil, body, width)
  end

  # Control's panel where its owner decides, in the frame of the single choice: what is
  # asked of them (`heading`) and the title in the bar, how many beside it; the byline;
  # then what it is judged on: its items (the selected one marked ▸, its details framed
  # under them), its checks (each with a mark of its state), a box (an error's in the error
  # colour); in a choice its answers one line each, the selected one's detail framed; and
  # the keys there are, as far as Control projects them.
  defp block(%Panel{} = panel, _at, model, width, _room) do
    content = max(width - 5, 1)
    choices = Model.panel_choices(panel)
    at = Model.panel_chosen(panel, model.choice)
    selected = Enum.at(choices, at)

    byline =
      case byline(panel.byline || [], DateTime.utc_now()) do
        "" -> []
        text -> Enum.map(detail_wrap(text, content), &[{:dim, &1}])
      end

    # In a choice the arrows select its answers (`Model.panel_choices/1`).
    choosing = choices != [] and choices == panel.answers

    choice =
      if choosing do
        rows =
          for answer <- choices do
            label =
              cond do
                answer.recommended == true -> {:ok, "★ recommended"}
                answer.note == true -> {:warning, "· note"}
                true -> nil
              end

            {answer.key, answer.label, label}
          end

        detail = String.trim(selected.detail || "")

        detail =
          if detail == "",
            do: [],
            else: boxed(text_lines(detail, content - 4), content, :border)

        [choice_rows(rows, at, content), detail]
      else
        []
      end

    sections =
      [
        item_rows(panel.items || [], at, content),
        item_details(Enum.at(panel.items || [], at), content),
        check_rows(panel.checks || []),
        panel_box(panel.box, content)
      ] ++ choice ++ [panel_keys(panel, choosing, choices, selected, model, content)]

    body = byline ++ Enum.flat_map(sections, &if(&1 == [], do: [], else: [[] | &1]))
    decision_frame(panel.heading, panel.title, panel.aside, body, width)
  end

  # A to-do step by step, as a panel like the single choice's: the work in a bar with how
  # far its owner is, why and since when, the done steps one line each (✓), the current
  # one framed with its commands each on its own line beside a bar, the later ones one
  # faint line each, and the keys: Control's actions and c/C/y to copy.
  defp block(%Steps{} = block, _at, _model, width, _room) do
    inner = max(width - 3, 1)
    content = max(inner - 2, 1)
    total = length(block.steps)

    progress =
      if block.current > total, do: "all #{total} done", else: "step #{block.current} of #{total}"

    why =
      case [single_line(block.why), age(block.since)] |> Enum.reject(&(&1 == "")) do
        [] -> []
        [why, age] -> [[]] ++ hanging("Why: ", why <> " · " <> age, content, :dim, :dim)
        [text] -> [[]] ++ hanging("Why: ", text, content, :dim, :dim)
      end

    rows =
      Enum.flat_map(block.steps, fn step ->
        number = "#{step.n}. "
        # A closed step shows its first line: the rest is how, for when it is current.
        head = step.text |> String.split("\n") |> hd() |> single_line()

        cond do
          step.n < block.current ->
            [fit([{:ok, "✓"}, {:dim, " " <> number <> head}], content)]

          step.n == block.current ->
            current_step(step, content)

          true ->
            [fit([{:dim, "  " <> number <> head}], content)]
        end
      end)

    keys = steps_keys(block, content)
    body = why ++ [[]] ++ rows ++ if(keys == [], do: [], else: [[]] ++ keys)

    framed =
      for line <- body,
          do: [{:frame, " │ "} | pad_line(fit(line, content), content)] ++ [{:frame, " │"}]

    title = "◆ TO DO FOR YOU  " <> single_line(block.title)
    room = inner - 2 - display_width(progress) - 2
    bar = " " <> cell_pad(title, max(room, 1)) <> "  " <> progress <> " "

    [[{:frame, " ┌" <> String.duplicate("─", inner) <> "┐"}]] ++
      [[{:frame, " │"}, {:header, cell_pad(bar, inner)}, {:frame, "│"}]] ++
      framed ++ [[{:frame, " └" <> String.duplicate("─", inner) <> "┘"}]]
  end

  # Values keep their line breaks and blank lines; a heading line (`#`) is bold. A value
  # without a label (prose, such as what a worker said) takes the whole width.
  defp block(%Item{} = item, _at, _model, width, _room) do
    fields =
      Enum.flat_map(item.fields, fn pair ->
        label = single_line(pair.label)
        bare = label == ""
        stacked = not bare and (width < 40 or display_width(label) >= @label_width)

        padding =
          cond do
            bare -> min(3, max(width - 2, 0))
            stacked -> min(5, max(width - 2, 0))
            true -> @label_width + 3
          end

        indent = String.duplicate(" ", padding)
        value_width = max(width - padding, 1)
        [first | rest] = detail_wrap(pair.value || "—", value_width)

        heading =
          cond do
            bare ->
              [[{:plain, indent}, text_row(first)]]

            stacked ->
              prefix = String.duplicate(" ", min(3, max(width - 2, 0)))

              Enum.map(detail_wrap(label <> ":", max(width - byte_size(prefix), 1)), fn line ->
                [{:dim, prefix <> line}]
              end) ++ [[{:plain, indent}, text_row(first)]]

            true ->
              [[{:dim, "   " <> cell_pad(label, @label_width)}, text_row(first)]]
          end

        origin =
          for line <- detail_wrap(origin_text(pair.origin), value_width),
              line != "",
              do: [{:plain, indent}, {:dim, line}]

        heading ++ Enum.map(rest, &[{:plain, indent}, text_row(&1)]) ++ origin
      end)

    title(item.title, width) ++ [[]] ++ fields
  end

  # A form that does not fit gives its focused multi-line input fewer rows, down to a few.
  defp block(%Form{} = form, _at, model, width, room) do
    lines = form_lines(form, model, width, :all)
    over = length(lines) - room

    case focused_rows(form, model, width) do
      rows when over > 0 and rows > @least_rows ->
        form_lines(form, model, width, max(rows - over, @least_rows))

      _ ->
        lines
    end
  end

  defp block(%Confirm{} = confirm, _at, _model, width, _room) do
    title(confirm.title, width) ++
      [[]] ++
      Enum.map(Text.wrap(confirm.text, width - 4), &[{:plain, "   " <> &1}])
  end

  # An agent's plan: what was asked, what it says, and each step with the values of the
  # form it fills. The selected step is the one space, e and the arrows act on.
  defp block(%Plan{} = plan, _at, model, width, _room) do
    about =
      [
        {"You asked", plan.request},
        {"Before", plan.before},
        {"By", plan.by},
        {"It says", plan.summary}
      ]
      |> Enum.reject(fn {_, value} -> value in [nil, ""] end)
      |> Enum.flat_map(fn {label, value} ->
        [first | rest] = Text.wrap(value, width - @label_width - 4)

        [
          [{:dim, "   " <> pad(label, @label_width)}, {:plain, first}]
          | Enum.map(rest, &[{:plain, String.duplicate(" ", @label_width + 3) <> &1}])
        ]
      end)

    steps =
      plan.steps
      |> Enum.with_index()
      |> Enum.flat_map(fn {step, i} ->
        selected = plan.state == "proposed" and i == model.steps.selected
        step_lines(step, selected, width)
      end)

    title(plan.title, width) ++ [[]] ++ about ++ [[]] ++ steps
  end

  defp block(%Fallback{type: type}, _at, _model, _width, _room),
    do: [[{:dim, "   (a #{type || "?"} block this TUI cannot show)"}]]

  # The frame of a decision: a bar with what is asked (`heading`) and its title, `aside`
  # at its right; `body` under it, each line fitted inside.
  defp decision_frame(heading, title, aside, body, width) do
    inner = max(width - 3, 1)
    content = max(inner - 2, 1)

    framed =
      for line <- body,
          do: [{:frame, " │ "} | pad_line(fit(line, content), content)] ++ [{:frame, " │"}]

    bar =
      for line <- decision_bar(heading, title, aside, inner),
          do: [{:frame, " │"}, {:header, cell_pad(line, inner)}, {:frame, "│"}]

    [[{:frame, " ┌" <> String.duplicate("─", inner) <> "┐"}]] ++
      bar ++ framed ++ [[{:frame, " └" <> String.duplicate("─", inner) <> "┘"}]]
  end

  # The current step in a box: ▸, its text, and its commands each on its own line behind
  # a bar, in plain text (no background: the same in both themes).
  defp current_step(step, width) do
    inner = max(width - 4, 1)
    number = "#{step.n}. "
    indent = String.duplicate(" ", 2 + display_width(number))
    [first | rest] = detail_wrap(String.trim(step.text), max(inner - display_width(indent), 1))

    lines =
      [[{:bold, "▸ " <> number <> first}] | Enum.map(rest, &[{:bold, indent <> &1}])] ++
        if(step.commands == [], do: [], else: [[]]) ++
        Enum.flat_map(step.commands, fn command ->
          for line <- detail_wrap(command, max(inner - 2 - display_width(indent), 1)),
              do: [{:plain, indent}, {:border, "│ "}, {:plain, line}]
        end)

    rule = String.duplicate("─", max(width - 2, 0))

    [[{:border, "┌" <> rule <> "┐"}]] ++
      Enum.map(lines, &([{:border, "│ "} | pad_line(fit(&1, inner), inner)] ++ [{:border, " │"}])) ++
      [[{:border, "└" <> rule <> "┘"}]]
  end

  # Control's actions on their keys, then what c, C and y copy when the step has commands.
  defp steps_keys(block, width) do
    copies =
      case Model.current_step(block) do
        %{commands: [_ | _]} -> [{"c", "copy"}, {"C", "copy next"}, {"y", "copy all"}]
        _ -> []
      end

    shown = %{"Enter" => "Enter", "Down" => "↓", "Up" => "↑"}

    (Enum.map(block.actions || [], &{Map.get(shown, &1.key, &1.key), &1.label}) ++ copies)
    |> Enum.map(fn {key, what} -> [{:key, key}, {:dim, " " <> what}] end)
    |> Enum.reduce([], fn item, lines ->
      used = fn line -> Enum.reduce(line, 0, fn {_, text}, n -> n + display_width(text) end) end

      case lines do
        [line | done] ->
          if used.(line) + 3 + used.(item) <= width,
            do: [line ++ [{:dim, " · "} | item] | done],
            else: [item, line | done]

        [] ->
          [item]
      end
    end)
    |> Enum.reverse()
  end

  # How long ago `since` (ISO 8601) was: "4m", "3h", "2d"; empty without one.
  defp age(since) do
    case DateTime.from_iso8601(since || "") do
      {:ok, at, _} ->
        seconds = max(DateTime.diff(DateTime.utc_now(), at), 0)

        cond do
          seconds < 3600 -> "#{div(seconds, 60)}m"
          seconds < 86_400 -> "#{div(seconds, 3600)}h"
          true -> "#{div(seconds, 86_400)}d"
        end

      _ ->
        ""
    end
  end

  # List prefixes and part frames can leave fewer than ten columns. Use the
  # actual budget; Text.wrap's reading/editor defaults remain unchanged.
  defp list_wrap(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      for {start, length} <- Text.rows(line, max(width, 1)),
          do: line |> String.slice(start, length) |> String.trim_trailing()
    end)
  end

  # A decision's bar: what is asked of its owner, the title beside it, wrapped under the
  # title, and `aside` at the right of its first line; in a bar too narrow for both, the
  # title (and `aside`) under the heading.
  defp decision_bar(heading, title, aside, inner) do
    lead = " ◆ " <> single_line(heading) <> "   "
    title = single_line(title)
    aside = single_line(aside)
    aside_room = if aside == "", do: 0, else: display_width(aside) + 2
    room = inner - display_width(lead) - 1 - aside_room

    cond do
      title == "" and aside == "" ->
        [String.trim_trailing(lead)]

      room >= 12 ->
        indent = String.duplicate(" ", display_width(lead))
        [first | rest] = detail_wrap(title, room)
        first = lead <> first

        first =
          if aside == "",
            do: first,
            else: cell_pad(first, inner - aside_room + 1) <> aside <> " "

        [first | Enum.map(rest, &(indent <> &1))]

      true ->
        [String.trim_trailing(lead)] ++
          Enum.map(detail_wrap(title, max(inner - 2, 1)), &(" " <> &1)) ++
          if(aside == "", do: [], else: [" " <> aside])
    end
  end

  # The options in fixed columns: the marker (▸ on the selected one), the key, the text,
  # and a label at the right (`{style, text}` or nil): the recommended one, one given with
  # a note. The labels go when the texts would not fit beside them.
  defp choice_rows(rows, at, width) do
    rows = for {key, text, label} <- rows, do: {single_line(key), single_line(text), label}
    widest = fn texts -> Enum.reduce(texts, 0, &max(display_width(&1), &2)) end
    key_width = widest.(for {key, _, _} <- rows, do: key)
    text_width = widest.(for {_, text, _} <- rows, do: text)
    label_width = widest.(for {_, _, {_, label}} <- rows, do: label)
    lead = 2 + key_width + 1

    label_room =
      if label_width > 0 and lead + text_width + 2 + label_width <= width,
        do: label_width,
        else: 0

    text_room = if label_room > 0, do: width - lead - 2 - label_room, else: width - lead

    rows
    |> Enum.with_index()
    |> Enum.map(fn {{key, text, label}, i} ->
      marker = if i == at, do: "▸ ", else: "  "
      key = String.duplicate(" ", key_width - display_width(key)) <> key
      text = " " <> cell_pad(text, text_room)

      {gap, style, label} =
        case label do
          {style, label} when label_room > 0 ->
            {"  " <> String.duplicate(" ", label_room - display_width(label)), style, label}

          _ ->
            {if(label_room > 0, do: String.duplicate(" ", label_room + 2), else: ""), :plain, ""}
        end

      if i == at,
        do: [{:selected, marker <> key <> text <> gap <> label}],
        else: [{:plain, marker}, {:bold, key}, {:plain, text <> gap}, {style, label}]
    end)
  end

  # What the selected option means, framed: its rule and what then follows; for one given
  # with a note (a decline), or one without either, its details.
  defp choice_detail(option, width) do
    inner = max(width - 4, 1)

    parts =
      [{"Rule", option.rule}, {"Then", option.consequences}]
      |> Enum.map(fn {label, text} -> {label, String.trim(text || "")} end)
      |> Enum.reject(fn {_, text} -> text == "" end)

    details = String.trim(option.details || "")

    lines =
      cond do
        parts != [] and option.note != true ->
          Enum.flat_map(parts, fn {label, text} ->
            hanging(label <> "  ", text, inner, :dim, :plain)
          end)

        details != "" ->
          text_lines(details, inner)

        true ->
          []
      end

    boxed(lines, width, :border)
  end

  # `lines` in a frame of `width` (drawn in `frame`), each fitted inside; unframed where
  # too narrow for a frame.
  defp boxed([], _width, _frame), do: []
  defp boxed(lines, width, _frame) when width < 12, do: lines

  defp boxed(lines, width, frame) do
    inner = width - 4
    rule = String.duplicate("─", width - 2)

    [[{frame, "┌" <> rule <> "┐"}]] ++
      Enum.map(lines, &([{frame, "│ "} | pad_line(fit(&1, inner), inner)] ++ [{frame, " │"}])) ++
      [[{frame, "└" <> rule <> "┘"}]]
  end

  defp text_lines(text, width), do: Enum.map(detail_wrap(text, max(width, 1)), &[{:plain, &1}])

  # The keys that answer, as far as Control projects them: the arrows and Enter select
  # and answer through an option's own key (`AtlasTui.Interactions`), so Enter is named
  # only when the selected option's key is an action now, and 0 only when it is one.
  defp choice_keys(%SingleChoice{options: options}, at, model, width) do
    keys = projected_keys(model)

    [
      length(options) > 1 && {"↑↓", "choose"},
      MapSet.member?(keys, Model.option_key(Enum.at(options, at), at)) && {"Enter", "answer"},
      MapSet.member?(keys, "0") && {"0", "recommended"}
    ]
    |> Enum.filter(& &1)
    |> Enum.map(fn {key, what} -> [{:key, key}, {:dim, " " <> what}] end)
    |> key_lines(width)
  end

  # The keys the page's actions take now.
  defp projected_keys(model) do
    for action <- AtlasTui.Interactions.active(model),
        action["props"]["available"],
        key <- action["props"]["keys"],
        into: MapSet.new(),
        do: key
  end

  # Keys (each a line of segments) one after the other, " · " between, wrapped at `width`.
  defp key_lines(items, width) do
    used = fn line -> Enum.reduce(line, 0, fn {_, text}, n -> n + display_width(text) end) end

    items
    |> Enum.reduce([], fn item, lines ->
      case lines do
        [line | done] ->
          if used.(line) + 3 + used.(item) <= width,
            do: [line ++ [{:dim, " · "} | item] | done],
            else: [item, line | done]

        [] ->
          [item]
      end
    end)
    |> Enum.reverse()
  end

  # A panel's byline: its clauses joined, each with how long ago its `since` was.
  defp byline(clauses, now) do
    clauses
    |> Enum.map(fn clause ->
      [single_line(clause.text), age(clause.since, now)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" ")
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" · ")
  end

  # A panel's items, one line each: the marker (▸ on the selected one), the key, the label.
  defp item_rows([], _at, _width), do: []

  defp item_rows(items, at, width) do
    key_width = Enum.reduce(items, 0, &max(display_width(single_line(&1.key)), &2))

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, i} ->
      key = cell_pad(single_line(item.key), key_width)
      label = "  " <> single_line(item.label)

      if i == at,
        do: [{:selected, cell_pad("▸ " <> key <> label, width)}],
        else: [{:plain, "  "}, {:bold, key}, {:plain, label}]
    end)
  end

  # The details of the selected item, framed, each under its label.
  defp item_details(%PanelItem{details: [_ | _] = details}, width) do
    inner = max(width - 4, 1)
    label_width = Enum.reduce(details, 0, &max(display_width(single_line(&1.label)), &2))

    details
    |> Enum.flat_map(fn pair ->
      label = cell_pad(single_line(pair.label), label_width) <> " "
      hanging(label, String.trim(pair.value || ""), inner, :dim, :plain)
    end)
    |> boxed(width, :border)
  end

  defp item_details(_item, _width), do: []

  # Its state as a mark as well as a colour.
  @check_marks %{
    "success" => {:ok, "✓"},
    "error" => {:error, "✗"},
    "pending" => {:pending, "…"}
  }

  # A panel's checks, one line each: the mark of its state, the label, what it says.
  defp check_rows(checks) do
    label_width = Enum.reduce(checks, 0, &max(display_width(single_line(&1.label)), &2))

    for check <- checks do
      {style, mark} = @check_marks[check.state] || {:dim, "—"}

      [
        {style, mark},
        {:plain, " " <> cell_pad(single_line(check.label), label_width) <> "  "},
        {:plain, single_line(check.text)}
      ]
    end
  end

  # A panel's box: its title over its text, framed; an error's in the error colour.
  defp panel_box(nil, _width), do: []

  defp panel_box(%Box{} = box, width) do
    {frame, heading} = if box.tone == "error", do: {:error_frame, :error}, else: {:border, :bold}
    inner = max(width - 4, 1)

    title =
      case single_line(box.title) do
        "" -> []
        title -> [[{heading, title}]]
      end

    boxed(title ++ text_lines(box.text || "", inner), width, frame)
  end

  # A panel's keys, as far as Control projects them: its answers (yes, or no with a note)
  # where they are no choice; in a choice, the arrows, Enter on the selected answer and 0;
  # with items, the arrows and Enter that opens one; what its actions and links open.
  defp panel_keys(panel, choosing, choices, selected, model, width) do
    keys = projected_keys(model)
    on = &MapSet.member?(keys, &1)

    answers =
      for answer <- panel.answers || [], not choosing, on.(answer.key) do
        if answer.note == true,
          do: [{:key, answer.key}, {:warning, " " <> single_line(answer.label) <> " · note"}],
          else: [{:key, answer.key}, {:ok, " " <> single_line(answer.label)}]
      end

    opens =
      for open <- (panel.actions || []) ++ (panel.links || []),
          on.(open.key),
          do: [{:key, open.key}, {:dim, " " <> single_line(open.label)}]

    moves =
      [
        length(choices) > 1 && {"↑↓", "choose"},
        match?(%PanelItem{}, selected) && {"Enter", "open"},
        choosing && on.(selected.key) && {"Enter", "answer"},
        choosing && on.("0") && {"0", "recommended"}
      ]
      |> Enum.filter(& &1)
      |> Enum.map(fn {key, what} -> [{:key, key}, {:dim, " " <> what}] end)

    key_lines(if(choosing, do: moves ++ opens, else: answers ++ opens ++ moves), width)
  end

  # `label` before the first line of `text`, the rest under it; under the label when
  # too little room is left beside it.
  defp hanging(label, text, width, label_style, text_style) do
    room = width - display_width(label)

    if room >= 12 do
      indent = String.duplicate(" ", display_width(label))
      [first | rest] = detail_wrap(text, room)

      [
        [{label_style, label}, {text_style, first}]
        | Enum.map(rest, &[{:plain, indent}, {text_style, &1}])
      ]
    else
      [
        [{label_style, String.trim_trailing(label)}]
        | Enum.map(detail_wrap(text, width), &[{text_style, &1}])
      ]
    end
  end

  @step_marks %{
    "proposed" => {:ok, "[✓]"},
    "dropped" => {:dim, "[ ]"},
    "blocked" => {:error, "[!]"},
    "running" => {:pending, "[…]"},
    "stored" => {:ok, "[✓]"},
    "refused" => {:error, "[✗]"},
    "not_run" => {:dim, "[-]"}
  }

  # A step: its mark and the form's title, its values, why, and what became of it.
  defp step_lines(step, selected, width) do
    {tone, mark} = @step_marks[step.state] || {:dim, "[?]"}
    dim = step.state in ["dropped", "not_run"]
    head_style = if selected, do: :selected, else: if(dim, do: :dim, else: :bold)
    marker = if selected, do: " › ", else: "   "

    head = [
      {head_style, marker},
      {if(selected, do: :selected, else: tone), mark},
      {head_style, " #{step.n}. #{step.label}"}
    ]

    values =
      for input <- step.inputs || [],
          row <- value_rows(input, width) do
        row
      end

    why =
      if step.why,
        do: Enum.map(Text.wrap("why: " <> step.why, width - 9), &[{:dim, "       " <> &1}]),
        else: []

    detail =
      case step.detail do
        nil ->
          []

        text ->
          style =
            %{"blocked" => :error, "refused" => :error, "not_run" => :dim}[step.state] || :ok

          Enum.map(Text.wrap(text, width - 9), &[{style, "       " <> &1}])
      end

    [head] ++ values ++ why ++ detail ++ [[]]
  end

  # A value of a step, at most a few rows; the rest is one edit (e) away.
  @value_rows 3
  defp value_rows(input, width) do
    label = "       " <> pad(input.label, @label_width - 3) <> " "
    rows = Text.wrap(input.value || "—", width - String.length(label) - 2)
    shown = Enum.take(rows, @value_rows)

    shown =
      if length(rows) > @value_rows, do: List.update_at(shown, -1, &(&1 <> " …")), else: shown

    indent = String.duplicate(" ", String.length(label))

    shown
    |> Enum.with_index()
    |> Enum.map(fn
      {row, 0} -> [{:dim, label}, {:plain, row}]
      {row, _} -> [{:plain, indent <> row}]
    end)
  end

  defp title(text, width), do: Enum.map(Text.wrap(text, width - 2), &[{:bold, " " <> &1}])

  defp text_row("#" <> _ = row), do: {:bold, row}
  defp text_row(row), do: {:plain, row}

  defp form_lines(%Form{} = form, model, width, rows) do
    items = Model.focusable(form)
    focus = min(model.focus, length(items) - 1)

    errors =
      Enum.flat_map(form.errors || [], fn error ->
        [first | rest] = Text.wrap(error, width - 7)
        [[{:error, "   ! " <> first}] | Enum.map(rest, &[{:error, "     " <> &1}])]
      end)

    inputs =
      Enum.flat_map(form.inputs, fn input ->
        focused = Enum.at(items, focus) == input
        value = model.values[input.name] || ""

        input_lines(
          input,
          value,
          if(focused, do: model.cursor),
          focused,
          field_width(width),
          rows
        )
      end)

    buttons = [
      [
        {:plain, "   "},
        {if(Enum.at(items, focus) == :submit, do: :selected, else: :bold),
         "[ #{form.submit_label} ]"},
        {:plain, "  "},
        {if(Enum.at(items, focus) == :cancel, do: :selected, else: :plain), "[ Cancel ]"}
      ]
    ]

    hint =
      case Enum.at(items, focus) do
        %Input{hint: hint} when is_binary(hint) ->
          Enum.map(Text.wrap(hint, width - 6), &[{:dim, "   " <> &1}])

        _ ->
          []
      end

    title(form.title, width) ++
      [[]] ++
      errors ++ if(errors == [], do: [], else: [[]]) ++ inputs ++ [[]] ++ buttons ++ [[]] ++ hint
  end

  # The width inside a text field's brackets.
  defp field_width(width), do: max(width - @label_width - 6, 12)

  # How many rows the focused multi-line input has, all of it shown.
  defp focused_rows(form, model, width) do
    case Enum.at(Model.focusable(form), min(model.focus, length(Model.focusable(form)) - 1)) do
      %Input{kind: "multiline", name: name} ->
        length(visual_rows(model.values[name] || "", field_width(width)))

      _ ->
        0
    end
  end

  defp input_lines(input, value, cursor, focused, inner, rows) do
    label = "   " <> pad(input.label <> if(input.required, do: " *", else: ""), @label_width)
    indent = String.duplicate(" ", String.length(label))

    lines =
      case input.kind do
        # Shown, never changed (an id).
        "readonly" ->
          Enum.map(Text.wrap(value, inner), &[{:plain, &1}])

        kind when kind in ["choice", "boolean"] ->
          shown = Enum.find_value(input.choices || [], value, &(&1.value == value && &1.label))
          [[{if(focused, do: :selected, else: :plain), "‹ #{shown} ›"}]]

        "multiline" ->
          editor(value, cursor, focused, inner, if(focused, do: rows, else: @resting_rows))

        # One line of text, wrapped when it is longer than the field; typing goes at its end.
        _ ->
          style = if focused, do: :selected, else: :plain
          rows = for {at, len} <- Text.rows(value, inner - 1), do: String.slice(value, at, len)
          rows = if focused, do: List.update_at(rows, -1, &(&1 <> "▏")), else: rows
          Enum.map(rows, &[{style, "[" <> pad(&1, inner) <> "]"}])
      end

    lines
    |> Enum.with_index()
    |> Enum.map(fn
      {line, 0} -> [{:dim, label} | line]
      {[{:dim, _} | _] = line, _} -> line
      {line, _} -> [{:plain, indent} | line]
    end)
  end

  # Every row the text takes in the field: `{line, start, length}`.
  defp visual_rows(value, inner) do
    value
    |> Text.lines()
    |> Enum.with_index()
    |> Enum.flat_map(fn {line, l} ->
      for {at, len} <- Text.rows(line, inner - 1), do: {l, at, len}
    end)
  end

  # A text area: the rows around the cursor when it has the focus (the cursor is the
  # reversed cell), else the first rows; a line under it says what is out of sight.
  defp editor(value, cursor, focused, inner, room) do
    lines = Text.lines(value)
    all = visual_rows(value, inner)
    {cl, cc} = Text.cursor(value, cursor)

    at =
      Enum.find_index(all, fn {l, start, len} -> l == cl and cc < start + len end) ||
        Enum.find_index(all, fn {l, start, len} -> l == cl and cc == start + len end) || 0

    room = if room == :all, do: length(all), else: room
    start = if focused, do: at - div(room, 2), else: 0
    start = start |> min(length(all) - room) |> max(0)
    shown = Enum.slice(all, start, room)

    edge = if focused, do: :selected, else: :plain

    rows =
      Enum.map(shown, fn {l, from, len} = row ->
        text = lines |> Enum.at(l) |> String.slice(from, len)

        if focused and row == Enum.at(all, at) do
          {before, rest} = String.split_at(text, cc - from)
          {under, after_} = if rest == "", do: {" ", ""}, else: String.split_at(rest, 1)
          tail = pad(after_, inner - String.length(before) - 1)
          [{edge, "["}, {:plain, before}, {:cursor, under}, {:plain, tail}, {edge, "]"}]
        else
          [{edge, "["}, {:plain, pad(text, inner)}, {edge, "]"}]
        end
      end)

    empty = [{edge, "["}, {:plain, pad("", inner)}, {edge, "]"}]
    rows = rows ++ List.duplicate(empty, max(@least_rows - length(rows), 0))
    above = start
    below = length(all) - start - length(shown)

    more =
      [above > 0 && "↑ #{above} more above", below > 0 && "↓ #{below} more below"]
      |> Enum.filter(& &1)

    if more == [],
      do: rows,
      else: rows ++ [[{:dim, String.duplicate(" ", @label_width + 4) <> Enum.join(more, " · ")}]]
  end

  # A page longer than the screen: the focus of a form, or the selected row of a list,
  # stays in sight until the page is scrolled by hand (a page about one fact starts at
  # its top); arrows follow the selection again. Its bounds are kept as the viewport of
  # the page not in parts (`nil`), so paging moves on from what is shown.
  defp window(lines, model, room) when length(lines) > room do
    last = length(lines) - room

    focus = Enum.find_index(lines, &cursor_line?/1) || Enum.find_index(lines, &selected_line?/1)
    follow = focus != nil and (model.scroll == nil or Model.form(model) != nil)
    start = if follow, do: focus - div(room, 2), else: model.scroll || 0
    start = start |> min(last) |> max(0)

    {Enum.slice(lines, start, room), %{start: start, last: last, step: max(room - 1, 1)}}
  end

  defp window(lines, _model, _room), do: {lines, nil}

  defp console_notice(%Model{console: %{error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error <> " · retrying boot"}]

  defp console_notice(%Model{console: %{action_error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error}]

  defp console_notice(%Model{console: %{key_buffer: buffer}}) when buffer != "",
    do: [{:dim, "Shortcut: #{buffer} · Enter to select · Esc to cancel"}]

  defp console_notice(%Model{console: %{key_prefix: prefix}}) when prefix != "",
    do: [{:dim, "#{prefix} … · Esc to cancel"}]

  defp console_notice(model), do: notice(model)

  # Footer

  defp footer_help(%Model{console: %{expected: target, restoring: false}, path: path})
       when target != nil and target != path,
       do: []

  defp footer_help(%Model{console: %{legend: legend}}) when legend != nil, do: []

  defp footer_help(%Model{ask: text}) when is_binary(text),
    do: [[{:bold, " Request "}, {:plain, text}, {:cursor, " "}]]

  defp footer_help(model), do: AtlasTui.LegendView.affordance(model)

  # A pending row as {label, mark, detail}: the selection still wins, muted inside it; the
  # mark stays the pending colour; the detail is muted either way.
  defp pending_styles(:selected),
    do: {{:selected, @pending_style}, :pending_selected, @pending_style}

  defp pending_styles(_), do: {@pending_style, :pending, @pending_style}

  # Adjacent segments of one style as one segment.
  defp coalesce(segments) do
    segments
    |> Enum.reduce([], fn
      {style, text}, [{style, before} | done] -> [{style, before <> text} | done]
      segment, done -> [segment | done]
    end)
    |> Enum.reverse()
  end

  # A done row is muted as a pending one is: faint, inside the highlight when selected.
  defp muted(:selected), do: {:selected, :muted}
  defp muted(_style), do: :muted

  # A list's room for the title and the detail after it, out of `available` cells:
  # `{summary_room, summary_gap, title_room}`. Titles come first; the detail gets at most a
  # third, and none in fewer than 16 cells.
  defp columns(available, titles, summaries) do
    available = max(available, 0)
    summary_room = if available >= 16, do: min(summaries, min(24, div(available, 3))), else: 0
    summary_gap = if summary_room > 0, do: 2, else: 0
    {summary_room, summary_gap, min(titles, max(available - summary_room - summary_gap, 0))}
  end

  # How long a row has been where it stands (Control's `since`), compact: `15d`, `6h`,
  # `46m`, `today` (under a minute); empty without a time.
  defp age(since, now) do
    case DateTime.from_iso8601(since || "") do
      {:ok, at, _} ->
        seconds = max(DateTime.diff(now, at), 0)

        cond do
          seconds >= 86_400 -> "#{div(seconds, 86_400)}d"
          seconds >= 3_600 -> "#{div(seconds, 3_600)}h"
          seconds >= 60 -> "#{div(seconds, 60)}m"
          true -> "today"
        end

      _ ->
        ""
    end
  end

  defp cursor_line?(line), do: Enum.any?(line, &match?({:cursor, _}, &1))

  defp selected_line?(line),
    do: Enum.any?(line, &(match?({:selected, _}, &1) or match?({{:selected, _}, _}, &1)))

  defp notice(%Model{notice: nil}), do: []

  defp notice(%Model{notice: notice}) do
    tone =
      if notice[:tone] in ["ok", "error", "pending", "info"],
        do: String.to_atom(notice.tone),
        else: :info

    icon = %{ok: "✓", error: "✗", pending: "…", info: "i"}[tone]
    [{tone, " #{icon} #{notice.text}"}]
  end

  defp status(model, reconcile_seconds) do
    connection = if model.connected, do: {:ok, " ● connected"}, else: {:error, " ○ not connected"}

    updated =
      case model.updated do
        nil ->
          ""

        u ->
          " · #{reason(u.reason)} at #{u.at}" <>
            if(u.position, do: " · position #{u.position}", else: "")
      end

    hint =
      case model.last_hint do
        %{reason: "hint"} = h when h != model.updated -> " · last hint at #{h.at}"
        _ -> ""
      end

    [connection, {:dim, updated <> hint <> " · reconciles every #{reconcile_seconds}s"}]
  end

  defp reason("open"), do: "opened"
  defp reason("hint"), do: "updated by hint"
  defp reason("reconcile"), do: "reconciled"
  defp reason("stored"), do: "stored"
  defp reason("refused"), do: "refused"
  defp reason("cache"), do: "from cache"
  defp reason("pending"), do: "updated"
  defp reason(other), do: to_string(other)

  # Text

  defp fit(segments, width) do
    {fitted, _} =
      Enum.reduce(segments, {[], width}, fn {style, text}, {acc, left} ->
        text = cell_take(text, max(left, 0))
        {[{style, text} | acc], left - display_width(text)}
      end)

    Enum.reverse(fitted)
  end

  defp pad(text, n), do: String.pad_trailing(String.slice(text, 0, n), n)

  # Keep paragraph/list wrapping, then fit by terminal cells without dropping text.
  defp detail_wrap(text, width) do
    text |> Text.wrap(width) |> Enum.flat_map(&detail_cell_rows(&1, width))
  end

  defp detail_cell_rows("", _width), do: [""]

  defp detail_cell_rows(text, width) do
    first = cell_take(text, width)

    {first, rest} =
      if first == "",
        do: String.next_grapheme(text),
        else: {first, binary_part(text, byte_size(first), byte_size(text) - byte_size(first))}

    if rest == "", do: [first], else: [first | detail_cell_rows(rest, width)]
  end

  defp single_line(nil), do: ""
  defp single_line(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  # Control appends provenance as " · since …", followed by the cause. Keep the
  # supplied summary (including owner/progress) without inferring workflow state.
  # The complete detail stays in the model and the item's detail presentation.
  defp row_summary(nil), do: ""

  defp row_summary(detail) do
    case :binary.match(detail, " · since ") do
      {at, _} -> detail |> binary_part(0, at) |> single_line()
      :nomatch -> single_line(detail)
    end
  end

  defp cell_pad(text, width) do
    text = cell_cut(text, width)
    text <> String.duplicate(" ", max(width - display_width(text), 0))
  end

  # Use the same native cell widths as OTP's terminal driver, keeping grapheme
  # clusters intact. Joined emoji may reserve extra cells rather than overflow.
  defp display_width(text), do: display_width(text, 0)
  defp display_width("", width), do: width

  defp display_width(text, width) do
    {grapheme, rest} = String.next_grapheme(text)
    display_width(rest, width + grapheme_width(grapheme))
  end

  defp grapheme_width(grapheme) do
    {width, emoji} =
      for <<cp::utf8 <- grapheme>>, reduce: {0, false} do
        {width, emoji} -> {width + :prim_tty.npwcwidth(cp), emoji or cp in [0xFE0F, 0x20E3]}
      end

    if emoji, do: max(width, 2), else: width
  end

  defp cell_cut(_text, width) when width <= 0, do: ""

  defp cell_cut(text, width) do
    taken = cell_take(text, width)
    if byte_size(taken) == byte_size(text), do: text, else: cell_take(taken, width - 1) <> "…"
  end

  defp cell_take(text, width), do: binary_part(text, 0, cell_bytes(text, width, 0))
  defp cell_bytes("", _width, bytes), do: bytes

  defp cell_bytes(text, width, bytes) do
    {grapheme, rest} = String.next_grapheme(text)
    cells = grapheme_width(grapheme)

    if cells <= width,
      do: cell_bytes(rest, width - cells, bytes + byte_size(grapheme)),
      else: bytes
  end

  @doc "A link's origin in a line: `since 3 Nov 15:10 · by melle · why`; empty without one."
  def origin_text(nil), do: ""

  def origin_text(origin) do
    since =
      case DateTime.from_iso8601(origin.since || "") do
        {:ok, at, _} -> "since " <> local(at)
        _ -> nil
      end

    by = origin.by && "by " <> origin.by
    [since, by, origin.cause] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  # In this machine's local time: "3 Nov 15:10".
  defp local(at) do
    {{y, mo, d}, {h, mi, _}} =
      at
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    Calendar.strftime(NaiveDateTime.from_erl!({{y, mo, d}, {h, mi, 0}}), "%-d %b %H:%M")
  end
end
