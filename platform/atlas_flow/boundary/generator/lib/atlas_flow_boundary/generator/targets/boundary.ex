defmodule AtlasFlowBoundary.Generator.Targets.Boundary do
  @moduledoc """
  A compile-time target: the Boundary Elixir target of one contract, made from its
  `__schema__/0` when the module that uses it compiles. It serves both directions of the
  contract. No file is written.

      defmodule MySystem.Boundary.Lending do
        use AtlasFlowBoundary.Generator.Targets.Boundary,
          contract: MyContracts.Lending,
          implementation: MySystem.Lending
      end

  With a private model, add the mappings between its entities and the contract's models
  (`AtlasFlowBoundary.Generator.Mappings`) and the model, and it also generates the
  translations (see "Translations" below):

      defmodule MySystem.Boundary.Lending do
        use AtlasFlowBoundary.Generator.Targets.Boundary,
          contract: MyContracts.Lending,
          mappings: MyContracts.LendingMappings,
          model: MySystem.Model.Lending,
          implementation: MySystem.Lending
      end

  Option `invalid_detail_right: right` (with either form): the contract's `invalid_input`
  answer carries its `detail:` text only for a client that holds that right; any other
  client gets the outcome without it. The contract must declare `invalid_input` with an
  optional `detail:` field, otherwise it is a `CompileError`.

  It defines, in and under that module (the facade, `F` below):

  - **A struct per model**, `F.<Model>` (`:lend_input` is `F.LendInput`), with the
    model's fields; its required fields are `@enforce_keys`. Each has:
    - `@type t`, and a `@type <field>` for each field whose type is or holds an `enum` or
      a `one_of` (not for a field named `t`, whose union stays inline);
    - `new/1`: builds the struct from a map (atom or string keys) or a keyword list, such
      as decoded JSON: `{:ok, struct}` or `{:error, [reason]}`. An unknown field, a
      missing required one or a wrong value is an error. It also takes the JSON forms: an
      enum value as its name, a datetime as ISO-8601 text, a model as a map, a `one_of`
      as a map with its tag naming the model;
    - `new!/1`: the same, raising `ArgumentError`;
    - `validate/1`: `:ok` or `{:error, [reason]}` for a struct that is built already (no
      JSON forms accepted);
    - `dump/1`: the struct as JSON-ready data: string keys, enum values and datetimes as
      text, a `one_of` with its tag, an optional field without a value left out.
  - **A struct per outcome**, `F.Outcome.<Outcome>`, with the fields of the model the
    outcome carries (none when it carries none), and the same functions.
  - **The behaviour**, `F.Implementation`: one `@callback` per capability,
    `name(client, input) :: outcome | ...` (`name(client)` for one without input). The
    implementation does `use F.Implementation`, which adds `@behaviour F.Implementation`
    and a `@before_compile` check over the module's own definitions
    (`Module.definitions_in/2`): a capability it does not define with its arity is a
    `CompileError` while that module compiles.
  - **One function per capability**, `F.name(client, input)` (or `F.name(client)`), with
    its `@spec`. The input is the input struct or a plain map (decoded JSON). It:
    1. raises `AtlasFlowBoundary.Generator.ContractError` when the client is not
       `{id, rights}`;
    2. returns `%AtlasFlowBoundary.Generator.NotPermitted{}` when the client lacks the
       capability's right, whatever the input, without calling the implementation;
    3. checks the input: a struct with `validate/1`, a map through `new/1`. When it does
       not validate it answers, without calling the implementation, the contract's
       `invalid_input` outcome if the capability declares that outcome (its `set:` values,
       and the reasons as text in its `detail:` field, for a client that holds
       `invalid_detail_right:` when that option is given), and otherwise
       `%AtlasFlowBoundary.Generator.InvalidInput{capability, reasons}`;
    4. calls the implementation's function of the same name with the client and the
       built input struct;
    5. returns its result when it is one of the capability's outcome structs and
       validates, and raises `ContractError` otherwise. A `:stream` field is checked by
       its type only and never enumerated, so the stream reaches the caller unconsumed.
  - `@type client :: {id :: term(), rights :: [atom()] | MapSet.t(atom())}`: an opaque
    caller, as the facade receives it and passes it on.

  A `:stream` field has the type `Enumerable.t()`. Its struct's `dump/1` raises
  `ContractError`: a stream is sent as bytes, never as JSON.

  **Compile-time checks.** The first is `use F.Implementation`'s `@before_compile` check
  above, run whenever the implementation compiles. As a backstop, the facade registers an
  `@after_verify` hook: once every module is compiled it checks that the implementation
  exists, declares `@behaviour F.Implementation`, and exports every capability with its
  arity; otherwise it raises a `CompileError` at the facade's `use` line. Neither depends
  on `--warnings-as-errors`. The implementation is not a compile-time dependency of the
  facade, so it may use the facade's structs.

  A model may not be named `outcome` or `implementation` (those modules are the target's).

  ## Translations (`mappings:` and `model:`, given together)

  `model:` is a compiled module with `__schema__/0` of the model schema shape
  (`AtlasFlowBoundary.Generator.ModelSchema`) and, per entity, a struct module named
  after it (`:loan_record` is `<model>.LoanRecord`) with `@type t` and `new/1` (atom keys;
  a nested entity as its struct or a map; a `one_of` member as its struct or a map with
  `kind:` naming its entity). That is what a model target gives; this target reads
  nothing else of it.

  When the facade compiles, every mapping is checked against the contract and the model,
  and a mistake is a `CompileError` at the mapping's line:

  - an unknown model entity or field, or an unknown boundary model or field;
  - a model field that no boundary field takes (keep its name, rename it, or drop it), or
    a boundary field that no model field gives and that is not supplied;
  - types that renaming cannot fit. A primitive fits itself; an enum fits an enum when
    each model value (after `values:` renames) is a boundary value, and, both ways, each
    boundary value has exactly one model value; a model string fits a boundary enum (the
    value is checked when translated); an entity fits a boundary model when the entity's
    mapping gives that model (both ways, when this one goes both ways); a `one_of` fits
    a `one_of` member by member in the same way; a list fits a list of a fitting type;
  - a required boundary field that is supplied, in a mapping that another one holds
    (nothing could supply it there).

  It adds to `F`:

  - `from_model(entity, opts \\\\ [])`: the boundary struct of a model entity (of any mapped
    entity): renames applied, dropped fields absent, built through the boundary model's
    `new/1`, so `{:ok, struct}` or `{:error, [reason]}`. `supply: [field: value]` gives
    the fields the mapping supplies; `as: outcome` gives that outcome's struct instead of
    the model's, for an outcome that carries the mapped model;
  - `to_model(struct, opts \\\\ [])`, for each mapping both ways: the model entity of a
    boundary struct, renames reversed, built through the model's `new/1`, whose result it
    returns. `with: [field: value]` gives fields the mapping drops (the model's private
    fields);
  - a `@spec` for each mapping. Calling either with something no mapping covers, or with
    an option the mapping does not declare, raises `ContractError`.
  """

  alias AtlasFlowBoundary.Generator.Targets.Boundary.{Translations, Values}

  @reserved ["Outcome", "Implementation"]

  defmacro __using__(opts) do
    caller = __CALLER__
    fail = &raise(CompileError, file: caller.file, line: caller.line, description: &1)

    unless Keyword.keyword?(opts) and
             Enum.sort(Keyword.keys(opts) -- [:invalid_detail_right]) in [
               [:contract, :implementation],
               [:contract, :implementation, :mappings, :model]
             ],
           do:
             fail.(
               "use #{inspect(__MODULE__)} takes contract: and implementation:, " <>
                 "optionally mappings: and model: together, and optionally invalid_detail_right:"
             )

    contract = Macro.expand(opts[:contract], caller)

    unless is_atom(contract) and Code.ensure_compiled(contract) == {:module, contract} and
             function_exported?(contract, :__schema__, 0),
           do: fail.("contract: #{Macro.to_string(opts[:contract])} is no compiled contract")

    # Expanded as a literal, so the implementation is no compile-time dependency.
    implementation =
      Macro.expand_literals(opts[:implementation], %{caller | function: {:__info__, 1}})

    unless is_atom(implementation) and not is_nil(implementation),
      do: fail.("implementation: expects a module")

    facade = caller.module
    schema = contract.__schema__()
    detail_right = invalid_detail_right!(opts, schema, fail)

    module_of = fn name ->
      camel = Macro.camelize(Atom.to_string(name))
      if camel in @reserved, do: fail.("model #{inspect(name)} is reserved by the target")
      Module.concat(facade, camel)
    end

    models = Map.new(schema.models, &{&1.name, module_of.(&1.name)})

    if models |> Map.values() |> Enum.uniq() |> length() != map_size(models),
      do: fail.("two models of the contract have the same module name")

    resolve = &resolve(&1, models)
    fields_of = Map.new(schema.models, &{&1.name, Enum.map(&1.fields, resolve_field(resolve))})

    model_modules =
      for model <- schema.models do
        struct_module(
          models[model.name],
          Atom.to_string(model.name),
          fields_of[model.name],
          "model"
        )
      end

    outcomes =
      schema.capabilities
      |> Enum.flat_map(& &1.outcomes)
      |> Enum.uniq_by(& &1.name)
      |> Map.new(fn outcome ->
        {outcome.name,
         {Module.concat([facade, Outcome, Macro.camelize(Atom.to_string(outcome.name))]),
          outcome.model}}
      end)

    outcome_modules =
      for {name, {module, model}} <- Enum.sort(outcomes) do
        fields = if model, do: fields_of[model], else: []
        struct_module(module, Atom.to_string(name), fields, "outcome")
      end

    behaviour = Module.concat(facade, Implementation)

    translations =
      if Keyword.has_key?(opts, :mappings),
        do:
          translations(
            Translations.plan!(
              schema,
              models,
              outcomes,
              Macro.expand(opts[:mappings], caller),
              Macro.expand(opts[:model], caller),
              fail
            )
          ),
        else: []

    # What a capability answers on invalid input: {outcome module, fields} or nil.
    invalid_answer = fn capability ->
      with %{outcome: name, set: set, detail: detail} <- schema.invalid_input,
           true <- Enum.any?(capability.outcomes, &(&1.name == name)) do
        {module, _model} = outcomes[name]
        {module, set, detail, detail_right}
      else
        _ -> nil
      end
    end

    signature = fn capability ->
      args =
        if capability.input,
          do: [
            quote(do: unquote(facade).client()),
            quote(do: unquote(models[capability.input]).t())
          ],
          else: [quote(do: unquote(facade).client())]

      returns =
        capability.outcomes
        |> Enum.map(fn outcome ->
          {module, _model} = outcomes[outcome.name]
          quote(do: unquote(module).t())
        end)
        |> union()

      {args, returns}
    end

    callbacks =
      for capability <- schema.capabilities do
        {args, returns} = signature.(capability)

        quote do
          @callback unquote(capability.name)(unquote_splicing(args)) :: unquote(returns)
        end
      end

    functions =
      for capability <- schema.capabilities do
        {args, returns} = signature.(capability)
        input = capability.input && models[capability.input]
        invalid = input && invalid_answer.(capability)

        returns =
          union(
            [returns, quote(do: AtlasFlowBoundary.Generator.NotPermitted.t())] ++
              if(input && !invalid,
                do: [quote(do: AtlasFlowBoundary.Generator.InvalidInput.t())],
                else: []
              )
          )

        args =
          if input,
            do: [hd(args), quote(do: unquote(input).t() | map())],
            else: args

        modules = for o <- capability.outcomes, do: elem(outcomes[o.name], 0)

        doc =
          "Capability `#{capability.name}` (right `#{capability.right}`): " <>
            "outcomes #{Enum.map_join(capability.outcomes, ", ", &"`#{&1.name}`")}."

        if input do
          quote do
            @doc unquote(doc)
            @spec unquote(capability.name)(unquote_splicing(args)) :: unquote(returns)
            def unquote(capability.name)(client, input),
              do:
                Values.call(
                  __MODULE__,
                  unquote(implementation),
                  unquote(capability.name),
                  unquote(capability.right),
                  client,
                  {unquote(input), input, unquote(Macro.escape(invalid))},
                  unquote(modules)
                )
          end
        else
          quote do
            @doc unquote(doc)
            @spec unquote(capability.name)(unquote_splicing(args)) :: unquote(returns)
            def unquote(capability.name)(client),
              do:
                Values.call(
                  __MODULE__,
                  unquote(implementation),
                  unquote(capability.name),
                  unquote(capability.right),
                  client,
                  nil,
                  unquote(modules)
                )
          end
        end
      end

    required =
      for capability <- schema.capabilities,
          do: {capability.name, if(capability.input, do: 2, else: 1)}

    quote do
      @typedoc "An opaque caller: its id and its rights."
      @type client :: {id :: term(), rights :: [atom()] | MapSet.t(atom())}

      unquote_splicing(model_modules)
      unquote_splicing(outcome_modules)

      defmodule unquote(behaviour) do
        @moduledoc unquote(
                     "What the implementation of #{inspect(contract)} implements: one callback per capability."
                   )
        unquote_splicing(callbacks)

        @doc """
        `use` it in the implementation: it adds `@behaviour #{inspect(__MODULE__)}` and a
        compile-time check that the module defines every capability with its arity.
        """
        defmacro __using__(opts),
          do:
            AtlasFlowBoundary.Generator.Targets.Boundary.__use_implementation__(
              __MODULE__,
              opts,
              __CALLER__
            )

        @doc false
        defmacro __before_compile__(env),
          do:
            AtlasFlowBoundary.Generator.Targets.Boundary.__check_implementation__(
              __MODULE__,
              unquote(required),
              env
            )
      end

      unquote_splicing(functions)
      unquote_splicing(translations)

      @after_verify __MODULE__
      @doc false
      def __after_verify__(_module),
        do:
          AtlasFlowBoundary.Generator.Targets.Boundary.verify!(
            unquote(implementation),
            unquote(behaviour),
            unquote(required),
            unquote(caller.file),
            unquote(caller.line)
          )
    end
  end

  # The right a client needs to see the invalid_input detail, or nil (every client).
  defp invalid_detail_right!(opts, schema, fail) do
    case Keyword.fetch(opts, :invalid_detail_right) do
      :error ->
        nil

      {:ok, right} ->
        unless is_atom(right) and right not in [nil, true, false],
          do: fail.("invalid_detail_right: expects a right (an atom)")

        detail =
          case schema.invalid_input do
            %{detail: detail} when detail != nil ->
              detail

            _ ->
              fail.("invalid_detail_right: the contract declares no invalid_input with detail:")
          end

        %{outcome: outcome} = schema.invalid_input
        model = for c <- schema.capabilities, o <- c.outcomes, o.name == outcome, do: o.model
        fields = Enum.find(schema.models, &(&1.name == hd(model))).fields

        if Enum.any?(fields, &(&1.name == detail and &1.required)),
          do:
            fail.(
              "invalid_detail_right: #{hd(model)}.#{detail} is required, so it cannot be left out"
            )

        right
    end
  end

  @doc false
  # What `use F.Implementation` adds to the implementation.
  def __use_implementation__(behaviour, opts, caller) do
    if opts != [],
      do:
        raise(CompileError,
          file: caller.file,
          line: caller.line,
          description: "use #{inspect(behaviour)} takes no options"
        )

    quote do
      @behaviour unquote(behaviour)
      @before_compile unquote(behaviour)
      Module.put_attribute(
        __MODULE__,
        :atlas_flow_boundary_implementation,
        unquote(caller.line)
      )
    end
  end

  @doc false
  # The implementation's own compile-time check, over the definitions of the module being
  # compiled; it raises at its `use` line.
  def __check_implementation__(behaviour, required, env) do
    line = Module.get_attribute(env.module, :atlas_flow_boundary_implementation, env.line)
    defined = Module.definitions_in(env.module, :def)

    case missing(required, defined) do
      [] ->
        nil

      missing ->
        raise CompileError,
          file: env.file,
          line: line,
          description:
            "#{inspect(env.module)} does not implement capability " <>
              Enum.join(missing, ", ") <> " of #{inspect(behaviour)}"
    end
  end

  @doc false
  # The facade's compile-time check (the backstop), run once every module is compiled.
  def verify!(implementation, behaviour, required, file, line) do
    fail = &raise(CompileError, file: file, line: line, description: &1)

    case Code.ensure_compiled(implementation) do
      {:module, _} ->
        :ok

      {:error, reason} ->
        fail.("implementation #{inspect(implementation)} is not available (#{reason})")
    end

    missing = missing(required, implementation.module_info(:exports))

    if missing != [],
      do:
        fail.(
          "#{inspect(implementation)} does not implement capability " <>
            Enum.join(missing, ", ") <> " of #{inspect(behaviour)}"
        )

    behaviours =
      implementation.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

    unless behaviour in behaviours,
      do: fail.("#{inspect(implementation)} does not declare @behaviour #{inspect(behaviour)}")

    :ok
  end

  # The capabilities of `required` that `defined` lacks, as text naming the arities it has.
  defp missing(required, defined) do
    for {name, arity} <- required, {name, arity} not in defined do
      case for({^name, other} <- defined, do: other) |> Enum.sort() do
        [] -> "#{name}/#{arity}"
        others -> "#{name}/#{arity} (it has #{Enum.map_join(others, ", ", &"#{name}/#{&1}")})"
      end
    end
  end

  # from_model/1,2 and to_model/1,2, with a @spec per mapping.
  defp translations(plan) do
    mappings = plan.mappings |> Map.values() |> Enum.sort_by(& &1.line)

    from_specs =
      for mapping <- mappings, arity <- [1, 2] do
        args =
          [quote(do: unquote(mapping.model_module).t())] ++
            if(arity == 2, do: [quote(do: keyword())], else: [])

        results =
          union(
            for(
              module <- [mapping.boundary_module | Enum.map(mapping.outcomes, &elem(&1, 1))],
              do: quote(do: unquote(module).t())
            )
          )

        quote do
          @spec from_model(unquote_splicing(args)) ::
                  {:ok, unquote(results)} | {:error, [String.t()]}
        end
      end

    to_specs =
      for %{direction: :both} = mapping <- mappings, arity <- [1, 2] do
        args =
          [quote(do: unquote(mapping.boundary_module).t())] ++
            if(arity == 2, do: [quote(do: keyword())], else: [])

        quote do
          @spec to_model(unquote_splicing(args)) ::
                  {:ok, unquote(mapping.model_module).t()} | {:error, term()}
        end
      end

    from_doc = """
    The boundary struct of a model entity: its mapping's renames applied, its dropped
    fields absent, built through the boundary model's `new/1`. `{:ok, struct}`, or
    `{:error, [reason]}` when the result does not validate. Options:

    - `supply:` the boundary fields the mapping declares as `supply:`;
    - `as:` an outcome that carries the mapped model: its outcome struct instead.

    Mappings: #{Enum.map_join(mappings, ", ", &"`#{&1.model}` → `#{&1.boundary}`")}.
    """

    to_doc = """
    The model entity of a boundary struct, for a mapping both ways: renames reversed,
    built through the model's `new/1`, whose `{:ok, entity}` or `{:error, reason}` it
    returns. `with:` gives fields the mapping drops (the model's private fields).

    Mappings: #{Enum.map_join(for(%{direction: :both} = m <- mappings, do: m), ", ", &"`#{&1.boundary}` → `#{&1.model}`")}.
    """

    [
      quote do
        @doc false
        def __translations__, do: unquote(Macro.escape(plan))

        @doc unquote(from_doc)
        unquote_splicing(from_specs)

        def from_model(entity, opts \\ []),
          do: Translations.from_model(__MODULE__, __translations__(), entity, opts)
      end
    ] ++
      if to_specs == [],
        do: [],
        else: [
          quote do
            @doc unquote(to_doc)
            unquote_splicing(to_specs)

            def to_model(value, opts \\ []),
              do: Translations.to_model(__MODULE__, __translations__(), value, opts)
          end
        ]
  end

  # A model's or an outcome's struct module.
  defp struct_module(module, name, fields, kind) do
    required = for {field, _type, true} <- fields, do: field

    named_types =
      for {field, type, _required} <- fields, field != :t, union_type?(type) do
        quote do
          @type unquote(Macro.var(field, nil)) :: unquote(typespec(type))
        end
      end

    struct_type =
      for {field, type, required} <- fields do
        spec =
          if field != :t and union_type?(type),
            do: {field, [], []},
            else: typespec(type)

        {field, if(required, do: spec, else: union([spec, nil]))}
      end

    doc =
      "The #{kind} `#{name}` of the contract. Fields: " <>
        if(fields == [],
          do: "none.",
          else:
            Enum.map_join(fields, ", ", fn {f, _t, r} -> "`#{f}`#{if r, do: " (required)"}" end) <>
              "."
        )

    quote do
      defmodule unquote(module) do
        @moduledoc unquote(doc)
        @enforce_keys unquote(required)
        defstruct unquote(Enum.map(fields, &elem(&1, 0)))

        unquote_splicing(named_types)
        @type t :: %__MODULE__{unquote_splicing(struct_type)}

        @doc false
        def __fields__, do: unquote(Macro.escape(fields))

        @doc "Build from a map or keyword list (JSON forms accepted): `{:ok, t}` or `{:error, [reason]}`."
        @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [String.t()]}
        def new(params), do: Values.new(__MODULE__, unquote(name), params)

        @doc "`new/1`, raising `ArgumentError` on an error."
        @spec new!(map() | keyword() | t()) :: t()
        def new!(params), do: Values.new!(__MODULE__, unquote(name), params)

        @doc "Check a built struct: `:ok` or `{:error, [reason]}`."
        @spec validate(t()) :: :ok | {:error, [String.t()]}
        def validate(value), do: Values.validate(__MODULE__, unquote(name), value)

        @doc "As JSON-ready data: string keys, text for enums and datetimes, no nil optional fields."
        @spec dump(t()) :: map()
        def dump(%__MODULE__{} = value), do: Values.dump(value)
      end
    end
  end

  # A ranged integer is `{:integer, min, max}` in `__fields__/0`, so new/1 and validate/1
  # refuse a value outside it.
  defp resolve_field(resolve) do
    fn
      %{type: :integer, range: {min, max}} = field ->
        {field.name, {:integer, min, max}, field.required}

      field ->
        {field.name, resolve.(field.type), field.required}
    end
  end

  defp resolve({:list, inner}, models), do: {:list, resolve(inner, models)}
  defp resolve({:map, inner}, _models), do: {:map, inner}
  defp resolve({:enum, values}, _models), do: {:enum, values}

  defp resolve({:one_of, members, tag: tag}, models),
    do: {:one_of, Enum.map(members, &{Atom.to_string(&1), models[&1]}), tag}

  defp resolve(type, _models) when type in [:string, :integer, :boolean, :datetime, :stream],
    do: type

  defp resolve(model, models), do: {:model, Map.fetch!(models, model)}

  defp union_type?({:list, inner}), do: union_type?(inner)
  defp union_type?({:enum, _}), do: true
  defp union_type?({:one_of, _, _}), do: true
  defp union_type?(_type), do: false

  defp typespec(:string), do: quote(do: String.t())
  defp typespec(:integer), do: quote(do: integer())
  defp typespec({:integer, min, max}), do: quote(do: unquote(min)..unquote(max))
  defp typespec(:boolean), do: quote(do: boolean())
  defp typespec(:datetime), do: quote(do: DateTime.t())
  defp typespec(:stream), do: quote(do: Enumerable.t())
  defp typespec({:enum, values}), do: union(values)
  defp typespec({:model, module}), do: quote(do: unquote(module).t())

  defp typespec({:one_of, members, _tag}),
    do: union(for({_name, module} <- members, do: quote(do: unquote(module).t())))

  defp typespec({:list, inner}), do: quote(do: [unquote(typespec(inner))])

  defp typespec({:map, inner}),
    do: quote(do: %{optional(String.t()) => unquote(typespec(inner))})

  defp union(specs), do: specs |> Enum.reverse() |> Enum.reduce(&{:|, [], [&1, &2]})
end
