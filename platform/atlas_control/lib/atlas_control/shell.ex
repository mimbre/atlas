defmodule AtlasControl.Shell do
  @moduledoc """
  Native shell metadata from the model (`shell/1`, with the tabs the environment's
  settings add), separate from page content. `m` is the model as Control serves it
  (`AtlasControl.Model.catalog/2`).
  """

  alias AtlasControl.Pages
  require AtlasControl.Blocks, as: Blocks

  @doc "Build a fresh shell; the optional target selects content without opening a page."
  def boot(m, by_kind, target \\ nil, resolve \\ nil) do
    with {:ok, title, configured} <- configuration(m),
         true <- is_nil(target) or text?(target, 2_048),
         true <- Enum.all?(configured, &valid_tab?(&1, m)),
         true <- distinct?(configured, "id"),
         configured <- Enum.map(configured, &Map.put(&1, "to", canonical_tab(&1["to"]))),
         true <- distinct?(configured, "to") do
      tabs =
        configured
        |> Enum.filter(fn tab ->
          tab["assigned"] != true or Pages.assigned_start?(m, by_kind)
        end)
        |> Enum.map(fn tab ->
          Blocks.shell_tab(id: tab["id"], label: tab["label"], to: tab["to"])
        end)

      if tabs == [] do
        {:error, "Shell has no eligible configured tabs"}
      else
        with {:ok, initial} <- initial_target(target, m, tabs, resolve) do
          active = Enum.find(tabs, &within?(initial, &1["to"]))
          env = AtlasBus.environment()
          spec = Blocks.version()

          # Navigation and request target do not change the revision. Configuration,
          # actor-visible tab set, environment and contract version do.
          revision =
            [title, env, spec, Enum.map(tabs, &[&1["id"], &1["label"], &1["to"]])]
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
             active_tab: active && active["id"]
           )}
        end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, "Invalid shell configuration or target"}
    end
  end

  defp configuration(m) do
    case m.module.shell(m.settings) do
      %{"title" => title, "tabs" => tabs} = shell
      when is_list(tabs) and length(tabs) <= 64 ->
        if text?(title, 128) and Map.keys(shell) -- ["title", "tabs"] == [],
          do: {:ok, title, tabs},
          else: {:error, "Invalid shell configuration"}

      _ ->
        {:error, "No shell navigation is configured"}
    end
  end

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to} = tab, m) do
    text?(id, 64) and text?(label, 128) and text?(to, 2_048) and
      Map.keys(tab) -- ["id", "label", "to", "assigned"] == [] and
      Map.get(tab, "assigned", false) in [true, false] and
      case Pages.route(if(is_binary(to), do: to, else: "")) do
        :home -> tab["assigned"] == true and Pages.assigned_rule(m) != nil
        {:list, kind} -> Pages.kind?(m, kind) and text?(canonical_tab(to), 2_048)
        {:worker_page, :workers, _} -> tab["assigned"] != true
        _ -> false
      end
  end

  defp valid_tab?(_, _m), do: false

  defp initial_target(target, m, tabs, resolve) do
    route =
      if is_binary(target) do
        if resolve,
          do: resolve.(target),
          else: target |> Pages.route() |> Pages.resolve(m)
      end

    with {:ok, canonical} <- canonical_target(route, m) do
      # A removed overview falls back; valid detail/form targets stay canonical.
      index? =
        route == :home or match?({:list, _}, route) or match?({:worker_page, :workers, _}, route)

      configured? = Enum.any?(tabs, &(&1["to"] == canonical))
      initial = if canonical && (not index? or configured?), do: canonical, else: hd(tabs)["to"]

      if text?(initial, 2_048),
        do: {:ok, initial},
        else: {:error, "Canonical boot target exceeds 2048 bytes"}
    end
  end

  defp canonical_target({:unavailable, _, _}, _m),
    do: {:error, "Facts did not resolve the boot target"}

  defp canonical_target(:home, _m), do: {:ok, "/"}
  defp canonical_target(:kinds, _m), do: {:ok, "/_kinds"}

  defp canonical_target({page, kind} = route, m) when page in [:list, :new],
    do: target_path(route, kind, [kind], m)

  defp canonical_target({:new, kind, {relation, parent}} = route, m),
    do: target_path(route, kind, [kind, relation, parent], m)

  defp canonical_target({page, kind, key} = route, m)
       when page in [:item, :edit, :delete],
       do: target_path(route, kind, [kind, key], m)

  defp canonical_target({:new, _kind, _invalid}, _m),
    do: {:error, "Invalid derived boot route parameters"}

  defp canonical_target({page, kind, key, relation} = route, m)
       when page in [:links, :set, :remove],
       do: target_path(route, kind, [kind, key, relation], m)

  defp canonical_target({:worker_page, page, params} = route, _m)
       when page in [:workers, :worker, :worker_guidance] do
    keys = if page == :workers, do: [], else: [:machine, :worker, :turn, :attempt]

    if Enum.all?(keys, &text?(params[&1], 2_048)),
      do: {:ok, Pages.path(route)},
      else: {:error, "Invalid worker execution route parameters"}
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
