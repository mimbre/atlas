defmodule AtlasTui.Columns do
  @moduledoc """
  The TUI's layout (docs/design/apple-clients.md, Layout): the tabs, the list of the tab,
  the page of the row selected in it, and that page's details, as columns anchored from the
  left, each right after the one before it; what room is left over stays at the far right.

    * The sidebar: 24 wide, the tabs one under the other with their counts and groups. The
      list: 60 wide. The page: its main blocks, at most 100. The details: the page's
      details group as a column of its own, 40 to 100 wide, growing with the room.
    * From 290 cells: the sidebar (in place of the tab bar), the list, the page, its details.
    * From 210 cells: the list, the page and its details side by side, under the tab bar
      and a row of the active tab's groups.
    * From 144 cells: the list and the page; the details under the page's main blocks.
    * Narrower: one column at a time (the page, its details beside it from 140 cells).

  What gives way first as the terminal narrows: the sidebar (to the tab bar), then the
  details (under the page), then the list.

  The list follows live: moving in it opens the selected row's page at once (its cached
  copy, while Control reads it fresh), as Enter does in one column; back from that page
  in one column returns to the list. The list column is the newest page Control sent for
  the list's path (`AtlasTui.PageCache`), so its hints keep it current. The sidebar follows
  live too: moving in it opens the tab or group at once, as Tab does.

  One column has the focus. → moves it right (sidebar → list → page → details), ← left;
  Enter in the sidebar or the list is →; Esc returns it to the list; a mouse click in a
  column takes it there. Details takes it only when it has related items, which ↑/↓ then
  choose and →/Enter open in the page. ↑/↓ act in the column with the focus only; every
  other key (the open item's actions, Tab for the tabs) works as in one column, on the
  page that is open. Pure.
  """

  alias AtlasTui.{Blocks, Console, ConsoleView, Interactions, Model, PageCache, Selection}
  alias AtlasTui.Blocks.Part

  @sidebar 24
  @list 60
  @page 100
  @details_least 40
  @details_most 100
  # The page beside the list keeps at least this much; narrower, the list goes.
  @page_least 84
  @two @list + @page_least
  # From here the details stand beside the page: at least 50 wide beside the list.
  @three 210
  # From here the tabs leave the bar for the sidebar.
  @four 290
  # Parts that hold what a page refers to, drawn in the details column.
  @details_roles ["details", "related"]

  @doc """
  How a terminal `width` lays out: `:four` columns (with the sidebar), `:three`, `:two`, or
  `:one` at a time.
  """
  def layout(width) when width >= @four, do: :four
  def layout(width) when width >= @three, do: :three
  def layout(width) when width >= @two, do: :two
  def layout(_width), do: :one

  @doc """
  The layout rule: the columns across `width` cells as `{column, x, width}`, from the left
  edge, each right after the one before it. Of `wanted` (`:sidebar`, `:list`, `:details`):
  the sidebar (#{@sidebar} wide), the list (#{@list}), then always the page (the rest, at most
  #{@page}), and its details when the room right of a full page holds at least
  #{@details_least} (at most #{@details_most}); else they go under the page's main blocks.
  Room left over is at the far right.
  """
  def place(width, wanted) do
    fixed = for {column, w} <- [sidebar: @sidebar, list: @list], column in wanted, do: {column, w}
    room = width - Enum.sum(Keyword.values(fixed))
    page = min(room, @page)
    side = min(room - @page, @details_most)
    details? = :details in wanted and side >= @details_least
    columns = fixed ++ [page: page] ++ if(details?, do: [details: side], else: [])

    {placed, _x} = Enum.map_reduce(columns, 0, fn {column, w}, x -> {{column, x, w}, x + w} end)
    placed
  end

  @doc """
  The columns across a terminal `width` (`place/2`): the list and the page; from #{@three}
  cells, the details too; from #{@four}, the sidebar before them. Empty in one column.
  """
  def geometry(width) do
    case layout(width) do
      :one -> []
      :two -> place(width, [:list])
      :three -> place(width, [:list, :details])
      :four -> place(width, [:sidebar, :list, :details])
    end
  end

  @doc "Whether the screen shows columns: wide enough, with a list to follow."
  def shown?(model) do
    {width, _height} = model.console.viewport

    layout(width) != :one and model.connected and model.plan == nil and
      model.console.legend == nil and list_model(model) != nil
  end

  @doc "Whether the tabs stand in the sidebar (and not in the tab bar): columns, from #{@four}."
  def sidebar?(model) do
    {width, _height} = model.console.viewport
    layout(width) == :four and model.console.shell != nil and shown?(model)
  end

  @doc """
  The sidebar's rows, top down: per section (`"work"`, then `"browse"`) its tabs, each
  followed by its groups, as `%{section, to, label, count, group?}`.
  """
  def sidebar_rows(model) do
    tabs = (model.console.shell || %{})["tabs"] || []
    {work, browse} = Enum.split_with(tabs, &Console.work?/1)

    for {section, tabs} <- [{"work", work}, {"browse", browse}],
        tab <- tabs,
        row <- [{tab, false} | Enum.map(tab["groups"] || [], &{&1, true})] do
      {entry, group?} = row

      %{
        section: section,
        to: entry["to"],
        label: entry["label"],
        count: entry["count"],
        group?: group?
      }
    end
  end

  @doc "Which sidebar row is the one shown: the list's group or tab, else the active tab's."
  def sidebar_at(model) do
    rows = sidebar_rows(model)
    tabs = (model.console.shell || %{})["tabs"] || []
    active = Enum.find(tabs, &(&1["id"] == model.console.active))

    Enum.find_index(rows, &(&1.to == model.columns.list)) ||
      (active && Enum.find_index(rows, &(&1.to == active["to"] and not &1.group?)))
  end

  @doc """
  The list column as a model of its own: the page on screen when that is the list, else
  the cached page for the list's path with the row selected that was left selected there.
  Nil without a list.
  """
  def list_model(%{columns: %{list: nil}}), do: nil
  def list_model(%{columns: %{list: path}, path: path} = model), do: model

  def list_model(%{columns: %{list: path}} = model) do
    case PageCache.get(model.console.cache, path) do
      nil ->
        nil

      page ->
        base = %Model{env: model.env, console: model.console, connected: true, now: model.now}
        list = Model.message(base, Interactions.content(page))
        selected = Selection.after_replace(model.console.selections[path], Model.rows(list))
        %{list | selected: selected || 0, columns: %{list.columns | list: path}}
    end
  end

  @doc "Whether `model` is drawn as the list column: the list, beside the page."
  def list_column?(model), do: nothing_open?(model) and shown?(model)

  @doc "Whether no row's page is open beside the list (the list itself is on screen)."
  def nothing_open?(model), do: model.path == model.columns.list

  @doc """
  The column with the focus: the sidebar only while it is shown, details only while they
  have related items.
  """
  def focus(model) do
    case model.columns.focus do
      :sidebar -> if sidebar?(model), do: :sidebar, else: :list
      _ when model.path == model.columns.list -> :list
      :details -> if related(model) == [], do: :page, else: :details
      focus -> focus
    end
  end

  @doc "The ids of the blocks in the page's details (parts of role details or related)."
  def details_ids(%{markup: []}), do: MapSet.new()

  def details_ids(model) do
    model.ids
    |> AtlasBFF.Markup.tree(model.markup)
    |> Enum.flat_map(fn
      {:markup, %{"value" => %Part{role: role}}, children} when role in @details_roles ->
        Enum.flat_map(children, &ids_in/1)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp ids_in({:block, id}), do: [id]
  defp ids_in({:markup, _entry, children}), do: Enum.flat_map(children, &ids_in/1)

  @doc "Where in the page's one selection its related items are: rows in its details that open a page."
  def related(model), do: indexes(model, true)

  # The rows of the page's lists in (or out of) its details, as places in its selection.
  defp indexes(model, details?) do
    ids = details_ids(model)

    {found, _} =
      Enum.flat_map_reduce(Model.lists(model), 0, fn {id, list}, at ->
        rows = list.rows || []

        found =
          if MapSet.member?(ids, id) == details?,
            do:
              for(
                {row, i} <- Enum.with_index(rows),
                not details? or is_binary(row.to),
                do: at + i
              ),
            else: []

        {found, at + length(rows)}
      end)

    found
  end

  # Keys

  @doc """
  A key the columns take: the focus keys, and ↑/↓ (or what Control binds to the previous
  and next row) in the column with the focus. Nil: the key works as in one column, and so
  does every key while a key sequence (`g …`, a row number) is being typed.
  """
  def key(model, key) do
    if model.console.key_prefix == "" and model.console.key_buffer == "" and shown?(model) and
         Interactions.content_context(model) == "browse",
       do: take(model, focus(model), direction(model, key))
  end

  @doc "A mouse click at column `x`, row `y` (from 1): the column under it takes the focus."
  def click(model, x, y) do
    {width, _height} = model.console.viewport
    header = length(ConsoleView.header(model, width))

    column =
      Enum.find_value(geometry(width), fn {column, left, w} ->
        if x - 1 >= left and x - 1 < left + w, do: column
      end)

    if shown?(model) and y > header and column != nil,
      do: focus_on(model, column),
      else: model
  end

  defp direction(_model, key) when key in [:up, :down, :left, :right, :enter, :esc], do: key
  defp direction(_model, key) when key in [:page_up, :page_down], do: key

  defp direction(model, {:char, _} = key) do
    case Interactions.operation(model, key) do
      "list_previous" -> :up
      "list_next" -> :down
      _ -> key
    end
  end

  defp direction(_model, key), do: key

  defp take(model, _focus, :esc), do: {focus_on(model, :list), []}
  defp take(model, :list, :up), do: follow(model, list_selected(model) - 1)
  defp take(model, :list, :down), do: follow(model, list_selected(model) + 1)
  defp take(model, :list, :page_up), do: follow(model, list_selected(model) - page(model))
  defp take(model, :list, :page_down), do: follow(model, list_selected(model) + page(model))
  defp take(model, :list, key) when key in [:right, :enter], do: {focus_on(model, :page), []}
  defp take(model, :list, :left), do: {focus_on(model, :sidebar), []}
  defp take(model, :sidebar, :up), do: sidebar_move(model, -1)
  defp take(model, :sidebar, :down), do: sidebar_move(model, 1)
  defp take(model, :sidebar, key) when key in [:right, :enter], do: {focus_on(model, :list), []}
  defp take(model, :sidebar, :left), do: {model, []}
  defp take(model, :page, :left), do: {focus_on(model, :list), []}
  defp take(model, :page, :right), do: {focus_on(model, :details), []}
  defp take(model, :page, key) when key in [:up, :down], do: page_move(model, key)
  defp take(model, :details, :left), do: {focus_on(model, :page), []}
  defp take(model, :details, :up), do: {choose(model, related(model), -1), []}
  defp take(model, :details, :down), do: {choose(model, related(model), 1), []}

  defp take(model, :details, key) when key in [:right, :enter] do
    case Enum.at(Model.rows(model), model.selected) do
      %{to: to} when is_binary(to) ->
        Console.open(put_in(model.columns.focus, :page), to)

      _ ->
        {model, []}
    end
  end

  # Page up and down scroll the page or the details from where the last frame showed it
  # (`model.viewports`, by column); the arrows make it follow the selection again.
  defp take(model, column, key)
       when column in [:page, :details] and key in [:page_up, :page_down] do
    case model.viewports[column] do
      %{start: start, last: last, step: step} ->
        by = if key == :page_up, do: -step, else: step
        {put_in(model.columns.scroll[column], (start + by) |> min(last) |> max(0)), []}

      nil ->
        {model, []}
    end
  end

  defp take(_model, _focus, _key), do: nil

  # In the page, the arrows choose as in one column (a panel's items, a decision's options,
  # the commands of instructions), and among its own rows where Control binds them to the
  # rows: never into the details.
  defp page_move(model, key) do
    panel = Model.panel(model)

    cond do
      Model.options(model) != [] ->
        nil

      panel != nil and Model.panel_choices(panel) != [] ->
        nil

      Model.commands(model) != [] ->
        nil

      Interactions.operation(model, key) in ["list_previous", "list_next"] ->
        {choose(model, indexes(model, false), if(key == :up, do: -1, else: 1)), []}

      true ->
        nil
    end
  end

  # The selection moved among `places` (in the page's one selection), the column scrolled
  # to follow it.
  defp choose(model, [], _by), do: model

  defp choose(model, places, by) do
    at = Enum.find_index(places, &(&1 == model.selected))
    to = if at, do: (at + by) |> max(0) |> min(length(places) - 1), else: 0
    %{model | selected: Enum.at(places, to), scroll: nil, columns: %{model.columns | scroll: %{}}}
  end

  defp focus_on(model, :details) do
    case related(model) do
      [] ->
        model

      places ->
        model = if model.selected in places, do: model, else: %{model | selected: hd(places)}
        put_in(model.columns.focus, :details)
    end
  end

  defp focus_on(model, :page) do
    if nothing_open?(model) do
      model
    else
      main = indexes(model, false)

      model =
        if model.selected in related(model) and main != [],
          do: %{model | selected: hd(main)},
          else: model

      put_in(model.columns.focus, :page)
    end
  end

  defp focus_on(model, :sidebar),
    do: if(sidebar?(model), do: put_in(model.columns.focus, :sidebar), else: model)

  defp focus_on(model, column), do: put_in(model.columns.focus, column)

  # The sidebar row `by` away from the one shown opens at once (its tab or group), the
  # focus kept in the sidebar.
  defp sidebar_move(model, by) do
    rows = sidebar_rows(model)
    at = sidebar_at(model)
    to = if at, do: (at + by) |> max(0) |> min(length(rows) - 1), else: 0

    case Enum.at(rows, to) do
      %{to: path} when path != model.columns.list -> Console.to_tab(model, path)
      _ -> {model, []}
    end
  end

  defp list_selected(model), do: list_model(model).selected

  # How far a page key moves: the body's height, less a line kept in sight.
  defp page(model) do
    {_width, height} = model.console.viewport
    max(height - 12, 1)
  end

  # Following the list

  @doc """
  Keeps the columns in step after a key or a page: a tab's own page on screen is the list
  to follow (its focus starts there); while it is on screen beside the page column, its
  selected row opens.
  """
  def settle({model, effects}) do
    {model, more} = settle(model)
    {model, effects ++ more}
  end

  def settle(model) do
    model = track(model)

    if model.columns.list != nil and nothing_open?(model) and shown?(model) and
         model.console.expected in [nil, model.path] and not Console.draft?(model),
       do: follow(model, model.selected),
       else: {model, []}
  end

  # A tab's page, or one of its groups, on screen becomes the list; the focus goes to it,
  # unless it is in the sidebar, which chose it.
  defp track(%{console: %{shell: %{"tabs" => tabs}, expected: expected}} = model)
       when expected in [nil, model.path] do
    tab? =
      Enum.any?(tabs, fn tab ->
        tab["to"] == model.path or Enum.any?(tab["groups"] || [], &(&1["to"] == model.path))
      end)

    if model.path != model.columns.list and tab? and list_page?(model) do
      focus = if model.columns.focus == :sidebar, do: :sidebar, else: :list
      %{model | columns: %{model.columns | list: model.path, focus: focus, scroll: %{}}}
    else
      model
    end
  end

  defp track(model), do: model

  # A page of lists (and the groups that filter them), not one about a fact.
  defp list_page?(model) do
    Enum.any?(model.blocks, &match?(%Blocks.List{}, &1)) and
      Enum.all?(model.blocks, &(match?(%Blocks.List{}, &1) or match?(%Blocks.Groups{}, &1)))
  end

  # Select row `index` of the list, and open its page beside it.
  defp follow(model, index) do
    path = model.columns.list
    rows = Model.rows(list_model(model))
    index = index |> max(0) |> min(max(length(rows) - 1, 0))
    selection = Selection.of(rows, index)

    model = %{
      model
      | console: %{model.console | selections: Map.put(model.console.selections, path, selection)},
        columns: %{model.columns | scroll: %{}}
    }

    model = if nothing_open?(model), do: %{model | selected: index}, else: model

    case Enum.at(rows, index) do
      %{to: to} when is_binary(to) ->
        if to == (model.console.expected || model.path),
          do: {model, []},
          else: Console.follow(model, path, selection, to)

      _ ->
        {model, []}
    end
  end

  # The key line

  # What the column keys say, by the column with the focus.
  @doc """
  The bottom key line for the column with the focus, as `[{key, label}]`: how the focus
  moves, then (in the page) the open item's own actions.
  """
  def keys(model) do
    related? = related(model) != []

    case focus(model) do
      :sidebar ->
        [{"↑↓", "Choose"}, {"→", "List"}]

      :list ->
        [{"↑↓", "Choose"}] ++
          if(sidebar?(model), do: [{"←", "Tabs"}], else: []) ++
          if(nothing_open?(model), do: [], else: [{"→", "Page"}])

      :page ->
        choose? =
          Model.options(model) != [] or
            (Model.panel(model) != nil and Model.panel_choices(Model.panel(model)) != []) or
            Model.commands(model) != [] or indexes(model, false) != []

        if(choose?, do: [{"↑↓", "Choose"}], else: []) ++
          [{"←", "List"}] ++ if(related?, do: [{"→", "Related"}], else: []) ++ item_keys(model)

      :details ->
        [{"↑↓", "Choose"}, {"→", "Open"}, {"←", "Page"}, {"Esc", "List"}]
    end
  end

  # Control's operations every page has; the rest are the open item's own.
  @generic ~w(tab_next tab_previous list_next list_previous open_selected back refresh
              legend_open agent_ask quit scroll_up scroll_down page_previous page_next
              part_next part_previous sections_toggle)

  defp item_keys(model) do
    tabs = for tab <- (model.console.shell || %{})["tabs"] || [], do: tab["to"]

    for action <- Interactions.active(model),
        props = action["props"],
        props["available"],
        operation = props["operation"],
        operation["name"] not in @generic,
        not (operation["name"] == "open" and operation["to"] in tabs),
        uniq: true,
        do: {Enum.join(props["keys"], " "), props["label"]}
  end
end
