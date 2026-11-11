defmodule AtlasTui.Console do
  @moduledoc """
  Persistent native shell and handshake lifecycle. Boot is independent of page
  content: compatibility pages cannot replace local drafts, and failed boot never
  replaces the last good navigation. Effects use the ordinary Control endpoints.
  """
  alias AtlasTui.{Blocks, Model, Protocol, WorkerConversation}

  defstruct shell: nil,
            stale: true,
            error: nil,
            phase: :welcome,
            boot_pending: false,
            boot_serial: 0,
            expected: nil,
            in_flight: nil,
            restoring: false,
            active: nil,
            selections: %{},
            projection: nil,
            legend: nil,
            viewport: {100, 30},
            action_error: nil,
            generation: 0

  def new, do: %__MODULE__{}

  def hello(model) do
    # IS120 acknowledges the requested presentation; old servers must not cause a
    # silent fallback to locally invented Console bindings.
    Protocol.request(:hello, %{
      "env" => model.env,
      "client" => "tui",
      "spec" => Protocol.version(),
      "surface" => "console"
    })
  end

  def disconnected(model) do
    model = WorkerConversation.capture(model)

    %{
      model
      | connected: false,
        console: %{
          model.console
          | stale: true,
            phase: :welcome,
            boot_pending: false,
            boot_serial: 0,
            expected: nil,
            in_flight: nil,
            restoring: false
        }
    }
  end

  def receive(model, %{"op" => "welcome"} = message) do
    if model.console.phase == :welcome and message["surface"] == "console" and
         message["env"] == model.env and message["spec"] == Protocol.version() do
      {%{
         model
         | connected: true,
           closed: false,
           notice: nil,
           console: %{model.console | phase: :compatibility, error: nil}
       }, []}
    else
      {%{
         model
         | connected: false,
           console: %{
             model.console
             | phase: :unsupported,
               stale: true,
               error: "Control did not acknowledge a compatible Console surface"
           }
       }, []}
    end
  end

  def receive(%{console: %{phase: :compatibility}} = model, %{"op" => "page"}) do
    refresh(%{model | console: %{model.console | phase: :boot}})
  end

  def receive(model, %{"op" => "boot"} = message) do
    if model.console.boot_pending do
      case validate_shell(message, model.env) do
        {:ok, shell} ->
          previous_tabs = if model.console.shell, do: model.console.shell["tabs"], else: []
          console = %{model.console | shell: shell, stale: false, error: nil, boot_pending: false}
          model = %{model | console: console}

          if console.phase == :boot do
            # Reopen the canonical target only after hello's compatibility page and
            # successful boot. Keep a local editor intact while restoring server path.
            target = if draft?(model) and model.path, do: model.path, else: shell["initial_to"]

            console = %{
              console
              | phase: :content,
                expected: target,
                in_flight: target,
                restoring: draft?(model)
            }

            {%{model | console: console}, [{:send, Protocol.request(:open, %{"to" => target})}]}
          else
            model = sync_active(model)

            removed_index =
              Enum.any?(previous_tabs, &(&1["to"] == model.path)) and
                !Enum.any?(shell["tabs"], &(&1["to"] == model.path))

            if removed_index && !draft?(model) && is_nil(console.expected),
              do: navigate(model, shell["initial_to"]),
              else: {model, []}
          end

        {:error, reason} ->
          {%{model | console: %{model.console | stale: true, error: reason, boot_pending: false}},
           []}
      end
    else
      {model, []}
    end
  end

  def receive(%{console: %{phase: phase}} = model, %{"op" => "page"})
      when phase in [:welcome, :boot, :unsupported],
      do: {model, []}

  # Open replies have no request ID and may redirect. Keep only one open on the
  # wire; rapid tab presses change the desired target without queuing old views.
  def receive(
        %{console: %{phase: :ready, in_flight: sent, expected: desired}} = model,
        %{"op" => "page", "reason" => "open"}
      )
      when sent != nil and sent != desired do
    navigate(%{model | console: %{model.console | in_flight: nil}}, desired)
  end

  def receive(%{console: %{expected: target}} = model, %{"op" => "page", "reason" => reason})
      when target != nil and reason != "open",
      do: {model, []}

  def receive(model, %{"op" => "page", "path" => path, "reason" => reason})
      when reason in ["hint", "reconcile", "refresh"] and path != model.path,
      do: {model, []}

  def receive(model, %{"op" => "page"} = message) do
    console = model.console
    redirected = WorkerConversation.redirected?(model, message)

    {updated, effects} =
      cond do
        redirected ->
          {%{
             model
             | console: %{console | expected: nil, in_flight: nil, restoring: false},
               notice: %{
                 tone: "error",
                 text: "Worker target changed; choose the exact turn explicitly."
               }
           }, []}

        console.expected && message["path"] != console.expected &&
            !(console.phase == :ready && message["reason"] == "open" && path?(message["path"])) ->
          {model, []}

        console.restoring and message["path"] == model.path ->
          # Replace the server page/actions but retain every actual editor value and
          # focus coordinate. No draft is reconstructed from default field values.
          {model, message} = AtlasTui.Interactions.install(model, message)
          updated = Model.message(model, message)

          updated = %{
            updated
            | values: model.values,
              focus: model.focus,
              cursor: model.cursor,
              ask: model.ask,
              plan: model.plan,
              steps: model.steps
          }

          {sync_active(%{
             updated
             | console: %{
                 updated.console
                 | phase: :ready,
                   expected: nil,
                   in_flight: nil,
                   restoring: false
               }
           }), []}

        draft?(model) and message["path"] == model.path and
            message["reason"] in ["hint", "reconcile"] ->
          {model, message} = AtlasTui.Interactions.install(model, message)
          updated = Model.message(model, message)

          {sync_active(%{
             updated
             | values: model.values,
               focus: model.focus,
               cursor: model.cursor
           }), []}

        true ->
          model = remember_selection(model)
          {model, message} = AtlasTui.Interactions.install(model, message)
          updated = Model.message(model, message)

          selected =
            if message["path"] != model.path,
              do: restored_selection(updated),
              else: stable_selection(model, updated)

          updated = %{
            updated
            | selected: selected,
              console: %{
                updated.console
                | phase: :ready,
                  expected: nil,
                  in_flight: nil,
                  restoring: false
              }
          }

          {sync_active(updated), []}
      end

    {updated, worker_effects} =
      if not redirected and updated.path == message["path"] and updated.console.phase == :ready,
        do: WorkerConversation.install(updated, model),
        else: {updated, []}

    {AtlasTui.Legend.reconcile(updated), effects ++ worker_effects}
  end

  def receive(model, %{"op" => "bye"} = message) do
    {Model.message(disconnected(model), message), []}
  end

  def receive(model, message),
    do: WorkerConversation.receive(Model.message(model, message), message)

  def refresh(%{connected: false} = model), do: {model, []}
  def refresh(%{console: %{boot_pending: true}} = model), do: {model, []}
  def refresh(%{console: %{expected: target}} = model) when target != nil, do: {model, []}

  def refresh(model) do
    request = Protocol.request(:boot, if(model.path, do: %{"to" => model.path}, else: %{}))

    {%{
       model
       | console: %{
           model.console
           | boot_pending: true,
             boot_serial: model.console.boot_serial + 1
         }
     }, [{:send, request}]}
  end

  def draft?(model),
    do:
      Model.form(model) != nil or Model.step_form(model) != nil or
        model.ask != nil or model.plan != nil or Model.confirm(model) != nil

  def cycle(model, step) do
    console = model.console

    if console.shell && !console.stale && model.connected && console.phase == :ready &&
         !console.restoring &&
         !draft?(model) do
      tabs = console.shell["tabs"]
      index = Enum.find_index(tabs, &(&1["id"] == console.active)) || 0
      target = Enum.at(tabs, Integer.mod(index + step, length(tabs)))
      navigate(model, target["to"])
    else
      {model, []}
    end
  end

  def navigate(model, target) do
    model = WorkerConversation.capture(model)

    if is_binary(target) and match?({:ok, _, _}, Blocks.match(target)) do
      model = remember_selection(model)
      console = %{model.console | expected: target, legend: nil}
      active = console.shell && Enum.find(console.shell["tabs"], &(&1["to"] == target))
      console = if active, do: %{console | active: active["id"]}, else: console

      if console.in_flight do
        {%{model | console: console, notice: nil}, []}
      else
        {%{model | console: %{console | in_flight: target}, notice: nil},
         [{:send, Protocol.request(:open, %{"to" => target})}]}
      end
    else
      {model, []}
    end
  end

  defp sync_active(%{console: %{shell: nil}} = model), do: model
  defp sync_active(%{console: %{expected: target}} = model) when target != nil, do: model

  defp sync_active(model) do
    active =
      Enum.find(model.console.shell["tabs"], fn tab ->
        model.path == tab["to"] or
          (tab["to"] != "/" and is_binary(model.path) and
             String.starts_with?(model.path, tab["to"] <> "/"))
      end)

    %{model | console: %{model.console | active: active && active["id"]}}
  end

  defp row_identity(nil), do: nil
  defp row_identity(row), do: row.to || row.id

  defp remember_selection(model) do
    tabs = if model.console.shell, do: model.console.shell["tabs"], else: []

    if Enum.any?(tabs, &(&1["to"] == model.path)) do
      selected = row_identity(Enum.at(Model.rows(model), model.selected))

      selections =
        model.console.selections
        |> Map.take(Enum.map(tabs, & &1["to"]))
        |> Map.put(model.path, selected)

      %{model | console: %{model.console | selections: selections}}
    else
      model
    end
  end

  defp restored_selection(model) do
    identity = model.console.selections[model.path]
    Enum.find_index(Model.rows(model), &(row_identity(&1) == identity)) || 0
  end

  defp stable_selection(before, after_model) do
    identity = row_identity(Enum.at(Model.rows(before), before.selected))

    Enum.find_index(Model.rows(after_model), &(row_identity(&1) == identity)) ||
      after_model.selected
  end

  defp validate_shell(%{"error" => error}, _env) when is_binary(error),
    do: {:error, error |> String.slice(0, 512) |> String.replace(~r/[\x00-\x1f\x7f]/, " ")}

  defp validate_shell(message, env) do
    tabs = message["tabs"]

    valid =
      match?({:reply, %{name: :shell, effect: :complete}}, Protocol.classify(:boot, message)) and
        message["env"] == env and message["spec"] == Protocol.version() and
        text?(message["title"], 128) and text?(message["revision"], 128) and
        is_list(tabs) and length(tabs) in 1..64 and Enum.all?(tabs, &valid_tab?/1) and
        distinct?(tabs, "id") and distinct?(tabs, "to") and path?(message["initial_to"]) and
        (is_nil(message["active_tab"]) or Enum.any?(tabs, &(&1["id"] == message["active_tab"])))

    if valid,
      do: {:ok, Map.take(message, ~w(title env spec revision tabs initial_to active_tab))},
      else: {:error, "Invalid Console boot response"}
  end

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to}) do
    text?(id, 64) and text?(label, 128) and path?(to) and
      case Blocks.match(to) do
        {:ok, page, _} -> page in [:home, :list, :workers]
        _ -> false
      end
  end

  defp valid_tab?(_), do: false
  defp path?(value), do: text?(value, 2048) and match?({:ok, _, _}, Blocks.match(value))
  defp distinct?(tabs, key), do: length(Enum.uniq_by(tabs, & &1[key])) == length(tabs)

  defp text?(value, limit),
    do:
      is_binary(value) and byte_size(value) <= limit and
        String.valid?(value) and String.trim(value) != "" and
        !String.match?(value, ~r/[\x00-\x1f\x7f]/)
end
