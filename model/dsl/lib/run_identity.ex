defmodule RelaDSL.RunIdentity do
  @moduledoc """
  The identity of a subflow's runs, per environment: its digest (`digest/0` of design
  section 3, the `RelaDSL.DefinitionDigest` of what `flows.json` holds for it, with the
  environment's limits) and its states; the approved migrations between digests; and
  `digests.json`, the proof of both.

  A run keeps the digest it started with. When a subflow's digest changes, its runs
  move only along a declared `migrate subflow, from:, to:, states:`. The history of a
  subflow in an environment is every digest from which migrations lead to its current
  one, so it is derived from the model and never edited.

  Rules, on the model alone (`problems/2`):

    * a migration's `to` is a current digest of the subflow, or the `from` of another
      of its migrations (a chain that ends at a current one);
    * its `states` map states of `from` to states of `to` (`:same`: each state of `to`
      to itself); a digest's states are the same in every migration that names them;
    * `rekey: true` maps every state to itself.

  Against the `digests.json` of a base branch (`base_problems/3`), so a change cannot
  approve its own migration:

    1. no history entry of the base is removed or changed;
    2. a subflow whose digest differs from the base's current one has a migration from
       that digest to the compiled one;
    3. every migration's `from` is in the base's history of the subflow;
    4. its `states` keys are states the base recorded for `from`.
  """

  alias RelaDSL.{Atlas, DefinitionDigest, Limits}

  @doc "Per environment, each subflow's `%{digest:, states:}`, by name."
  def current(flows, gates, environments) do
    Map.new(environments, fn env ->
      definitions = Atlas.definitions(Limits.resolve(flows, gates, env), gates)

      {env,
       Map.new(definitions, fn {name, d} ->
         {String.to_atom(name),
          %{digest: DefinitionDigest.of(d), states: Enum.sort(Map.keys(d["states"]))}}
       end)}
    end)
  end

  @doc "Every digest the model knows the states of: the current ones, and each migration's `from`."
  def states(current, migrations) do
    known =
      for {_env, by_name} <- current,
          {_, %{digest: d, states: s}} <- by_name,
          into: %{},
          do: {d, s}

    Enum.reduce(1..(length(migrations) + 1), known, fn _, acc ->
      Enum.reduce(migrations, acc, fn m, acc ->
        from = m.opts[:from]

        case {Map.has_key?(acc, from), m.opts[:states], acc[m.opts[:to]]} do
          {true, _, _} ->
            acc

          {false, :same, nil} ->
            acc

          {false, :same, to_states} ->
            Map.put(acc, from, to_states)

          {false, map, _} when is_list(map) or is_map(map) ->
            Map.put(acc, from, map |> Enum.map(&to_string(elem(&1, 0))) |> Enum.sort())

          _ ->
            acc
        end
      end)
    end)
  end

  @doc "Problems of the migrations on the model alone: `[{migration, RelaDSL.Problem}]`."
  def problems(current, migrations) do
    states = states(current, migrations)

    Enum.flat_map(migrations, fn m ->
      name = m.subflow
      %{from: from, to: to} = Map.new(Keyword.take(m.opts, [:from, :to]))
      currents = for {_, by_name} <- current, %{digest: d} <- [by_name[name]], do: d
      chain = for n <- migrations, n.subflow == name, do: n.opts[:from]
      expanded = expand(m.opts[:states], to, states)
      pre = "migrate #{name} from #{short(from)}: "
      names = [to_string(name)]
      p = &RelaDSL.Problem.new(&1, names, pre <> &2)

      [
        not (hex?(from) and hex?(to)) && p.(:digests, "from: and to: are full SHA-256 digests"),
        currents == [] && p.(:not_run, "the composition runs no subflow #{name}"),
        (currents != [] and to not in currents and to not in chain) &&
          p.(
            :not_current,
            "to: #{short(to)} is no current digest of #{name}, nor the from of another of its migrations"
          ),
        not text?(m.opts[:reason]) && p.(:reason, "needs reason: why the runs may move"),
        expanded == :invalid &&
          p.(:states_shape, "states: is a map of from-states to to-states, or :same"),
        (expanded != :invalid and states[to] != nil and
           Enum.any?(expanded, fn {_, v} -> v not in states[to] end)) &&
          p.(:states_to, "states: maps to states that #{short(to)} does not have"),
        (expanded != :invalid and states[from] != nil and
           Enum.sort(Enum.map(expanded, &elem(&1, 0))) != states[from]) &&
          p.(:states_from, "states: maps other states than #{short(from)} has"),
        (m.opts[:rekey] == true and expanded != :invalid and
           Enum.any?(expanded, fn {k, v} -> k != v end)) &&
          p.(:rekey, "rekey: true keeps every state: map each to itself")
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&{m, &1})
    end)
  end

  defp expand(:same, to, states), do: for(s <- Map.get(states, to, []), do: {s, s})

  defp expand(map, _to, _states)
       when (is_list(map) and map != []) or (is_map(map) and map != %{}) do
    if Enum.all?(map, &match?({k, v} when is_atom(k) and is_atom(v), &1)),
      do: Enum.map(map, fn {k, v} -> {to_string(k), to_string(v)} end),
      else: :invalid
  end

  defp expand(_, _, _), do: :invalid

  @doc "The history of each subflow and environment: `[%{digest:, states:}]`, sorted by digest."
  def history(current, migrations) do
    states = states(current, migrations)

    for {env, by_name} <- current, {name, %{digest: d}} <- by_name, into: %{} do
      mine = for m <- migrations, m.subflow == name, do: {m.opts[:from], m.opts[:to]}
      reached = reach(MapSet.new([d]), mine)

      {{name, env},
       for(x <- Enum.sort(reached), do: %{digest: x, states: Map.get(states, x, [])})}
    end
  end

  defp reach(set, edges) do
    more =
      for {from, to} <- edges, MapSet.member?(set, to), not MapSet.member?(set, from), do: from

    if more == [], do: set, else: reach(MapSet.union(set, MapSet.new(more)), edges)
  end

  @doc "`digests.json` as a plain value (string keys)."
  def document(current, migrations) do
    history = history(current, migrations)

    subflows =
      for {env, by_name} <- current, {name, c} <- by_name, reduce: %{} do
        acc ->
          entry = %{
            "digest" => c.digest,
            "states" => Enum.map(c.states, &to_string/1),
            "history" =>
              for(h <- history[{name, env}], do: %{"digest" => h.digest, "states" => h.states})
          }

          Map.update(
            acc,
            to_string(name),
            %{to_string(env) => entry},
            &Map.put(&1, to_string(env), entry)
          )
      end

    %{"subflows" => subflows}
  end

  @doc """
  Problems against `base`, the base branch's `digests.json` (decoded), for the
  compiled `document` and the `migrations`: `[message]`.
  """
  def base_problems(base, document, migrations) do
    base_flows = base["subflows"] || %{}
    now = document["subflows"]

    removed =
      for {name, envs} <- base_flows,
          {env, entry} <- envs,
          h <- entry["history"] || [],
          h not in (get_in(now, [name, env, "history"]) || []),
          do: "#{name} (#{env}): history entry #{short(h["digest"])} was removed or changed"

    unapproved =
      for {name, envs} <- base_flows,
          {env, entry} <- envs,
          compiled = get_in(now, [name, env, "digest"]),
          compiled != nil and compiled != entry["digest"],
          not Enum.any?(migrations, fn m ->
            to_string(m.subflow) == name and m.opts[:from] == entry["digest"] and
              m.opts[:to] == compiled
          end),
          do:
            "#{name} (#{env}): its digest changed from #{short(entry["digest"])} to #{short(compiled)} " <>
              "without a migrate from: the base's digest, to: the compiled one"

    unknown =
      for m <- migrations,
          name = to_string(m.subflow),
          known = for({_, e} <- base_flows[name] || %{}, h <- e["history"] || [], do: h),
          (entry = Enum.find(known, &(&1["digest"] == m.opts[:from]))) == nil or
            not states_known?(m, entry),
          uniq: true do
        if entry == nil,
          do:
            "migrate #{name} from #{short(m.opts[:from])}: from is not in the base's history of #{name}",
          else:
            "migrate #{name} from #{short(m.opts[:from])}: states maps states the base did not record for it"
      end

    removed ++ unapproved ++ unknown
  end

  defp states_known?(%{opts: opts}, entry) do
    case opts[:states] do
      :same -> true
      map -> Enum.all?(map, fn {k, _} -> to_string(k) in (entry["states"] || []) end)
    end
  end

  defp hex?(d), do: is_binary(d) and Regex.match?(~r/\A[0-9a-f]{64}\z/, d)
  defp text?(t), do: is_binary(t) and String.trim(t) != ""
  defp short(d) when is_binary(d), do: String.slice(d, 0, 8) <> "…"
  defp short(d), do: inspect(d)
end
