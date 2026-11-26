defmodule AtlasTui.View do
  @moduledoc """
  Draws the model as lines for a terminal of `width` × `height`. Pure, so tests can read
  the screen. Each line is a list of `{style, text}` segments; `to_ansi/1` adds colour.
  """

  alias AtlasTui.Blocks.{
    Actions,
    Answers,
    Box,
    Confirm,
    Fallback,
    Form,
    Header,
    Highlight,
    Input,
    Instruction,
    Item,
    Option,
    Panel,
    PanelItem,
    Part,
    Plan,
    Section
  }

  alias AtlasTui.Blocks.List, as: ListBlock
  alias AtlasTui.Blocks.Text, as: TextBlock
  alias AtlasTui.{Columns, Console, Model, Text}

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
  @column_title_floor 20
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
  # The card surfaces a segment on a card is wrapped in (`{surface, role}`).
  @surfaces AtlasTui.Palette.surfaces()

  @doc """
  The contract's names this view knows: the blocks it draws, and the kinds of markup it
  draws or, for now, passes through. A test fails when the contract has one it does not.
  """
  def known,
    do: %{
      blocks:
        ~w(list groups item option panel header text instruction answers actions form confirm plan console_action),
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
    model = put_in(model.console.viewport, {width, height})
    header = AtlasTui.ConsoleView.header(model, width)
    help = footer_help(model)
    status = status(model, reconcile_seconds, width)
    room = max(height - length(header) - 2 - length(status) - length(help), 1)

    {body, viewports} =
      if Columns.shown?(model) do
        in_columns(model, width, room)
      else
        measure = body_width(model, width)
        margin = String.duplicate(" ", div(width - measure, 2))
        {lines, _long, viewports} = laid_out(model, measure, room)
        {body, viewport} = window(lines, model, room)
        body = if margin == "", do: body, else: Enum.map(body, &[{:plain, margin} | &1])
        viewports = if viewport, do: Map.put(viewports, nil, viewport), else: viewports
        {body ++ Elixir.List.duplicate([], room - length(body)), viewports}
      end

    footer =
      help ++ [[{:dim, String.duplicate("─", width)}], console_notice(model)] ++ status

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

  # Without Control's content the body stays empty: nothing old is shown as if it were
  # current, and the status line says why and what happens next (`status/2`).
  defp body(%Model{connected: false, closed: true}, _width, _room), do: []

  # Waiting for a page that is not shown yet; a page kept for it (back, a tab) shows.
  defp body(%Model{console: %{expected: target, restoring: false}, path: path}, _width, _room)
       when target != nil and target != path,
       do: [[], [{:pending, " Loading…"}]]

  defp body(%Model{console: %{legend: legend}} = model, width, room) when legend != nil,
    do: AtlasTui.LegendView.render(model, width, room)

  defp body(%Model{connected: false}, _width, _room), do: []

  # The agent's plan shows over the page; the page stays underneath and follows hints.
  defp body(%Model{plan: %Plan{}} = model, width, room) do
    block = Model.step_form(model) || %{model.plan | steps: Model.plan_steps(model)}
    block(block, 0, model, width, room)
  end

  defp body(%Model{blocks: []}, _width, _room), do: []

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
    {body, cut, viewport} = scrolled(part_lines(node, model, width), scrolled, max(height - 2, 1))

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

    {lines, cut, viewport}
  end

  # `room` lines of `lines`, from where they are scrolled to (by hand, or to keep the
  # selected row in sight); when they are more than fit, the last says how many more.
  defp scrolled(lines, scrolled, room) do
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

    {body, cut, %{start: start, last: last, step: max(shown - 1, 1)}}
  end

  # Columns (`AtlasTui.Columns`): the list, the page of its selected row and that page's
  # details, each framed and scrolled on its own; the frame of the column with the focus
  # in primary, its title bold and marked ▸, the others grey.
  defp in_columns(model, width, room) do
    focus = Columns.focus(model)
    geometry = Columns.geometry(width)
    beside? = Enum.any?(geometry, &match?({:details, _, _}, &1))
    {main, details} = page_nodes(model)

    drawn =
      for {column, _x, w} <- geometry do
        inner = w - 4

        {lines, title} =
          case column do
            :list ->
              list = Columns.list_model(model)
              {nodes(content(list), list, inner, :all), list_title(model, list)}

            :page ->
              {page_lines(model, main, if(beside?, do: [], else: details), inner, room),
               if(Columns.nothing_open?(model), do: "Page", else: model.title)}

            :details when details == [] ->
              {[[], [{:dim, " No details beside this page."}]], "Details"}

            :details ->
              {nodes(Enum.flat_map(details, &inside/1), model, inner, :all),
               details_title(details)}
          end

        # The list follows its selection; the page opens at its top as in one column (a
        # page about one fact, `model.scroll`) until the arrows move in it.
        scroll =
          case column do
            :list -> nil
            :page -> model.columns.scroll[:page] || model.scroll
            :details -> model.columns.scroll[:details]
          end

        {body, _cut, viewport} = scrolled(lines, scroll, max(room - 2, 1))
        {column, w, framed(body, title, column == focus, w), viewport}
      end

    [{_, left, _} | _] = geometry
    margin = [{:plain, String.duplicate(" ", left)}]

    lines =
      for row <- 0..(room - 1) do
        margin ++
          Enum.flat_map(drawn, fn {_, w, lines, _} -> pad_line(Enum.at(lines, row) || [], w) end)
      end

    {lines, Map.new(drawn, fn {column, _, _, viewport} -> {column, viewport} end)}
  end

  defp framed(body, title, focused, width) do
    inner = width - 4
    style = if focused, do: :frame, else: :rest_frame
    title = String.slice(if(focused, do: "▸ " <> title, else: title), 0, max(width - 6, 0))
    label = {if(focused, do: :bold, else: :dim), " " <> title <> " "}
    rule = String.duplicate("─", max(width - 5 - String.length(title), 0))

    [[{style, "┌─"}, label, {style, rule <> "┐"}]] ++
      Enum.map(body, &([{style, "│ "}] ++ pad_line(fit(&1, inner), inner) ++ [{style, " │"}])) ++
      [[{style, "└" <> String.duplicate("─", max(width - 2, 0)) <> "┘"}]]
  end

  defp list_title(model, list) do
    tabs = (model.console.shell || %{})["tabs"] || []

    case Enum.find(tabs, &(&1["to"] == list.path)) do
      %{"label" => label} -> label
      nil -> list.title
    end
  end

  defp details_title([{:markup, %{"value" => %Part{title: title}}, _} | _]), do: title
  defp details_title(_details), do: "Details"

  # The page column: the page open beside the list, the details under it when they do not
  # stand beside it; while one is on its way, as a page on its way shows.
  defp page_lines(model, main, details, width, room) do
    cond do
      Columns.nothing_open?(model) and model.console.expected in [nil, model.path] ->
        [[], [{:dim, " Nothing open: the list has no row to show."}]]

      page_shown?(model) ->
        nodes(main ++ details, model, width, :all)

      true ->
        body(model, width, room)
    end
  end

  # The page's top-level nodes as the columns draw them: its details (parts of role
  # details or related) apart; its other parts unframed, under their titles.
  defp page_nodes(model) do
    if page_shown?(model) and not Columns.nothing_open?(model) do
      {details, main} = Enum.split_with(content(model), &related?/1)
      {Enum.map(main, &unframed/1), Enum.map(details, &unframed/1)}
    else
      {[], []}
    end
  end

  defp related?({:markup, %{"value" => %Part{role: role}}, _}), do: role in ["details", "related"]
  defp related?(_node), do: false

  defp unframed({:markup, %{"value" => %Part{role: "details"}}, _children} = node), do: node

  defp unframed({:markup, %{"value" => %Part{title: title}} = entry, children}),
    do: {:markup, %{entry | "value" => %Section{title: title}}, children}

  defp unframed(node), do: node

  # What the details column holds: the details without their own heading (its title).
  defp inside({:markup, %{"value" => %Part{role: "details"}}, children}), do: children
  defp inside({:markup, %{"value" => %Section{}}, children}), do: children
  defp inside(node), do: [node]

  defp count(n, noun), do: "#{n} #{noun}#{if n == 1, do: "", else: "s"}"

  defp pad_line(line, width) do
    used = Enum.reduce(line, 0, fn {_, text}, used -> used + display_width(text) end)
    line ++ [{:plain, String.duplicate(" ", max(width - used, 0))}]
  end

  # A tolerant reader (D-0105): a block that cannot be drawn as its type (a property it
  # needs is missing) is drawn plainly, and markup that cannot be drawn leaves its blocks
  # as they are; never a crash.
  defp nodes(tree, model, width, room) do
    tree
    |> Enum.map(fn
      {:block, block, at} ->
        try do
          block(block, at, model, width, room)
        rescue
          _ -> block(plainly(block), at, model, width, room)
        end

      {:markup, %{"value" => value}, children} ->
        try do
          markup(value, children, model, width, room)
        rescue
          _ -> nodes(children, model, width, room)
        end
    end)
    |> Enum.intersperse([[]])
    |> Enum.concat()
  end

  # Parts frame content; Console highlights retain the supplied semantic tone as
  # a text badge as well as a color, without inferring status from entity text.
  # A collapsible section is folded until the page's sections are unfolded: its heading
  # alone, marked ▸; unfolded, ▾ above its blocks. A section's heading has a rule after it,
  # except on a card (`{:on_card, section}`), which draws no lines.
  defp markup({:on_card, %Section{} = section}, children, model, width, room),
    do: section(section, children, model, width, room, false)

  defp markup(%Section{} = section, children, model, width, room),
    do: section(section, children, model, width, room, true)

  # The page's details: compact, in a card under their heading, whether beside the page or
  # under it (the details column draws them without it, `inside/1`).
  defp markup(%Part{role: "details", title: title}, children, model, width, room) do
    heading = if title, do: [[{:bold, single_line(title)}], []], else: []
    children = Enum.map(children, &on_card/1)
    card(heading ++ nodes(children, model, card_width(width), room), width, :card, model)
  end

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

  defp section(%Section{title: title, collapsible: true}, children, model, width, room, rule?) do
    mark = if model.unfolded, do: "▾ ", else: "▸ "
    heading = [[{:bold, " " <> mark <> title} | rule(rule?, width - String.length(title) - 5)]]

    if model.unfolded,
      do: heading ++ [[]] ++ nodes(children, model, width, room),
      else: heading
  end

  defp section(%Section{title: title}, children, model, width, room, rule?) do
    heading = [{:bold, " " <> title} | rule(rule?, width - String.length(title) - 3)]
    [heading, []] ++ nodes(children, model, width, room)
  end

  defp rule(false, _width), do: []
  defp rule(true, width), do: [{:dim, " " <> String.duplicate("─", max(width, 0))}]

  defp on_card({:markup, %{"value" => %Section{} = section} = entry, children}),
    do: {:markup, %{entry | "value" => {:on_card, section}}, children}

  defp on_card(node), do: node

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
    # list drops it before it cuts a title (below `@title_floor`). The list column keeps it
    # (dot, key, age, title), its titles cut sooner (`@column_title_floor`).
    age_width = ages |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    floor = if Columns.list_column?(model), do: @column_title_floor, else: @title_floor

    age_room =
      with true <- age_width > 0,
           {_, _, title_room} = columns(available - age_width - 2, titles, summaries),
           true <- title_room >= min(titles, floor) do
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

  # One option of a decision, in a card of its own (the selected one, which Enter answers,
  # on the selected surface and marked ▸): its number as an instruction's, its text and its
  # badge in its tone; each of its fields under it ("Rule: …"); then its answer as a key, as
  # far as Control projects it: Choose in green, Decline… (which asks a note) in orange, and
  # on the selected one the keys that select and answer.
  defp block(%Option{} = option, _at, model, width, _room) do
    options = Model.options(model)
    selected = Enum.at(options, Model.chosen(options, model.choice)) == option
    content = card_width(width)
    lead = "#{option.n}. "
    indent = String.duplicate(" ", 2 + display_width(lead))
    room = max(content - display_width(indent), 1)
    badge = single_line(option.badge)
    badge_style = if option.tone == "warning", do: :warning, else: :ok
    [first | rest] = detail_wrap(single_line(option.text), room)

    {first, badge_line} =
      cond do
        badge == "" ->
          {[{:bold, first}], []}

        rest == [] and display_width(first) + 2 + display_width(badge) <= room ->
          gap = String.duplicate(" ", room - display_width(first) - display_width(badge))
          {[{:bold, first}, {:plain, gap}, {badge_style, badge}], []}

        true ->
          {[{:bold, first}], [[{:plain, indent}, {badge_style, badge}]]}
      end

    mark = if selected, do: {:bold, "▸ "}, else: {:plain, "  "}

    head =
      [[mark, {:bold, lead} | first]] ++
        Enum.map(rest, &[{:plain, indent}, {:bold, &1}]) ++ badge_line

    fields =
      for pair <- option.fields,
          line <- hanging(single_line(pair.label) <> ": ", pair.value || "—", room, :dim, :plain),
          do: [{:plain, indent} | line]

    answer =
      for line <- option_answer(option.answer, selected, options, model, room),
          do: [{:plain, indent} | line]

    lines = head ++ fields ++ if(answer == [], do: [], else: [[] | answer])

    card(lines, width, if(selected, do: :card_selected, else: :card), model)
  end

  # Control's panel where its owner decides: what is asked of them (`heading`) and the
  # title under it, how many beside it; the byline; then what it is judged on: its items
  # (the selected one marked ▸, its details in a card under them), its checks (each with a
  # mark of its state), a box (an error's heading in the error colour); and the keys there
  # are, as far as Control projects them. Its own rows line up with its cards' text.
  defp block(%Panel{} = panel, _at, model, width, _room) do
    content = card_width(width)
    choices = Model.panel_choices(panel)
    at = Model.panel_chosen(panel, model.choice)

    indent = fn lines ->
      for line <- lines, do: if(line == [], do: [], else: [{:plain, "  "} | line])
    end

    byline =
      case byline(panel.byline || [], DateTime.utc_now()) do
        "" -> []
        text -> Enum.map(detail_wrap(text, content), &[{:dim, &1}])
      end

    sections = [
      indent.(item_rows(panel.items || [], at, content)),
      item_details(Enum.at(panel.items || [], at), width, model),
      indent.(check_rows(panel.checks || [])),
      panel_box(panel.box, width, model),
      indent.(panel_keys(panel, choices, model, content))
    ]

    body = indent.(byline) ++ Enum.flat_map(sections, &if(&1 == [], do: [], else: [[] | &1]))
    heading(keyed(panel.heading, panel.key), panel.title, panel.aside, width) ++ body
  end

  # A page's header: its eyebrow ("TO DO FOR YOU") with the fact's key, its title under it.
  defp block(%Header{} = header, _at, _model, width, _room),
    do: heading(keyed(header.eyebrow, header.key), header.title, nil, width)

  # What went wrong (`role` error): a card, its label as a heading in the error colour over
  # its text (the label says what it is, not the colour alone).
  defp block(%TextBlock{role: "error"} = text, _at, model, width, _room) do
    heading =
      case single_line(text.label) do
        "" -> []
        label -> [[{:error, label}]]
      end

    lines = heading ++ text_lines(text_words(text, model), card_width(width))
    card(lines, width, :card_error, model)
  end

  # A paragraph, dim, after its label ("Why: ") and with how long ago its `since` was; its
  # lines under the first.
  defp block(%TextBlock{} = text, _at, model, width, _room) do
    label = if single_line(text.label) == "", do: "", else: single_line(text.label) <> ": "

    for line <- hanging(label, text_words(text, model), max(width - 4, 1), :dim, :dim),
        do: [{:plain, "   "} | line]
  end

  # One numbered step, in full, in a card: a mark column (▸ beside the selected command of
  # the page), a number column as wide as the page's widest number, so every step's number
  # and text line up, then its lines in the order written, a blank line where the kind
  # changes. Text is bold; a command is plain behind a bar, the selected one highlighted; a
  # route is a muted ⌘ and its parts (`route_rows/2`). The same in both themes.
  defp block(%Instruction{} = step, _at, model, width, _room) do
    widest = Enum.max([step.n | for(%Instruction{n: n} <- model.blocks, do: n)])
    numbers = display_width("#{widest}. ")
    text_width = max(card_width(width) - 2 - numbers, 1)
    selected = Model.command(model)

    first =
      length(Model.commands(%{model | blocks: Enum.take_while(model.blocks, &(&1 != step))}))

    {runs, _} =
      step.lines
      |> Enum.chunk_by(& &1.kind)
      |> Enum.map_reduce(first, fn run, at ->
        Enum.flat_map_reduce(run, at, fn
          %{kind: "command", text: command}, at ->
            {command_rows(command, at == selected, text_width), at + 1}

          line, at ->
            {for(row <- instruction_rows(line, text_width), do: {false, row}), at}
        end)
      end)

    rows =
      case runs |> Enum.intersperse([{false, []}]) |> Enum.concat() do
        [] -> [{false, []}]
        rows -> rows
      end

    lines =
      for {{marked, row}, i} <- Enum.with_index(rows) do
        mark = if marked, do: {:bold, "▸ "}, else: {:plain, "  "}
        number = if i == 0, do: "#{step.n}. ", else: ""
        [mark, {:bold, String.pad_trailing(number, numbers)} | row]
      end

    card(lines, width, :card, model)
  end

  # What the viewer can answer, each on its key as far as Control projects it (one given
  # with a note says so), then, muted, the page's other actions (its `actions` block), then
  # the keys of the page's commands: ↑↓, c and y.
  defp block(%Answers{} = block, _at, model, width, _room) do
    keys = projected_keys(model)

    answers =
      for answer <- block.answers || [], MapSet.member?(keys, answer.key), do: answer_key(answer)

    others = for %Actions{} = actions <- model.blocks, item <- other_keys(actions, keys), do: item

    copies =
      case Model.commands(model) do
        [] -> []
        [_] -> [{"c", "copy"}, {"y", "copy all"}]
        _ -> [{"↑↓", "command"}, {"c", "copy"}, {"y", "copy all"}]
      end

    copies = for {key, what} <- copies, do: [{:key, key}, {:dim, " " <> what}]

    for line <- key_lines(answers ++ others ++ copies, max(width - 4, 1)),
        do: [{:plain, "   "} | line]
  end

  # What else can be done with the page's subject, quieter than its answers: in the
  # answers' key line when the page has one, else a key line of its own.
  defp block(%Actions{} = block, _at, model, width, _room) do
    if Enum.any?(model.blocks, &match?(%Answers{}, &1)) do
      []
    else
      items = other_keys(block, projected_keys(model))
      for line <- key_lines(items, max(width - 4, 1)), do: [{:plain, "   "} | line]
    end
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

  # A block this TUI does not know, or cannot draw as its type: what it says, plainly.
  defp block(%Fallback{title: nil, lines: [], type: type}, _at, _model, _width, _room),
    do: [[{:dim, "   (a #{type || "?"} block this TUI cannot show)"}]]

  defp block(%Fallback{title: title, lines: lines}, _at, _model, width, _room) do
    heading = if title, do: [[{:bold, " " <> single_line(title)}]], else: []

    heading ++
      Enum.flat_map(lines, fn line ->
        Enum.map(Text.wrap(line, max(width - 4, 1)), &[{:plain, "   " <> &1}])
      end)
  end

  defp plainly(%Fallback{} = fallback), do: fallback

  defp plainly(block) do
    {title, lines} = AtlasTui.Blocks.plain(props(block))
    %Fallback{type: type_name(block), title: title, lines: lines}
  end

  # A decoded block as its props: string keys, nested structs as maps.
  defp props(%_{} = struct), do: struct |> Map.from_struct() |> props()
  defp props(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), props(v)} end)
  defp props(list) when is_list(list), do: Enum.map(list, &props/1)
  defp props(value), do: value

  defp type_name(block),
    do: block.__struct__ |> Module.split() |> List.last() |> Macro.underscore()

  # What a panel asks, with the key of the fact it is about: "TO ACCEPT · UC-03".
  defp keyed(heading, key) when key in [nil, ""], do: heading
  defp keyed(heading, key) when heading in [nil, ""], do: single_line(key)
  defp keyed(heading, key), do: heading <> " · " <> single_line(key)

  # A command of an instruction behind a bar, as `{marked, row}`: the first row of the
  # selected one is marked (▸) and it is highlighted.
  defp command_rows(command, selected, width) do
    style = if selected, do: :selected, else: :plain

    for {line, i} <- Enum.with_index(detail_wrap(command || "", max(width - 2, 1))),
        do: {selected and i == 0, [{:border, "▎ "}, {style, line}]}
  end

  defp instruction_rows(%{kind: "route", parts: parts}, width), do: route_rows(parts || [], width)

  defp instruction_rows(%{text: text}, width),
    do: for(line <- detail_wrap(text || "", width), do: [{:bold, line}])

  # A route: a muted ⌘, then its parts bold in `:route`, a muted › between them. A route
  # too long for its row goes on at a separator: the next row starts with that › under
  # the first part. A part too long for a row of its own wraps, under itself.
  defp route_rows(parts, width) do
    {rows, row, _used} =
      parts
      |> Enum.with_index()
      |> Enum.reduce({[], [{:dim, "⌘ "}], 2}, fn {part, index}, {rows, row, used} ->
        need = display_width(part)

        cond do
          index == 0 and used + need <= width ->
            {rows, row ++ [{:route, part}], used + need}

          index > 0 and used + 3 + need <= width ->
            {rows, row ++ [{:dim, " › "}, {:route, part}], used + 3 + need}

          true ->
            {rows, lead} =
              if index == 0, do: {rows, row}, else: {[row | rows], [{:plain, "  "}, {:dim, "› "}]}

            [first | rest] = detail_wrap(part, max(width - 4, 1))

            Enum.reduce(
              rest,
              {rows, lead ++ [{:route, first}],
               if(index == 0, do: 2, else: 4) + display_width(first)},
              fn piece, {rows, row, _used} ->
                {[row | rows], [{:plain, "    "}, {:route, piece}], 4 + display_width(piece)}
              end
            )
        end
      end)

    Enum.reverse([row | rows])
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

  # A page's or a decision's heading: its eyebrow (what is asked of its owner, with the
  # fact's key) after ◆, bold light blue, `aside` dim at its right where it fits (else
  # under the title); the title bold under it. No bar: the page's background.
  defp heading(eyebrow, title, aside, width) do
    inner = max(width - 1, 1)
    lead = if single_line(eyebrow) == "", do: "◆", else: "◆ " <> single_line(eyebrow)
    aside = single_line(aside)
    [first | rest] = detail_wrap(lead, inner)
    room = inner - display_width(first) - 2
    beside = aside != "" and rest == [] and display_width(aside) <= room

    top =
      if beside,
        do: [
          {:eyebrow, first},
          {:plain, cell_pad("", room + 2 - display_width(aside))},
          {:dim, aside}
        ],
        else: [{:eyebrow, first}]

    under = if aside == "" or beside, do: [], else: [[{:dim, aside}]]

    titles =
      case single_line(title) do
        "" -> []
        title -> for line <- detail_wrap(title, inner), do: [{:bold, line}]
      end

    for line <- [top | Enum.map(rest, &[{:eyebrow, &1}])] ++ titles ++ under,
        do: [{:plain, " "} | line]
  end

  # A card: `lines` on a surface of their own (`AtlasTui.Palette`, cards), a column in from
  # the page's edge, a column of padding left and right, each row filled edge to edge; its
  # top and bottom rows half blocks in the surface's colour on the page (▗▄▄▖, ▝▀▀▘), which
  # round its corners; no lines. `kind` is `:card`, `:card_selected` (the one selected: the
  # primary tinted surface) or `:card_error` (what went wrong: a card, its heading in the
  # error colour and saying so). Where the terminal reports no truecolor
  # (`console.truecolor`), a surface could not be told from the page: a card is its lines
  # behind a left bar ▌ instead, grey, in primary when selected, in the error colour for
  # what went wrong. Too narrow for a card: its lines alone. Its lines fit `card_width/1`.
  defp card([], _width, _kind, _model), do: []
  defp card(lines, width, _kind, _model) when width < 6, do: lines

  defp card(lines, width, kind, %Model{console: %{truecolor: false}}) do
    bar = %{card: :rest_frame, card_selected: :frame, card_error: :error_frame}[kind]

    for line <- lines,
        do: [{:plain, " "}, {bar, "▌"}, {:plain, " "} | fit(line, card_width(width))]
  end

  defp card(lines, width, kind, _model) do
    {surface, edge} =
      if kind == :card_selected,
        do: {:card_selected, :card_selected_edge},
        else: {:card, :card_edge}

    inner = card_width(width)
    fill = width - 3
    pad = {{surface, :plain}, " "}

    rows =
      for line <- lines do
        content =
          for {style, text} <- pad_line(fit(line, inner), inner), do: {{surface, style}, text}

        [{:plain, " "}, pad | content] ++ [pad]
      end

    [[{:plain, " "}, {edge, "▗" <> String.duplicate("▄", fill) <> "▖"}]] ++
      rows ++ [[{:plain, " "}, {edge, "▝" <> String.duplicate("▀", fill) <> "▘"}]]
  end

  # The width of a card's lines in a card `width` wide (its margin, padding or bar).
  defp card_width(width), do: max(width - 3, 1)

  # A paragraph's text with how long ago its `since` was.
  defp text_words(text, model) do
    words = String.trim(text.text || "")

    case age(text.since, model.now || DateTime.utc_now()) do
      "" -> words
      "today" -> words <> " · just now"
      age -> words <> " · " <> age <> " ago"
    end
  end

  # An option's answer on its key, as far as Control projects it: Choose in green, one
  # that asks a note (Decline…) in orange; on the selected option, Enter that answers it as
  # its key does and, among more options, the arrows that select; wrapped at `width`.
  defp option_answer(answer, selected, options, model, width) do
    if MapSet.member?(projected_keys(model), answer.key) do
      style = if answer.note == true, do: :warning, else: :ok

      [
        [{:key, answer.key}, {style, " " <> single_line(answer.label)}],
        selected && [{:key, "Enter"}, {:dim, " answer"}],
        selected && length(options) > 1 && [{:key, "↑↓"}, {:dim, " select"}]
      ]
      |> Enum.filter(& &1)
      |> key_lines(width)
    else
      []
    end
  end

  defp text_lines(text, width), do: Enum.map(detail_wrap(text, max(width, 1)), &[{:plain, &1}])

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

  # The details of the selected item, in a card, each under its label.
  defp item_details(%PanelItem{details: [_ | _] = details}, width, model) do
    inner = card_width(width)
    label_width = Enum.reduce(details, 0, &max(display_width(single_line(&1.label)), &2))

    details
    |> Enum.flat_map(fn pair ->
      label = cell_pad(single_line(pair.label), label_width) <> " "
      hanging(label, String.trim(pair.value || ""), inner, :dim, :plain)
    end)
    |> card(width, :card, model)
  end

  defp item_details(_item, _width, _model), do: []

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

  # A panel's box: its title over its text, in a card; an error's heading in the error
  # colour (its bar in the error colour where cards are bars).
  defp panel_box(nil, _width, _model), do: []

  defp panel_box(%Box{} = box, width, model) do
    {kind, heading} = if box.tone == "error", do: {:card_error, :error}, else: {:card, :bold}

    title =
      case single_line(box.title) do
        "" -> []
        title -> [[{heading, title}]]
      end

    card(title ++ text_lines(box.text || "", card_width(width)), width, kind, model)
  end

  # A panel's keys, as far as Control projects them: its answers (yes, or no with a note);
  # what its actions and links open; with items, the arrows and Enter that opens one.
  defp panel_keys(panel, choices, model, width) do
    keys = projected_keys(model)
    on = &MapSet.member?(keys, &1)

    answers = for answer <- panel.answers || [], on.(answer.key), do: answer_key(answer)

    opens =
      for open <- (panel.actions || []) ++ (panel.links || []),
          on.(open.key),
          do: [{:key, open.key}, {:dim, " " <> single_line(open.label)}]

    moves =
      [
        length(choices) > 1 && {"↑↓", "choose"},
        choices != [] && {"Enter", "open"}
      ]
      |> Enum.filter(& &1)
      |> Enum.map(fn {key, what} -> [{:key, key}, {:dim, " " <> what}] end)

    key_lines(answers ++ opens ++ moves, width)
  end

  # The page's other actions on their keys, muted, as far as Control projects them.
  defp other_keys(%Actions{actions: actions}, keys) do
    for action <- actions || [],
        MapSet.member?(keys, action.key),
        do: [{:muted, action.key}, {:muted, " " <> single_line(action.label)}]
  end

  # An answer on its key: a yes, or one given with a note, which says so.
  defp answer_key(answer) do
    if answer.note == true,
      do: [{:key, answer.key}, {:warning, " " <> single_line(answer.label) <> " · note"}],
      else: [{:key, answer.key}, {:ok, " " <> single_line(answer.label)}]
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

  defp console_notice(%Model{console: %{action_error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error}]

  defp console_notice(%Model{console: %{key_buffer: buffer}}) when buffer != "",
    do: [{:dim, "Shortcut: #{buffer} · Enter to select · Esc to cancel"}]

  defp console_notice(%Model{console: %{key_prefix: prefix}}) when prefix != "",
    do: [{:dim, "#{prefix} … · Esc to cancel"}]

  # Closed by Control: its words are the status line's (`status/2`), not said twice.
  defp console_notice(%Model{connected: false, closed: true}), do: []

  defp console_notice(model), do: notice(model)

  # Footer

  defp footer_help(%Model{console: %{expected: target, restoring: false}, path: path})
       when target != nil and target != path,
       do: []

  defp footer_help(%Model{console: %{legend: legend}}) when legend != nil, do: []

  defp footer_help(%Model{ask: text}) when is_binary(text),
    do: [[{:bold, " Request "}, {:plain, text}, {:cursor, " "}]]

  # In columns, the keys of the column with the focus, and the legend's own key.
  defp footer_help(model) do
    if Columns.shown?(model) and AtlasTui.Interactions.content_context(model) == "browse" do
      legend =
        case AtlasTui.Legend.opener(model) do
          nil -> []
          action -> [{Enum.join(action["props"]["keys"], ", "), action["props"]["label"]}]
        end

      keys =
        (Columns.keys(model) ++ legend)
        |> Enum.map(fn {key, label} -> [{:key, key}, {:dim, " " <> label}] end)
        |> Enum.intersperse([{:dim, " · "}])
        |> Enum.concat()

      [[{:dim, " "} | keys]]
    else
      AtlasTui.LegendView.affordance(model)
    end
  end

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

  defp selected_line?(line), do: Enum.any?(line, fn {style, _} -> selected_style?(style) end)

  # The selection, as it is, muted (`{:selected, :muted}`) or on a card (`{:card, :selected}`).
  defp selected_style?(:selected), do: true
  defp selected_style?({:selected, _}), do: true
  defp selected_style?({surface, style}) when surface in @surfaces, do: selected_style?(style)
  defp selected_style?(_style), do: false

  defp notice(%Model{notice: nil}), do: []

  defp notice(%Model{notice: notice}) do
    tone =
      if notice[:tone] in ["ok", "error", "pending", "info"],
        do: String.to_atom(notice.tone),
        else: :info

    icon = %{ok: "✓", error: "✗", pending: "…", info: "i"}[tone]
    [{tone, " #{icon} #{notice.text}"}]
  end

  # The connection, compact and in plain words, as lines: connected (what the page on
  # screen is and how it stays current), or not, with why and what happens next, wrapped
  # when it does not fit, so what to do is never cut off.
  defp status(%Model{connected: true} = model, reconcile_seconds, _width) do
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

    [
      [{:ok, " ● connected"} | versions(model)] ++
        [{:dim, waiting(model) <> updated <> hint <> " · reconciles every #{reconcile_seconds}s"}]
    ]
  end

  defp status(model, _reconcile_seconds, width) do
    {why, retries} = offline(model)
    retries = if retries, do: " · retries every #{div(Console.retry_ms(), 1_000)}s", else: ""
    mark = "○ not connected"

    [first | rest] = Text.wrap("#{mark} · #{why}#{retries}", width - 1)

    first =
      case String.split_at(first, String.length(mark)) do
        {^mark, after_mark} -> [{:error, " " <> mark}, {:dim, after_mark}]
        _ -> [{:error, " " <> first}]
      end

    [first | Enum.map(rest, &[{:dim, " " <> &1}])]
  end

  defp waiting(%Model{console: %{error: error}}) when is_binary(error),
    do: " · the tabs could not be refreshed (#{error}); the last ones stay and are asked again"

  defp waiting(%Model{blocks: []}), do: " · waiting for Control's first page"
  defp waiting(_model), do: ""

  # Why there is no Control content, and what happens next; and whether it is tried again
  # every few seconds (a Control that answered but refused this TUI is not asked again until
  # it restarts).
  defp offline(%Model{closed: true, notice: %{text: text}}), do: {text, true}

  defp offline(%Model{offline: :no_tunnel}),
    do: {"the tunnel to Control is closed; any atlas command opens it", true}

  defp offline(%Model{offline: :unreachable}),
    do: {"Control cannot be reached; connects by itself once it answers", true}

  defp offline(%Model{offline: :silent}),
    do: {"Control is down or restarting; connects once it answers", true}

  defp offline(%Model{offline: :refused, env: env}),
    do: {"Control #{env} refused this TUI as its Console; connects once Control restarts", false}

  defp offline(_model), do: {"connecting to Control", false}

  # Control on another contract than this build (D-0105): the two versions in plain words,
  # and what happens: a newer Control is taken as a reason to update (bin/atlas restarts
  # this TUI on a newer build); otherwise it still shows what it knows, the rest plainly.
  @doc false
  def versions(%Model{connected: true, control_spec: theirs, env: env} = model)
      when is_binary(theirs) do
    ours = AtlasTui.Protocol.version()

    cond do
      theirs == ours ->
        []

      AtlasTui.Console.newer?(theirs) ->
        next =
          case model.release do
            :restart -> "updating"
            {:not_updated, why} -> "not updated: #{why}; some parts may look plain"
            nil -> "some parts may look plain; run atlas again to update"
          end

        [{:warning, " · #{env} speaks #{short(theirs)}, this TUI #{short(ours)} · #{next}"}]

      true ->
        [{:warning, " · this TUI is newer than #{env} (#{short(ours)} vs #{short(theirs)})"}]
    end
  end

  def versions(_model), do: []

  # A version in short: 0.33.0 is 0.33.
  defp short(version), do: String.replace_suffix(version, ".0", "")

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
