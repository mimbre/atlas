defmodule AtlasControl.Shell do
  @moduledoc "Native shell metadata from the selected description, separate from page content."

  alias AtlasControl.Pages
  require AtlasControl.Blocks, as: Blocks

  @doc "Build a fresh shell; the optional target selects content without opening a page."
  def boot(description, by_kind, target \\ nil, resolve \\ nil) do
    with :ok <- validate_description(description),
         {:ok, title, configured} <- configuration(description),
         true <- is_nil(target) or text?(target, 2_048),
         true <- Enum.all?(configured, &valid_tab?(&1, description)),
         true <- distinct?(configured, "id"),
         configured <- Enum.map(configured, &Map.put(&1, "to", canonical_tab(&1["to"]))),
         true <- distinct?(configured, "to") do
      tabs =
        configured
        |> Enum.filter(fn tab ->
          tab["assigned"] != true or Pages.assigned_start?(description, by_kind)
        end)
        |> Enum.map(fn tab ->
          Blocks.shell_tab(id: tab["id"], label: tab["label"], to: tab["to"])
        end)

      if tabs == [] do
        {:error, "Shell has no eligible configured tabs"}
      else
        with {:ok, initial} <- initial_target(target, description, tabs, resolve) do
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

  @doc "Validate the nested shapes used by boot, installation and actor/route resolution."
  def validate_description(description) do
    valid =
      is_map(description) and
        map_of?(description["entities"], &entity_shape?/1) and
        optional?(description["relations"], &map_of?(&1, fn spec -> relation_shape?(spec) end)) and
        optional?(description["start"], fn start ->
          is_map(start) and
            optional?(start["assigned"], fn assigned ->
              is_map(assigned) and optional?(assigned["relation"], &is_binary/1)
            end)
        end)

    if valid, do: :ok, else: {:error, "Invalid boot description shape"}
  end

  defp entity_shape?(spec) when is_map(spec) do
    optional?(spec["properties"], &map_of?(&1, fn prop -> is_map(prop) end)) and
      optional?(spec["id_prefixes"], &strings?/1) and
      optional?(spec["id_prefix"], &is_binary/1) and
      optional?(spec["create"], fn create ->
        is_map(create) and optional?(create["ask"], &strings?/1) and
          optional?(create["id"], fn id ->
            is_map(id) and optional?(id["prefix"], &is_binary/1)
          end)
      end)
  end

  defp entity_shape?(_), do: false

  defp relation_shape?(spec) when is_map(spec) do
    optional?(spec["from"], &strings?/1) and optional?(spec["to"], &strings?/1) and
      optional?(spec["component"], fn component ->
        is_map(component) and
          text?(component["key"], 2_048)
      end)
  end

  defp relation_shape?(_), do: false
  defp optional?(nil, _check), do: true
  defp optional?(value, check), do: check.(value)
  defp strings?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)

  defp map_of?(value, check),
    do:
      is_map(value) and Enum.all?(value, fn {key, spec} -> text?(key, 2_048) and check.(spec) end)

  defp configuration(description) do
    case description["shell"] do
      %{"title" => title, "tabs" => tabs}
      when is_list(tabs) and length(tabs) <= 64 ->
        if text?(title, 128) and Map.keys(description["shell"]) -- ["title", "tabs"] == [],
          do: {:ok, title, tabs},
          else: {:error, "Invalid shell configuration"}

      _ ->
        {:error, "No shell navigation is configured"}
    end
  end

  defp valid_tab?(%{"id" => id, "label" => label, "to" => to} = tab, description) do
    text?(id, 64) and text?(label, 128) and text?(to, 2_048) and
      Map.keys(tab) -- ["id", "label", "to", "assigned"] == [] and
      Map.get(tab, "assigned", false) in [true, false] and
      case Pages.route(if(is_binary(to), do: to, else: "")) do
        :home -> tab["assigned"] == true and Pages.assigned_rule(description) != nil
        {:list, kind} -> known_kind?(kind, description) and text?(canonical_tab(to), 2_048)
        {:worker_page, :workers, _} -> tab["assigned"] != true
        _ -> false
      end
  end

  defp valid_tab?(_, _description), do: false

  defp initial_target(target, description, tabs, resolve) do
    route =
      if is_binary(target) do
        if resolve,
          do: resolve.(target),
          else: target |> Pages.route() |> Pages.resolve(description)
      end

    with {:ok, canonical} <- canonical_target(route, description) do
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

  defp canonical_target({:unavailable, _, _}, _description),
    do: {:error, "State did not resolve the boot target"}

  defp canonical_target(:home, _description), do: {:ok, "/"}
  defp canonical_target(:kinds, _description), do: {:ok, "/_kinds"}

  defp canonical_target({page, kind} = route, description) when page in [:list, :new],
    do: target_path(route, kind, [kind], description)

  defp canonical_target({:new, kind, {relation, parent}} = route, description),
    do: target_path(route, kind, [kind, relation, parent], description)

  defp canonical_target({page, kind, key} = route, description)
       when page in [:item, :edit, :delete],
       do: target_path(route, kind, [kind, key], description)

  defp canonical_target({:new, _kind, _invalid}, _description),
    do: {:error, "Invalid derived boot route parameters"}

  defp canonical_target({page, kind, key, relation} = route, description)
       when page in [:links, :set, :remove],
       do: target_path(route, kind, [kind, key, relation], description)

  defp canonical_target({:worker_page, page, params} = route, _description)
       when page in [:workers, :worker, :worker_guidance] do
    keys = if page == :workers, do: [], else: [:machine, :worker, :turn, :attempt]

    if Enum.all?(keys, &text?(params[&1], 2_048)),
      do: {:ok, Pages.path(route)},
      else: {:error, "Invalid worker execution route parameters"}
  end

  defp canonical_target(_route, _description), do: {:ok, nil}

  # Validate every required parameter at the path-builder boundary. A malformed
  # description-derived key/relation must be an error, never an exception or fallback.
  # No rescue hides unrelated resolver, process or programming failures.
  defp target_path(route, kind, params, description) do
    if Enum.all?(params, &text?(&1, 2_048)) do
      {:ok, if(known_kind?(kind, description), do: Pages.path(route))}
    else
      {:error, "Invalid derived boot route parameters"}
    end
  end

  defp canonical_tab(to), do: to |> Pages.route() |> Pages.path()

  defp known_kind?(kind, description),
    do: Map.has_key?(description["entities"] || %{}, kind)

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
