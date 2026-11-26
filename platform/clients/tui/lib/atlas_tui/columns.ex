defmodule AtlasTui.Columns do
  @moduledoc """
  The TUI's columns on a wide terminal (docs/design/apple-clients.md, Columns in the TUI): the list of
  the tab, the page of the row selected in it, and that page's details.

    * From 144 cells: the list (60 wide) beside the page, its details under it.
    * From 210 cells: the list, the page (at most 100) and its details (the rest, at
      most 100) side by side.
    * Narrower: one column at a time, as before.

  The list follows live: moving in it opens the selected row's page at once (its cached
  copy, while Control reads it fresh), as Enter does in one column; back from that page
  in one column returns to the list. The list column is the newest page Control sent for
  the list's path (`AtlasTui.PageCache`), so its hints keep it current.

  One column has the focus. → moves it right (list → page → details), ← left; Enter in
  the list is →; Esc returns it to the list; a mouse click in a column takes it there.
  Details takes it only when it has related items, which ↑/↓ then choose and →/Enter
  open in the page. ↑/↓ act in the column with the focus only; every other key (the
  open item's actions, Tab for the tabs) works as in one column, on the page that is open.
  Pure.
  """

  alias AtlasTui.{Blocks, Console, ConsoleView, Interactions, Model, PageCache, Selection}
  alias AtlasTui.Blocks.Part

  @list 60
  @two 144
  @three 210
  @page 100
  # Parts that hold what a page refers to, drawn in the details column.
  @details_roles ["details", "related"]

  @doc "How a terminal `width` lays out: `:three` columns, `:two`, or `:one` at a time."
  def layout(width) when width >= @three, do: :three
  def layout(width) when width >= @two, do: :two
  def layout(_width), do: :one

  @doc """
  The columns across a terminal `width`, as `{column, x, width}`, centred together: the
  list and the page; from #{@three} cells, the details too. Empty in one column.
  """
  def geometry(width) do
    case layout(width) do
      :one ->
        []

      :two ->
        page = min(width - @list, @page)
        left = div(width - @list - page, 2)
        [{:list, left, @list}, {:page, left + @list, page}]

      :three ->
        details = min(width - @list - @page, @page)
        left = div(width - @list - @page - details, 2)

        [
          {:list, left, @list},
          {:page, left + @list, @page},
          {:details, left + @list + @page, details}
        ]
    end
  end

  @doc "Whether the screen shows columns: wide enough, with a list to follow."
  def shown?(model) do
    {width, _height} = model.console.viewport

    layout(width) != :one and model.connected and model.plan == nil and
      model.console.legend == nil and list_model(model) != nil
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

  @doc "The column with the focus: details only while it has related items."
  def focus(model) do
    case model.columns.focus do
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
  defp take(model, :list, :left), do: {model, []}
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

  # In the page, the arrows choose as in one column (a panel's items or answers, a single
  # choice, the steps' moves Control binds), and among its own rows where Control binds
  # them to the rows: never into the details.
  defp page_move(model, key) do
    panel = Model.panel(model)

    cond do
      Model.single_choice(model) != nil ->
        nil

      panel != nil and Model.panel_choices(panel) != [] ->
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

  defp focus_on(model, column), do: put_in(model.columns.focus, column)

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

  defp track(%{console: %{shell: %{"tabs" => tabs}, expected: expected}} = model)
       when expected in [nil, model.path] do
    if model.path != model.columns.list and Enum.any?(tabs, &(&1["to"] == model.path)) and
         list_page?(model),
       do: %{model | columns: %{model.columns | list: model.path, focus: :list, scroll: %{}}},
       else: model
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
      :list ->
        [{"↑↓", "Choose"}] ++ if(nothing_open?(model), do: [], else: [{"→", "Page"}])

      :page ->
        choose? =
          Model.single_choice(model) != nil or
            (Model.panel(model) != nil and Model.panel_choices(Model.panel(model)) != []) or
            indexes(model, false) != []

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
