defmodule AtlasTui.View do
  @moduledoc """
  Draws the model as lines for a terminal of `width` × `height`. Pure, so tests can read
  the screen. Each line is a list of `{style, text}` segments; `to_ansi/1` adds colour.
  """

  alias AtlasTui.Blocks.{
    Confirm,
    Fallback,
    Form,
    Highlight,
    Input,
    Item,
    Part,
    Plan,
    Section
  }

  alias AtlasTui.Blocks.List, as: ListBlock
  alias AtlasTui.{Model, Text}

  @label_width 16
  # Beside the label of a row Control marks pending (docs/design/page-freshness.md §2.3).
  @pending_mark "  ⋯ being processed"
  # How such a row looks: muted (faint), muted inside the highlight when selected; the
  # mark itself keeps the pending colour, so the eye still catches it.
  @pending_style :muted
  # A multi-line input that does not have the focus shows at most this many rows.
  @resting_rows 8
  # A focused one never shows fewer than this, however small the screen.
  @least_rows 3
  # Markup says what a stretch of a page means; how it looks is this view's choice. A page
  # in parts shows them side by side from this width; narrower, one above the other.
  @side_by_side 120

  @doc """
  The contract's names this view knows: the blocks it draws, and the kinds of markup it
  draws or, for now, passes through. A test fails when the contract has one it does not.
  """
  def known,
    do: %{
      blocks: ~w(list item form confirm plan console_action),
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
    {lines, _long, viewports} = laid_out(model, width, room)

    body = window(lines, model, room)
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

  # The body's lines, and whether it is longer than its room. A page in parts fills its
  # room exactly, each part scrolled on its own; a part that is cut says so itself.
  defp laid_out(model, width, room) do
    if model.connected and model.blocks != [] and model.plan == nil and
         model.console.legend == nil and
         (model.console.expected in [nil, model.path] or model.console.restoring) and
         Model.parts(model) != [],
       do: parts(content(model), model, width, room),
       else: plain_layout(model, width, room)
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

  defp with_offsets(model) do
    {placed, _} =
      model.ids
      |> Enum.zip(model.blocks)
      |> Enum.map_reduce(0, fn
        {id, %ListBlock{rows: rows} = block}, at -> {{id, block, at}, at + length(rows || [])}
        {id, block}, at -> {{id, block, at}, at}
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
  defp markup(%Section{title: title}, children, model, width, room) do
    rule = String.duplicate("─", max(width - String.length(title) - 3, 0))
    [[{:bold, " " <> title}, {:dim, " " <> rule}], []] ++ nodes(children, model, width, room)
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

    prepared =
      Enum.map(rows, fn row ->
        {single_line(row.id), single_line(row.label), row_summary(row.detail)}
      end)

    pending = Enum.map(rows, &(&1.pending == true))

    {ids, titles, summaries} =
      Enum.reduce(prepared, {0, 0, 0}, fn {id, title, summary}, {ids, titles, summaries} ->
        {max(ids, display_width(id)), max(titles, display_width(title)),
         max(summaries, display_width(summary))}
      end)

    marker_room = if width >= 3, do: 3, else: 1
    available = max(width - marker_room, 0)
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
    summary_room = if available >= 16, do: min(summaries, min(24, div(available, 3))), else: 0
    summary_gap = if summary_room > 0, do: 2, else: 0
    title_room = min(titles, max(available - summary_room - summary_gap, 0))

    content =
      prepared
      |> Enum.zip(pending)
      |> Enum.with_index()
      |> Enum.map(fn {{{id, title, summary}, pending?}, i} ->
        style = if at + i == model.selected, do: :selected, else: :bold
        marker = if style == :selected, do: "›", else: " "
        marker = if marker_room == 3, do: " " <> marker <> " ", else: marker
        identity = if id_room > 0, do: cell_pad(id, id_room) <> "  ", else: ""
        label = marker <> identity <> cell_pad(title, title_room)
        metadata = cell_cut(summary, summary_room)

        {style, mark_style, detail} =
          if pending?, do: pending_styles(style), else: {style, style, :dim}

        mark =
          cond do
            pending_room == 0 -> []
            pending? -> [{mark_style, @pending_mark}]
            metadata == "" -> []
            true -> [{style, String.duplicate(" ", pending_room)}]
          end

        [{style, label}] ++
          mark ++ if(metadata == "", do: [], else: [{detail, "  " <> metadata}])
      end)

    indent = String.duplicate(" ", min(3, max(width - 1, 0)))

    empty =
      for line <- list_wrap(list.empty || "Nothing here.", width - String.length(indent)),
          do: [{:dim, indent <> line}]

    heading ++ if(rows == [], do: empty, else: content)
  end

  # Values keep their line breaks and blank lines; a heading line (`#`) is bold.
  defp block(%Item{} = item, _at, _model, width, _room) do
    fields =
      Enum.flat_map(item.fields, fn pair ->
        label = single_line(pair.label)
        stacked = width < 40 or display_width(label) >= @label_width
        padding = if stacked, do: min(5, max(width - 2, 0)), else: @label_width + 3
        indent = String.duplicate(" ", padding)
        value_width = max(width - padding, 1)
        [first | rest] = detail_wrap(pair.value || "—", value_width)

        heading =
          if stacked do
            prefix = String.duplicate(" ", min(3, max(width - 2, 0)))

            Enum.map(detail_wrap(label <> ":", max(width - byte_size(prefix), 1)), fn line ->
              [{:dim, prefix <> line}]
            end) ++ [[{:plain, indent}, text_row(first)]]
          else
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
  # its top); arrows follow the selection again.
  defp window(lines, model, room) when length(lines) > room do
    last = length(lines) - room

    focus = Enum.find_index(lines, &cursor_line?/1) || Enum.find_index(lines, &selected_line?/1)
    follow = focus != nil and (model.scroll == nil or Model.form(model) != nil)
    start = if follow, do: focus - div(room, 2), else: model.scroll || 0

    Enum.slice(lines, start |> min(last) |> max(0), room)
  end

  defp window(lines, _model, _room), do: lines

  defp console_notice(%Model{console: %{error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error <> " · retrying boot"}]

  defp console_notice(%Model{console: %{action_error: error}}) when is_binary(error),
    do: [{:error, " Console: " <> error}]

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
