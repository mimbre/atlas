defmodule AtlasControl.Shell do
  @moduledoc """
  Native shell metadata from the model (`shell/1`, with the tabs the environment's
  settings add), separate from page content. `m` is the model as Control serves it
  (`AtlasControl.Model.catalog/2`).

  A tab opens `/` (what is assigned, `assigned: true`), a kind's list, the machines (or
  the workers, deprecated), or one of the supervision screens (`/_open`, `/_supervised`) when the model's start page has
  it. Without a target, a client opens on the tab the shell names as its `default` (its
  id), when the client may see it; else on the first tab. A tab is in the "work" section
  (the default: what needs someone) or "browse" (reference); a browse tab may name its
  own key sequence (`key`, as "g s").

  A client that is a fact of a kind the start's assigned relation points at is greeted (`greeting`), when the model words a greeting: its words with `{name}` the
  viewer's name, as Session read it once at boot. An agent or a migration has none. Under
  that name the shell names the agent that assists the viewer (`assistant`, "assistant:
  coordinator"): the model's shell names the agent (`assistant`), the environment's
  settings say whom it assists (`AtlasBus.Actors.assisted/1`).
  """

  alias AtlasControl.Pages
  require AtlasControl.Blocks, as: Blocks

  # The supervision screens (M3b P4): index routes, as `/` and a kind's list are.
  @screens [:open_for_you, :supervised_by_you]

  @doc """
  Build a fresh shell; the optional target selects content without opening a page.
  `name` is the viewer's name (its fact's label), which a greeting fills in; `by` the
  viewer's key, whom the model's assistant may assist.
  """
  def boot(m, by_kind, target \\ nil, resolve \\ nil, name \\ nil, by \\ nil) do
    with {:ok, title, configured, default, assistant} <- configuration(m),
         true <- is_nil(target) or text?(target, 2_048),
         true <- Enum.all?(configured, &valid_tab?(&1, m)),
         true <- distinct?(configured, "id"),
         true <- is_nil(default) or Enum.any?(configured, &(&1["id"] == default)),
         configured <- Enum.map(configured, &Map.put(&1, "to", canonical_tab(&1["to"]))),
         true <- distinct?(configured, "to") do
      tabs =
        configured
        |> Enum.filter(fn tab ->
          tab["assigned"] != true or Pages.assigned_start?(m, by_kind)
        end)
        |> Enum.map(fn tab ->
          route = Pages.route(tab["to"])

          Blocks.shell_tab(
            id: tab["id"],
            label: tab["label"],
            to: tab["to"],
            section: tab["section"] || "work",
            key: tab["key"],
            icon: tab["icon"] || icon(m, route),
            for_you: for_you?(route)
          )
        end)

      if tabs == [] do
        {:error, "Shell has no eligible configured tabs"}
      else
        with {:ok, initial} <- initial_target(target, m, tabs, default, resolve) do
          # A group belongs to its list's tab, not a separate shell destination.
          parent =
            case Pages.route(initial) do
              {:group, :assigned, _, _} -> "/"
              {:group, screen, _, _} -> Pages.path({screen, nil})
              _ -> nil
            end

          active = Enum.find(tabs, &(within?(initial, &1["to"]) or &1["to"] == parent))

          env = AtlasBus.environment()
          spec = Blocks.version()
          name = viewer(m, by_kind, name)
          greeting = greeting(m, name)
          assistant = assistant(assistant, name, by)

          # Navigation and request target do not change the revision. Configuration,
          # actor-visible tab set, environment, contract version, greeting, name and
          # assistant do.
          revision =
            [
              title,
              env,
              spec,
              Enum.map(
                tabs,
                &[
                  &1["id"],
                  &1["label"],
                  &1["to"],
                  &1["section"],
                  &1["key"],
                  &1["icon"],
                  &1["for_you"]
                ]
              )
            ]
            # A shell without a greeting, name or assistant keeps the revision it had
            # before either.
            |> Kernel.++(List.wrap(greeting))
            |> Kernel.++(List.wrap(name))
            |> Kernel.++(List.wrap(assistant))
            |> JSON.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)

          {:ok,
           Blocks.shell(
             title: title,
             env: env,
             spec: spec,
             revision: revision,
             tabs: tabs,
             initial_to: initial,
             active_tab: active && active["id"],
             greeting: greeting,
             name: name,
             assistant: assistant
           )}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid shell configuration or target"}
    end
  end

  # The viewer's name, for a viewer the start's assigned relation points at; nil for any
  # other (an agent, a migration). It stays on one line, as a client draws it (a control
  # character would make it refuse the whole shell).
  defp viewer(m, by_kind, name) do
    with %{} <- Pages.assigned_rule(m),
         true <- text?(name, 512),
         true <- Pages.assigned_start?(m, by_kind) do
      String.replace(name, ~r/[\x00-\x1f\x7f]+/, " ")
    else
      _ -> nil
    end
  end

  # The model's assistant, when it assists this named viewer: "assistant: coordinator";
  # nil otherwise.
  defp assistant(agent, name, by) do
    if is_binary(agent) and is_binary(name) and is_binary(by) and
         AtlasBus.Actors.assisted(agent) == by,
       do: "assistant: " <> agent
  end

  # The model's greeting with the viewer's name; nil without either.
  defp greeting(_m, nil), do: nil

  defp greeting(m, name) do
    with words when is_binary(words) <- Map.get(Pages.assigned_rule(m), :greeting),
         text = String.replace(words, "{name}", name),
         true <- text?(text, 1_024) do
      text
    else
      _ -> nil
    end
  end

  defp configuration(m) do
    case m.module.shell(m.settings) do
      %{"title" => title, "tabs" => tabs} = shell
      when is_list(tabs) and length(tabs) <= 64 ->
        default = shell["default"]
        assistant = shell["assistant"]

        if text?(title, 128) and
             Map.keys(shell) -- ["title", "tabs", "default", "assistant"] == [] and
             (is_nil(default) or text?(default, 64)) and
             (is_nil(assistant) or text?(assistant, 64)),
           do: {:ok, title, tabs, default, assistant},
           else: {:error, "Invalid shell configuration"}

      _ ->
        {:error, "No shell navigation is configured"}
    end
  end

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to} = tab, m) do
    text?(id, 64) and text?(label, 128) and text?(to, 2_048) and
      Map.keys(tab) -- ["id", "label", "to", "assigned", "icon", "section", "key"] == [] and
      (is_nil(tab["icon"]) or text?(tab["icon"], 64)) and
      Map.get(tab, "section", "work") in ["work", "browse"] and
      (is_nil(tab["key"]) or
         (tab["section"] == "browse" and AtlasBFFContract.Console.sequence?(tab["key"]))) and
      Map.get(tab, "assigned", false) in [true, false] and
      case Pages.route(if(is_binary(to), do: to, else: "")) do
        :home -> tab["assigned"] == true and Pages.assigned_rule(m) != nil
        {:list, kind} -> Pages.kind?(m, kind) and text?(canonical_tab(to), 2_048)
        {:worker_page, :health, _} -> tab["assigned"] != true
        {:machine_page, :machines, _} -> tab["assigned"] != true and Pages.machines(m) != nil
        {:open_for_you, _} -> tab["assigned"] != true and Pages.open_for_you_rule(m) != nil
        {:supervised_by_you, _} -> tab["assigned"] != true and Pages.supervised_rule(m) != nil
        _ -> false
      end
  end

  defp valid_tab?(_, _m), do: false

  defp initial_target(target, m, tabs, default, resolve) do
    route =
      if is_binary(target) do
        if resolve,
          do: resolve.(target),
          else: target |> Pages.route() |> Pages.resolve(m)
      end

    with {:ok, canonical} <- canonical_target(route, m) do
      # A removed overview falls back; valid detail/form targets stay canonical.
      index? =
        route == :home or match?({:list, _}, route) or
          match?({:worker_page, :health, _}, route) or
          match?({:machine_page, :machines, _}, route) or
          screen?(route)

      configured? = Enum.any?(tabs, &(&1["to"] == canonical))
      # Without a target (or one a tab no longer offers): the shell's default tab, when
      # this client has it; else the first.
      fallback = (Enum.find(tabs, &(&1["id"] == default)) || hd(tabs))["to"]
      initial = if canonical && (not index? or configured?), do: canonical, else: fallback

      if text?(initial, 2_048),
        do: {:ok, initial},
        else: {:error, "Canonical boot target exceeds 2048 bytes"}
    end
  end

  defp canonical_target({:unavailable, _, _}, _m),
    do: {:error, "Facts did not resolve the boot target"}

  defp canonical_target(:home, _m), do: {:ok, "/"}

  defp canonical_target({screen, _} = route, _m) when screen in @screens,
    do: {:ok, Pages.path(route)}

  defp canonical_target({:group, _screen, _key, _by} = route, _m),
    do: {:ok, Pages.path(route)}

  defp canonical_target(:kinds, _m), do: {:ok, "/_kinds"}

  defp canonical_target({page, kind} = route, m) when page in [:list, :new],
    do: target_path(route, kind, [kind], m)

  defp canonical_target({:new, kind, {relation, parent}} = route, m),
    do: target_path(route, kind, [kind, relation, parent], m)

  defp canonical_target({page, kind, key} = route, m)
       when page in [:item, :more, :edit, :delete],
       do: target_path(route, kind, [kind, key], m)

  defp canonical_target({:new, _kind, _invalid}, _m),
    do: {:error, "Invalid derived boot route parameters"}

  defp canonical_target({page, kind, key, relation} = route, m)
       when page in [:links, :set, :remove],
       do: target_path(route, kind, [kind, key, relation], m)

  defp canonical_target({:worker_page, page, params} = route, _m)
       when page in [:health, :worker, :worker_guidance] do
    keys = if page == :health, do: [], else: [:machine, :worker, :turn, :attempt]

    if Enum.all?(keys, &text?(params[&1], 2_048)),
      do: {:ok, Pages.path(route)},
      else: {:error, "Invalid worker execution route parameters"}
  end

  defp canonical_target({:machine_page, page, params} = route, _m) do
    if page == :machines or text?(params[:machine], 2_048),
      do: {:ok, Pages.path(route)},
      else: {:error, "Invalid machine route parameters"}
  end

  defp canonical_target(_route, _m), do: {:ok, nil}

  # Validate every required parameter at the path-builder boundary. A malformed
  # model-derived key/relation must be an error, never an exception or fallback.
  # No rescue hides unrelated resolver, process or programming failures.
  defp target_path(route, kind, params, m) do
    if Enum.all?(params, &text?(&1, 2_048)) do
      {:ok, if(Pages.kind?(m, kind), do: Pages.path(route))}
    else
      {:error, "Invalid derived boot route parameters"}
    end
  end

  defp canonical_tab(to), do: to |> Pages.route() |> Pages.path()

  # The icon of a tab whose model names none: a list's, its kind's (as on its rows); else
  # one from the page it opens.
  defp icon(m, {:list, kind}), do: Pages.kind_icon(m, kind)
  defp icon(_m, :home), do: "assigned"
  defp icon(_m, {:supervised_by_you, _}), do: "supervised"
  defp icon(_m, {:open_for_you, _}), do: "open"
  defp icon(_m, {:worker_page, _, _}), do: "workers"
  defp icon(m, {:machine_page, _, _}), do: m |> Pages.machines() |> machine_icon(m)
  defp icon(_m, _route), do: nil

  defp machine_icon(%{"kind" => kind}, m), do: Pages.kind_icon(m, kind)
  defp machine_icon(_none, _m), do: nil

  # Whether a tab's count is what waits for the viewer: what is assigned to them.
  defp for_you?(route), do: route == :home

  defp screen?({screen, _}) when screen in @screens, do: true
  defp screen?(_route), do: false

  defp text?(value, max),
    do:
      is_binary(value) and byte_size(value) <= max and String.valid?(value) and
        String.trim(value) != ""

  defp distinct?(tabs, field) do
    values = Enum.map(tabs, & &1[field])
    Enum.uniq(values) == values
  end

  defp within?(target, to),
    do: target == to or (to != "/" and String.starts_with?(target, to <> "/"))
end
