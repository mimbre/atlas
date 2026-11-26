defmodule AtlasTui.Interactions do
  @moduledoc """
  Console operations from the current BFF projection. Contract owns validation,
  binding selection and action identity. The renderer adds local focus and shell
  revision checks to reject captured events after its own state changes. On a page of
  decision options, ↑/↓ select an option and Enter answers it with the option's own key; on
  a page with a panel, ↑/↓ select its item (Enter opens it); on a page with instructions,
  ↑/↓ select a command, `c` copies it and `y` all of them.
  """
  alias AtlasTui.{Blocks, Console, Legend, Model}
  alias AtlasBFFContract.Console, as: Contract

  def context(%{console: %{legend: legend}}) when legend != nil, do: "legend"
  def context(model), do: content_context(model)

  def content_context(model) do
    cond do
      Model.step_form(model) ->
        "step_form"

      model.ask != nil ->
        "ask"

      model.plan != nil ->
        "plan_" <>
          if(model.plan.state in ["planning", "proposed", "running"],
            do: model.plan.state,
            else: "done"
          )

      Model.form(model) ->
        "form"

      Model.confirm(model) ->
        "confirm"

      true ->
        "browse"
    end
  end

  def install(model, page) do
    {projection, error} =
      case Contract.compile(page) do
        {:ok, projection} -> {projection, nil}
        {:error, _} -> {nil, "Unsupported or invalid Console actions"}
      end

    console = %{
      model.console
      | projection: projection,
        generation: model.console.generation + 1,
        action_error: error,
        key_buffer: "",
        key_prefix: "",
        legend: if(projection && page["path"] == model.path, do: model.console.legend, else: nil)
    }

    {%{model | console: console}, content(page)}
  end

  @doc "What of `page` is drawn: its blocks and markup but those the Console presents itself."
  def content(page) do
    names = Contract.presentation_names()

    page
    |> Map.put("blocks", Enum.reject(page["blocks"] || [], &(&1["type"] in names.blocks)))
    |> Map.put("markup", Enum.reject(page["markup"] || [], &(&1["kind"] in names.markup)))
  end

  @doc "The name of the operation `key` resolves to on this page now, or nil."
  def operation(%{console: %{projection: nil}}, _key), do: nil

  def operation(model, key) do
    with {:ok, event} <- Contract.capture(model.console.projection, token(key), current(model)),
         {:ok, action} <- Contract.resolve(model.console.projection, event, current(model)) do
      action["props"]["operation"]["name"]
    else
      _ -> nil
    end
  end

  def active(model), do: active_for(model, context(model))

  def active_for(model, context) do
    case Contract.active(model.console.projection, %{current(model) | context: context}) do
      {:ok, actions} ->
        Enum.map(actions, fn action ->
          operation = action["props"]["operation"]

          cond do
            not action["props"]["available"] ->
              action

            not AtlasTui.WorkerConversation.action_available?(model, operation) ->
              unavailable(
                action,
                "No eligible loaded selection or page; a read may be in progress"
              )

            not available?(model, operation) ->
              unavailable(action, "No earlier page to go back to")

            true ->
              action
          end
        end)

      _ ->
        []
    end
  end

  def capture(model, key) do
    case Contract.capture(model.console.projection, token(key), current(model)) do
      {:ok, event} ->
        case Contract.resolve(model.console.projection, event, current(model)) do
          {:ok, action} ->
            if AtlasTui.WorkerConversation.action_available?(model, action["props"]["operation"]) and
                 available?(model, action["props"]["operation"]),
               do: Map.merge(event, %{focus: focus(model), shell_revision: shell_revision(model)})

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  def dispatch(model, nil), do: {model, []}

  def dispatch(model, event) do
    valid = event[:focus] == focus(model) && event[:shell_revision] == shell_revision(model)

    resolved = if valid, do: Contract.resolve(model.console.projection, event, current(model))

    case resolved do
      {:ok, action} ->
        operation = action["props"]["operation"]

        local =
          operation["name"] == "legend_open" or
            (model.console.legend != nil and
               operation["name"] in ~w(legend_close scroll_up scroll_down page_previous page_next))

        # While a page is asked for, only the page kept for it (back, a tab) takes actions.
        pending_allowed =
          model.console.expected in [nil, model.path] or
            operation["name"] in ["tab_next", "tab_previous", "quit"]

        if pending_allowed && AtlasTui.WorkerConversation.action_available?(model, operation) &&
             available?(model, operation) &&
             (local || (model.connected && model.console.phase == :ready)),
           do: execute(model, operation, action["props"]["label"]),
           else: {model, []}

      _ ->
        {model, []}
    end
  end

  # A pending sequence's second key completes it ("g" then "s" is "g s"); any other
  # key, Esc included, only cancels it.
  def key(%{console: %{key_prefix: prefix}} = model, key) when prefix != "" do
    model = put_in(model.console.key_prefix, "")

    case key do
      {:char, char} -> dispatch(model, capture(model, {:char, prefix <> " " <> char}))
      _ -> {model, []}
    end
  end

  def key(model, key) do
    sequences? =
      context(model) == "browse" and
        Enum.any?(active(model), fn action ->
          Enum.any?(action["props"]["keys"], &String.match?(&1, ~r/^[0-9]{2,6}$/))
        end)

    case {sequences?, key, model.console.key_buffer} do
      {true, {:char, digit}, buffer} when digit in ~w(0 1 2 3 4 5 6 7 8 9) ->
        {put_in(model.console.key_buffer, String.slice(buffer <> digit, 0, 7)), []}

      {true, :enter, buffer} when buffer != "" ->
        model = put_in(model.console.key_buffer, "")
        dispatch(model, capture(model, {:char, buffer}))

      {true, :backspace, buffer} when buffer != "" ->
        {put_in(model.console.key_buffer, String.slice(buffer, 0, String.length(buffer) - 1)), []}

      {_, :esc, buffer} when buffer != "" ->
        {put_in(model.console.key_buffer, ""), []}

      _ ->
        model = put_in(model.console.key_buffer, "")

        cond do
          choice = choice_key(model, key) || panel_key(model, key) -> choice
          command = command_key(model, key) -> command
          prefix?(model, key) -> {put_in(model.console.key_prefix, elem(key, 1)), []}
          true -> direct_key(model, key)
        end
    end
  end

  # A page of decision options (`option` blocks): the arrows move the selection among them
  # (from the first) and never answer; Enter answers the selected option exactly as its
  # key does, through the action Control projects for that key (a decline's opens its note
  # form); a key Control does not project does nothing.
  defp choice_key(model, key) when key in [:up, :down, :enter] do
    with "browse" <- context(model),
         [_ | _] = options <- Model.options(model) do
      at = Model.chosen(options, model.choice)

      case key do
        :enter ->
          dispatch(model, capture(model, {:char, Enum.at(options, at).answer.key}))

        move ->
          to = (at + if(move == :up, do: -1, else: 1)) |> max(0) |> min(length(options) - 1)
          {%{model | choice: Enum.at(options, to).answer.key}, []}
      end
    else
      _ -> nil
    end
  end

  defp choice_key(_model, _key), do: nil

  # A page with a panel with items: the arrows move the selection; Enter opens the
  # selected item's page.
  defp panel_key(model, key) when key in [:up, :down, :enter] do
    with "browse" <- context(model),
         %Blocks.Panel{} = panel <- Model.panel(model),
         [_ | _] = choices <- Model.panel_choices(panel) do
      at = Model.panel_chosen(panel, model.choice)

      case {key, Enum.at(choices, at)} do
        {:enter, %Blocks.PanelItem{to: to}} ->
          Console.open(model, to)

        {move, _} ->
          to = (at + if(move == :up, do: -1, else: 1)) |> max(0) |> min(length(choices) - 1)
          {%{model | choice: Enum.at(choices, to).key}, []}
      end
    else
      _ -> nil
    end
  end

  defp panel_key(_model, _key), do: nil

  # A page with instructions: the arrows move the one selection among their commands, c
  # copies the selected one, y all of them; the TUI says so.
  defp command_key(model, key) when key in [:up, :down] do
    if context(model) == "browse" and Model.commands(model) != [],
      do: {Model.move_command(model, if(key == :up, do: -1, else: 1)), []}
  end

  defp command_key(model, {:char, char}) when char in ["c", "y"] do
    with "browse" <- context(model),
         text when is_binary(text) <- Model.copy(model, char) do
      {%{model | notice: %{tone: "ok", text: "copied"}}, [{:copy, text}]}
    else
      _ -> nil
    end
  end

  defp command_key(_model, _key), do: nil

  # Whether `key` starts an action's two-key sequence; a single-key action on the
  # same character keeps it.
  defp prefix?(model, {:char, char}) do
    if context(model) == "browse" do
      keys = Enum.flat_map(active(model), & &1["props"]["keys"])
      char not in keys and Enum.any?(keys, &String.starts_with?(&1, char <> " "))
    else
      false
    end
  end

  defp prefix?(_model, _key), do: false

  defp direct_key(model, key) do
    case capture(model, key) do
      nil ->
        if model.console.legend || model.console.expected,
          do: {model, []},
          else: Model.literal(model, key)

      event ->
        dispatch(model, event)
    end
  end

  defp execute(model, %{"name" => "legend_open"}, _label), do: {Legend.open(model), []}
  defp execute(model, %{"name" => "legend_close"}, _label), do: {Legend.close(model), []}

  defp execute(%{console: %{legend: legend}} = model, %{"name" => operation}, _label)
       when legend != nil and
              operation in ["scroll_up", "scroll_down", "page_previous", "page_next"] do
    updated =
      case operation do
        "scroll_up" -> Legend.scroll(model, -1)
        "scroll_down" -> Legend.scroll(model, 1)
        "page_previous" -> Legend.page(model, -1)
        "page_next" -> Legend.page(model, 1)
      end

    {updated, []}
  end

  defp execute(model, %{"name" => "tab_next"}, _label), do: Console.cycle(model, 1)
  defp execute(model, %{"name" => "tab_previous"}, _label), do: Console.cycle(model, -1)
  defp execute(model, %{"name" => "open", "to" => to}, _label), do: Console.open(model, to)

  defp execute(model, %{"name" => "invoke", "call" => call}, _label),
    do:
      {%{model | waiting: true}, [{:send, Map.merge(call, %{"op" => "submit", "values" => %{}})}]}

  defp execute(model, %{"name" => "open_url", "url" => url}, _label),
    do: Model.external(model, url)

  defp execute(model, %{"name" => "agent_ask"} = operation, label),
    do: Model.agent_action(model, label, operation["intent"])

  defp execute(model, %{"name" => name} = operation, _label)
       when name in ["worker_history", "worker_receipts", "worker_output_subscribe"],
       do: AtlasTui.WorkerConversation.action(model, operation)

  defp execute(model, %{"name" => name}, _label), do: Model.operation(model, name)

  defp current(model) do
    selected =
      Enum.flat_map(Model.lists(model), fn {id, %Blocks.List{rows: rows}} ->
        Enum.map(rows || [], &{id, &1.id || &1.to})
      end)
      |> Enum.at(model.selected)

    {on, row} = selected || {nil, nil}

    %{
      path: model.path,
      context: context(model),
      generation: model.console.generation,
      on: on,
      row: row
    }
  end

  defp unavailable(action, reason),
    do: action |> put_in(["props", "available"], false) |> put_in(["props", "reason"], reason)

  # Back follows the user's own history (`Console.back/1`), which only this client knows.
  defp available?(model, %{"name" => "back"}), do: Console.back?(model)
  defp available?(_model, _operation), do: true

  defp focus(model), do: {model.focus, model.part, model.steps.selected, model.steps.editing}
  defp shell_revision(%{console: %{shell: nil}}), do: nil
  defp shell_revision(model), do: model.console.shell["revision"]

  # Terminal decoding, independent of the operation the BFF assigns to each token.
  def token({:char, " "}), do: "Space"
  def token({:char, text}), do: text
  def token(:tab), do: "Tab"
  def token(:shift_tab), do: "Shift+Tab"
  def token(:enter), do: "Enter"
  def token(:esc), do: "Esc"
  def token(:up), do: "Up"
  def token(:down), do: "Down"
  def token(:left), do: "Left"
  def token(:right), do: "Right"
  def token(:home), do: "Home"
  def token(:end), do: "End"
  def token(:backspace), do: "Backspace"
  def token(:ctrl_c), do: "Ctrl+C"
  def token(:ctrl_s), do: "Ctrl+S"
  def token(:page_up), do: "PageUp"
  def token(:page_down), do: "PageDown"
  def token(_), do: nil
end
