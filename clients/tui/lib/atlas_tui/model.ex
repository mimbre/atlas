defmodule AtlasTui.Model do
  @moduledoc """
  Console content and local editor state. `message/2` installs decoded page content;
  `key/2` resolves the current BFF Console actions through `AtlasTui.Interactions`.
  Only Ctrl+C is a universal terminal escape; there is no local navigation key table.

  Pages divided by part markup have independent manual scroll positions. List rows
  share one selection (`rows/1`); moving it resumes following only its owning pane.

  Declared agent actions open a request editor or request a plan. Plans and step
  drafts remain local while page content follows server updates. Agent effects are
  `{:agent, message}` and replies arrive through `agent/2`.
  """

  alias AtlasTui.{Blocks, Selection, Text}
  alias AtlasTui.Blocks.{Confirm, Form, Input, Item, Part, Plan, Section}
  alias AtlasTui.Blocks.List, as: ListBlock

  @scroll_step 10

  defstruct console: nil,
            conversation: nil,
            env: nil,
            connected: false,
            path: nil,
            title: "",
            # What waits for the user, as Control words it (`count` on every page), or nil.
            count: nil,
            back: nil,
            blocks: [],
            # The view model's block ids, in order, and its markup (decoded entries).
            ids: [],
            markup: [],
            selected: 0,
            # A page longer than the screen: nil follows the selected row or the focus;
            # a number of lines is scrolled to by page up and page down.
            scroll: nil,
            # The part with the focus (nil: the one with the lists), and how far each part
            # is scrolled by hand (by part number; missing: its top, or its selected row).
            part: nil,
            scrolls: %{},
            # Whether the page's collapsible sections are open (`sections_toggle`); a new
            # page starts with them folded.
            unfolded: false,
            # Bounds and page sizes from the last rendered frame, keyed by part number.
            viewports: %{},
            focus: 0,
            # Where typing goes in a multi-line input: `{line, column}`, nil for the end.
            cursor: nil,
            values: %{},
            notice: nil,
            updated: nil,
            last_hint: nil,
            waiting: false,
            closed: false,
            # The request line (`:`): its text while it is open, nil when closed.
            ask: nil,
            # The agent's plan for the last request, shown over the page; nil when none.
            plan: nil,
            # What the user makes of a proposed plan: the selected step, the steps they
            # dropped, the values they edited (by step number), the step being edited.
            steps: %{selected: 0, dropped: MapSet.new(), values: %{}, editing: nil}

  @no_steps %{selected: 0, dropped: MapSet.new(), values: %{}, editing: nil}

  def new(env), do: %__MODULE__{env: env, console: AtlasTui.Console.new()}

  # Messages from Control

  def message(model, %{"op" => "welcome"}), do: %{model | connected: true, notice: nil}

  def message(model, %{"op" => "bye", "text" => text}),
    do: %{model | notice: %{tone: "error", text: text}, closed: true}

  def message(model, %{"op" => "notice"} = msg) do
    notice = %{tone: msg["tone"], text: msg["text"], at: msg["at"]}
    %{model | notice: notice, waiting: msg["tone"] == "pending"}
  end

  def message(model, %{"op" => "page"} = msg) do
    {blocks, ids, markup} = Blocks.view_model(msg)
    same = msg["path"] == model.path
    before = if same, do: Selection.of(rows(model), model.selected)
    updated = %{reason: msg["reason"], at: msg["at"], position: msg["position"]}

    model = %{
      model
      | path: msg["path"],
        title: msg["title"] || "",
        count: msg["count"],
        back: msg["back"],
        blocks: blocks,
        ids: ids,
        markup: markup,
        updated: updated,
        waiting: model.waiting and msg["reason"] not in ["stored", "refused"]
    }

    model = %{
      model
      | selected: Selection.after_replace(before, rows(model)) || 0,
        focus: if(same, do: model.focus, else: 0),
        cursor: if(same, do: model.cursor, else: nil),
        scroll: if(same, do: model.scroll, else: first_scroll(blocks)),
        part: if(same, do: model.part, else: nil),
        scrolls: if(same, do: model.scrolls, else: %{}),
        unfolded: same and model.unfolded
    }

    model = if msg["reason"] == "hint", do: %{model | last_hint: updated}, else: model

    if same and step_form(model) != nil do
      # Background hints update the page beneath the local step editor. Its inputs
      # belong to the draft, not to that page, and must survive the redraw.
      model
    else
      case form(model) do
        %Form{inputs: inputs} -> %{model | values: Map.new(inputs, &{&1.name, &1.value || ""})}
        nil -> %{model | values: %{}}
      end
    end
  end

  def message(model, _other), do: model

  # Messages from the agent

  @doc "What the agent sent: the plan as it is now, or a notice."
  def agent(%{plan: nil} = model, %{"op" => "plan"}), do: model

  def agent(model, %{"op" => "plan", "block" => block}) do
    case Blocks.decode(block) do
      %Plan{} = plan ->
        # A new proposal starts with every step kept, as the agent made it.
        fresh = plan.state == "proposed" and model.plan.state != "proposed"
        steps = if fresh, do: @no_steps, else: model.steps
        # "Stopping after this step…" is answered by the plan itself once it ends.
        over = plan.state in ["done", "stopped", "failed"] and model.plan.state == "running"
        notice = if over and match?(%{tone: "pending"}, model.notice), do: nil, else: model.notice
        advance_mode(%{model | plan: plan, steps: steps, notice: notice})

      _ ->
        %{model | notice: %{tone: "error", text: "The agent sent a plan this TUI cannot show."}}
    end
  end

  def agent(model, %{"op" => "notice"} = msg),
    do: %{model | notice: %{tone: msg["tone"], text: msg["text"], at: msg["at"]}}

  def agent(model, _other), do: model

  @doc "The agent stopped (its process ended); a plan it was making or running is lost."
  def agent_gone(model, why) do
    plan =
      case model.plan do
        %Plan{state: state} = plan when state in ["planning", "running"] ->
          %{plan | state: "failed", title: "The agent stopped", summary: why}

        other ->
          other
      end

    updated = %{model | plan: plan, notice: %{tone: "error", text: "The agent stopped: #{why}"}}
    if plan != model.plan, do: advance_mode(updated), else: updated
  end

  # A page about one fact opens at its top, even when a list under it has a selected row.
  defp first_scroll(blocks), do: if(Enum.any?(blocks, &match?(%Item{}, &1)), do: 0, else: nil)

  def disconnected(model), do: AtlasTui.Console.disconnected(model)

  # The block that takes the keys.

  def form(model), do: Enum.find(model.blocks, &match?(%Form{}, &1))

  @doc """
  The form a step of the plan is edited in: the step's inputs, as Control's form for it
  has them. nil when no step is being edited.
  """
  def step_form(%{plan: %Plan{} = plan, steps: %{editing: n}}) when n != nil do
    step = Enum.find(plan.steps, &(&1.n == n))

    %Form{
      title: "Step #{n}: #{step.label}",
      inputs: step.inputs || [],
      submit_label: "Keep",
      submit_to: nil,
      cancel_to: ""
    }
  end

  def step_form(_model), do: nil

  @doc """
  The steps as they would run: dropped ones marked dropped, edited values in place.
  """
  def plan_steps(%{plan: %Plan{state: "proposed"} = plan, steps: steps}) do
    Enum.map(plan.steps, fn step ->
      step =
        case steps.values[step.n] do
          nil ->
            step

          values ->
            inputs =
              Enum.map(step.inputs || [], &%{&1 | value: Map.get(values, &1.name, &1.value)})

            %{step | inputs: inputs}
        end

      if MapSet.member?(steps.dropped, step.n), do: %{step | state: "dropped"}, else: step
    end)
  end

  def plan_steps(%{plan: %Plan{} = plan}), do: plan.steps
  def plan_steps(_model), do: []
  def confirm(model), do: Enum.find(model.blocks, &match?(%Confirm{}, &1))

  @doc "The rows of every list on the page, in order: one selection."
  def rows(model), do: Enum.flat_map(lists(model), fn {_id, list} -> list.rows || [] end)

  @doc """
  The page's lists a reader can reach, as `{id, list}` in page order: all of them but those
  inside a folded collapsible section. Their rows are the page's one selection.
  """
  def lists(model) do
    hidden = folded(model)

    for {id, %ListBlock{} = list} <- Enum.zip(model.ids, model.blocks),
        not MapSet.member?(hidden, id),
        do: {id, list}
  end

  @doc "The ids of the blocks inside the page's collapsible sections while they are folded."
  def folded(%__MODULE__{unfolded: true}), do: MapSet.new()
  def folded(%__MODULE__{markup: []}), do: MapSet.new()

  def folded(model) do
    model.ids
    |> AtlasBFF.Markup.tree(model.markup)
    |> folded_ids()
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  defp folded_ids(nodes) do
    Enum.flat_map(nodes, fn
      {:markup, %{"value" => %Section{collapsible: true}}, children} ->
        Enum.flat_map(children, &ids_in/1)

      {:markup, _entry, children} ->
        folded_ids(children)

      {:block, _id} ->
        []
    end)
  end

  @doc """
  The parts of a page: the block ids of each, when the page's markup divides all of it
  into two or more parts (`part` markup at the top). `[]` for a page in one part.
  """
  def parts(%__MODULE__{markup: []}), do: []

  def parts(model) do
    case AtlasBFF.Markup.tree(model.ids, model.markup) do
      [_, _ | _] = nodes ->
        if Enum.all?(nodes, &part?/1), do: Enum.map(nodes, &ids_in/1), else: []

      _ ->
        []
    end
  end

  @doc "Whether a node of the markup tree is a part."
  def part?({:markup, %{"value" => %Part{}}, _children}), do: true
  def part?(_node), do: false

  defp ids_in({:block, id}), do: [id]
  defp ids_in({:markup, _entry, children}), do: Enum.flat_map(children, &ids_in/1)

  @doc "The focused part, or the first part containing a list before focus is moved."
  def part(model) do
    parts = parts(model)

    lists =
      for {id, %ListBlock{}} <- Enum.zip(model.ids, model.blocks), into: MapSet.new(), do: id

    cond do
      parts == [] -> nil
      model.part != nil -> rem(model.part, length(parts))
      true -> Enum.find_index(parts, fn ids -> Enum.any?(ids, &(&1 in lists)) end) || 0
    end
  end

  @doc "Whether the TUI opens `url`: only an http or https address with a host."
  def openable?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        not String.match?(url, ~r/[\s\x00-\x1f]/)

      _ ->
        false
    end
  end

  def openable?(_url), do: false

  @doc "What can take focus in a form: its inputs (not the read-only ones), then the buttons."
  def focusable(%Form{inputs: inputs}),
    do: Enum.reject(inputs, &(&1.kind == "readonly")) ++ [:submit, :cancel]

  # Keys

  def key(model, :ctrl_c), do: {model, [:quit]}

  def key(model, key) do
    {model, effects} = AtlasTui.Interactions.key(model, key)
    {AtlasTui.WorkerConversation.capture(model), effects}
  end

  @doc "Literal editor input; Console commands are dispatched only from BFF actions."
  def literal(model, {:char, _} = key) do
    cond do
      model.ask != nil -> ask_key(model, model.ask, key)
      form = step_form(model) -> step_form_key(model, form, key)
      form = form(model) -> form_key(model, form, key)
      true -> {model, []}
    end
  end

  def literal(model, _key), do: {model, []}

  @doc "Finite Console operations; callers resolve a current declared action first."
  def operation(model, "list_next"), do: operation(model, "move_next")
  def operation(model, "list_previous"), do: operation(model, "move_previous")
  def operation(model, "scroll_up"), do: operation(model, "page_previous")
  def operation(model, "scroll_down"), do: operation(model, "page_next")
  def operation(model, "submit"), do: operation(model, "submit_form")
  def operation(model, "cancel"), do: operation(model, "cancel_form")

  def operation(model, "open_selected") do
    case Enum.at(rows(model), model.selected) do
      nil -> {model, []}
      row -> AtlasTui.Console.open(model, row.to)
    end
  end

  def operation(model, "move_next"),
    do: select(model, min(model.selected + 1, max(length(rows(model)) - 1, 0)))

  def operation(model, "move_previous"), do: select(model, max(model.selected - 1, 0))
  def operation(model, "select_first"), do: select(model, 0)

  def operation(model, "select_last"),
    do: select(model, max(length(rows(model)) - 1, 0))

  def operation(model, "back"), do: AtlasTui.Console.back(model)
  def operation(model, "refresh"), do: {model, [{:send, %{"op" => "refresh"}}]}
  def operation(model, "quit"), do: {model, [:quit]}

  # Folds or unfolds the page's collapsible sections; the selection stays on a reachable row.
  def operation(model, "sections_toggle") do
    model = %{model | unfolded: not model.unfolded}
    {%{model | selected: min(model.selected, max(length(rows(model)) - 1, 0))}, []}
  end

  def operation(model, name) when name in ["page_next", "page_previous"] do
    by = if name == "page_next", do: @scroll_step, else: -@scroll_step

    case part(model) do
      nil -> {%{model | scroll: max((model.scroll || 0) + by, 0)}, []}
      part -> {scroll_part(model, part, by), []}
    end
  end

  def operation(model, name) when name in ["part_next", "part_previous"] do
    count = length(parts(model))

    if count > 0 do
      step = if name == "part_next", do: 1, else: -1
      {%{model | part: Integer.mod((part(model) || 0) + step, count)}, []}
    else
      {model, []}
    end
  end

  def operation(model, name) when name in ["focus_next", "focus_previous"] do
    case step_form(model) || form(model) do
      nil ->
        {model, []}

      form ->
        step = if name == "focus_next", do: 1, else: -1
        focus = Integer.mod(model.focus + step, length(focusable(form)))
        {focus_to(model, focus), []}
    end
  end

  def operation(model, "submit_form") do
    cond do
      form = form(model) -> submit(model, form.submit_to, model.values)
      confirm = confirm(model) -> submit(model, confirm.confirm_to, %{})
      true -> {model, []}
    end
  end

  def operation(model, "cancel_form") do
    cond do
      form = form(model) -> AtlasTui.Console.navigate(model, form.cancel_to)
      confirm = confirm(model) -> AtlasTui.Console.navigate(model, confirm.cancel_to)
      true -> {model, []}
    end
  end

  def operation(model, "form_enter"), do: editor_operation(model, :enter)
  def operation(model, "input_up"), do: editor_operation(model, :up)
  def operation(model, "input_down"), do: editor_operation(model, :down)
  def operation(model, "input_left"), do: editor_operation(model, :left)
  def operation(model, "input_right"), do: editor_operation(model, :right)
  def operation(model, "input_home"), do: editor_operation(model, :home)
  def operation(model, "input_end"), do: editor_operation(model, :end)
  def operation(model, "input_backspace"), do: editor_operation(model, :backspace)

  def operation(%{ask: text} = model, "ask_send") when is_binary(text),
    do: ask_key(model, text, :enter)

  def operation(model, "ask_cancel"), do: {advance_mode(%{model | ask: nil}), []}

  def operation(%{plan: %Plan{state: state}} = model, "plan_cancel")
      when state in ["planning", "proposed"],
      do: close_plan(model, [{:agent, %{"op" => "cancel"}}])

  def operation(%{plan: %Plan{state: "proposed"}} = model, "plan_run"), do: run(model)

  def operation(%{plan: %Plan{state: "proposed"}} = model, "plan_toggle") do
    case Enum.at(model.plan.steps, model.steps.selected) do
      nil ->
        {model, []}

      selected ->
        dropped =
          if MapSet.member?(model.steps.dropped, selected.n),
            do: MapSet.delete(model.steps.dropped, selected.n),
            else: MapSet.put(model.steps.dropped, selected.n)

        {put_in(model.steps.dropped, dropped), []}
    end
  end

  def operation(%{plan: %Plan{state: "proposed"}} = model, "plan_edit") do
    case Enum.at(model.plan.steps, model.steps.selected) do
      %{inputs: [_ | _]} = selected -> edit_step(model, selected)
      _ -> {model, []}
    end
  end

  def operation(%{plan: %Plan{}} = model, "plan_previous"),
    do: {put_in(model.steps.selected, max(model.steps.selected - 1, 0)), []}

  def operation(%{plan: %Plan{}} = model, "plan_next"),
    do:
      {put_in(
         model.steps.selected,
         min(model.steps.selected + 1, max(length(model.plan.steps) - 1, 0))
       ), []}

  def operation(%{plan: %Plan{state: "running"}} = model, "plan_stop") do
    notice = %{tone: "pending", text: "Stopping after this step…"}
    {%{model | notice: notice}, [{:agent, %{"op" => "stop"}}]}
  end

  def operation(%{plan: %Plan{state: state}} = model, "plan_close")
      when state not in ["planning", "running", "proposed"],
      do: close_plan(model, [])

  def operation(model, "step_save") do
    if step_form(model) do
      steps = %{
        model.steps
        | editing: nil,
          values: Map.put(model.steps.values, model.steps.editing, model.values)
      }

      {advance_mode(%{model | steps: steps, values: %{}, waiting: false}), []}
    else
      {model, []}
    end
  end

  def operation(model, "step_cancel") do
    if step_form(model),
      do: {advance_mode(%{model | steps: %{model.steps | editing: nil}, values: %{}}), []},
      else: {model, []}
  end

  # IS121 supplies legend presentation. Unknown/unimplemented operations do not run.
  def operation(model, _unknown),
    do: {%{model | notice: %{tone: "error", text: "Action unavailable in this Console"}}, []}

  # Following the selection clears only the pane that contains the selected row.
  # Other panes retain the reader's independent manual position.
  defp select(model, selected) do
    {id, _offset} =
      Enum.reduce_while(lists(model), {nil, selected}, fn
        {id, %ListBlock{rows: rows}}, {nil, offset} ->
          count = length(rows || [])

          if offset < count,
            do: {:halt, {id, offset}},
            else: {:cont, {nil, offset - count}}

        _, acc ->
          {:cont, acc}
      end)

    pane = Enum.find_index(parts(model), &(id in &1))

    updated =
      if pane == nil,
        do: %{model | selected: selected, scroll: nil},
        else: %{model | selected: selected, scrolls: Map.delete(model.scrolls, pane)}

    {updated, []}
  end

  defp editor_operation(model, key) do
    cond do
      model.ask != nil -> ask_key(model, model.ask, key)
      form = step_form(model) -> step_form_key(model, form, key)
      form = form(model) -> form_key(model, form, key)
      true -> {model, []}
    end
  end

  def external(model, url), do: open_url(model, url)
  def agent_action(model, _label, nil), do: {advance_mode(%{model | ask: ""}), []}
  def agent_action(model, label, intent), do: ask_agent(model, label, intent)

  # Literal request text and editor operations resolved from declared Console actions.
  defp ask_key(model, text, key) do
    case key do
      {:char, c} ->
        {%{model | ask: text <> c}, []}

      :backspace ->
        {%{model | ask: String.slice(text, 0..-2//1)}, []}

      :enter ->
        case String.trim(text) do
          "" ->
            {advance_mode(%{model | ask: nil}), []}

          request ->
            ask_agent(%{model | ask: nil}, request, nil)
        end

      _ ->
        {model, []}
    end
  end

  # Ask the agent about the page you are on; its plan shows over the page.
  defp ask_agent(model, request, intent) do
    plan = %Plan{title: "Planning…", request: request, state: "planning", steps: []}
    ask = %{"op" => "ask", "request" => request, "on" => model.path || "/"}
    ask = if intent, do: Map.put(ask, "intent", intent), else: ask
    {advance_mode(%{model | plan: plan, steps: @no_steps, notice: nil}), [{:agent, ask}]}
  end

  # Captured actions belong to one local editor/plan lifetime, even when a cycle
  # returns to the same context, focus and page without another server projection.
  defp advance_mode(model), do: update_in(model.console.generation, &(&1 + 1))

  defp close_plan(model, effects),
    do: {advance_mode(%{model | plan: nil, steps: @no_steps}), effects}

  # Enter runs the kept steps, in order, with their edited values.
  defp run(model) do
    kept = Enum.reject(plan_steps(model), &(&1.state == "dropped"))

    case Enum.filter(kept, &(&1.state == "blocked")) do
      [] when kept == [] ->
        {%{model | notice: %{tone: "info", text: "Every step is dropped; cancel this plan."}}, []}

      [] ->
        steps =
          for step <- kept,
              do: %{
                "n" => step.n,
                "values" => Map.new(step.inputs || [], &{&1.name, &1.value || ""})
              }

        {model, [{:agent, %{"op" => "run", "steps" => steps}}]}

      blocked ->
        text = "Step #{Enum.map_join(blocked, ", ", & &1.n)} cannot run; drop it before running."
        {%{model | notice: %{tone: "error", text: text}}, []}
    end
  end

  # Editing a step retains its draft until the declared save or cancel action.
  defp edit_step(model, step) do
    values = Map.new(step.inputs, &{&1.name, &1.value || ""})
    values = Map.merge(values, model.steps.values[step.n] || %{})
    model = %{model | values: values, focus: 0, cursor: nil}
    {advance_mode(put_in(model.steps.editing, step.n)), []}
  end

  defp step_form_key(model, form, key) do
    {edited, effects} = form_key(model, form, key)

    case effects do
      [{:send, %{"op" => "submit"}}] -> operation(edited, "step_save")
      _ -> {edited, effects}
    end
  end

  defp form_key(model, %Form{} = form, key) do
    items = focusable(form)
    focus = min(model.focus, length(items) - 1)
    current = Enum.at(items, focus)

    case {key, current} do
      # Text of several lines: enter starts a new line, the arrows move in the text, and
      # leave it past its first or last line; tab always goes on.
      {k, %Input{kind: "multiline", name: name}} when k not in [:tab, :shift_tab] ->
        case Text.key(model.values[name] || "", model.cursor, k) do
          {:ok, text, cursor} -> {%{put_in(model.values[name], text) | cursor: cursor}, []}
          {:leave, :up} -> {focus_to(model, focus - 1), []}
          {:leave, :down} -> {focus_to(model, focus + 1), []}
          :ignore -> {model, []}
        end

      {k, _} when k in [:up, :shift_tab] ->
        {focus_to(model, focus - 1), []}

      {k, _} when k in [:down, :tab] ->
        {focus_to(model, focus + 1), []}

      {:enter, :submit} ->
        submit(model, form.submit_to, model.values)

      {:enter, :cancel} ->
        if step_form(model),
          do: operation(model, "step_cancel"),
          else: AtlasTui.Console.navigate(model, form.cancel_to || model.back)

      {:enter, %Input{}} ->
        {focus_to(model, focus + 1), []}

      {k, :submit} when k in [:left, :right] ->
        {focus_to(model, focus + 1), []}

      {k, :cancel} when k in [:left, :right] ->
        {focus_to(model, focus - 1), []}

      {k, %Input{kind: kind} = input} when kind in ["choice", "boolean"] ->
        choose(model, input, k)

      {{:char, c}, %Input{} = input} ->
        edit(model, input, &(&1 <> c))

      {:backspace, %Input{} = input} ->
        edit(model, input, &String.slice(&1, 0..-2//1))

      _ ->
        {model, []}
    end
  end

  # Moving down into a multi-line input starts at its beginning; moving up, at its end.
  defp focus_to(model, to) do
    last = length(focusable(step_form(model) || form(model))) - 1
    to = to |> max(0) |> min(last)

    cond do
      to > model.focus -> %{model | focus: to, cursor: {0, 0}}
      to < model.focus -> %{model | focus: to, cursor: nil}
      true -> model
    end
  end

  defp choose(model, %Input{choices: choices, name: name}, key) do
    values = Enum.map(choices || [], & &1.value)
    at = Enum.find_index(values, &(&1 == model.values[name])) || 0

    step =
      case key do
        :left -> -1
        k when k in [:right, {:char, " "}] -> 1
        _ -> 0
      end

    if values == [] or step == 0 do
      {model, []}
    else
      value = Enum.at(values, rem(at + step + length(values), length(values)))
      {put_in(model.values[name], value), []}
    end
  end

  defp edit(model, %Input{kind: "text", name: name}, fun),
    do: {put_in(model.values[name], fun.(model.values[name] || "")), []}

  defp edit(model, _input, _fun), do: {model, []}

  # Move from the displayed position, with overlap and no accumulated overscroll.
  defp scroll_part(model, part, by) do
    case model.viewports[part] do
      nil ->
        model

      %{start: start, last: last, step: step} ->
        at = min(model.scrolls[part] || start, last)
        next = at + if(by > 0, do: step, else: -step)
        put_in(model.scrolls[part], next |> max(0) |> min(last))
    end
  end

  defp open_url(model, url) do
    if openable?(url),
      do:
        {%{model | notice: %{tone: "info", text: "Opened #{url} in the browser"}},
         [{:open_url, url}]},
      else:
        {%{model | notice: %{tone: "error", text: "Not opened: only http and https addresses"}},
         []}
  end

  # A form's submit_to (or a confirm's confirm_to) names the endpoint and its params; the
  # submit carries them as they are. A step form being edited has none: it stays here.
  defp submit(model, %Blocks.Call{endpoint: "queue_worker_guidance", params: params}, values),
    do: AtlasTui.WorkerConversation.submit(model, params, values)

  defp submit(model, %Blocks.Call{endpoint: endpoint, params: params}, values) do
    message = %{
      "op" => "submit",
      "endpoint" => endpoint,
      "params" => params || %{},
      "values" => values
    }

    {%{model | waiting: true}, [{:send, message}]}
  end

  defp submit(model, _to, values),
    do: {%{model | waiting: true}, [{:send, %{"op" => "submit", "values" => values}}]}
end
