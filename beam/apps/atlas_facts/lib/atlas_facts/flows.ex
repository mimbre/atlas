defmodule AtlasFacts.Flows do
  @moduledoc """
  Checks the flow definitions in the description (`flows` in `rela/atlas.json`) before
  anyone runs them (architecture, rule 4): every state that is not done has an owner and
  a way out to a next state, every state can reach done, the last state holds when no
  other does, and what a definition names exists. Facts answers the problems with the
  description (`flow_problems`, per definition); Flow runs only a definition without any.
  Knows no kind by name.
  """

  @conditions ~w(completed progress reopened values empty)

  @doc "The problems of every definition: `%{name => [problem]}` (empty lists when sound)."
  def check(description) do
    for {name, flow} <- description["flows"] || %{}, into: %{} do
      {name, if(is_map(flow), do: problems(description, flow), else: ["is not a definition"])}
    end
  end

  defp problems(description, flow) do
    states = Enum.filter(List.wrap(flow["states"]), &is_map/1)
    names = Enum.map(states, & &1["name"])
    by_name = Map.new(states, &{&1["name"], &1})

    kinds(description, flow) ++
      on(description, flow) ++
      relation(description, flow) ++
      owner_kinds(description, flow) ++
      empties(description, flow) ++
      writes(description, flow) ++
      cond do
        states == [] ->
          ["has no states"]

        length(Enum.uniq(names)) != length(names) or Enum.any?(names, &(not is_binary(&1))) ->
          ["every state needs a name of its own"]

        true ->
          shape(states, by_name) ++ reach(states, by_name)
      end
  end

  defp kinds(description, flow) do
    kinds = List.wrap(flow["kinds"])
    field = flow["field"]
    written = written_kind(description, flow)

    cond do
      kinds == [] ->
        ["runs on no kind"]

      true ->
        for kind <- kinds,
            problem <-
              (cond do
                 not Map.has_key?(description["entities"] || %{}, kind) ->
                   ["#{kind} is not described"]

                 is_binary(field) and
                     get_in(description, ["entities", written || kind, "properties", field]) ==
                       nil ->
                   ["#{written || kind} has no #{field} to write what is expected"]

                 is_binary(flow["state_field"]) and
                     get_in(description, [
                       "entities",
                       written || kind,
                       "properties",
                       flow["state_field"]
                     ]) == nil ->
                   ["#{written || kind} has no #{flow["state_field"]} to write its state"]

                 true ->
                   []
               end),
            do: problem
    end
  end

  defp relation(_description, %{"owner_relation" => nil}), do: []

  defp relation(description, %{"owner_relation" => relation} = flow) do
    case get_in(description, ["relations", relation]) do
      nil ->
        ["#{relation} is not described"]

      spec ->
        for kind <- writes_on(description, flow),
            kind not in (spec["from"] || []),
            do: "#{relation} does not start at #{kind}"
    end
  end

  defp relation(_description, _flow), do: []

  # `on`: Flow writes on the one fact this relation of each of its facts points at (its
  # Assignment), not on the fact itself. It starts at every kind and points at one kind.
  defp on(_description, %{"on" => nil}), do: []

  defp on(description, %{"on" => relation} = flow) do
    case get_in(description, ["relations", relation]) do
      nil ->
        ["#{relation} is not described"]

      spec ->
        for(
          kind <- List.wrap(flow["kinds"]),
          kind not in (spec["from"] || []),
          do: "#{relation} does not start at #{kind}"
        ) ++
          if(match?([_], spec["to"]), do: [], else: ["#{relation} must point at one kind"]) ++
          if(spec["max_outgoing"] == 1, do: [], else: ["#{relation} must allow one link"])
    end
  end

  defp on(_description, _flow), do: []

  # The kind of the facts Flow writes on: the one `on` points at, or nil for the fact's own.
  defp written_kind(description, %{"on" => relation}) when is_binary(relation) do
    case get_in(description, ["relations", relation, "to"]) do
      [kind] -> kind
      _ -> nil
    end
  end

  defp written_kind(_description, _flow), do: nil

  defp writes_on(description, flow) do
    case written_kind(description, flow) do
      nil -> List.wrap(flow["kinds"])
      kind -> [kind]
    end
  end

  # `empty: relation` (nothing points at the fact through it) names a relation that ends at
  # one of the flow's kinds: a parent relation (nothing under it) or an association (nothing
  # based on it).
  defp empties(description, flow) do
    kinds = List.wrap(flow["kinds"])

    for state <- List.wrap(flow["states"]),
        is_map(state),
        {"empty", relation} <- state["when"] || %{},
        # In a list, so a relation that is not described is a problem, not passed over.
        rel <- [get_in(description, ["relations", to_string(relation)])],
        not (is_map(rel) and Enum.any?(List.wrap(rel["to"]), &(&1 in kinds))),
        do: "#{state["name"]}: empty names #{relation}, which points at none of its kinds"
  end

  # Flow passes over the hints of its own writes, so no state may depend on what it writes:
  # not a condition on the owner relation, nor a progress or completion rule that reads its
  # field or that relation: of the kinds it writes on (its own, or what `on` points at), or
  # of its own kinds through `on`.
  defp writes(description, flow) do
    written = Enum.reject([flow["field"], flow["state_field"], flow["owner_relation"]], &is_nil/1)

    conditions =
      for state <- List.wrap(flow["states"]),
          is_map(state),
          {condition, value} <- state["when"] || %{},
          read <- if(condition == "values" and is_map(value), do: Map.keys(value), else: [value]),
          read in written,
          do: "#{state["name"]} depends on #{read}, which Flow writes"

    on = flow["on"]

    rules =
      for kind <- Enum.uniq(List.wrap(flow["kinds"]) ++ writes_on(description, flow)),
          rule <- rules(description, kind),
          {_, value} <- rule,
          value in written,
          on == nil or kind not in List.wrap(flow["kinds"]) or rule["through"] == on,
          uniq: true,
          do: "#{kind}'s progress or completion depends on #{value}, which Flow writes"

    conditions ++ rules
  end

  defp rules(description, kind) do
    progress = get_in(description, ["entities", kind, "progress"])
    completion = get_in(description, ["entities", kind, "completion"])
    Enum.filter([progress | List.wrap(completion)], &is_map/1)
  end

  defp shape(states, by_name) do
    last = List.last(states)

    fallback =
      if (last["when"] || %{}) == %{},
        do: [],
        else: ["the last state, #{last["name"]}, must hold when no other does (no when)"]

    done = if Enum.any?(states, &(&1["done"] == true)), do: [], else: ["has no done state"]

    each =
      Enum.flat_map(states, fn state ->
        name = state["name"]

        unknown =
          for {condition, _} <- state["when"] || %{},
              condition not in @conditions,
              do: "#{name}: when knows no #{condition}"

        unknown ++ open_problems(state, by_name)
      end)

    fallback ++ done ++ each
  end

  # A state that is not done needs an owner and a way out to states that exist.
  defp open_problems(%{"done" => true}, _by_name), do: []

  defp open_problems(state, by_name) do
    name = state["name"]

    owner =
      if owner_key(state["owner"]) not in [nil, ""],
        do: [],
        else: ["#{name} has no owner"]

    next =
      case List.wrap(state["next"]) do
        [] ->
          ["#{name} has no way out (next)"]

        next ->
          for n <- next,
              not Map.has_key?(by_name, n),
              do: "#{name}: its next #{inspect(n)} is no state"
      end

    owner ++ next
  end

  defp owner_key(%{"key" => key}) when is_binary(key), do: key
  defp owner_key(key) when is_binary(key), do: key
  defp owner_key(_owner), do: nil

  # With an owner relation, each open state's owner names its kind, one the relation allows.
  defp owner_kinds(description, %{"owner_relation" => relation} = flow)
       when is_binary(relation) do
    allowed = get_in(description, ["relations", relation, "to"]) || []

    for state <- List.wrap(flow["states"]),
        is_map(state),
        state["done"] != true,
        problem <-
          (case state["owner"] do
             %{"kind" => kind} when is_binary(kind) ->
               if kind in allowed,
                 do: [],
                 else: ["#{state["name"]}: #{relation} does not allow its owner's kind, #{kind}"]

             _ ->
               ["#{state["name"]}: its owner names no kind (owner: {kind, key})"]
           end),
        do: problem
  end

  defp owner_kinds(_description, _flow), do: []

  # From every state, following next, some done state is reached.
  defp reach(states, by_name) do
    for state <- states,
        state["done"] != true,
        not reaches_done?(state["name"], by_name, MapSet.new()),
        do: "#{state["name"]} never reaches done"
  end

  defp reaches_done?(name, by_name, seen) do
    state = by_name[name] || %{}

    cond do
      state["done"] == true ->
        true

      MapSet.member?(seen, name) ->
        false

      true ->
        Enum.any?(List.wrap(state["next"]), &reaches_done?(&1, by_name, MapSet.put(seen, name)))
    end
  end
end
