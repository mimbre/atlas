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
                   delete_error decision_options)
  @listed %{action: "actions", counts: "counts", requires: "requires"}
  @select_keys [
    :choices,
    :roles,
    :projection,
    :admission,
    :imports,
    :verification,
    :reopen,
    :restart_by
  ]
  @migrate_keys [:from, :to, :states, :rekey, :preserve_entry, :reason]
  @flow_runtime_keys [:runs, :writer, :inputs, :supervision, :senders]
  @supervision_keys [:relation, :operation, :hand_to]
  @work_keys [:kind, :of, :for, :ended]
  @operations ["pickup", "hand_over", "retry"]
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
        case unknown(i, {"flow_runtime"}, opts, @flow_runtime_keys) do
          [] -> senders_problems(i, opts[:senders], items)
          problems -> problems
        end

      %{kind: :root, value: {:supervised_work, opts}} = i ->
        unknown(i, {"supervised_work"}, opts, @work_keys)

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
  defp fragment(%{kind: :root, value: {:supervised_work, _}}), do: []

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
                      :reopen,
                      :restart_by
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
               {"writer", writer(opts[:writer], opts[:senders])},
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
             ] ++ supervision(opts[:supervision], flows, work(items))}}
         ]}
    end
  end

  # The run writer, `{sender, by}`; with `senders:`, also the further endpoints of the same
  # writer per kind (`"senders"`, kind → [sender]), which only that kind's field guard
  # accepts (`RelaDSL.Facts.Writes.rules/2`). Without `senders:` it is exactly `writer:`.
  defp writer(writer, nil), do: Plain.ordered(writer)

  defp writer(writer, senders) do
    {:ordered, pairs} = Plain.ordered(writer)

    {:ordered,
     pairs ++
       [
         {"senders",
          {:ordered,
           for({kind, list} <- senders, do: {to_string(kind), Enum.map(list, &to_string/1)})}}
       ]}
  end

  # `senders:` is a keyword list of kinds the items declare, each with a list of senders
  # (atoms or strings), each kind once.
  defp senders_problems(_i, nil, _items), do: []

  defp senders_problems(i, senders, items) do
    kinds = for %{kind: :entity, value: e} <- items, into: MapSet.new(), do: e.name
    shape? = fn v -> is_list(v) and v != [] and Enum.all?(v, &(is_atom(&1) or is_binary(&1))) end

    cond do
      not Keyword.keyword?(senders) or not Enum.all?(senders, fn {_, v} -> shape?.(v) end) ->
        [
          {i.file, i.line,
           problem(
             :flow_runtime_senders,
             [],
             "flow_runtime senders: takes a keyword list of kinds, each with a list of senders"
           )}
        ]

      (twice = Keyword.keys(senders) -- Enum.uniq(Keyword.keys(senders))) != [] ->
        twice = Enum.uniq(twice)

        [
          {i.file, i.line,
           problem(
             :given_twice,
             ["flow_runtime", "senders" | Enum.map(twice, &to_string/1)],
             "flow_runtime senders: gives #{Enum.map_join(twice, ", ", &to_string/1)} twice"
           )}
        ]

      true ->
        for {kind, _} <- senders, not MapSet.member?(kinds, kind) do
          {i.file, i.line,
           problem(
             :not_a_kind,
             ["flow_runtime", "senders", to_string(kind)],
             "flow_runtime senders: #{kind} is no kind"
           )}
        end
    end
  end

  # Who supervises a run (work acquisition design 2026-11-17, §5.6), only when `flow_runtime` declares
  # it: the relation from a run to its human supervisor, which only the run's writer
  # sets; the fields of a pickup or hand-over input (`operation`, `hand_to`); and each
  # running subflow's supervised spans, as its `supervise` gives them; and, when
  # `supervised_work` gives it, what a supervisor's running work is (`work`). It sits
  # beside the subflows, never in one, so it changes no subflow's digest.
  defp supervision(nil, _flows, _work), do: []

  defp supervision(opts, flows, work) do
    spans =
      for f <- flows, f.spans != [] do
        {to_string(f.name),
         for span <- f.spans do
           {:ordered,
            [
              {"name", to_string(span.name)},
              {"label", span.label},
              {"states", Enum.map(span.states, &to_string/1)},
              {"with", Enum.map(span.with, &to_string/1)}
            ]
            |> Enum.reject(&(elem(&1, 1) == nil))}
         end}
      end

    [
      {"supervision",
       {:ordered,
        [
          {"version", 1},
          {"relation", Plain.of(opts[:relation])},
          {"inputs",
           {:ordered,
            [
              {"operation", Plain.of(opts[:operation])},
              {"operations", @operations},
              {"hand_to", Plain.of(opts[:hand_to])}
            ]}},
          {"spans", {:ordered, spans}}
        ] ++
          for(
            w <- [work],
            w != nil,
            do: {"work", {:ordered, for(k <- @work_keys, do: {to_string(k), Plain.of(w[k])})}}
          )}}
    ]
  end

  # The one `supervised_work` the contributions give, or nil.
  defp work(items) do
    Enum.find_value(items, fn
      %{kind: :root, value: {:supervised_work, opts}} -> opts
      _ -> nil
    end)
  end

  @doc """
  Problems of supervision (work acquisition design 2026-11-17, §5.6) on the composition: a subflow
  with a span needs `flow_runtime`'s `supervision:`; that names a relation from the
  runs to one supervisor, and the inputs' `operation` (whose values hold `pickup` and
  `hand_over`) and `hand_to` fields; a span's `with:` names a running subflow whose
  subject points at the span's subject. `[{file, line, RelaDSL.Problem}]`.
  """
  def supervision_problems(items, flows, schema) do
    declared =
      Enum.find_value(items, fn
        %{kind: :root, value: {:flow_runtime, opts}} = i -> {i, opts}
        _ -> nil
      end)

    spanned = for f <- flows, span <- f.spans, do: {f, span}

    supervised? =
      case declared do
        {_, opts} when is_list(opts) -> opts[:supervision] != nil
        _ -> false
      end

    # The start page's two supervision entries read the declared supervision.
    entries =
      for %{kind: :root, value: {:start_page, o}} = i <- items,
          Keyword.keyword?(o),
          entry <- [:open_for_you, :supervised_by_you],
          Keyword.has_key?(o, entry),
          not supervised? do
        {i.file, i.line,
         problem(
           :supervision_undeclared,
           [entry],
           "start_page #{entry}: no flow_runtime declares supervision: (the relation to a run's human supervisor)"
         )}
      end

    entries ++
      work_problems(items, flows, schema, declared, supervised?) ++
      case {declared, spanned} do
        {nil, []} ->
          []

        {nil, [{f, span} | _]} ->
          [
            {f.file, span.line,
             problem(
               :supervision_undeclared,
               [f.name, span.name],
               "subflow #{f.name}: supervise #{span.name}: no flow_runtime declares supervision: (the relation to a run's human supervisor)"
             )}
          ]

        {{i, opts}, _} ->
          with_problems(spanned, flows, schema) ++
            case opts[:supervision] do
              nil when spanned == [] ->
                []

              nil ->
                [{f, span} | _] = spanned

                [
                  {f.file, span.line,
                   problem(
                     :supervision_undeclared,
                     [f.name, span.name],
                     "subflow #{f.name}: supervise #{span.name}: flow_runtime declares no supervision: (the relation to a run's human supervisor)"
                   )}
                ]

              s ->
                for p <- supervision_shape(s, opts, schema), do: {i.file, i.line, p}
            end
      end
  end

  defp supervision_shape(s, opts, schema) do
    if Keyword.keyword?(s) do
      run = to_string(opts[:runs])
      inputs = to_string(opts[:inputs])
      relation = schema["relations"][Plain.of(s[:relation])]
      unknown = Keyword.keys(s) -- @supervision_keys
      at = "flow_runtime.supervision: "

      operation_type =
        get_in(schema, ["entities", inputs, "properties", Plain.of(s[:operation]), "type"])

      values = get_in(schema, ["types", operation_type || "", "values"]) || []

      values =
        Enum.map(values, fn
          %{"value" => v} -> v
          v -> v
        end)

      [
        unknown != [] &&
          problem(
            :supervision_keys,
            Enum.map(unknown, &to_string/1),
            at <> "unknown keys #{Enum.map_join(unknown, ", ", &to_string/1)}"
          ),
        (relation == nil or run not in (relation["from"] || []) or
           relation["max_outgoing"] != 1) &&
          problem(
            :supervision_relation,
            [Plain.of(s[:relation])],
            at <>
              "relation #{Plain.of(s[:relation])} must lead from #{run} to one supervisor (max_outgoing 1)"
          ),
        Enum.any?(@operations, &(&1 not in values)) &&
          problem(
            :supervision_operation,
            [inputs, Plain.of(s[:operation])],
            at <>
              "#{inputs}.#{Plain.of(s[:operation])} must be a field whose type has the values #{Enum.join(@operations, ", ")}"
          ),
        get_in(schema, ["entities", inputs, "properties", Plain.of(s[:hand_to])]) == nil &&
          problem(
            :supervision_hand_to,
            [inputs, Plain.of(s[:hand_to])],
            at <> "#{inputs}.#{Plain.of(s[:hand_to])} must be a field (the person handed to)"
          )
      ]
      |> Enum.filter(& &1)
    else
      [
        problem(
          :supervision_keys,
          [],
          "flow_runtime.supervision: takes relation:, operation: and hand_to:"
        )
      ]
    end
  end

  # What a supervisor's running work is (`supervised_work`), given once and only with
  # supervision: `kind` is a kind; `of` leads from it to each span's subject or to one of
  # its `with:` subjects (the work the span's runs make); `for` leads from it to the
  # supervisor's kind; `ended` is a field of it (empty while the work runs).
  defp work_problems(items, flows, schema, declared, supervised?) do
    given = for %{kind: :root, value: {:supervised_work, opts}} = i <- items, do: {i, opts}

    case given do
      [] ->
        []

      [{i, _} | _] when not supervised? ->
        [
          {i.file, i.line,
           problem(
             :supervision_undeclared,
             ["supervised_work"],
             "supervised_work: no flow_runtime declares supervision: (the relation to a run's human supervisor)"
           )}
        ]

      [_, {i, _} | _] ->
        [
          {i.file, i.line,
           problem(:given_twice, ["supervised_work"], "supervised_work is given more than once")}
        ]

      [{i, opts}] ->
        if Keyword.keyword?(opts) and Enum.all?(@work_keys, &is_atom(opts[&1])) and
             Enum.all?(@work_keys, &(opts[&1] != nil)) do
          {_, runtime} = declared
          for p <- work_shape(opts, runtime[:supervision], flows, schema), do: {i.file, i.line, p}
        else
          [
            {i.file, i.line,
             problem(:supervision_work, [], "supervised_work: takes kind:, of:, for: and ended:")}
          ]
        end
    end
  end

  defp work_shape(w, supervision, flows, schema) do
    [kind, of, for_, ended] = Enum.map(@work_keys, &to_string(w[&1]))
    relations = schema["relations"] || %{}
    subjects = Map.new(flows, &{&1.name, to_string(&1.subject)})

    supervisor =
      Keyword.keyword?(supervision) &&
        get_in(relations, [to_string(supervision[:relation]), "to"])

    from? = fn r -> r != nil and kind in (r["from"] || []) end
    at = "supervised_work: "

    spans_off =
      for f <- flows,
          span <- f.spans,
          parts = [to_string(f.subject) | Enum.map(span.with, &subjects[&1])],
          not Enum.any?(parts, &(&1 in (get_in(relations, [of, "to"]) || []))),
          do: span.name

    if get_in(schema, ["entities", kind]) == nil do
      # The other three names are read on the kind, so a kind that is none is the one reason.
      [problem(:supervision_work_kind, [kind], at <> "kind #{kind} is no kind")]
    else
      [
        (not from?.(relations[of]) or spans_off != []) &&
          problem(
            :supervision_work_of,
            [of, kind],
            at <>
              "of #{of} must lead from #{kind} to each span's subject or one of its with: subjects"
          ),
        (not from?.(relations[for_]) or not is_list(supervisor) or
           supervisor -- (relations[for_]["to"] || []) != []) &&
          problem(
            :supervision_work_for,
            [for_, kind],
            at <> "for #{for_} must lead from #{kind} to the supervisor's kind"
          ),
        get_in(schema, ["entities", kind, "properties", ended]) == nil &&
          problem(
            :supervision_work_ended,
            [kind, ended],
            at <> "#{kind}.#{ended} must be a field"
          )
      ]
      |> Enum.filter(& &1)
    end
  end

  # A span's `with:` names a subflow the composition runs whose subject points at the
  # span's subject (a part is under the thing it is part of), so its runs belong to the span.
  defp with_problems(spanned, flows, schema) do
    subjects = Map.new(flows, &{&1.name, to_string(&1.subject)})

    for {f, span} <- spanned, other <- span.with, is_atom(other) do
      subject = to_string(f.subject)

      under? =
        Enum.any?(schema["relations"] || %{}, fn {_, r} ->
          subjects[other] in (r["from"] || []) and subject in (r["to"] || [])
        end)

      cond do
        not Map.has_key?(subjects, other) ->
          {f.file, span.line,
           problem(
             :supervision_with,
             [f.name, span.name, other],
             "subflow #{f.name}: supervise #{span.name}: with: #{other} is no subflow the composition runs"
           )}

        not under? ->
          {f.file, span.line,
           problem(
             :supervision_with,
             [f.name, span.name, other],
             "subflow #{f.name}: supervise #{span.name}: with: #{other} runs on #{subjects[other]}, which points at no #{subject}"
           )}

        true ->
          nil
      end
    end
    |> Enum.filter(& &1)
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
