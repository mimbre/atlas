defmodule AtlasRuntimeBoundary.Generator.Schema do
  @moduledoc """
  The schema of a boundary contract, written as a DSL: a system's own interface, its
  capabilities and the values they take and give, with no transport in it. Copied from
  Control's generator (`defmodel`, `field`, `__schema__/0`) and extended for boundary
  contracts.

      defmodule MyContract do
        use AtlasRuntimeBoundary.Generator.Schema

        version "1.0.0"

        defmodel :shelf do
          field :row, :integer, required: true
        end

        defmodel :branch do
          field :city, :string, required: true
        end

        defmodel :book do
          field :title, :string, required: true
          field :condition, {:enum, [:new, :worn, :"badly-worn"]}, required: true
          field :place, {:one_of, [:shelf, :branch], tag: :kind}
          field :due_at, :datetime
        end

        defmodel :lend_input do
          field :title, :string, required: true
        end

        defmodel :refusal do
          field :why, {:enum, [:banned, :unreadable]}, required: true
          field :note, :string
        end

        defcapability :lend,
          input: :lend_input,
          outcomes: [lent: :book, declined: :refusal, missing: nil],
          right: :lend

        invalid_input :declined, set: [why: :unreadable], detail: :note
      end

  - `defmodel`: a value a capability takes or gives, with its fields.
  - `field`: a snake_case name, a type and `required: true | false` (default `false`).
    An `:integer` field may also take `range: min..max` (integer literals, `min <= max`):
    a value outside it does not validate, so the facade refuses it as an invalid input and
    the implementation never sees it. Nothing is clamped.
    Types:
    - `:string`, `:integer`, `:boolean`;
    - `:datetime`: a point in time (an Elixir `DateTime`; ISO-8601 text in JSON);
    - a model's name;
    - `{:enum, [atom]}`: one of these atoms (at least one, each once; any atom, so
      `:"read-only"` too);
    - `{:one_of, [model], tag: atom}`: one of these models (at least two, each once). In
      JSON the value carries the tag as a member naming its model (`"kind": "shelf"`), so
      no member model may have a field named like the tag;
    - `{:list, type}`;
    - `{:map, primitive}`: an object of names to `:string`, `:integer`, `:boolean` or
      `:datetime` values;
    - `:stream`: an opaque byte stream, an `Enumerable` of binary chunks that the facade
      passes on without enumerating it. It is allowed only as a direct field of a model
      that an outcome carries or that is a capability's input, and of no other model: not
      in a `list`, a `map` or a `one_of`, and not in a model held by another model. A
      capability's input model has at most one `:stream` field (an upload is one body),
      and that field is always required, whatever `required:` says: an upload without
      its body is not valid, so `new/1` and the facade refuse a missing one.
      Anywhere else it is a `CompileError` at the field's line.
  - `defcapability`: an operation the system offers, by name, with options:
    - `input:` the model it takes, or `nil` / left out when it takes none;
    - `outcomes:` `[outcome: model]`, at least one, in order: each outcome by name, with
      the model whose fields it carries, or `nil` when it carries none. An outcome name
      means the same everywhere in a contract: two capabilities that both have `found`
      give it the same model;
    - `right:` the right (an atom) a caller needs to call it (required).
  - `invalid_input`: at most once, the outcome a capability answers when its input does not
    validate, for every capability that declares that outcome. `set:` gives fixed field
    values (an enum value, a string, an integer or a boolean) and `detail:` (optional)
    names a string field that receives the reasons as text. Together they cover every
    required field of the outcome's model. Without it, or for a capability that does not
    declare that outcome, the facade answers its own `InvalidInput` (see
    `AtlasRuntimeBoundary.Generator.Targets.Boundary`).

  A mistake fails at compile time and points at its line.

  ## The schema as data

  A contract compiles to one function, `__schema__/0`, and the targets read only that,
  never this module's internals (a test checks it):

      %{
        version: "1.0.0",
        file: "/abs/path/to/the/contract.ex",
        models: [
          %{name: atom, fields: [%{name: atom, type: type, required: boolean, range?: {min, max}}]}
        ],
        capabilities: [
          %{name: atom, input: atom | nil, right: atom,
            outcomes: [%{name: atom, model: atom | nil}]}
        ],
        invalid_input: nil | %{outcome: atom, set: [{atom, value}], detail: atom | nil}
      }

  Models, fields, capabilities and outcomes are in the order written. A type is as written
  in `field`; a `one_of` is always `{:one_of, [model], tag: atom}`. `range` is present only
  on a field that declares one.
  """

  @primitives [:string, :integer, :boolean, :datetime]

  # Not a primitive: it may not be listed, mapped or held (see the moduledoc).
  @stream :stream

  defmacro __using__(_opts) do
    quote do
      import AtlasRuntimeBoundary.Generator.Schema,
        only: [
          version: 1,
          defmodel: 2,
          defcapability: 2,
          field: 2,
          field: 3,
          invalid_input: 1,
          invalid_input: 2
        ]

      Module.register_attribute(__MODULE__, :spec_entries, accumulate: true)
      @before_compile AtlasRuntimeBoundary.Generator.Schema
    end
  end

  defmacro version(version) do
    quote do: @spec_version(unquote(version))
  end

  defmacro defmodel(name, do: body) do
    %{file: file, line: line} = __CALLER__

    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasRuntimeBoundary.Generator.Schema.__fail__(
          unquote(file),
          unquote(line),
          "#{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      Module.put_attribute(__MODULE__, :spec_open, unquote(name))
      Module.register_attribute(__MODULE__, :spec_fields, accumulate: true)
      unquote(body)

      @spec_entries %{
        type: :model,
        name: unquote(name),
        file: unquote(file),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :spec_fields))
      }

      Module.delete_attribute(__MODULE__, :spec_fields)
      Module.delete_attribute(__MODULE__, :spec_open)
    end
  end

  defmacro defcapability(name, opts) do
    %{file: file, line: line} = __CALLER__

    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasRuntimeBoundary.Generator.Schema.__fail__(
          unquote(file),
          unquote(line),
          "capability #{inspect(unquote(name))} inside #{inspect(open)}"
        )
      end

      @spec_entries %{
        type: :capability,
        name: unquote(name),
        opts: unquote(opts),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  defmacro invalid_input(outcome, opts \\ []) do
    %{file: file, line: line} = __CALLER__

    quote do
      if open = Module.get_attribute(__MODULE__, :spec_open) do
        AtlasRuntimeBoundary.Generator.Schema.__fail__(
          unquote(file),
          unquote(line),
          "invalid_input inside #{inspect(open)}"
        )
      end

      @spec_entries %{
        type: :invalid_input,
        outcome: unquote(outcome),
        opts: unquote(opts),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  defmacro field(name, type, opts \\ []) do
    %{file: file, line: line} = __CALLER__

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:required, :range] == [] and
             is_boolean(Keyword.get(opts, :required, false)) do
      __fail__(
        file,
        line,
        "field #{inspect(name)}: the options are required: true | false and range: min..max"
      )
    end

    range =
      case Keyword.fetch(opts, :range) do
        :error ->
          nil

        {:ok, {:.., _, [min, max]}} when is_integer(min) and is_integer(max) and min <= max ->
          if type != :integer,
            do: __fail__(file, line, "field #{inspect(name)}: range: is only for :integer fields")

          {min, max}

        {:ok, other} ->
          __fail__(
            file,
            line,
            "field #{inspect(name)}: range must be min..max with integer literals and " <>
              "min <= max, got #{Macro.to_string(other)}"
          )
      end

    entry =
      quote do
        %{
          name: unquote(name),
          type: unquote(type),
          required: unquote(Keyword.get(opts, :required, false)),
          file: unquote(file),
          line: unquote(line)
        }
      end

    entry = if range, do: quote(do: Map.put(unquote(entry), :range, unquote(range))), else: entry

    quote do
      unless Module.get_attribute(__MODULE__, :spec_open) do
        AtlasRuntimeBoundary.Generator.Schema.__fail__(
          unquote(file),
          unquote(line),
          "field #{inspect(unquote(name))} outside a model"
        )
      end

      @spec_fields unquote(entry)
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:spec_entries) |> Enum.reverse()

    version =
      Module.get_attribute(env.module, :spec_version) ||
        __fail__(env.file, 1, "the contract needs a version")

    {invalid_inputs, entries} = Enum.split_with(entries, &(&1.type == :invalid_input))
    {capabilities, models} = Enum.split_with(entries, &(&1.type == :capability))
    {models, streams} = validate_models!(models)
    capabilities = validate_capabilities!(capabilities, Enum.map(models, & &1.name))
    validate_streams!(streams, models, capabilities)
    models = require_input_streams(models, capabilities)
    invalid_input = validate_invalid_input!(invalid_inputs, capabilities, models)

    spec = %{
      version: version,
      file: env.file,
      models: models,
      capabilities: capabilities,
      invalid_input: invalid_input
    }

    quote do
      @doc "The contract as plain data, for the targets (see `AtlasRuntimeBoundary.Generator.Schema`)."
      def __schema__, do: unquote(Macro.escape(spec))
    end
  end

  defp validate_models!(models) do
    names = for %{name: name} <- models, do: name

    {models, _seen} =
      Enum.map_reduce(models, MapSet.new(), fn model, seen ->
        fail = &__fail__(model.file, model.line, &1)
        unless snake?(model.name), do: fail.("#{inspect(model.name)} is not a snake_case atom")
        if model.name in seen, do: fail.("#{inspect(model.name)} is defined twice")

        if model.name in [@stream | @primitives],
          do: fail.("#{inspect(model.name)} clashes with a primitive type")

        {fields, _names} =
          Enum.map_reduce(model.fields, MapSet.new(), fn field, field_names ->
            fail = &__fail__(field.file, field.line, &1)

            unless snake?(field.name),
              do: fail.("field #{inspect(field.name)} is not a snake_case atom")

            if field.name in field_names,
              do: fail.("#{inspect(model.name)} has field #{inspect(field.name)} twice")

            type = check_type!(field.type, names, "#{model.name}.#{field.name}", fail)

            {%{field | type: type}, MapSet.put(field_names, field.name)}
          end)

        {%{model | fields: fields}, MapSet.put(seen, model.name)}
      end)

    # A one_of's tag is a member of the JSON object of each of its models.
    by_name = Map.new(models, &{&1.name, &1})

    for model <- models,
        field <- model.fields,
        {:one_of, members, tag: tag} <- [inner(field.type)],
        member <- members,
        Enum.any?(by_name[member].fields, &(&1.name == tag)) do
      __fail__(
        field.file,
        field.line,
        "#{model.name}.#{field.name}: tag #{inspect(tag)} is also a field of #{inspect(member)}"
      )
    end

    # The direct :stream fields, with their lines, for validate_streams!/3.
    streams =
      for model <- models, %{type: @stream} = field <- model.fields, do: {model.name, field}

    models =
      for model <- models do
        %{
          name: model.name,
          fields: Enum.map(model.fields, &Map.take(&1, [:name, :type, :required, :range]))
        }
      end

    {models, streams}
  end

  # A :stream is a direct field of an outcome model (§1.3, S5a) or of an input model
  # (S5c): not held by another model (directly, in a list or in a one_of), carried by at
  # least one outcome or taken by at least one capability, and at most one per input model.
  defp validate_streams!(streams, models, capabilities) do
    for {model, field} <- streams do
      fail =
        &__fail__(
          field.file,
          field.line,
          "#{model}.#{field.name}: a :stream is allowed only as a direct field of an " <>
            "input or outcome model; " <> &1
        )

      for holder <- models,
          holding <- holder.fields,
          model in held(holding.type),
          do: fail.("#{inspect(model)} is held by #{holder.name}.#{holding.name}")

      carried? = Enum.any?(capabilities, fn c -> Enum.any?(c.outcomes, &(&1.model == model)) end)
      input? = Enum.any?(capabilities, &(&1.input == model))

      unless carried? or input?,
        do: fail.("no outcome carries #{inspect(model)} and no capability takes it")
    end

    # An input takes one byte stream: its second :stream field fails at its line.
    inputs = for %{input: input} <- capabilities, input != nil, into: MapSet.new(), do: input

    streams
    |> Enum.filter(fn {model, _field} -> model in inputs end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn
      {model, [first, second | _]} ->
        __fail__(
          second.file,
          second.line,
          "#{model}.#{second.name}: an input model has at most one :stream field, " <>
            "and #{model}.#{first.name} is one already"
        )

      {_model, [_one]} ->
        :ok
    end)

    :ok
  end

  # An input's :stream is its upload body, so it is required whatever `required:` says
  # (S5c P1: new/1 refuses a missing value). Forced here, in the schema data, so every
  # target (struct keys, new/1, the facade, JSON, the backend) sees the same flag.
  defp require_input_streams(models, capabilities) do
    inputs = for %{input: input} <- capabilities, input != nil, into: MapSet.new(), do: input

    for model <- models do
      if model.name in inputs do
        fields =
          for field <- model.fields do
            if field.type == @stream, do: %{field | required: true}, else: field
          end

        %{model | fields: fields}
      else
        model
      end
    end
  end

  # The models a field type holds.
  defp held({:list, inner}), do: held(inner)
  defp held({:one_of, members, _opts}), do: members
  defp held(type) when is_atom(type), do: [type]
  defp held(_type), do: []

  defp validate_capabilities!(capabilities, models) do
    {capabilities, _seen} =
      Enum.map_reduce(capabilities, {MapSet.new(), %{}}, fn capability, {seen, outcomes_seen} ->
        fail = &__fail__(capability.file, capability.line, &1)
        name = capability.name
        opts = capability.opts

        unless snake?(name), do: fail.("capability #{inspect(name)} is not a snake_case atom")
        if name in seen, do: fail.("capability #{inspect(name)} is defined twice")

        unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:input, :outcomes, :right] == [],
          do: fail.("capability #{inspect(name)}: the options are input:, outcomes: and right:")

        input = opts[:input]

        unless is_nil(input) or input in models,
          do: fail.("capability #{inspect(name)} takes #{inspect(input)}, which is no model")

        right = opts[:right]

        unless snake?(right),
          do: fail.("capability #{inspect(name)} needs right: <a snake_case atom>")

        outcomes = opts[:outcomes]

        unless Keyword.keyword?(outcomes) and outcomes != [],
          do: fail.("capability #{inspect(name)} needs outcomes: [outcome: model or nil]")

        {outcomes, {_names, outcomes_seen}} =
          Enum.map_reduce(outcomes, {MapSet.new(), outcomes_seen}, fn {outcome, model},
                                                                      {names, all} ->
            unless snake?(outcome),
              do:
                fail.(
                  "capability #{inspect(name)}: outcome #{inspect(outcome)} is not snake_case"
                )

            if outcome in names,
              do: fail.("capability #{inspect(name)} has outcome #{inspect(outcome)} twice")

            unless is_nil(model) or model in models,
              do:
                fail.(
                  "capability #{inspect(name)}: outcome #{outcome} carries #{inspect(model)}, which is no model"
                )

            case Map.fetch(all, outcome) do
              {:ok, ^model} ->
                :ok

              {:ok, other} ->
                fail.(
                  "outcome #{inspect(outcome)} carries #{inspect(model)} here and #{inspect(other)} elsewhere; " <>
                    "an outcome means the same in every capability"
                )

              :error ->
                :ok
            end

            {%{name: outcome, model: model},
             {MapSet.put(names, outcome), Map.put(all, outcome, model)}}
          end)

        entry = %{name: name, input: input, right: right, outcomes: outcomes}
        {entry, {MapSet.put(seen, name), outcomes_seen}}
      end)

    capabilities
  end

  defp validate_invalid_input!([], _capabilities, _models), do: nil

  defp validate_invalid_input!([_, second | _], _capabilities, _models),
    do: __fail__(second.file, second.line, "invalid_input is declared twice")

  defp validate_invalid_input!([entry], capabilities, models) do
    fail = &__fail__(entry.file, entry.line, "invalid_input: " <> &1)
    %{outcome: outcome, opts: opts} = entry

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:set, :detail] == [],
      do: fail.("the options are set: and detail:")

    model_name =
      case for(c <- capabilities, o <- c.outcomes, o.name == outcome, do: o.model) do
        [] -> fail.("#{inspect(outcome)} is no capability's outcome")
        [nil | _] -> fail.("outcome #{inspect(outcome)} carries no model")
        [name | _] -> name
      end

    fields = Enum.find(models, &(&1.name == model_name)).fields |> Map.new(&{&1.name, &1})
    set = Keyword.get(opts, :set, [])
    detail = Keyword.get(opts, :detail)

    unless Keyword.keyword?(set), do: fail.("set: is [field: value]")

    for {name, value} <- set do
      case fields[name] do
        nil ->
          fail.("#{inspect(model_name)} has no field #{inspect(name)}")

        %{type: type} ->
          unless fixed_value?(type, value),
            do: fail.("#{model_name}.#{name} cannot be #{inspect(value)}")
      end
    end

    if detail != nil do
      unless match?(%{type: :string}, fields[detail]),
        do: fail.("detail: #{inspect(detail)} is no string field of #{inspect(model_name)}")

      if Keyword.has_key?(set, detail), do: fail.("#{inspect(detail)} is both set and detail")
    end

    for {name, %{required: true}} <- fields, not Keyword.has_key?(set, name), name != detail do
      fail.("required field #{model_name}.#{name} is neither set nor detail")
    end

    %{outcome: outcome, set: set, detail: detail}
  end

  defp fixed_value?({:enum, values}, value), do: value in values
  defp fixed_value?(:string, value), do: is_binary(value)
  defp fixed_value?(:integer, value), do: is_integer(value)
  defp fixed_value?(:boolean, value), do: is_boolean(value)
  defp fixed_value?(_type, _value), do: false

  # The type as kept in the schema; fails on an unknown or malformed one.
  defp check_type!({:list, @stream}, _models, at, fail),
    do:
      fail.(
        "#{at} is a list of :stream; a :stream is allowed only as a direct field of an " <>
          "input or outcome model"
      )

  defp check_type!({:list, inner}, models, at, fail),
    do: {:list, check_type!(inner, models, at, fail)}

  defp check_type!({:map, inner}, _models, at, fail) do
    unless inner in @primitives,
      do: fail.("#{at} is a map of #{inspect(inner)}; a map holds a primitive type")

    {:map, inner}
  end

  defp check_type!({:enum, values} = type, _models, at, fail) do
    unless is_list(values) and values != [] and
             Enum.all?(
               values,
               &(is_atom(&1) and not is_nil(&1) and not is_boolean(&1) and &1 != :"")
             ),
           do: fail.("#{at}: an enum is {:enum, [atom]}, with at least one atom")

    if Enum.uniq(values) != values, do: fail.("#{at}: an enum lists a value twice")
    type
  end

  defp check_type!({:one_of, members, opts}, models, at, fail) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) == [:tag] and snake?(opts[:tag]),
      do: fail.("#{at}: a one_of is {:one_of, [model], tag: atom}")

    unless is_list(members) and length(members) >= 2,
      do: fail.("#{at}: a one_of lists at least two models")

    if Enum.uniq(members) != members, do: fail.("#{at}: a one_of lists a model twice")

    for member <- members, member not in models do
      fail.("#{at}: one_of member #{inspect(member)} is no model")
    end

    {:one_of, members, tag: opts[:tag]}
  end

  defp check_type!({:one_of, _members}, _models, at, fail),
    do: fail.("#{at}: a one_of is {:one_of, [model], tag: atom}")

  defp check_type!(type, _models, _at, _fail) when type in @primitives, do: type
  defp check_type!(@stream, _models, _at, _fail), do: @stream

  defp check_type!(type, models, at, fail) do
    if is_atom(type) and type in models,
      do: type,
      else: fail.("#{at} has unknown type #{inspect(type)}")
  end

  defp inner({:list, type}), do: inner(type)
  defp inner(type), do: type

  defp snake?(name),
    do:
      is_atom(name) and name not in [nil, true, false] and
        Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end
