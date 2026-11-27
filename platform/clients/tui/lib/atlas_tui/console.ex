defmodule AtlasTui.Console do
  @moduledoc """
  Persistent native shell and handshake lifecycle. Boot is independent of page
  content: compatibility pages cannot replace local drafts, and failed boot never
  replaces the last good navigation. Effects use the ordinary Control endpoints.

  Back is the user's own way here, not the parent a page names: `open/2` remembers
  the page left (its selection and scroll) in `history`, `back/1` returns to the
  newest one. Switching tabs, or a boot that reopens the start, starts afresh.

  Every page Control sends is kept, the newest per path (`AtlasTui.PageCache`), also
  for paths not on screen; only the path on screen is drawn. Back and a tab switch show
  the cached page at once and still ask for it; whenever a page replaces the list on
  screen, `AtlasTui.Selection` says which row stays selected.
  """
  alias AtlasTui.{Blocks, Model, PageCache, Protocol, Selection, WorkerConversation}

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
            # The selection each tab was left with: `%{path => {identity, index}}`.
            selections: %{},
            # The pages the user came from, newest first:
            # `%{path, selection: {identity, index}, scroll, scrolls, part}`.
            history: [],
            # The page `back/1` is on its way to, restored as it was left when it arrives.
            returning: nil,
            # The newest page Control sent per path.
            cache: PageCache.new(),
            projection: nil,
            legend: nil,
            viewport: {100, 30},
            # Whether the terminal reports truecolor (`COLORTERM`): cards are filled
            # surfaces; without it, a left bar (`AtlasTui.View`, cards).
            truecolor: true,
            action_error: nil,
            key_buffer: "",
            # The first key of a two-key sequence ("g" of "g s") waiting for its second.
            key_prefix: "",
            # The page to open after the first boot instead of the shell's start page: the
            # one a TUI showed before it ended to take a newer build (IS-Atlas-76).
            start_to: nil,
            generation: 0

  @history_limit 100
  # How long after losing Control the TUI tries again (`AtlasTui.App`).
  @retry_ms 2_000

  def retry_ms, do: @retry_ms

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

  @doc "No Control content any more; `why` (see `AtlasTui.Model`'s `offline`) when known."
  def disconnected(model, why \\ nil) do
    model = WorkerConversation.capture(model)

    %{
      model
      | connected: false,
        offline: why || model.offline,
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

  def receive(model, %{"op" => "page"} = message),
    do: AtlasTui.Columns.settle(page(cache(model, message), message))

  # Any contract version is welcome (D-0105): this TUI reads what it knows and shows the
  # rest plainly; the status line says when the versions differ. A Control on a newer
  # contract makes a TUI started by bin/atlas take the newest build (IS-Atlas-76): it
  # ends with `{:update, page, control spec}` and bin/atlas starts it again on that page.
  def receive(model, %{"op" => "welcome"} = message) do
    if model.console.phase == :welcome and message["surface"] == "console" and
         message["env"] == model.env do
      theirs = if is_binary(message["spec"]), do: message["spec"]

      model = %{
        model
        | connected: true,
          offline: nil,
          closed: false,
          notice: nil,
          control_spec: theirs,
          console: %{model.console | phase: :compatibility, error: nil}
      }

      if model.release == :restart and newer?(theirs),
        do: {model, [{:update, model.path, theirs}]},
        else: {model, []}
    else
      {%{
         model
         | connected: false,
           offline: :refused,
           console: %{model.console | phase: :unsupported, stale: true}
       }, []}
    end
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
            target =
              cond do
                draft?(model) and model.path -> model.path
                console.start_to -> console.start_to
                true -> shell["initial_to"]
              end

            console = %{
              console
              | phase: :content,
                start_to: nil,
                expected: target,
                in_flight: target,
                restoring: draft?(model),
                history: if(draft?(model), do: console.history, else: []),
                returning: nil
            }

            {%{model | console: console}, [{:send, Protocol.request(:open, %{"to" => target})}]}
          else
            model = sync_active(model)

            removed_index =
              Enum.any?(previous_tabs, &(&1["to"] == model.path)) and
                !Enum.any?(shell["tabs"], &(&1["to"] == model.path))

            if removed_index && !draft?(model) && is_nil(console.expected),
              do: navigate(afresh(model), shell["initial_to"]),
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

  def receive(model, %{"op" => "bye"} = message) do
    {Model.message(disconnected(model), message), []}
  end

  def receive(model, message),
    do: WorkerConversation.receive(Model.message(model, message), message)

  # A page is kept for its path first, whatever happens to it here.
  defp cache(%{console: %{phase: :unsupported}} = model, _message), do: model
  defp cache(model, message), do: update_in(model.console.cache, &PageCache.put(&1, message))

  defp page(%{console: %{phase: :compatibility}} = model, %{"op" => "page"}) do
    refresh(%{model | console: %{model.console | phase: :boot}})
  end

  defp page(%{console: %{phase: phase}} = model, %{"op" => "page"})
       when phase in [:welcome, :boot, :unsupported],
       do: {model, []}

  # Open replies have no request ID and may redirect. Keep only one open on the
  # wire; rapid tab presses change the desired target without queuing old views.
  defp page(
         %{console: %{phase: :ready, in_flight: sent, expected: desired}} = model,
         %{"op" => "page", "reason" => "open"}
       )
       when sent != nil and sent != desired do
    navigate(%{model | console: %{model.console | in_flight: nil}}, desired)
  end

  defp page(%{console: %{expected: target}} = model, %{"op" => "page", "reason" => reason})
       when target != nil and reason != "open",
       do: {model, []}

  # An unasked page for a path not on screen is only kept (above), not drawn.
  defp page(model, %{"op" => "page", "path" => path, "reason" => reason})
       when reason in ["hint", "pending", "reconcile", "refresh"] and path != model.path,
       do: {model, []}

  defp page(model, %{"op" => "page"} = message) do
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
            message["reason"] in ["hint", "pending", "reconcile"] ->
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

          # The same path keeps its selection by `Model.message/2` (the selection rule).
          updated = if message["path"] != model.path, do: arrive(updated), else: updated

          updated = %{
            updated
            | console: %{
                updated.console
                | phase: :ready,
                  returning: nil,
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

  # Tab and Shift+Tab go round the work tabs; from a browse tab, to the first or last.
  # A page under no tab counts as the first.
  def cycle(model, step) do
    console = model.console

    if tabs_open?(model) do
      tabs = Enum.filter(console.shell["tabs"], &work?/1)
      index = Enum.find_index(tabs, &(&1["id"] == console.active))
      browse? = console.active != nil and index == nil

      target =
        cond do
          tabs == [] -> nil
          browse? and step > 0 -> List.first(tabs)
          browse? -> List.last(tabs)
          true -> Enum.at(tabs, Integer.mod((index || 0) + step, length(tabs)))
        end

      if target, do: to_tab(model, target["to"]), else: {model, []}
    else
      {model, []}
    end
  end

  @doc """
  Opens the page of a tab or of one of its groups (`to`, as the sidebar and Tab do), as it
  was left there; nothing while a tab cannot be left (a draft, a stale shell, …).
  """
  def to_tab(model, to) do
    if tabs_open?(model) do
      {model, effects} = navigate(afresh(model), to)
      reopen(model, effects, to, model.console.selections[to], %{})
    else
      {model, []}
    end
  end

  defp tabs_open?(model) do
    console = model.console

    console.shell != nil and !console.stale and model.connected and console.phase == :ready and
      !console.restoring and !draft?(model)
  end

  @doc "Whether `tab` is a work tab; a tab without a section is one."
  def work?(tab), do: tab["section"] in [nil, "work"]

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

  @doc "Opens `target` from this page, which `back/1` then returns to as it is left."
  def open(model, target) do
    if is_binary(model.path) and is_binary(target) and target != model.path and
         match?({:ok, _, _}, Blocks.match(target)),
       do: navigate(remember(model), target),
       else: navigate(model, target)
  end

  @doc """
  Opens `target`, the row selected in the list at `list` (`AtlasTui.Columns`), in place of
  the page open beside it: back then returns to the list, with that row (`selection`)
  selected. Its cached page shows at once while the open brings it fresh.
  """
  def follow(model, list, selection, target) do
    entry =
      if model.path == list,
        do: entry(model),
        else: %{path: list, selection: selection, scroll: nil, scrolls: %{}, part: nil}

    {model, effects} =
      navigate(%{model | console: %{model.console | history: [entry], returning: nil}}, target)

    reopen(model, effects, target, nil, %{})
  end

  @doc "Back to the page the user came from, in their own history; at its root, nothing."
  def back(%{console: %{history: [entry | rest]} = console} = model) do
    {model, effects} =
      navigate(%{model | console: %{console | history: rest, returning: entry}}, entry.path)

    reopen(
      model,
      effects,
      entry.path,
      entry.selection,
      Map.take(entry, [:scroll, :scrolls, :part])
    )
  end

  def back(model), do: {model, []}

  @doc "Whether `back/1` has a page to return to."
  def back?(model), do: model.console.history != []

  # Back or a tab switch to `path`: its cached page at once, with the selection `before`
  # and `layout` it was left with, while the open just sent brings it fresh (that copy
  # then keeps the selection by the same rule). Without a cached page, or when the open
  # was not sent, the page waits for Control as before.
  defp reopen(model, effects, path, before, layout) do
    case model.console.expected == path && PageCache.get(model.console.cache, path) do
      %{} = cached ->
        {installed, message} =
          AtlasTui.Interactions.install(model, Map.put(cached, "reason", "cache"))

        shown = Model.message(installed, message)
        selected = Selection.after_replace(before, Model.rows(shown)) || 0
        shown = Map.merge(%{shown | selected: selected}, layout)
        shown = %{shown | console: %{shown.console | returning: nil}}
        {shown, worker_effects} = WorkerConversation.install(shown, model)
        {AtlasTui.Legend.reconcile(shown), effects ++ worker_effects}

      _ ->
        {model, effects}
    end
  end

  defp afresh(model), do: %{model | console: %{model.console | history: [], returning: nil}}

  # The page left, newest first. Leaving it again (from the same page) replaces it.
  defp remember(model) do
    entry = entry(model)

    history =
      case model.console.history do
        [%{path: path} | rest] when path == model.path -> [entry | rest]
        history -> [entry | history]
      end

    %{model | console: %{model.console | history: Enum.take(history, @history_limit)}}
  end

  defp entry(model),
    do: %{
      path: model.path,
      title: model.title,
      selection: Selection.of(Model.rows(model), model.selected),
      scroll: model.scroll,
      scrolls: model.scrolls,
      part: model.part
    }

  # A page at a new path: the one back/1 returns to, or the newest page left (a form's
  # cancel or a stored change returns there), as it was left; else as its tab was left.
  defp arrive(model) do
    case model.console do
      %{returning: %{path: path} = entry} when path == model.path ->
        restore(model, entry)

      %{history: [%{path: path} = entry | rest]} = console when path == model.path ->
        restore(%{model | console: %{console | history: rest}}, entry)

      _ ->
        %{model | selected: restored_selection(model)}
    end
  end

  defp restore(model, entry) do
    selected = Selection.after_replace(entry.selection, Model.rows(model)) || 0
    %{model | selected: selected, scroll: entry.scroll, scrolls: entry.scrolls, part: entry.part}
  end

  defp sync_active(%{console: %{shell: nil}} = model), do: model
  defp sync_active(%{console: %{expected: target}} = model) when target != nil, do: model

  # The tab whose page, a page under it, or one of its groups (boot's `groups`) is shown;
  # beside the list of a tab (`AtlasTui.Columns`), that tab.
  defp sync_active(model) do
    tabs = model.console.shell["tabs"]
    list = AtlasTui.Columns.shown?(model) && model.columns.list

    active =
      Enum.find(tabs, &(&1["to"] == model.path)) || (list && Enum.find(tabs, &(&1["to"] == list))) ||
        Enum.find(tabs, fn tab ->
          (tab["to"] != "/" and is_binary(model.path) and
             String.starts_with?(model.path, tab["to"] <> "/")) or
            Enum.any?(tab["groups"] || [], &(&1["to"] == model.path))
        end) ||
        Enum.find_value(model.console.history, fn entry ->
          Enum.find(tabs, fn tab ->
            tab["to"] == entry.path or Enum.any?(tab["groups"] || [], &(&1["to"] == entry.path))
          end)
        end)

    %{model | console: %{model.console | active: active && active["id"]}}
  end

  defp remember_selection(model) do
    tabs = if model.console.shell, do: model.console.shell["tabs"], else: []

    if Enum.any?(tabs, &(&1["to"] == model.path)) do
      selected = Selection.of(Model.rows(model), model.selected)

      selections =
        model.console.selections
        |> Map.take(Enum.map(tabs, & &1["to"]))
        |> Map.put(model.path, selected)

      %{model | console: %{model.console | selections: selections}}
    else
      model
    end
  end

  defp restored_selection(model),
    do: Selection.after_replace(model.console.selections[model.path], Model.rows(model)) || 0

  defp validate_shell(%{"error" => error}, _env) when is_binary(error),
    do: {:error, error |> String.slice(0, 512) |> String.replace(~r/[\x00-\x1f\x7f]/, " ")}

  defp validate_shell(message, env) do
    tabs = message["tabs"]

    valid =
      match?({:reply, %{name: :shell, effect: :complete}}, Protocol.classify(:boot, message)) and
        message["env"] == env and
        text?(message["title"], 128) and text?(message["revision"], 128) and
        is_list(tabs) and length(tabs) in 1..64 and Enum.all?(tabs, &valid_tab?/1) and
        distinct?(tabs, "id") and distinct?(tabs, "to") and path?(message["initial_to"]) and
        (is_nil(message["active_tab"]) or Enum.any?(tabs, &(&1["id"] == message["active_tab"]))) and
        (is_nil(message["greeting"]) or text?(message["greeting"], 1_024))

    if valid,
      do:
        {:ok, Map.take(message, ~w(title env spec revision tabs initial_to active_tab greeting))},
      else: {:error, "Invalid Console boot response"}
  end

  # The index pages a tab may open: the ones Control's shell serves as tabs
  # (`AtlasControl.Shell`): what is assigned, a kind's list, the workers and the
  # supervision screens (Open for you, Supervised by you; M3b P4).
  @tab_pages [:home, :list, :workers, :open_for_you, :supervised_by_you]

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to} = tab) do
    text?(id, 64) and text?(label, 128) and path?(to) and
      tab["section"] in [nil, "work", "browse"] and
      (is_nil(tab["key"]) or AtlasBFFContract.Console.key?(tab["key"])) and
      case Blocks.match(to) do
        {:ok, page, _} -> page in @tab_pages
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

  @doc "Whether Control's contract `theirs` is newer than this build's."
  def newer?(theirs) do
    case is_binary(theirs) && Version.parse(theirs) do
      {:ok, version} -> Version.compare(version, Version.parse!(Protocol.version())) == :gt
      _ -> false
    end
  end
end
