defmodule AtlasCodeBoundary.Generator.Targets.Boundary.Translations do
  @moduledoc """
  The model ↔ boundary translations of `AtlasCodeBoundary.Generator.Targets.Boundary`
  (options `mappings:` and `model:`): the compile-time check of the mappings against the
  contract and the model, which gives a plan, and the run-time translation by that plan.

  A plan is `%{from: %{model module => entity}, to: %{boundary module => entity},
  mappings: %{entity => mapping}}`, where each mapping has its modules and a list of
  `{model_field, boundary_field, conversion}`. A conversion is `:same`,
  `{:enum, model_to_boundary, boundary_to_model}`, `:to_enum` (a model string to a
  boundary enum value, cast by its name; back with `Atom.to_string/1`),
  `{:entity, entity}`, `{:one_of, [member], tag}` or `{:list, conversion}`.
  """

  alias AtlasCodeBoundary.Generator.{ContractError, ModelSchema}

  @primitives [:string, :integer, :boolean, :datetime]

  ## Compile time

  @doc false
  # The plan, or a CompileError: `fail` raises at the facade's `use` line; a mapping's own
  # error raises at its line in the mappings module.
  def plan!(schema, boundary_modules, outcomes, mappings_module, model_module, fail) do
    unless is_atom(mappings_module) and
             Code.ensure_compiled(mappings_module) == {:module, mappings_module} and
             function_exported?(mappings_module, :__mappings__, 0),
           do: fail.("mappings: #{inspect(mappings_module)} is no compiled mappings module")

    unless is_atom(model_module) and Code.ensure_compiled(model_module) == {:module, model_module} and
             function_exported?(model_module, :__schema__, 0),
           do:
             fail.(
               "model: #{inspect(model_module)} is no compiled model with __schema__/0 " <>
                 "(the model schema shape, AtlasCodeBoundary.Generator.ModelSchema)"
             )

    model_schema = model_module.__schema__()

    case ModelSchema.validate(model_schema) do
      :ok ->
        :ok

      {:error, reasons} ->
        fail.(
          "model: #{inspect(model_module)}.__schema__/0 is not the model schema shape: " <>
            Enum.join(reasons, "; ")
        )
    end

    file = mappings_module.__info__(:compile)[:source] |> to_string()
    entities = Map.new(model_schema.entities, &{&1.name, &1})
    contract_models = Map.new(schema.models, &{&1.name, &1})
    mappings = mappings_module.__mappings__()
    by_entity = Map.new(mappings, &{&1.model, &1})

    model_module_of = fn name ->
      Module.concat(model_module, Macro.camelize(Atom.to_string(name)))
    end

    planned =
      for mapping <- mappings do
        fail_at = &raise(CompileError, file: file, line: mapping.line, description: &1)
        at = "defmapping #{inspect(mapping.model)} -> #{inspect(mapping.boundary)}"

        entity =
          entities[mapping.model] ||
            fail_at.("#{at}: the model has no entity #{inspect(mapping.model)}")

        model = model_module_of.(mapping.model)

        unless Code.ensure_compiled(model) == {:module, model} and
                 function_exported?(model, :new, 1),
               do: fail_at.("#{at}: the model has no struct module #{inspect(model)} with new/1")

        boundary =
          contract_models[mapping.boundary] ||
            fail_at.("#{at}: the contract has no model #{inspect(mapping.boundary)}")

        fields =
          fields!(mapping, entity, boundary, by_entity, entities, contract_models, at, fail_at)

        {mapping.model,
         %{
           model: mapping.model,
           boundary: mapping.boundary,
           direction: mapping.direction,
           model_module: model,
           boundary_module: Map.fetch!(boundary_modules, mapping.boundary),
           fields: fields,
           drop: mapping.drop,
           supply: mapping.supply,
           outcomes:
             for(
               {name, {module, model}} <- outcomes,
               model == mapping.boundary,
               do: {name, module}
             ),
           line: mapping.line
         }}
      end

    plans = Map.new(planned)

    # A supplied required field can only be passed to a translation on its own, never to
    # one inside another.
    for {_key, plan} <- plans, {_m, _b, conversion} <- plan.fields, inner <- held(conversion) do
      held = plans[inner]
      required = for f <- contract_models[held.boundary].fields, f.required, do: f.name

      for field <- held.supply, field in required do
        raise CompileError,
          file: file,
          line: held.line,
          description:
            "defmapping #{inspect(held.model)} -> #{inspect(held.boundary)}: the required field " <>
              "#{held.boundary}.#{field} is supplied, but #{plan.model} holds #{held.model}, " <>
              "and nothing can supply it there"
      end
    end

    to =
      for {key, %{direction: :both} = plan} <- planned, reduce: %{} do
        acc ->
          if Map.has_key?(acc, plan.boundary_module),
            do:
              raise(CompileError,
                file: file,
                line: plan.line,
                description:
                  "defmapping #{inspect(key)} -> #{inspect(plan.boundary)}: another mapping " <>
                    "maps #{inspect(plan.boundary)} both ways already"
              )

          Map.put(acc, plan.boundary_module, key)
      end

    %{
      from: Map.new(planned, fn {key, plan} -> {plan.model_module, key} end),
      to: to,
      mappings: plans
    }
  end

  defp fields!(mapping, entity, boundary, by_entity, entities, contract_models, at, fail) do
    model_fields = Map.new(entity.fields, &{&1.name, &1})
    boundary_fields = Map.new(boundary.fields, &{&1.name, &1})
    rename = Map.new(mapping.rename)
    values = Map.new(mapping.values)

    for name <- Map.keys(rename) ++ mapping.drop ++ Map.keys(values),
        not is_map_key(model_fields, name),
        do: fail.("#{at}: model entity #{inspect(mapping.model)} has no field #{inspect(name)}")

    for name <- Map.values(rename) ++ mapping.supply,
        not is_map_key(boundary_fields, name),
        do:
          fail.(
            "#{at}: boundary model #{inspect(mapping.boundary)} has no field #{inspect(name)}"
          )

    given =
      for field <- entity.fields, field.name not in mapping.drop do
        target = Map.get(rename, field.name, field.name)

        unless is_map_key(boundary_fields, target),
          do:
            fail.(
              "#{at}: model field #{mapping.model}.#{field.name} has no field in " <>
                "#{inspect(mapping.boundary)}: rename it onto one, or drop it"
            )

        {field.name, target}
      end

    # One boundary field, one model field: a kept field and another renamed onto it (or
    # two renamed onto it) would both be written, the last one winning at run time.
    for {target, sources} <- Enum.group_by(given, &elem(&1, 1), &elem(&1, 0)),
        match?([_, _ | _], sources),
        do:
          fail.(
            "#{at}: boundary field #{mapping.boundary}.#{target} is given by " <>
              "#{length(sources)} model fields, " <>
              Enum.map_join(sources, " and ", &"#{mapping.model}.#{&1}") <>
              ": rename all but one elsewhere, or drop them"
          )

    for {_model, target} <- given,
        target in mapping.supply,
        do: fail.("#{at}: #{mapping.boundary}.#{target} is given by a model field and supplied")

    targets = Enum.map(given, &elem(&1, 1))

    for field <- boundary.fields,
        field.name not in targets,
        field.name not in mapping.supply,
        do:
          fail.(
            "#{at}: boundary field #{mapping.boundary}.#{field.name} is given by no model " <>
              "field: rename one onto it, or supply it"
          )

    context = %{
      direction: mapping.direction,
      by_entity: by_entity,
      entities: entities,
      contract_models: contract_models,
      fail: fail,
      at: at
    }

    for {model_name, boundary_name} <- given do
      model_field = model_fields[model_name]
      boundary_field = boundary_fields[boundary_name]
      where = "#{mapping.model}.#{model_name} -> #{mapping.boundary}.#{boundary_name}"
      renames = values[model_name]
      conversion = conversion!(model_field.type, boundary_field.type, renames, where, context)

      if renames && not enum?(conversion),
        do: fail.("#{at}: values: #{inspect(model_name)} is no enum field mapped onto an enum")

      {model_name, boundary_name, conversion}
    end
  end

  defp conversion!(model, boundary, _renames, _where, _context)
       when model == boundary and model in @primitives,
       do: :same

  defp conversion!({:enum, model_values}, {:enum, boundary_values}, renames, where, context) do
    renames = renames || []

    for {value, _} <- renames,
        value not in model_values,
        do: context.fail.("#{context.at}: values: #{inspect(value)} is no value of #{where}")

    from = Map.new(model_values, &{&1, Keyword.get(renames, &1, &1)})

    for {value, target} <- from,
        target not in boundary_values,
        do:
          context.fail.(
            "#{context.at}: #{where}: model value #{inspect(value)} is no boundary value" <>
              if(target != value, do: " (renamed #{inspect(target)})", else: "") <>
              "; rename it with values:"
          )

    to =
      if context.direction == :both do
        for value <- boundary_values,
            value not in Map.values(from),
            do:
              context.fail.(
                "#{context.at}: #{where}: boundary value #{inspect(value)} is no model value; " <>
                  "a mapping both ways needs one for each"
              )

        for {target, count} <- Enum.frequencies(Map.values(from)),
            count > 1,
            do:
              context.fail.(
                "#{context.at}: #{where}: two model values become #{inspect(target)}; " <>
                  "a mapping both ways needs one for each"
              )

        Map.new(from, fn {value, target} -> {target, value} end)
      else
        %{}
      end

    {:enum, from, to}
  end

  defp conversion!(:string, {:enum, _values}, _renames, _where, _context), do: :to_enum

  # No model type is a stream: the facade's caller supplies it.
  defp conversion!(_model, :stream, _renames, where, context),
    do:
      context.fail.("#{context.at}: #{where}: a boundary :stream takes no model field; supply it")

  defp conversion!({:list, model}, {:list, boundary}, renames, where, context),
    do: {:list, conversion!(model, boundary, renames, where, context)}

  defp conversion!(
         {:one_of, members},
         {:one_of, boundary_members, tag: tag},
         _renames,
         where,
         context
       ) do
    pairs =
      for member <- members do
        target = mapped!(member, boundary_members, where, context)
        {member, target}
      end

    if context.direction == :both do
      for target <- boundary_members,
          target not in Enum.map(pairs, &elem(&1, 1)),
          do:
            context.fail.(
              "#{context.at}: #{where}: boundary model #{inspect(target)} of the one_of is " <>
                "mapped from no member; a mapping both ways needs one for each"
            )

      for {target, count} <- Enum.frequencies(Enum.map(pairs, &elem(&1, 1))),
          count > 1,
          do:
            context.fail.(
              "#{context.at}: #{where}: two members become #{inspect(target)}; " <>
                "a mapping both ways needs one for each"
            )
    end

    {:one_of, for({member, target} <- pairs, do: {member, target}), tag}
  end

  defp conversion!(model, boundary, _renames, where, context)
       when is_atom(model) and is_atom(boundary) and is_map_key(context.entities, model) and
              is_map_key(context.contract_models, boundary) do
    mapped!(model, [boundary], where, context)
    {:entity, model}
  end

  defp conversion!(model, boundary, _renames, where, context),
    do:
      context.fail.(
        "#{context.at}: #{where}: a model #{describe(model)} cannot become a boundary " <>
          "#{describe(boundary)} by renaming"
      )

  # The boundary model (one of `targets`) that the mapping of model entity `entity` gives.
  defp mapped!(entity, targets, where, context) do
    case context.by_entity[entity] do
      %{boundary: boundary, direction: direction} = _mapping ->
        unless boundary in targets,
          do:
            context.fail.(
              "#{context.at}: #{where}: model entity #{inspect(entity)} is mapped to " <>
                "#{inspect(boundary)}, not to #{Enum.map_join(targets, " or ", &inspect/1)}"
            )

        if context.direction == :both and direction != :both,
          do:
            context.fail.(
              "#{context.at}: #{where}: the mapping of #{inspect(entity)} is one way " <>
                "(direction: :from_model), so this one cannot go both ways"
            )

        boundary

      nil ->
        context.fail.(
          "#{context.at}: #{where}: model entity #{inspect(entity)} has no mapping " <>
            "(defmapping #{inspect(entity)}, #{Enum.map_join(targets, " or ", &inspect/1)})"
        )
    end
  end

  defp enum?({:enum, _, _}), do: true
  defp enum?({:list, inner}), do: enum?(inner)
  defp enum?(_), do: false

  defp held({:entity, entity}), do: [entity]
  defp held({:one_of, members, _tag}), do: Enum.map(members, &elem(&1, 0))
  defp held({:list, inner}), do: held(inner)
  defp held(_), do: []

  defp describe({:enum, _}), do: "enum"
  defp describe({:list, inner}), do: "list of #{describe(inner)}"
  defp describe({:one_of, _}), do: "one_of"
  defp describe({:one_of, _, _}), do: "one_of"
  defp describe({:map, _}), do: "map"
  defp describe(type) when type in @primitives, do: inspect(type)
  defp describe(name), do: "#{inspect(name)}"

  ## Run time

  @doc false
  def from_model(facade, plan, entity, opts) do
    at = "#{inspect(facade)}.from_model"

    key =
      (is_struct(entity) && plan.from[entity.__struct__]) ||
        raise ContractError, "#{at}: no mapping from #{inspect(entity)}"

    mapping = plan.mappings[key]
    opts = options!(opts, [:supply, :as], at)
    supplied = Keyword.get(opts, :supply, [])

    unless Keyword.keyword?(supplied) and Keyword.keys(supplied) -- mapping.supply == [],
      do:
        raise(
          ContractError,
          "#{at}: #{mapping.model} -> #{mapping.boundary} supplies " <>
            "#{inspect(mapping.supply)}, got supply: #{inspect(supplied)}"
        )

    target =
      case Keyword.fetch(opts, :as) do
        :error ->
          mapping.boundary_module

        {:ok, outcome} ->
          case List.keyfind(mapping.outcomes, outcome, 0) do
            {_name, module} ->
              module

            nil ->
              raise ContractError,
                    "#{at}: as: #{inspect(outcome)} is no outcome carrying #{inspect(mapping.boundary)} " <>
                      "(#{inspect(Enum.map(mapping.outcomes, &elem(&1, 0)))})"
          end
      end

    plan
    |> from_fields(mapping, entity)
    |> Map.merge(Map.new(supplied))
    |> target.new()
  end

  @doc false
  def to_model(facade, plan, value, opts) do
    at = "#{inspect(facade)}.to_model"

    key =
      (is_struct(value) && plan.to[value.__struct__]) ||
        raise ContractError, "#{at}: no mapping both ways for #{inspect(value)}"

    mapping = plan.mappings[key]

    with {:error, reasons} <- mapping.boundary_module.validate(value),
         do: raise(ContractError, "#{at}: invalid value: #{Enum.join(reasons, "; ")}")

    opts = options!(opts, [:with], at)
    extra = Keyword.get(opts, :with, [])

    unless Keyword.keyword?(extra) and Keyword.keys(extra) -- mapping.drop == [],
      do:
        raise(
          ContractError,
          "#{at}: with: takes the fields #{mapping.boundary} does not give " <>
            "(#{inspect(mapping.drop)}), got #{inspect(extra)}"
        )

    plan
    |> to_fields(mapping, value)
    |> Map.merge(Map.new(extra))
    |> mapping.model_module.new()
  end

  defp options!(opts, allowed, at) do
    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [],
      do:
        raise(
          ContractError,
          "#{at}: the options are #{Enum.map_join(allowed, ", ", &"#{&1}:")}, got #{inspect(opts)}"
        )

    opts
  end

  defp from_fields(plan, mapping, entity) when is_map(entity) do
    for {model, boundary, conversion} <- mapping.fields,
        into: %{},
        do: {boundary, from_value(plan, conversion, Map.get(entity, model))}
  end

  # Not an entity: the boundary's new/1 refuses it, naming where.
  defp from_fields(_plan, _mapping, other), do: other

  defp from_value(_plan, _conversion, nil), do: nil
  defp from_value(_plan, :same, value), do: value
  defp from_value(_plan, :to_enum, value), do: value
  defp from_value(_plan, {:enum, from, _to}, value), do: Map.get(from, value, value)

  defp from_value(plan, {:entity, key}, value),
    do: from_fields(plan, plan.mappings[key], value)

  defp from_value(plan, {:one_of, members, tag}, value) do
    case member(plan, members, value) do
      {key, boundary} -> plan |> from_fields(plan.mappings[key], value) |> Map.put(tag, boundary)
      nil -> value
    end
  end

  defp from_value(plan, {:list, inner}, values) when is_list(values),
    do: Enum.map(values, &from_value(plan, inner, &1))

  defp from_value(_plan, _conversion, value), do: value

  defp member(plan, members, %module{}),
    do: Enum.find(members, fn {key, _b} -> plan.mappings[key].model_module == module end)

  defp member(_plan, members, %{kind: kind}), do: List.keyfind(members, kind, 0)
  defp member(_plan, _members, _value), do: nil

  defp to_fields(plan, mapping, value) do
    for {model, boundary, conversion} <- mapping.fields,
        (item = Map.fetch!(value, boundary)) != nil,
        into: %{},
        do: {model, to_value(plan, conversion, item)}
  end

  defp to_value(_plan, :same, value), do: value
  defp to_value(_plan, :to_enum, value), do: Atom.to_string(value)
  defp to_value(_plan, {:enum, _from, to}, value), do: Map.fetch!(to, value)
  defp to_value(plan, {:entity, key}, value), do: to_fields(plan, plan.mappings[key], value)

  defp to_value(plan, {:one_of, members, _tag}, %module{} = value) do
    {key, _boundary} =
      Enum.find(members, fn {key, _b} -> plan.mappings[key].boundary_module == module end)

    plan |> to_fields(plan.mappings[key], value) |> Map.put(:kind, key)
  end

  defp to_value(plan, {:list, inner}, values), do: Enum.map(values, &to_value(plan, inner, &1))
end
