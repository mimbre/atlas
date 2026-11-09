defmodule RelaDSL.Description.Build do
  @moduledoc """
  Builds a composition's description from what its modules, their concepts and the
  composition itself declare: the Rela schema of each file, Atlas's additions merged
  leaf by leaf (one author per leaf), the run mapping, and the roles. Problems are
  `{file, line, problem}`, each a `RelaDSL.Problem`; the composition refuses to compile
  on any.
  """

  alias RelaDSL.Description.Plain
  alias RelaDSL.Problem

  @type_keys [:values, :labels, :descriptions, :description, :validations]
  @entity_keys [:label, :plural, :aliases, :id_type, :id_prefix, :description]
  @field_keys [:required, :unique, :default, :description]
  @field_notes [:set_by, :multiline, :label, :cause]
  @relation_keys [:label, :description, :from, :to, :max_outgoing, :inverse]
  @relation_notes [
    :parent,
    :add,
    :component,
    :set_by,
    :limit,
    :actions,
    :only_target,
    :requires_completed_children,
    :closes_parent,
    :review
  ]
  @entity_notes ~w(top primary plural_label start create properties completion progress connector agent order
                   by_hand late actions counts requires authority frozen replaces layering sealed
                   delete_error)
  @listed %{action: "actions", counts: "counts", requires: "requires"}
  @select_keys [
    :choices,
    :roles,
    :projection,
    :admission,
    :imports,
    :verification,
    :reopen
  ]
  @migrate_keys [:from, :to, :states, :rekey, :preserve_entry, :reason]
  @flow_runtime_keys [:runs, :writer, :inputs]
  @writer "atlas-flow"

  @doc "Every contribution, in order: `[{origin, kind, value}]` of each module's concepts, the module, then the composition."
  def contributions(modules, composition_items) do
    Enum.flat_map(modules, fn m ->
      Enum.flat_map(m.concepts, & &1.items) ++ m.items
    end) ++ composition_items
  end

  @doc "The schema document of a list of items: `types`, `entities`, `relations` (YAML-ordered)."
  def schema_doc(items) do
    types = for %{kind: :type} = i <- items, do: type_doc(i)
    entities = for %{kind: :entity} = i <- items, do: entity_doc(i)
    relations = for %{kind: :relation} = i <- items, do: relation_doc(i)

    {:ordered,
     for(
       {key, list} <- [{"types", types}, {"entities", entities}, {"relations", relations}],
       list != [],
       do: {key, {:ordered, list}}
     )}
  end

  defp type_doc(%{value: {name, opts}}) do
    {to_string(name), ordered(opts, @type_keys)}
  end

  defp entity_doc(%{value: e}) do
    props =
      for f <- e.fields do
        {to_string(f.name),
         {:ordered, [{"type", Plain.of(f.type)} | elem(ordered(f.opts, @field_keys), 1)]}}
      end

    {:ordered, head} = ordered(e.opts, @entity_keys)

    {to_string(e.name),
     {:ordered, head ++ if(props == [], do: [], else: [{"properties", {:ordered, props}}])}}
  end

  defp relation_doc(%{value: {name, opts}}) do
    {:ordered, pairs} = ordered(Keyword.delete(opts, :inverse), @relation_keys)

    inverse =
      case opts[:inverse] do
        {id, label} ->
          [{"inverse", {:ordered, [{"id", Plain.of(id)}, {"label", Plain.of(label)}]}}]

        nil ->
          []
      end

    {to_string(name), {:ordered, pairs ++ inverse}}
  end

  # The keys of `keys` that `opts` gives, in the order of `keys`.
  defp ordered(opts, keys) do
    {:ordered,
     for(k <- keys, Keyword.has_key?(opts, k), do: {to_string(k), Plain.ordered(opts[k])})}
  end

  @doc "Shape problems of the schema items: keys that no construct holds."
  def shape_problems(items) do
    Enum.flat_map(items, fn
      %{kind: :type, value: {name, opts}} = i ->
        unknown(i, {"type", name}, opts, @type_keys ++ [:format])

      %{kind: :entity, value: e} = i ->
        unknown(i, {"entity", e.name}, e.opts, @entity_keys) ++
          Enum.flat_map(e.fields, fn f ->
            unknown(
              %{i | line: f.line},
              {"field", e.name, f.name},
              f.opts,
              @field_keys ++ @field_notes
            ) ++
              if is_atom(f.type) and f.type != nil,
                do: [],
                else: [
                  {i.file, f.line,
                   problem(
                     :field_type,
                     [e.name, f.name],
                     "field #{e.name}.#{f.name} needs a type"
                   )}
                ]
          end) ++ note_problems(i, e)

      %{kind: :relation, value: {name, opts}} = i ->
        unknown(i, {"relation", name}, opts, @relation_keys ++ @relation_notes) ++
          case opts[:inverse] do
            {_, _} ->
              []

            nil ->
              []

            _ ->
              [
                {i.file, i.line,
                 problem(:relation_inverse, [name], "relation #{name}: inverse is {id, label}")}
              ]
          end

      %{kind: :select, value: {name, opts}} = i ->
        unknown(i, {"select", name}, opts, @select_keys)

      %{kind: :migrate, value: {name, opts}} = i ->
        unknown(i, {"migrate", name}, opts, @migrate_keys)

      %{kind: :root, value: {:flow_runtime, opts}} = i ->
        unknown(i, {"flow_runtime"}, opts, @flow_runtime_keys)

      %{kind: :extend_entity, value: {name, rules}} = i ->
        unknown(i, {"extend_entity", name}, rules, Enum.map(@entity_notes, &String.to_atom/1))

      %{kind: :extend_relation, value: {name, rules}} = i ->
        unknown(i, {"extend_relation", name}, rules, @relation_notes)

      _ ->
        []
    end)
  end

  defp note_problems(i, e) do
    notes = for {k, _, _} <- e.notes, k not in [:flag | Map.keys(@listed)], do: k

    for k <- Enum.uniq(notes -- Enum.uniq(notes)) do
      {i.file, i.line,
       problem(:given_twice, [e.name, k], "entity #{e.name}: #{k} is given more than once")}
    end ++
      case for({:flag, _, l} <- e.notes, do: l) do
        [_, l | _] ->
          [{i.file, l, problem(:flag_twice, [e.name], "entity #{e.name}: one flag per kind")}]

        _ ->
          []
      end
  end

  # What `opts` gives that its construct (`{construct, name, ...}`) holds no key for, or
  # gives twice; the names are the construct's, then the keys.
  defp unknown(i, construct, opts, keys) do
    [what | names] = Tuple.to_list(construct)

    what =
      Enum.join([what | Enum.take(names, 1)], " ") <>
        Enum.map_join(Enum.drop(names, 1), &".#{&1}")

    cond do
      not Keyword.keyword?(opts) ->
        [{i.file, i.line, problem(:expected_keywords, names, "#{what} takes a keyword list")}]

      (extra = Keyword.keys(opts) -- keys) != [] ->
        [
          {i.file, i.line,
           problem(
             :unknown_keys,
             names ++ extra,
             "#{what} knows no #{Enum.map_join(extra, ", ", &to_string/1)}"
           )}
        ]

      (twice = Keyword.keys(opts) -- Enum.uniq(Keyword.keys(opts))) != [] ->
        twice = Enum.uniq(twice)

        [
          {i.file, i.line,
           problem(
             :given_twice,
             names ++ twice,
             "#{what} gives #{Enum.map_join(twice, ", ", &to_string/1)} twice"
           )}
        ]

      true ->
        []
    end
  end

  defp problem(tag, names, text), do: Problem.new(tag, Enum.map(names, &to_string/1), text)

  # -- Atlas's additions (atlas.json) --------------------------------------------------

  @doc """
  The fragments each contribution adds to `atlas.json`: `[{fragment, origin}]` with
  `origin` `{file, line}`.
  """
  def fragments(items) do
    Enum.flat_map(items, fn i -> for f <- fragment(i), f != %{}, do: {f, {i.file, i.line}} end)
  end

  defp fragment(%{kind: :type, value: {name, opts}}) do
    if opts[:format],
      do: [%{"types" => %{to_string(name) => %{"format" => Plain.of(opts[:format])}}}],
      else: []
  end

  defp fragment(%{kind: :entity, value: e}) do
    props =
      for f <- e.fields,
          notes = Keyword.take(f.opts, @field_notes),
          notes != [],
          into: %{},
          do: {to_string(f.name), Plain.of(notes)}

    single =
      for {k, v, _} <- e.notes,
          k not in [:flag | Map.keys(@listed)],
          into: %{},
          do: {to_string(k), Plain.of(v)}

    listed =
      for {k, json} <- @listed,
          values = for({^k, v, _} <- e.notes, do: Plain.of(v)),
          values != [],
          into: %{},
          do: {json, values}

    rules =
      single
      |> Map.merge(listed)
      |> then(&if(props == %{}, do: &1, else: Map.put(&1, "properties", props)))

    if rules == %{}, do: [], else: [%{"entities" => %{to_string(e.name) => rules}}]
  end

  defp fragment(%{kind: :relation, value: {name, opts}}) do
    case Keyword.take(opts, @relation_notes) do
      [] -> []
      notes -> [%{"relations" => %{to_string(name) => Plain.of(notes)}}]
    end
  end

  defp fragment(%{kind: :root, value: {:flow_runtime, _}}), do: []

  defp fragment(%{kind: :root, value: {construct, value}}),
    do: [%{RelaDSL.Description.root_key(construct) => Plain.of(value)}]

  defp fragment(%{kind: :extend_entity, value: {name, rules}}),
    do: [%{"entities" => %{to_string(name) => Plain.of(rules)}}]

  defp fragment(%{kind: :extend_relation, value: {name, rules}}),
    do: [%{"relations" => %{to_string(name) => Plain.of(rules)}}]

  defp fragment(_), do: []

  @doc """
  The fragments merged, leaf by leaf: `{extension, origins, problems}`. A leaf given by
  two contributions is refused, even when both say the same; maps merge only when both
  are non-empty. `origins` maps each written path to the `{file, line}` that wrote it.
  """
  def merge(fragments) do
    Enum.reduce(fragments, {%{}, %{}, []}, fn {fragment, origin}, {acc, origins, problems} ->
      combine(acc, fragment, [], origin, origins, problems)
    end)
  end

  defp combine(left, right, path, origin, origins, problems) do
    Enum.reduce(right, {left, origins, problems}, fn {key, value}, {l, o, p} ->
      at = path ++ [key]

      cond do
        not Map.has_key?(l, key) ->
          {Map.put(l, key, value), Map.put(o, at, origin), p}

        is_map(l[key]) and is_map(value) and l[key] != %{} and value != %{} ->
          {merged, o, p} = combine(l[key], value, at, origin, o, p)
          {Map.put(l, key, merged), Map.put_new(o, at, origin), p}

        true ->
          {file, line} = origin
          {other_file, other_line} = Map.get(o, at, origin)

          {l, o,
           p ++
             [
               {file, line,
                problem(
                  :leaf_twice,
                  at,
                  "#{Enum.join(at, ".")} is given twice (also at #{Path.relative_to_cwd(other_file)}:#{other_line}); " <>
                    "each leaf has one author"
                )}
             ]}
      end
    end)
  end

  @doc "The origin of `path`: of the longest written prefix of it."
  def origin(origins, path, default) do
    Enum.find_value(length(path)..1//-1, default, fn n -> Map.get(origins, Enum.take(path, n)) end)
  end

  # -- The run mapping (flow-runtime.json) ----------------------------------------------

  @doc """
  The run mapping, as `{:ordered, …}`, or nil when no contribution declares
  `flow_runtime`. `flows` are the subflows the composition runs, `states` maps each
  digest to its states (`RelaDSL.RunIdentity`), `acl` the roles.
  """
  def flow_runtime(items, flows, states, roles) do
    case for(%{kind: :root, value: {:flow_runtime, opts}} <- items, do: opts) do
      [] ->
        nil

      [opts | _] ->
        run = to_string(opts[:runs])
        inputs = to_string(opts[:inputs])
        running = MapSet.new(flows, & &1.name)
        selects = for %{kind: :select, value: {name, o}} <- items, name in running, do: {name, o}

        migrations =
          for %{kind: :migrate, value: {name, o}} <- items, name in running, do: {name, o}

        flags =
          for %{kind: :entity, value: e} <- items, {:flag, {field, o}, _} <- e.notes do
            {to_string(e.name),
             {:ordered, [{"field", Plain.of(field)} | elem(Plain.ordered(o), 1)]}}
          end

        reviews =
          for name <- Enum.uniq(for %{kind: :review, value: {r, _}} <- items, do: to_string(r)) do
            {name,
             for(
               %{kind: :review, value: {r, o}} <- items,
               to_string(r) == name,
               do: Plain.ordered(o)
             )}
          end

        input_roles =
          for {_, o} <- selects,
              {role, rel} <- Keyword.get(o, :roles, []),
              do: {to_string(role), Plain.of(rel)}

        acl =
          for {role, _} <- input_roles,
              do: {role, {:ordered, [{"update", Plain.of(get_in(roles, [role, :update]) || [])}]}}

        selection =
          for {name, o} <- selects do
            flow = Enum.find(flows, &(&1.name == name))
            mine = for {^name, m} <- migrations, do: migration(m, states)

            pairs =
              [
                {"choices", Plain.of(o[:choices])},
                {"choice_states", Enum.map(choice_states(flow, o[:choices] || []), &to_string/1)},
                {"migrations", mine},
                {"subject", to_string(flow.subject)}
              ] ++
                for k <- [
                      :projection,
                      :admission,
                      :imports,
                      :verification,
                      :reopen
                    ],
                    Keyword.has_key?(o, k),
                    do: {to_string(k), Plain.ordered(o[k])}

            {to_string(name), {:ordered, pairs}}
          end

        {:ordered,
         [
           {"flow_runtime",
            {:ordered,
             [
               {"version", 1},
               {"flags", {:ordered, flags}},
               {"reviews", {:ordered, reviews}},
               {"kind", run},
               {"writer", Plain.ordered(opts[:writer])},
               {"fields", identity(items, run)},
               {"selection", {:ordered, selection}},
               {"inputs",
                {:ordered,
                 [
                   {"kind", inputs},
                   {"fields", identity(items, inputs)},
                   {"acl", {:ordered, acl}},
                   {"roles", {:ordered, input_roles}}
                 ]}}
             ]}}
         ]}
    end
  end

  defp identity(items, kind) do
    fields =
      Enum.find_value(items, [], fn
        %{kind: :entity, value: %{name: name, fields: fields}} ->
          to_string(name) == kind && fields

        _ ->
          nil
      end)

    {:ordered, for(f <- fields, name = to_string(f.name), do: {name, name})}
  end

  # The states whose people choose one of `choices`: a branch of a role other than the
  # writer, on one of those fields.
  @doc false
  def choice_states(flow, choices) do
    for s <- flow.states,
        Enum.any?(s.branches, fn b ->
          b.roles != [@writer] and b.roles != [] and
            Enum.any?(choices, &String.starts_with?(b.when || "", "entity.#{&1} =="))
        end),
        do: s.name
  end

  defp migration(opts, states) do
    {:ordered,
     for {k, v} <- opts do
       case k do
         :states -> {"states", {:ordered, expand_states(v, opts[:to], states)}}
         _ -> {to_string(k), Plain.of(v)}
       end
     end}
  end

  @doc "A migration's `states:`, as sorted `[{from_state, to_state}]` strings; `:same` maps each state of `to` to itself."
  def expand_states(:same, to, states),
    do: for(s <- Enum.sort(Map.get(states, to, [])), do: {s, s})

  def expand_states(map, _to, _states) when is_list(map) or is_map(map),
    do: map |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end) |> Enum.sort()

  def expand_states(_, _, _), do: []
end
