defmodule AtlasFlow.Definition do
  @moduledoc """
  Flow definitions, as rela's description holds them (`flows` in `rela/atlas.json`), and
  which state a fact is in. Pure; knows no kind by name.

  A definition:

      "flows": {"<name>": {
        "kinds": [<kind>, ...],            the kinds it runs on
        "on": "<relation>",                writes on the fact this relation of its fact
                                           points at (its Assignment), not on the fact
        "field": "<property>",             where it writes what the owner is expected to do
        "state_field": "<property>",       where it writes the name of the state (optional)
        "owner_relation": "<relation>",    where it writes the owner (optional)
        "states": [                        in order: the first that holds is the state
          {"name": ..., "when": {...}, "done": true},
          {"name": ..., "when": {...}, "owner": {"kind": <kind>, "key": <key>},
           "expected": <text>, "why": <text>, "next": [<state>, ...],
           "every_seconds": <n>}, ...
          {"name": ..., "owner": ..., ...}        the last holds when nothing else does
        ]}}

  What a state's `when` can say, of the fact as Facts answers it:

  - `"completed": true`: it is completed (`completion`);
  - `"progress": <value>`: its progress has that value (such as to test);
  - `"reopened": <relation>`: the newest fact about that association removed it, and no
    fact came under it since (through a parent relation). `{note}` in `expected` is that
    fact's cause;
  - `"values": {<property>: [<value>, ...]}`: each property has one of those values (such
    as merged or closed);
  - `"empty": <relation>`: nothing points at the fact through that relation, one that ends
    at its kind: a parent relation (nothing is under it yet) or an association (nothing is
    based on it yet). Never for a relation that does not end at its kind.

  `expected` may name the fact's own properties (`{consequences}`) besides `{note}`.

  Facts checks every definition (`flow_problems` in the description it answers): every
  state that is not done has an owner and a way out to a next state, and every state can
  reach done. A definition with problems is not run.
  """

  @doc "The definitions that may run: `%{name => definition}`, without those Facts refused."
  def flows(description) do
    problems = description["flow_problems"] || %{}

    for {name, flow} <- description["flows"] || %{},
        is_map(flow),
        (problems[name] || []) == [],
        into: %{},
        do: {name, flow}
  end

  @doc "The definition that runs on `kind`, as `{name, definition}`, or nil."
  def for_kind(description, kind) do
    Enum.find(flows(description), fn {_name, flow} -> kind in (flow["kinds"] || []) end)
  end

  @doc "The kinds the definitions assign to: what their owner relations point at."
  def owner_kinds(description) do
    for {_name, %{"owner_relation" => relation}} <- flows(description),
        is_binary(relation),
        kind <- get_in(description, ["relations", relation, "to"]) || [],
        uniq: true,
        do: kind
  end

  @doc """
  The associations (not parent relations) that a definition's `empty` conditions name and
  that end at `kind`: Flow reads what points at a fact through them.
  """
  def pointing(description, flow, kind) do
    for state <- flow["states"] || [],
        is_map(state),
        {"empty", relation} <- state["when"] || %{},
        spec = get_in(description, ["relations", relation]),
        is_map(spec) and spec["parent"] != true and kind in (spec["to"] || []),
        uniq: true,
        do: relation
  end

  @doc "Every kind a definition runs on."
  def kinds(description),
    do: description |> flows() |> Enum.flat_map(fn {_, f} -> f["kinds"] || [] end) |> Enum.uniq()

  @doc """
  The state `fact` is in: `{state, vars}`, where `vars` fill its texts (`"note"`).
  `children` are the facts that point at it through a parent relation, as Facts answers
  them, with their `origins`; `parents` names those relations. `pointing` names the
  associations that end at its kind and that its flow reads (`empty`); the facts that
  point at it through them are among `children` too.
  """
  def state_of(flow, fact, children, parents, pointing \\ []) do
    own = own_vars(fact)

    Enum.find_value(flow["states"] || [], {nil, own}, fn state ->
      case holds(state["when"] || %{}, fact, children, {parents, pointing}) do
        nil -> nil
        vars -> {state, Map.merge(own, vars)}
      end
    end)
  end

  defp holds(conditions, fact, children, parents) do
    Enum.reduce_while(conditions, %{}, fn {name, value}, vars ->
      case condition(name, value, fact, children, parents) do
        nil -> {:halt, nil}
        more -> {:cont, Map.merge(vars, more)}
      end
    end)
  end

  defp condition("completed", true, fact, _, _), do: if(fact["completion"], do: %{})
  defp condition("completed", false, fact, _, _), do: if(!fact["completion"], do: %{})

  defp condition("progress", value, fact, _, _),
    do: if(get_in(fact, ["progress", "value"]) == value, do: %{})

  defp condition("reopened", relation, fact, children, {parents, _pointing}) do
    case get_in(fact, ["origins", relation]) do
      %{"keys" => [], "position" => at} = origin when is_integer(at) ->
        if at > newest_under(children, parents), do: %{"note" => origin["cause"] || ""}

      _ ->
        nil
    end
  end

  # Nothing points at the fact through `relation`: one by which facts belong under its kind
  # (one of `parents`), or an association that ends at its kind (one of `pointing`); for any
  # other relation, never.
  defp condition("empty", relation, _fact, children, {parents, pointing}) do
    if (relation in parents or relation in pointing) and
         not Enum.any?(children, &((get_in(&1, ["links", relation]) || []) != [])),
       do: %{}
  end

  defp condition("values", values, fact, _, _) when is_map(values) do
    if Enum.all?(values, fn {name, allowed} -> fact["values"][name] in List.wrap(allowed) end),
      do: %{}
  end

  defp condition(_name, _value, _fact, _children, _parents), do: nil

  # The position of the newest fact that came under this one (created or moved there).
  defp newest_under(children, parents) do
    children
    |> Enum.flat_map(fn child ->
      for relation <- parents,
          at = get_in(child, ["origins", relation, "position"]),
          is_integer(at),
          do: at
    end)
    |> Enum.max(fn -> 0 end)
  end

  # The fact's own values a state's text may name; a condition's vars (`note`) win.
  defp own_vars(fact) do
    for {name, value} <- fact["values"] || %{},
        is_binary(value) or is_number(value) or is_boolean(value),
        into: %{},
        do: {name, value}
  end

  @doc "What the owner is expected to do in `state`, with `vars` filled in; nil when done."
  def expected(%{"done" => true}, _vars), do: nil

  def expected(state, vars) do
    Enum.reduce(vars, state["expected"] || "", fn {name, value}, text ->
      String.replace(text, "{#{name}}", to_string(value))
    end)
    |> String.trim()
    |> String.trim_trailing(":")
  end

  @doc "The owner of `state`, the key of a fact (who is next in line), or nil when done."
  def owner(%{"done" => true}), do: nil
  def owner(%{"owner" => %{"key" => key}}), do: key
  def owner(%{"owner" => key}) when is_binary(key), do: key
  def owner(_state), do: nil

  @doc "The kind of the owner of `state`, or nil when it names none."
  def owner_kind(%{"owner" => %{"kind" => kind}}), do: kind
  def owner_kind(_state), do: nil

  @doc "How often a fact in `state` is looked at again, in ms; `default` when it says nothing."
  def every(state, default) do
    case state do
      %{"every_seconds" => s} when is_integer(s) and s > 0 -> s * 1000
      _ -> default
    end
  end
end
