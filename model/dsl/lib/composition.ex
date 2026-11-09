defmodule RelaDSL.Composition do
  @moduledoc """
  The root of a model: which modules it selects, how they are bound together, and
  the subflows it runs. One composition is one Rela project.

      defmodule MyModel.Office do
        use RelaDSL.Composition, name: "office"

        schema version: "1.0", namespace: "https://example.org/office#",
          description: "The post room.\\n", comment: "The office composition."
        modules [MyModel.Post]
        environments [:prod, :test]
        bindings comment: "What the office binds together."

        relation :handled_by, label: "handled by", from: [:letter], to: [:clerk], max_outgoing: 1,
          inverse: {:handled, "handled"}

        acl comment: "The roles the flows name."
        role "post-flow", read: ["*"], update: [:letter]
        assign "system:post", "post-flow"

        defcomposition :office do
          subflows [MyModel.Letter]
        end
      end

  `schema` writes the root `schema.yaml`, which includes each module's file and then
  `compositions/<name>/bindings.yaml`, the relations written here. `acl`, `role` and
  `assign` write `acl.yaml`. `defcomposition` is `RelaDSL.Schema.Composition`'s.
  `environments` names the environments whose limits give the subflows their digests
  (default `[:prod]`).

  ## Checks

  When the composition compiles, the whole model is checked; a mistake fails the
  compile with the file and line that wrote it:

    * every key is one a construct holds, and each leaf of `atlas.json` has one author;
    * every kind, type and relation is defined once;
    * every name a rule gives resolves (`RelaDSL.Description.Check`), and so does
      every name a subflow, a link or count, a `select` or a role names
      (`RelaDSL.Description.Subflows`);
    * every module a subflow comes from is a concept of a selected module, and a
      subflow's gates are among the concepts' gates;
    * the migrations follow `RelaDSL.RunIdentity`'s rules on the model;
    * root keys of Rela's schema that Atlas does not use (`worlds`, `copies`,
      `default_world`, root `validations`) are refused: no construct writes them.

  ## What it compiles

  The composition is the model a runner is wired to: it compiles each subflow it runs,
  per environment (`RelaDSL.Flow.Subflow`), and each legacy flow (`RelaDSL.Flow.Legacy`),
  and gets their callbacks (`RelaDSL.Flow.Model`). `use RelaDSL.Composition` takes
  `subflow_behaviour:` and `legacy_behaviour:`, the behaviours those modules declare.
  It gets the callbacks of the component that runs turns as well (`RelaDSL.Runtime.Model`:
  the turn, the agent, the guidance records and what a worker reads first), and those of
  the component that serves pages (`RelaDSL.Control.Model`: the shell, the start page,
  the kinds, forms, keys, actions, what an owner is to do and their answers), and those
  of the store (`RelaDSL.Facts.Model`: the schema rela must serve, the write rules,
  what a write brings along, what is worked out on a read, and the connectors).

  ## Introspection

  `__rela__(:description)` is everything the targets are written from: the schema
  documents, `atlas.json`, the run mapping, the roles and `digests.json`.
  `__rela__({:entity, kind})` and `__rela__({:relation, name})` give one kind's or
  relation's part of the schema and of `atlas.json`; `__rela__(:gates)` every gate;
  `__rela__(:digests)` each subflow's digest and states per environment;
  `__rela__(:migrations)` the declared migrations.
  """

  alias RelaDSL.Description.{Build, Check, Plain, Subflows}
  alias RelaDSL.RunIdentity

  @unused [:worlds, :copies, :default_world, :validations]
  @schema_keys [:version, :namespace, :description, :comment]

  defmacro __using__(opts) do
    quote do
      use RelaDSL.Schema.Composition

      import RelaDSL.Description,
        only: unquote(RelaDSL.Description.__macros__(:root) ++ [relation: 2])

      RelaDSL.Description.__init__(__MODULE__)

      import RelaDSL.Composition,
        only: [schema: 1, modules: 1, bindings: 1, environments: 1, acl: 1, role: 2, assign: 2]

      @rela_composition unquote(opts)
      @before_compile RelaDSL.Composition
    end
  end

  @doc "The root `schema.yaml`: `version:`, `namespace:`, `description:`, and its first line's `comment:`."
  defmacro schema(opts), do: item(:schema, opts)

  @doc "The modules the composition selects, in include order."
  defmacro modules(list), do: item(:modules, list)

  @doc "The bindings file: its first line's `comment:`."
  defmacro bindings(opts), do: item(:bindings, opts)

  @doc "The environments whose limits give the subflows their digests."
  defmacro environments(list), do: item(:environments, list)

  @doc "`acl.yaml`: its `comment:` lines."
  defmacro acl(opts), do: item(:acl, opts)

  @doc "A role Rela checks flows against: `comment:`, `read:`, `create:`, `update:` kinds."
  defmacro role(name, opts), do: item(:role, {name, opts})

  @doc "The role a principal (`run_as`) is assigned."
  defmacro assign(principal, role), do: item(:assign, {principal, role})

  defp item(kind, value) do
    quote do
      RelaDSL.Description.__item__(
        __MODULE__,
        unquote(kind),
        unquote(value),
        __ENV__.file,
        __ENV__.line
      )
    end
  end

  # -- Building ------------------------------------------------------------------------

  @doc false
  defmacro __before_compile__(env) do
    file = env.file
    opts = Module.get_attribute(env.module, :rela_composition)
    items = RelaDSL.Description.items(env.module)
    name = opts[:name]

    unless is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, name),
      do:
        raise(CompileError,
          file: file,
          line: 1,
          description: "use RelaDSL.Composition needs name: a lower-case name"
        )

    once = fn kind, default ->
      case for(%{kind: ^kind} = i <- items, do: i) do
        [] ->
          {default, nil}

        [i] ->
          {i.value, i}

        [_, i | _] ->
          raise CompileError,
            file: file,
            line: i.line,
            description: "#{kind} is given more than once"
      end
    end

    {schema_opts, schema_item} = once.(:schema, nil)
    {module_list, modules_item} = once.(:modules, [])
    {bindings_opts, _} = once.(:bindings, [])
    {environments, _} = once.(:environments, [:prod])
    {acl_opts, _} = once.(:acl, nil)

    if schema_opts == nil,
      do:
        raise(CompileError,
          file: file,
          line: 1,
          description: "a composition needs schema: its root schema.yaml"
        )

    refuse!(schema_problems(schema_opts, schema_item), file)

    modules = Enum.map(module_list, &load!(&1, :module, file, modules_item.line))

    modules =
      for m <- modules,
          do: %{m | concepts: Enum.map(m.concepts, &load!(&1, :concept, m.file, 1))}

    own =
      for i <- items,
          i.kind not in [:schema, :modules, :bindings, :environments, :acl, :role, :assign],
          do: i

    all = Build.contributions(modules, own)
    concept_items = Enum.flat_map(modules, fn m -> Enum.flat_map(m.concepts, & &1.items) end)
    placed = placement(modules, own)

    # The schema documents: each module's file, then the bindings.
    bindings_path = "compositions/#{name}/bindings.yaml"

    files =
      for(
        m <- modules,
        do: %{
          path: m.path,
          comment: nil,
          doc: Build.schema_doc(Enum.flat_map(m.concepts, & &1.items))
        }
      ) ++
        [%{path: bindings_path, comment: bindings_opts[:comment], doc: Build.schema_doc(own)}]

    {schema, defined} = resolve(files)

    ends =
      for {name, spec} <- schema["relations"],
          kind <- (spec["from"] || []) ++ (spec["to"] || []),
          not Map.has_key?(schema["entities"], kind),
          uniq: true,
          do:
            {origin_of(all, :relation, name, file),
             "relation #{name} leads from or to #{kind}, which is not a kind of the composition"}

    root = %{
      path: "schema.yaml",
      comment: schema_opts[:comment],
      doc:
        {:ordered,
         for(
           k <- [:version, :namespace, :description],
           Keyword.has_key?(schema_opts, k),
           do: {to_string(k), schema_opts[k]}
         ) ++
           [{"includes", Enum.map(files, & &1.path)}]}
    }

    {extension, origins, merged} = Build.merge(Build.fragments(all))

    checked =
      for {path, message} <- Check.check(schema, extension) do
        {f, l} = Build.origin(origins, path, {file, 1})
        {f, l, message}
      end

    # Subflows, gates and their names.
    raw = Module.get_attribute(env.module, :afg_composition)
    {flow_modules, flows_line} = (raw && raw.subflows) || {[], 1}
    flows = Enum.flat_map(flow_modules, &flows!(&1, file, flows_line))
    concept_modules = for m <- modules, c <- m.concepts, do: c.module

    gates =
      for c <- concept_modules,
          function_exported?(c, :__gates__, 0),
          g <- c.__gates__(),
          do: g

    strays =
      for m <- flow_modules,
          m not in concept_modules,
          do:
            {file, flows_line,
             "#{inspect(m)} runs subflows but is no concept of a selected module"}

    acl = acl(acl_opts, items)

    subflow_problems =
      Subflows.check(
        flows,
        %{file: file, links: (raw && raw.links) || [], counts: (raw && raw.counts) || []},
        schema,
        acl
      )

    selects = for %{kind: :select} = i <- all, do: i

    running = Enum.map(flows, & &1.name)

    migrations =
      for %{kind: :migrate, value: {s, o}} = i <- all,
          s in running,
          do: %{subflow: s, opts: o, file: i.file, line: i.line}

    current = RunIdentity.current(flows, gates, environments)
    states = RunIdentity.states(current, migrations)

    run_problems =
      for {m, message} <- RunIdentity.problems(current, migrations), do: {m.file, m.line, message}

    select_problems = Subflows.selects(selects, flows, schema, extension)
    acl_problems = acl_problems(acl, schema, items)

    refuse!(
      Build.shape_problems(all) ++
        placed ++
        defined ++
        Enum.map(ends, fn {{f, l}, m} -> {f, l, m} end) ++
        merged ++
        checked ++ strays ++ subflow_problems ++ select_problems ++ run_problems ++ acl_problems,
      file
    )

    flow_runtime =
      Build.flow_runtime(concept_items ++ own, flows, states, (acl && acl.roles) || %{})

    description = %{
      name: name,
      file: file,
      root: root,
      files: files,
      schema: schema,
      extension: extension,
      flow_runtime: flow_runtime,
      acl: acl,
      environments: environments,
      digests: RunIdentity.document(current, migrations),
      sources:
        Enum.uniq([
          file | Enum.flat_map(modules, &[&1.file | Enum.map(&1.concepts, fn c -> c.file end)])
        ])
    }

    migrations = Enum.map(migrations, &Map.take(&1, [:subflow, :opts]))

    compiled =
      RelaDSL.Flow.Model.body(
        env.module,
        opts,
        flows,
        gates,
        environments,
        schema,
        extension,
        flow_runtime
      )

    runtime = RelaDSL.Runtime.Model.body(schema, extension)

    facts =
      RelaDSL.Facts.Model.body(schema, extension, flow_runtime && Plain.unorder(flow_runtime))

    control =
      RelaDSL.Control.Model.body(
        schema,
        extension,
        flow_runtime && Plain.unorder(flow_runtime),
        presentations!(flows, gates, environments, file)
      )

    quote do
      unquote(compiled)
      unquote(runtime)
      unquote(control)
      unquote(facts)

      @doc "The model, as plain data (see `RelaDSL.Composition`)."
      def __rela__(:description), do: unquote(Macro.escape(description))
      def __rela__(:gates), do: unquote(Macro.escape(gates))
      def __rela__(:digests), do: unquote(Macro.escape(current))
      def __rela__(:migrations), do: unquote(Macro.escape(migrations))

      def __rela__({:entity, kind}),
        do: RelaDSL.Composition.part(__rela__(:description), "entities", to_string(kind))

      def __rela__({:relation, name}),
        do: RelaDSL.Composition.part(__rela__(:description), "relations", to_string(name))
    end
  end

  # What each subflow's states show their owner, by subflow; the same in every
  # environment (limits change timers, never what a state shows), so pages need no
  # environment.
  defp presentations!(flows, gates, environments, file) do
    [first | rest] =
      for env <- environments do
        for {name, definition} <- RelaDSL.Flow.Subflow.definitions(flows, gates, env),
            into: %{},
            do:
              {name,
               %{
                 "states" =>
                   Map.new(definition["states"] || %{}, fn {state, s} ->
                     {state, Map.take(s, ["present"])}
                   end)
               }}
      end

    if Enum.any?(rest, &(&1 != first)),
      do:
        raise(CompileError,
          file: file,
          line: 1,
          description: "a subflow presents its states differently per environment"
        )

    first
  end

  defp origin_of(items, kind, name, file) do
    Enum.find_value(items, {file, 1}, fn
      %{kind: ^kind, value: {n, _}} = i -> to_string(n) == name && {i.file, i.line}
      _ -> nil
    end)
  end

  @doc false
  def part(description, section, name) do
    case description.schema[section][name] do
      nil -> nil
      schema -> %{schema: schema, extension: description.extension[section][name]}
    end
  end

  defp schema_problems(opts, item) do
    cond do
      not Keyword.keyword?(opts) ->
        [{item.file, item.line, "schema takes version:, namespace:, description:, comment:"}]

      (used = Keyword.keys(opts) -- @schema_keys) != [] ->
        for k <- used do
          if k in @unused,
            do:
              {item.file, item.line,
               "schema: #{k} is a key of Rela's schema that Atlas does not use; no construct writes it"},
            else: {item.file, item.line, "schema knows no #{k}"}
        end

      not is_binary(opts[:version]) ->
        [{item.file, item.line, "schema needs version: its Rela schema version, as text"}]

      true ->
        []
    end
  end

  # Kinds and types belong in concepts; a module holds root constructs only.
  defp placement(modules, own) do
    for(
      m <- modules,
      i <- m.items,
      i.kind in [:type, :entity, :relation, :select, :migrate],
      do: {i.file, i.line, "#{i.kind} belongs in a concept (use RelaDSL), not in a module"}
    ) ++
      for i <- own,
          i.kind in [:type, :entity, :select, :migrate],
          do:
            {i.file, i.line, "#{i.kind} belongs in a concept (use RelaDSL), not in a composition"}
  end

  # One resolved schema, as plain maps; each kind, type and relation defined once.
  defp resolve(files) do
    Enum.reduce(files, {%{"types" => %{}, "entities" => %{}, "relations" => %{}}, []}, fn f,
                                                                                          {acc,
                                                                                           problems} ->
      {:ordered, sections} = f.doc

      Enum.reduce(sections, {acc, problems}, fn {section, {:ordered, defs}}, {acc, ps} ->
        Enum.reduce(defs, {acc, ps}, fn {name, def}, {acc, ps} ->
          if Map.has_key?(acc[section], name),
            do:
              {acc,
               ps ++ [{f.path, 1, "#{section}.#{name} is defined twice (again in #{f.path})"}]},
            else: {put_in(acc, [section, name], Plain.unorder(def)), ps}
        end)
      end)
    end)
  end

  defp acl(nil, own) do
    if Enum.any?(own, &(&1.kind in [:role, :assign])),
      do:
        raise(CompileError, file: hd(own).file, line: 1, description: "role and assign need acl"),
      else: nil
  end

  defp acl(opts, own) do
    roles =
      for %{kind: :role, value: {name, o}} <- own,
          do: %{
            name: to_string(name),
            comment: o[:comment],
            read: o[:read],
            create: o[:create],
            update: o[:update],
            line: nil
          }

    %{
      comment: opts[:comment],
      roles: Map.new(roles, &{&1.name, &1}),
      order: Enum.map(roles, & &1.name),
      assignments:
        Map.new(for %{kind: :assign, value: {p, r}} <- own, do: {to_string(p), to_string(r)}),
      assignment_order:
        for(%{kind: :assign, value: {p, r}} <- own, do: {to_string(p), to_string(r)})
    }
  end

  defp acl_problems(nil, _schema, _own), do: []

  defp acl_problems(acl, schema, own) do
    for(
      %{kind: :role, value: {name, o}} = i <- own,
      {k, list} <- Keyword.take(o, [:read, :create, :update]),
      kind <- list,
      to_string(kind) != "*",
      not Map.has_key?(schema["entities"], to_string(kind)),
      do:
        {i.file, i.line,
         "role #{name}: #{k} names #{kind}, which is not a kind of the composition"}
    ) ++
      for(
        %{kind: :role, value: {name, o}} = i <- own,
        Keyword.keys(o) -- [:comment, :read, :create, :update] != [],
        do: {i.file, i.line, "role #{name} knows only comment:, read:, create:, update:"}
      ) ++
      for %{kind: :assign, value: {p, r}} = i <- own,
          not Map.has_key?(acl.roles, to_string(r)),
          do: {i.file, i.line, "assign #{p}: #{r} is no role of the acl"}
  end

  defp load!(mod, what, file, line) do
    case Code.ensure_compiled(mod) do
      {:module, ^mod} ->
        if function_exported?(mod, :__rela__, 1) do
          try do
            mod.__rela__(what)
          rescue
            FunctionClauseError ->
              raise CompileError,
                file: file,
                line: line,
                description:
                  "#{inspect(mod)} is no #{what} (use RelaDSL#{if what == :module, do: ".Module"})"
          end
        else
          raise CompileError,
            file: file,
            line: line,
            description:
              "#{inspect(mod)} is no #{what} (use RelaDSL#{if what == :module, do: ".Module"})"
        end

      {:error, reason} ->
        raise CompileError,
          file: file,
          line: line,
          description: "the #{what} #{inspect(mod)} is #{reason}"
    end
  end

  defp flows!(mod, file, line) do
    case Code.ensure_compiled(mod) do
      {:module, ^mod} ->
        if function_exported?(mod, :__flows__, 0), do: mod.__flows__(), else: []

      {:error, reason} ->
        raise CompileError,
          file: file,
          line: line,
          description: "the subflow module #{inspect(mod)} is #{reason}"
    end
  end

  # A mistake is refused at its own file and line; the others follow in the message.
  defp refuse!([], _file), do: :ok

  defp refuse!(problems, _file) do
    [{f, line, message} | rest] = Enum.sort_by(problems, &{elem(&1, 0), elem(&1, 1)})

    also =
      Enum.map_join(rest, "", fn {pf, pl, m} -> "\n  #{Path.relative_to_cwd(pf)}:#{pl}: #{m}" end)

    raise CompileError, file: f, line: line, description: message <> also
  end
end
