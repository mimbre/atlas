defmodule RelaDSL.Description.Check do
  @moduledoc """
  The checks of a composition's description, on its plain data: every name a rule
  gives resolves to a kind, field, relation or value the schema describes, and each
  rule has the shape its readers expect. `check/2` returns `[{path, message}]`, with
  `path` the keys of `atlas.json` at fault, so the composition can name the file and
  line that wrote them.

  These are the assembler's checks (D-0083 slice 2 moved them here), and the
  soundness of the legacy flow definitions that Facts checks again when it loads them.
  """

  @guidance %{
    "execution" =>
      ~w(environment worker turn attempt machine harness harness_version configured_model reported_model capability_version queued_input durable_accept_query consumption_evidence recorded_at recorded_position),
    "interaction" =>
      ~w(environment actor client_key body body_digest worker turn attempt mode execution cause recorded_at recorded_position),
    "receipt" =>
      ~w(environment interaction worker turn attempt execution stage evidence_id admission_id consumption_id reason writer cause recorded_at recorded_position)
  }
  @conditions ~w(completed progress reopened values empty)

  @doc "Problems of `extension` against `schema` (both plain): `[{path, message}]`."
  def check(schema, extension) do
    ctx = %{
      entities: schema["entities"] || %{},
      relations: schema["relations"] || %{},
      types: schema["types"] || %{},
      x: extension
    }

    guidance(ctx) ++
      keyed(ctx, "todo", ~w(title why instructions answers)) ++
      shell(ctx) ++
      start(ctx) ++
      types(ctx) ++
      entities(ctx) ++
      relations(ctx) ++
      progress(ctx) ++ flows(ctx) ++ read_first(ctx) ++ runtime(ctx)
  end

  # -- References ---------------------------------------------------------------------

  defp p(path, message), do: [{path, message}]

  defp keys(value, allowed, path) when is_map(value) do
    case Map.keys(value) -- allowed do
      [] ->
        []

      unknown ->
        p(path, "#{Enum.join(path, ".")}: unknown keys #{Enum.join(Enum.sort(unknown), ", ")}")
    end
  end

  defp keys(_value, _allowed, path), do: p(path, "#{Enum.join(path, ".")}: expected a map")

  defp entity(ctx, kind, path) do
    if is_binary(kind) and Map.has_key?(ctx.entities, kind),
      do: [],
      else: p(path, "unknown kind: #{inspect(kind)}")
  end

  defp field(ctx, kind, name, path) do
    cond do
      not (is_binary(kind) and Map.has_key?(ctx.entities, kind)) ->
        p(path, "unknown kind: #{inspect(kind)}")

      Map.has_key?(ctx.entities[kind]["properties"] || %{}, name) ->
        []

      true ->
        p(path, "#{kind}: unknown field #{inspect(name)}")
    end
  end

  defp prop(ctx, kind, name), do: get_in(ctx.entities, [kind, "properties", name])

  defp rel(ctx, name), do: is_binary(name) && ctx.relations[name]

  defp relation(ctx, name, kind \\ nil, direction \\ "from", path) do
    case rel(ctx, name) do
      nil ->
        p(path, "unknown relation: #{inspect(name)}")

      false ->
        p(path, "unknown relation: #{inspect(name)}")

      spec ->
        if kind == nil or kind in (spec[direction] || []),
          do: [],
          else: p(path, "#{name}: #{direction} does not contain #{kind}")
    end
  end

  defp values(ctx, kind, mapping, path) when is_map(mapping) do
    Enum.flat_map(mapping, fn {name, allowed} ->
      case field(ctx, kind, name, path) do
        [] ->
          enum = get_in(ctx.types, [prop(ctx, kind, name)["type"], "values"])
          given = List.wrap(allowed)

          if enum && Enum.any?(given, &(&1 not in enum)),
            do: p(path, "#{kind}.#{name}: unknown value in #{inspect(given)}"),
            else: []

        problems ->
          problems
      end
    end)
  end

  defp values(_ctx, _kind, nil, _path), do: []
  defp values(_ctx, kind, _other, path), do: p(path, "#{kind}: expected {field: values}")

  defp text?(v), do: is_binary(v) and String.trim(v) != ""

  # -- Root constructs -----------------------------------------------------------------

  defp guidance(%{x: %{"guidance" => g}} = ctx) do
    path = ["guidance"]

    shape =
      keys(g, Map.keys(@guidance), path) ++
        if(is_map(g) and Enum.sort(Map.keys(g)) == Enum.sort(Map.keys(@guidance)),
          do: [],
          else: p(path, "guidance: all three durable roles required")
        )

    roles =
      for {role, slots} <- @guidance, mapping = is_map(g) && g[role], is_map(mapping) do
        at = path ++ [role]
        fields = mapping["fields"] || %{}

        keys(mapping, ~w(kind fields), at) ++
          entity(ctx, mapping["kind"], at) ++
          if(Enum.sort(Map.keys(fields)) == Enum.sort(slots),
            do: [],
            else: p(at, "guidance.#{role}: incomplete field mapping")
          ) ++
          if(length(Enum.uniq(Map.values(fields))) == map_size(fields),
            do: [],
            else: p(at, "guidance.#{role}: duplicate field mapping")
          ) ++
          Enum.flat_map(Map.values(fields), &field(ctx, mapping["kind"], &1, at))
      end
      |> List.flatten()

    kinds = for {role, _} <- @guidance, is_map(g) and is_map(g[role]), do: g[role]["kind"]
    turn = get_in(ctx.x, ["runtime", "turn"]) || %{}

    shape ++
      roles ++
      if(length(Enum.uniq(kinds)) == 3,
        do: [],
        else: p(path, "guidance: roles must use separate kinds")
      ) ++
      field(ctx, turn["kind"], turn["attempt"], path)
  end

  defp guidance(_ctx), do: []

  defp keyed(ctx, key, allowed) do
    case ctx.x[key] do
      nil -> []
      value -> keys(value, allowed, [key])
    end
  end

  defp shell(%{x: %{"shell" => shell}} = ctx) do
    path = ["shell"]
    tabs = is_map(shell) && shell["tabs"]

    keys(shell, ~w(title tabs), path) ++
      if(is_map(shell) and text?(shell["title"]) and byte_size(shell["title"]) <= 128,
        do: [],
        else: p(path, "shell.title: expected nonempty text")
      ) ++
      if(is_list(tabs) and tabs != [] and length(tabs) <= 64,
        do: tabs(ctx, tabs, path),
        else: p(path, "shell.tabs: expected nonempty list")
      )
  end

  defp shell(_ctx), do: []

  defp tabs(ctx, tabs, path) do
    {problems, _, _} =
      Enum.reduce(tabs, {[], MapSet.new(), MapSet.new()}, fn tab, {ps, ids, targets} ->
        at = path ++ ["tabs"]

        texts =
          if is_map(tab) and Enum.all?(~w(id label to), &text?(tab[&1])) do
            for {k, limit} <- [{"id", 64}, {"label", 128}, {"to", 2048}],
                byte_size(tab[k]) > limit,
                do: {at, "shell.tabs: text exceeds size limit"}
          else
            p(at, "shell.tabs: id, label and to require nonempty text")
          end

        tab = if is_map(tab), do: tab, else: %{}
        target = tab["to"]

        destination =
          cond do
            not is_binary(target) ->
              []

            target == "/" ->
              if tab["assigned"] == true and get_in(ctx.x, ["start", "assigned"]),
                do: [],
                else: p(at, "shell.tabs: root requires an assigned start")

            String.starts_with?(target, "/k/") and length(String.split(target, "/")) == 3 ->
              entity(ctx, String.slice(target, 3..-1//1), at)

            true ->
              p(at, "shell.tabs: destination must be an index page")
          end

        twice =
          if MapSet.member?(ids, tab["id"]) or MapSet.member?(targets, target),
            do: p(at, "shell.tabs: duplicate id or destination"),
            else: []

        {ps ++
           keys(tab, ~w(id label to assigned), at) ++
           texts ++
           if(is_boolean(Map.get(tab, "assigned", false)),
             do: [],
             else: p(at, "shell.tabs.assigned: expected boolean")
           ) ++
           destination ++ twice, MapSet.put(ids, tab["id"]), MapSet.put(targets, target)}
      end)

    problems
  end

  defp start(%{x: %{"start" => start}} = ctx) do
    path = ["start"]

    keys(start, ~w(assigned open), path) ++
      case is_map(start) && start["assigned"] do
        spec when is_map(spec) ->
          keys(spec, ~w(relation title count empty), path ++ ["assigned"]) ++
            if(spec["relation"], do: relation(ctx, spec["relation"], path), else: [])

        _ ->
          []
      end ++
      case is_map(start) && start["open"] do
        spec when is_map(spec) -> keys(spec, ~w(title empty), path ++ ["open"])
        _ -> []
      end
  end

  defp start(_ctx), do: []

  defp types(ctx) do
    for {name, spec} <- ctx.x["types"] || %{}, at = ["types", name] do
      if(Map.has_key?(ctx.types, name), do: [], else: p(at, "unknown type: #{name}")) ++
        keys(spec, ["format"], at) ++
        if(is_map(spec) and spec["format"] == "url", do: [], else: p(at, "unknown type format"))
    end
    |> List.flatten()
  end

  # -- Kinds ----------------------------------------------------------------------------

  defp entities(ctx) do
    specs = ctx.x["entities"] || %{}

    shortcuts = for {_k, %{"start" => %{"key" => key}}} <- specs, do: key

    Enum.flat_map(specs, fn {kind, spec} -> kind_problems(ctx, kind, spec, ["entities", kind]) end) ++
      if(length(shortcuts) == length(Enum.uniq(shortcuts)),
        do: [],
        else: p(["entities"], "duplicate navigation shortcut")
      )
  end

  defp kind_problems(ctx, kind, spec, path) do
    case entity(ctx, kind, path) do
      [] ->
        if is_map(spec),
          do: kind_rules(ctx, kind, spec, path),
          else: p(path, "#{kind}: expected a map")

      problems ->
        problems
    end
  end

  defp kind_rules(ctx, kind, spec, path) do
    at = &(path ++ [&1])

    keys(
      spec,
      ~w(top primary start create properties completion progress connector agent order by_hand late actions counts requires authority frozen replaces layering sealed delete_error),
      path
    ) ++
      navigation(spec["start"], at.("start")) ++
      if(spec["primary"], do: field(ctx, kind, spec["primary"], at.("primary")), else: []) ++
      if(Map.has_key?(spec, "delete_error") and not text?(spec["delete_error"]),
        do:
          p(
            at.("delete_error"),
            "#{kind}.delete_error: expected the sentence a refused delete says"
          ),
        else: []
      ) ++
      create(ctx, kind, spec["create"], at.("create")) ++
      Enum.flat_map(spec["properties"] || %{}, fn {name, note} ->
        field(ctx, kind, name, at.("properties")) ++
          keys(note, ~w(set_by multiline label cause), at.("properties") ++ [name])
      end) ++
      late(ctx, kind, spec["late"], at.("late")) ++
      Enum.flat_map(List.wrap(spec["counts"]), fn c ->
        keys(c, ~w(relation text), at.("counts")) ++
          relation(ctx, c["relation"], kind, "to", at.("counts"))
      end) ++
      Enum.flat_map(
        List.wrap(spec["completion"]),
        &condition(ctx, kind, &1, at.("completion"), false)
      ) ++
      if(spec["progress"],
        do: condition(ctx, kind, spec["progress"], at.("progress"), true),
        else: []
      ) ++
      connector(ctx, kind, spec["connector"], at.("connector")) ++
      Enum.flat_map(List.wrap(spec["actions"]), fn a ->
        keys(a, ~w(key label to when), at.("actions")) ++
          values(ctx, kind, a["when"], at.("actions"))
      end) ++
      Enum.flat_map(List.wrap(spec["requires"]), fn r ->
        keys(r, ~w(when fields error), at.("requires")) ++
          values(ctx, kind, r["when"], at.("requires")) ++
          Enum.flat_map(List.wrap(r["fields"]), &field(ctx, kind, &1, at.("requires")))
      end) ++
      authority(ctx, kind, spec["authority"], at.("authority")) ++
      layering(ctx, kind, spec["layering"], at.("layering")) ++
      frozen(ctx, kind, spec["frozen"], at.("frozen")) ++
      sealed(ctx, kind, spec["sealed"], at.("sealed")) ++
      replaces(ctx, kind, spec["replaces"], at.("replaces"))
  end

  defp navigation(nil, _path), do: []

  defp navigation(spec, path) do
    keys(spec, ~w(key label), path) ++
      if(is_map(spec) and is_binary(spec["key"]) and String.length(spec["key"]) == 1,
        do: [],
        else: p(path, "#{Enum.join(path, ".")}: shortcut must be one character")
      )
  end

  defp create(_ctx, _kind, nil, _path), do: []

  defp create(ctx, kind, create, path) do
    id = (is_map(create) && create["id"]) || %{}

    keys(create, ~w(ask id defaults), path) ++
      Enum.flat_map(List.wrap(is_map(create) && create["ask"]), &field(ctx, kind, &1, path)) ++
      Enum.flat_map((is_map(create) && create["defaults"]) || %{}, fn {name, value} ->
        values(ctx, kind, %{name => [value]}, path ++ ["defaults"])
      end) ++
      keys(id, ~w(prefix digits first from pattern template replace lower error), path ++ ["id"]) ++
      if(is_map(id) and id["from"], do: field(ctx, kind, id["from"], path ++ ["id"]), else: [])
  end

  defp late(_ctx, _kind, nil, _path), do: []

  defp late(ctx, kind, late, path) do
    keys(late, ~w(after while label), path) ++
      Enum.flat_map(~w(after while), &field(ctx, kind, is_map(late) && late[&1], path))
  end

  defp condition(ctx, kind, rule, path, progress?) do
    allowed =
      if progress?, do: ~w(over field own while), else: ~w(by over through field value shows)

    rule = if is_map(rule), do: rule, else: %{}

    target =
      cond do
        rule["over"] -> (rel(ctx, rule["over"]) || %{})["from"] || []
        rule["through"] -> (rel(ctx, rule["through"]) || %{})["to"] || []
        true -> [kind]
      end

    keys(rule, allowed, path) ++
      if(rule["own"], do: field(ctx, kind, rule["own"], path), else: []) ++
      Enum.flat_map(List.wrap(rule["while"]), &condition(ctx, kind, &1, path ++ ["while"], false)) ++
      if(rule["by"], do: relation(ctx, rule["by"], kind, path), else: []) ++
      if(rule["over"], do: relation(ctx, rule["over"], kind, "to", path), else: []) ++
      if(rule["through"], do: relation(ctx, rule["through"], kind, path), else: []) ++
      if rule["field"] do
        Enum.flat_map(target, fn k ->
          field(ctx, k, rule["field"], path) ++
            if(Map.has_key?(rule, "value"),
              do: values(ctx, k, %{rule["field"] => [rule["value"]]}, path),
              else: []
            )
        end)
      else
        []
      end
  end

  defp connector(_ctx, _kind, nil, _path), do: []

  defp connector(ctx, kind, c, path) do
    names = is_map(c) && c["names"]

    keys(c, ~w(system address fields until names), path) ++
      if(c["address"], do: field(ctx, kind, c["address"], path), else: []) ++
      Enum.flat_map(Map.keys(c["fields"] || %{}), &field(ctx, kind, &1, path)) ++
      values(ctx, kind, c["until"], path) ++
      if is_map(names) do
        keys(names, ~w(field relation when), path ++ ["names"]) ++
          field(ctx, kind, names["field"], path ++ ["names"]) ++
          relation(ctx, names["relation"], kind, "to", path ++ ["names"]) ++
          values(ctx, kind, names["when"], path ++ ["names"])
      else
        []
      end
  end

  defp authority(_ctx, _kind, nil, _path), do: []

  defp authority(ctx, kind, rule, path) do
    by = rel(ctx, rule["by"]) || %{}
    decider = rule["decider"]

    keys(
      rule,
      ~w(when by kind agent_kind decider only_kind_when delegated_by error writes writer_error also),
      path
    ) ++
      values(ctx, kind, rule["writes"], path) ++
      values(ctx, kind, rule["when"], path) ++
      relation(ctx, rule["by"], kind, path) ++
      if(rule["kind"] in (by["to"] || []),
        do: [],
        else: p(path, "#{kind}.authority: #{rule["by"]} does not point at #{rule["kind"]}")
      ) ++
      Enum.flat_map(List.wrap(rule["only_kind_when"]), &values(ctx, kind, &1, path)) ++
      if(Map.has_key?(rule, "agent_kind") and rule["agent_kind"] not in (by["to"] || []),
        do: p(path, "#{kind}.authority: invalid agent kind"),
        else: []
      ) ++
      decider(ctx, kind, decider, path ++ ["decider"]) ++
      if(rule["delegated_by"], do: relation(ctx, rule["delegated_by"], kind, path), else: [])
  end

  defp decider(_ctx, _kind, nil, _path), do: []

  defp decider(ctx, kind, d, path) do
    via = rel(ctx, d["relation"]) || %{}
    fingerprint = d["fingerprint"] || %{}

    keys(d, ~w(gate relation kind fingerprint), path) ++
      if(text?(d["gate"]), do: [], else: p(path, "decider needs a gate")) ++
      relation(ctx, d["relation"], kind, "to", path) ++
      entity(ctx, d["kind"], path) ++
      if(d["kind"] in (via["from"] || []),
        do: [],
        else: p(path, "decider relation must come from its verdict kind")
      ) ++
      keys(fingerprint, ~w(fields relations), path ++ ["fingerprint"]) ++
      Enum.flat_map(List.wrap(fingerprint["fields"]), &field(ctx, kind, &1, path)) ++
      Enum.flat_map(List.wrap(fingerprint["relations"]), &relation(ctx, &1, kind, path))
  end

  defp layering(_ctx, _kind, nil, _path), do: []

  defp layering(ctx, kind, rule, path) do
    banned = rule["not"] || %{}

    keys(rule, ~w(relation field not error), path) ++
      if((rel(ctx, rule["relation"]) || %{})["to"] == [kind],
        do: [],
        else: p(path, "#{kind}.layering: #{rule["relation"]} must point at #{kind}")
      ) ++
      field(ctx, kind, rule["field"], path) ++
      values(ctx, kind, %{rule["field"] => Map.keys(banned)}, path) ++
      Enum.flat_map(Map.values(banned), &values(ctx, kind, %{rule["field"] => &1}, path))
  end

  defp frozen(_ctx, _kind, nil, _path), do: []

  defp frozen(ctx, kind, rule, path) do
    keys(rule, ~w(when only error), path) ++
      values(ctx, kind, rule["when"], path) ++ values(ctx, kind, rule["only"], path)
  end

  defp sealed(_ctx, _kind, nil, _path), do: []

  defp sealed(ctx, kind, rule, path) do
    keys(rule, ~w(once links error once_error), path) ++
      if(Map.get(rule, "links", "once") == "once",
        do: [],
        else: p(path, "#{kind}.sealed.links: expected once")
      ) ++
      Enum.flat_map(List.wrap(rule["once"]), fn name ->
        if prop(ctx, kind, name), do: [], else: relation(ctx, name, kind, path)
      end)
  end

  defp replaces(_ctx, _kind, nil, _path), do: []

  defp replaces(ctx, kind, rule, path) do
    keys(rule, ~w(relation when of set error), path) ++
      if((rel(ctx, rule["relation"]) || %{})["to"] == [kind],
        do: [],
        else: p(path, "#{kind}.replaces: #{rule["relation"]} must point at #{kind}")
      ) ++
      values(ctx, kind, rule["when"], path) ++
      values(ctx, kind, rule["of"], path) ++ values(ctx, kind, rule["set"], path)
  end

  # -- Relations ------------------------------------------------------------------------

  defp relations(ctx) do
    {problems, _parents} =
      Enum.reduce(ctx.x["relations"] || %{}, {[], %{}}, fn {name, note}, {ps, parents} ->
        path = ["relations", name]

        case rel(ctx, name) do
          spec when is_map(spec) and is_map(note) ->
            {parent_ps, parents} =
              if note["parent"] do
                Enum.reduce(spec["from"] || [], {[], parents}, fn kind, {pp, acc} ->
                  if Map.has_key?(acc, kind),
                    do: {pp ++ p(path, "ambiguous parent for #{kind}"), acc},
                    else: {pp, Map.put(acc, kind, name)}
                end)
              else
                {[], parents}
              end

            {ps ++ parent_ps ++ relation_rules(ctx, name, spec, note, path), parents}

          _ ->
            {ps ++ relation(ctx, name, path), parents}
        end
      end)

    problems
  end

  defp relation_rules(ctx, name, spec, note, path) do
    component = note["component"]
    limit = note["limit"]
    review = note["review"]

    keys(
      note,
      ~w(parent add component set_by limit actions only_target requires_completed_children closes_parent review),
      path
    ) ++
      if is_map(component) do
        template = component["key"]

        keys(component, ~w(key values), path ++ ["component"]) ++
          if(text?(template) and byte_size(template) <= 2048,
            do: [],
            else:
              p(path, "#{name}: component key template must be nonempty text within 2048 bytes")
          ) ++
          case spec["to"] do
            [target] ->
              Enum.flat_map(Map.keys(component["values"] || %{}), &field(ctx, target, &1, path))

            _ ->
              p(path, "#{name}: component needs one target kind")
          end
      else
        if(Map.has_key?(note, "component"),
          do: p(path, "#{name}: component key template must be nonempty text within 2048 bytes"),
          else: []
        )
      end ++
      if is_map(limit) do
        keys(limit, ~w(max field values error), path ++ ["limit"]) ++
          Enum.flat_map(
            spec["from"] || [],
            &values(ctx, &1, %{limit["field"] => limit["values"]}, path)
          )
      else
        []
      end ++
      if is_map(review) do
        keys(review, ~w(field value label), path ++ ["review"]) ++
          Enum.flat_map(
            spec["to"] || [],
            &values(ctx, &1, %{review["field"] => [review["value"]]}, path)
          )
      else
        []
      end ++
      if(note["only_target"],
        do: keys(note["only_target"], ~w(error also), path ++ ["only_target"]),
        else: []
      ) ++
      actions(ctx, spec, note["actions"] || %{}, path ++ ["actions"])
  end

  defp actions(ctx, spec, actions, path) do
    keys(actions, ~w(set remove change), path) ++
      Enum.flat_map(if(is_map(actions), do: actions, else: %{}), fn {action_name, action} ->
        keys(action, ~w(key label with cause), path ++ [action_name]) ++
          for prop <- List.wrap(is_map(action) && action["with"]),
              kind <- spec["from"] || [],
              problem <- field(ctx, kind, prop, path),
              do: problem
      end)
  end

  defp progress(%{x: %{"progress" => progress}} = ctx) do
    path = ["progress"]
    order = (is_map(progress) && progress["order"]) || []

    known =
      for({_, spec} <- ctx.types, v <- spec["values"] || [], do: v) ++
        [get_in(progress, ["to_test", "value"])]

    keys(progress, ~w(order done_label to_test), path) ++
      if(length(order) == length(Enum.uniq(order)) and Enum.all?(order, &(&1 in known)),
        do: [],
        else: p(path, "progress order has duplicate or unknown values")
      ) ++
      if(is_map(progress) and progress["to_test"],
        do: keys(progress["to_test"], ~w(value label), path ++ ["to_test"]),
        else: []
      )
  end

  defp progress(_ctx), do: []

  defp read_first(%{x: %{"read_first" => spec}} = ctx) do
    path = ["read_first"]
    anchors = (rel(ctx, spec["through"]) || %{})["to"] || []

    keys(spec, ~w(title through then standing tags text), path) ++
      relation(ctx, spec["through"], path) ++
      case anchors do
        [anchor] ->
          relation(ctx, spec["then"], anchor, path) ++
            Enum.flat_map(List.wrap(spec["standing"]), fn group ->
              keys(group, ~w(title first when), path ++ ["standing"]) ++
                values(ctx, anchor, group["when"], path)
            end) ++
            Enum.flat_map(
              List.wrap(spec["tags"]) ++ [spec["text"]],
              &field(ctx, anchor, &1, path)
            )

        _ ->
          p(path, "read_first.through: must point at one kind")
      end
  end

  defp read_first(_ctx), do: []

  defp runtime(ctx) do
    runtime = ctx.x["runtime"] || %{}
    path = ["runtime"]

    keys(runtime, ~w(turn agent), path) ++
      if(
        runtime != %{} and not (Map.has_key?(runtime, "turn") and Map.has_key?(runtime, "agent")),
        do: p(path, "runtime requires both turn and agent mappings"),
        else: []
      ) ++
      if(runtime["agent"],
        do: keys(runtime["agent"], ~w(cannot_run), path ++ ["agent"]),
        else: []
      ) ++
      turn(ctx, runtime, path)
  end

  defp turn(ctx, %{"turn" => turn} = runtime, path) do
    path = path ++ ["turn"]
    kind = turn["kind"]

    missing =
      for k <- ~w(state machine lease activity why ended_at outcome),
          not Map.has_key?(turn, k),
          do: k

    keys(
      turn,
      ~w(kind key on by state running ended machine lease activity why ended_at outcome attempt title model),
      path
    ) ++
      entity(ctx, kind, path) ++
      Enum.flat_map(missing, &p(path, "runtime.turn: missing #{&1}")) ++
      for(
        k <- ~w(state machine lease activity why ended_at outcome title model),
        Map.has_key?(turn, k),
        problem <- field(ctx, kind, turn[k], path),
        do: problem
      ) ++
      values(ctx, kind, %{turn["state"] => [turn["running"], turn["ended"]]}, path) ++
      relation(ctx, turn["on"], kind, path) ++
      relation(ctx, turn["by"], kind, path) ++
      for agent <- (rel(ctx, turn["by"]) || %{})["to"] || [],
          runtime["agent"],
          problem <- field(ctx, agent, runtime["agent"]["cannot_run"], path),
          do: problem
  end

  defp turn(_ctx, _runtime, _path), do: []

  # -- Legacy flows ---------------------------------------------------------------------

  defp flows(ctx) do
    specs = ctx.x["flows"] || %{}

    {problems, _} =
      Enum.reduce(Enum.sort(specs), {[], MapSet.new()}, fn {name, flow}, {ps, used} ->
        path = ["flows", name]
        flow = if is_map(flow), do: flow, else: %{}
        kinds = List.wrap(flow["kinds"])

        overlap =
          if Enum.any?(kinds, &MapSet.member?(used, &1)),
            do: p(path, "overlapping flow kinds"),
            else: []

        {ps ++ overlap ++ flow_problems(ctx, name, flow, path),
         MapSet.union(used, MapSet.new(kinds))}
      end)

    problems
  end

  defp flow_problems(ctx, name, flow, path) do
    kinds = List.wrap(flow["kinds"])
    states = Enum.filter(List.wrap(flow["states"]), &is_map/1)
    names = Enum.map(states, & &1["name"])
    by_name = Map.new(states, &{&1["name"], &1})
    written = written(ctx, flow)

    keys(flow, ~w(on state_field handover_field owner_relation kinds field states), path) ++
      if(get_in(ctx.x, ["runtime", "turn"]) && not Map.has_key?(flow, "handover_field"),
        do: p(path, "#{name}: Runtime flows require handover_field"),
        else: []
      ) ++
      if(kinds == [],
        do: p(path, "#{name}: runs on no kind"),
        else: Enum.flat_map(kinds, &entity(ctx, &1, path))
      ) ++
      if(flow["on"], do: on(ctx, flow, path), else: []) ++
      for(
        kind <- written,
        f <- ~w(field state_field handover_field),
        Map.has_key?(flow, f),
        problem <- field(ctx, kind, flow[f], path),
        do: problem
      ) ++
      for(
        kind <- written,
        flow["owner_relation"],
        problem <- relation(ctx, flow["owner_relation"], kind, path),
        do: problem
      ) ++
      writes(ctx, flow, written, path) ++
      cond do
        states == [] ->
          p(path, "#{name}: has no states")

        length(Enum.uniq(names)) != length(names) ->
          p(path, "#{name}: every state needs a name of its own")

        true ->
          shape(ctx, name, flow, states, by_name, path) ++ reach(name, states, by_name, path)
      end
  end

  defp written(ctx, %{"on" => on} = flow) when is_binary(on),
    do: if(spec = rel(ctx, on), do: spec["to"] || [], else: List.wrap(flow["kinds"]))

  defp written(_ctx, flow), do: List.wrap(flow["kinds"])

  defp on(ctx, flow, path) do
    on = flow["on"]

    case rel(ctx, on) do
      spec when is_map(spec) ->
        for(
          kind <- List.wrap(flow["kinds"]),
          kind not in (spec["from"] || []),
          do: {path, "#{on} does not start at #{kind}"}
        ) ++
          if(match?([_], spec["to"]), do: [], else: p(path, "#{on} must point at one kind")) ++
          if(spec["max_outgoing"] == 1, do: [], else: p(path, "#{on} must allow one link"))

      _ ->
        p(path, "unknown relation: #{inspect(on)}")
    end
  end

  # Flow passes over its own writes, so no state may depend on what it writes.
  defp writes(ctx, flow, written, path) do
    own = Enum.reject([flow["field"], flow["state_field"], flow["owner_relation"]], &is_nil/1)
    kinds = List.wrap(flow["kinds"])

    conditions =
      for state <- List.wrap(flow["states"]),
          is_map(state),
          {condition, value} <- state["when"] || %{},
          read <- if(condition == "values" and is_map(value), do: Map.keys(value), else: [value]),
          read in own,
          do: {path, "#{state["name"]} depends on #{read}, which Flow writes"}

    rules =
      for kind <- Enum.uniq(kinds ++ written),
          spec = get_in(ctx.x, ["entities", kind]) || %{},
          rule <- Enum.filter([spec["progress"] | List.wrap(spec["completion"])], &is_map/1),
          {_, value} <- rule,
          value in own,
          flow["on"] == nil or kind not in kinds or rule["through"] == flow["on"],
          uniq: true,
          do: {path, "#{kind}'s progress or completion depends on #{value}, which Flow writes"}

    conditions ++ rules
  end

  defp shape(ctx, name, flow, states, by_name, path) do
    last = List.last(states)
    kinds = List.wrap(flow["kinds"])
    allowed = (rel(ctx, flow["owner_relation"]) || %{})["to"] || []
    order = get_in(ctx.x, ["progress", "order"]) || []

    if((last["when"] || %{}) == %{},
      do: [],
      else:
        p(
          path,
          "#{name}: the last state, #{last["name"]}, must hold when no other does (no when)"
        )
    ) ++
      if(Enum.any?(states, &(&1["done"] == true)),
        do: [],
        else: p(path, "#{name}: has no done state")
      ) ++
      Enum.flat_map(states, fn state ->
        at = path ++ ["states"]
        s = state["name"]
        when_ = state["when"] || %{}
        todo = state["todo"] || %{}
        answers = List.wrap(todo["answers"])
        answer_keys = Enum.map(answers, & &1["key"])

        keys(state, ~w(name when done owner expected why next every_seconds todo), at) ++
          keys(when_, @conditions, at) ++
          if(Map.has_key?(when_, "progress") and when_["progress"] not in order,
            do: p(at, "#{name}: unknown progress condition"),
            else: []
          ) ++
          Enum.flat_map(kinds, fn kind ->
            values(ctx, kind, when_["values"], at) ++
              if(when_["reopened"], do: relation(ctx, when_["reopened"], kind, at), else: [])
          end) ++
          empty(ctx, s, when_["empty"], kinds, at) ++
          owner(ctx, flow, state, allowed, at) ++
          keys(todo, ~w(instructions section answers), at) ++
          if(todo["section"],
            do:
              keys(todo["section"], ~w(field heading), at) ++
                Enum.flat_map(kinds, &field(ctx, &1, todo["section"]["field"], at)),
            else: []
          ) ++
          if(length(answer_keys) == length(Enum.uniq(answer_keys)),
            do: [],
            else: p(at, "duplicate answer shortcut")
          ) ++
          Enum.flat_map(answers, fn answer ->
            keys(answer, ~w(key label set remove), at) ++
              for(
                op <- ~w(set remove),
                answer[op],
                kind <- kinds,
                problem <- relation(ctx, answer[op], kind, at),
                do: problem
              )
          end) ++ open(state, by_name, at)
      end)
  end

  defp empty(_ctx, _state, nil, _kinds, _path), do: []

  defp empty(ctx, state, relation, kinds, path) do
    case rel(ctx, relation) do
      spec when is_map(spec) ->
        if Enum.any?(spec["to"] || [], &(&1 in kinds)),
          do: [],
          else: p(path, "#{state}: empty names #{relation}, which points at none of its kinds")

      _ ->
        p(path, "unknown relation: #{inspect(relation)}")
    end
  end

  defp owner(_ctx, _flow, %{"done" => true}, _allowed, _path), do: []

  defp owner(ctx, flow, state, allowed, path) do
    case state["owner"] do
      %{"kind" => kind} = o when is_binary(kind) ->
        named(o, state, path) ++
          entity(ctx, kind, path) ++
          if(flow["owner_relation"] == nil or kind in allowed,
            do: [],
            else:
              p(
                path,
                "#{state["name"]}: #{flow["owner_relation"]} does not allow its owner's kind, #{kind}"
              )
          )

      _ ->
        p(
          path,
          "#{state["name"]}: its owner names no kind and key " <>
            "(owner: {kind, key}, or {kind, config: role})"
        )
    end
  end

  # An owner names a key, or the role of an actor the environment configures (`config`),
  # and nothing else.
  defp named(o, state, path) do
    {name, shape} =
      if Map.has_key?(o, "config"),
        do: {o["config"], ~w(kind config)},
        else: {o["key"], ~w(kind key)}

    if is_binary(name) and name != "",
      do: keys(o, shape, path),
      else:
        p(
          path,
          "#{state["name"]}: its owner names no kind and key " <>
            "(owner: {kind, key}, or {kind, config: role})"
        )
  end

  defp open(%{"done" => true}, _by_name, _path), do: []

  defp open(state, by_name, path) do
    case List.wrap(state["next"]) do
      [] ->
        p(path, "#{state["name"]} has no way out (next)")

      next ->
        for n <- next,
            not Map.has_key?(by_name, n),
            do: {path, "#{state["name"]}: its next #{inspect(n)} is no state"}
    end
  end

  defp reach(name, states, by_name, path) do
    for state <- states,
        state["done"] != true,
        not reaches?(state["name"], by_name, MapSet.new()),
        do: {path, "#{name}: #{state["name"]} never reaches done"}
  end

  defp reaches?(name, by_name, seen) do
    state = by_name[name] || %{}

    cond do
      state["done"] == true -> true
      MapSet.member?(seen, name) -> false
      true -> Enum.any?(List.wrap(state["next"]), &reaches?(&1, by_name, MapSet.put(seen, name)))
    end
  end
end
