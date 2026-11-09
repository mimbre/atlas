defmodule AtlasControl.Console do
  @moduledoc "Opt-in action projection. Native pages and existing authorization remain shared."
  require AtlasControl.Blocks, as: Blocks
  alias AtlasBFFContract.Console, as: Contract

  @max_actions 256
  @max_bytes 3_000_000

  def project(page, tab_count, declared_actions \\ []) do
    revision = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    native = page["blocks"]

    with true <- is_list(native) and length(native) <= 256,
         true <- byte_size(JSON.encode!(page)) <= @max_bytes,
         :ok <-
           if(Enum.all?(declared_actions, &Contract.operation?(&1.operation)),
             do: :ok,
             else: :invalid_operations
           ) do
      groups = [
        {"browse", "Navigation", browsing(page, tab_count)},
        {"browse", "Active view", view_actions(native) ++ declared_actions},
        {"form", "Editing", editing(native, "form")},
        {"confirm", "Confirmation", confirmation(native)},
        {"ask", "Agent request",
         simple([
           {"Send request", ["Enter"], "ask_send"},
           {"Cancel request", ["Esc"], "ask_cancel"},
           {"Delete character", ["Backspace"], "input_backspace"}
         ])},
        {"plan_planning", "Planning", simple([{"Cancel planning", ["Esc"], "plan_cancel"}])},
        {"plan_proposed", "Plan",
         simple([
           {"Previous step", ["Up", "k"], "plan_previous"},
           {"Next step", ["Down", "j"], "plan_next"},
           {"Keep or drop step", ["Space"], "plan_toggle"},
           {"Edit step", ["e"], "plan_edit"},
           {"Run kept steps", ["Enter"], "plan_run"},
           {"Cancel plan", ["Esc"], "plan_cancel"}
         ])},
        {"plan_running", "Running plan",
         simple([{"Stop after this step", ["Esc"], "plan_stop"}])},
        {"plan_done", "Plan result",
         simple([
           {"Close plan", ["Esc", "Enter", "Left", "b"], "plan_close"},
           {"Ask an agent", [":"], "agent_ask"}
         ])},
        {"step_form", "Edit step", editing([], "step_form")},
        {"legend", "Keys",
         simple([
           {"Close keys", ["Esc"], "legend_close"},
           {"Scroll up", ["Up", "k"], "scroll_up"},
           {"Scroll down", ["Down", "j"], "scroll_down"},
           {"Previous page", ["PageUp"], "page_previous"},
           {"Next page", ["PageDown"], "page_next"}
         ])}
      ]

      groups =
        Enum.map(groups, fn {context, title, actions} ->
          if context in ["browse", "legend"] do
            {context, title, actions}
          else
            help =
              if context in ["form", "step_form", "ask"],
                do: [],
                else: [command("Keys", ["?"], "legend_open")]

            {context, title, actions ++ help ++ [command("Quit", ["Ctrl+C"], "quit")]}
          end
        end)

      groups = settle_aliases(groups)
      total = Enum.sum(for {_, _, actions} <- groups, do: length(actions))

      if total <= @max_actions do
        {content, markup} =
          Enum.reduce(groups, {[], page["markup"] || []}, fn {context, title, actions},
                                                             {content, markup} ->
            additions = Enum.map(actions, &block(&1, page["path"], revision, context))

            case additions do
              [] ->
                {content, markup}

              _ ->
                {first, _} = hd(additions)
                {last, _} = List.last(additions)

                {content ++ additions,
                 markup ++ [Blocks.legend(first, last, title: title, context: context)]}
            end
          end)

        ids = Enum.map(native, & &1["id"]) ++ Enum.map(content, &elem(&1, 0))

        with :ok <- AtlasBFF.Markup.check(ids, markup),
             true <- valid_commands?(content) do
          vm = Blocks.view_model(Enum.map(native, &{&1["id"], &1}) ++ content, markup)

          result =
            Map.merge(page, %{
              "blocks" => vm.blocks,
              "markup" => vm.markup,
              "actions_revision" => revision
            })

          case Contract.compile(result) do
            {:ok, _projection} -> {:ok, result}
            {:error, _} -> {:error, "Invalid Console action scope or bindings"}
          end
        else
          _ -> {:error, "Invalid Console action projection"}
        end
      else
        {:error, "Console projection exceeds action limit"}
      end
    else
      :invalid_operations -> {:error, "Invalid declared Console operation"}
      _ -> {:error, "Console projection exceeds page budget"}
    end
  end

  defp simple(definitions),
    do: Enum.map(definitions, fn {label, keys, name} -> command(label, keys, name) end)

  defp command(label, keys, name, opts \\ []),
    do: %{
      label: label,
      keys: keys,
      operation: %{"name" => name},
      on: opts[:on],
      row: opts[:row],
      available: Keyword.get(opts, :available, true),
      reason: opts[:reason]
    }

  defp browsing(page, tabs) do
    rows? = Enum.any?(page["blocks"], &(&1["type"] == "list" and &1["props"]["rows"] != []))

    [
      command("Next tab", ["Tab"], "tab_next",
        available: tabs > 1,
        reason: if(tabs <= 1, do: "Only one configured tab")
      ),
      command("Previous tab", ["Shift+Tab"], "tab_previous",
        available: tabs > 1,
        reason: if(tabs <= 1, do: "Only one configured tab")
      ),
      command("Previous row", ["Up", "k"], "list_previous", available: rows?),
      command("Next row", ["Down", "j"], "list_next", available: rows?),
      command("Open selected", ["Enter", "Right"], "open_selected", available: rows?),
      # Back is the client's own history, which only the client knows (not the page's parent).
      command("Back", ["Esc", "Left", "b"], "back"),
      command("Refresh", ["r"], "refresh"),
      command("Keys", ["?"], "legend_open"),
      command("Ask an agent", [":"], "agent_ask"),
      command("Quit", ["q", "Ctrl+C"], "quit"),
      command("Scroll up", ["PageUp"], "scroll_up"),
      command("Scroll down", ["PageDown"], "scroll_down")
    ] ++
      if complete_panes?(page) do
        [
          command("Previous pane", ["["], "part_previous"),
          command("Next pane", ["]"], "part_next")
        ]
      else
        []
      end
  end

  defp complete_panes?(page) do
    ids = Enum.map(page["blocks"], & &1["id"])

    case AtlasBFF.Markup.tree(ids, page["markup"] || []) do
      [_, _ | _] = nodes ->
        Enum.all?(nodes, &match?({:markup, %{"kind" => "part"}, _}, &1))

      _ ->
        false
    end
  rescue
    # Invalid native markup is rejected by project/2's final validation.
    ArgumentError -> false
  end

  defp view_actions(blocks) do
    Stream.flat_map(blocks, fn block ->
      props = block["props"] || %{}
      on = block["id"]
      actions = Stream.map(props["actions"] || [], &source_action(&1, on))
      links = Stream.map(props["links"] || [], &source_link(&1, on, nil))
      rows = props["rows"] || []

      row_links =
        Stream.flat_map(rows, fn row ->
          Stream.map(row["links"] || [], &source_link(&1, on, row["id"] || row["to"]))
        end)

      Stream.concat([actions, links, row_links])
    end)
    |> Enum.take(@max_actions + 1)
  end

  defp source_action(source, on) do
    {name, values} =
      case source["to"] do
        "agent:" <> intent -> {"agent_ask", %{"intent" => intent}}
        to -> {"open", %{"to" => to}}
      end

    %{
      command(source["label"], [source["key"]], name, on: on)
      | operation: Map.put(values, "name", name)
    }
  end

  defp source_link(source, on, row),
    do: %{
      command(source["label"], [source["key"]], "open_url", on: on, row: row)
      | operation: %{"name" => "open_url", "url" => source["url"]}
    }

  defp editing(blocks, context) do
    form = Enum.find(blocks, &(&1["type"] == "form"))
    on = form && form["id"]
    submit = if context == "step_form", do: "step_save", else: "submit"
    cancel = if context == "step_form", do: "step_cancel", else: "cancel"
    label = if form, do: form["props"]["submit_label"], else: "Keep changes"

    if context == "form" and form == nil do
      []
    else
      [
        command(label, ["Ctrl+S"], submit, on: on),
        command("Cancel", ["Esc"], cancel, on: on),
        command("Next field", ["Tab"], "focus_next", on: on),
        command("Previous field", ["Shift+Tab"], "focus_previous", on: on)
      ] ++
        Enum.map(
          [
            {"Enter", "form_enter"},
            {"Up", "input_up"},
            {"Down", "input_down"},
            {"Left", "input_left"},
            {"Right", "input_right"},
            {"Home", "input_home"},
            {"End", "input_end"},
            {"Backspace", "input_backspace"}
          ],
          fn {key, op} -> command(key, [key], op, on: on) end
        )
    end
  end

  defp confirmation(blocks) do
    case Enum.find(blocks, &(&1["type"] == "confirm")) do
      nil ->
        []

      block ->
        props = block["props"]

        [
          command(props["confirm_label"] || "Confirm", ["Enter", "y"], "submit",
            on: block["id"],
            available: is_map(props["confirm_to"])
          ),
          command("Cancel", ["Esc", "Left", "b", "n"], "cancel", on: block["id"])
        ]
    end
  end

  # View bindings take precedence over optional navigation aliases, as legacy actions do.
  # The final declaration is shared by execution and legend; there is no duplicate help.
  defp settle_aliases(groups) do
    view =
      for {"browse", "Active view", actions} <- groups,
          action <- actions,
          action.row == nil,
          key <- action.keys,
          do: key

    Enum.map(groups, fn
      {"browse", "Navigation", actions} ->
        actions =
          Enum.flat_map(actions, fn action ->
            keys = Enum.reject(action.keys, &(&1 in view))
            if keys == [], do: [], else: [%{action | keys: keys}]
          end)

        {"browse", "Navigation", actions}

      group ->
        group
    end)
  end

  defp block(action, path, revision, context) do
    scope =
      Blocks.console_scope(
        page: path,
        revision: revision,
        context: context,
        on: action.on,
        row: action.row
      )

    id =
      :crypto.hash(
        :sha256,
        JSON.encode!([path, context, action.on, action.row, action.operation])
      )
      |> Base.url_encode64(padding: false)

    {"action:" <> id,
     Blocks.console_action(
       label: action.label,
       keys: action.keys,
       operation: action.operation,
       scope: scope,
       available: action.available,
       reason: action.reason
     )}
  end

  defp valid_commands?(content),
    do:
      Enum.all?(content, fn {_id, block} ->
        p = block["props"]

        is_binary(p["label"]) and byte_size(p["label"]) in 1..256 and length(p["keys"]) in 1..8 and
          Enum.all?(p["keys"], &Contract.key?/1) and Contract.operation?(p["operation"])
      end)
end
