defmodule AtlasCodeBoundary.Generator.Mappings do
  @moduledoc """
  Mappings between a private model's entities and a boundary contract's models, written
  as a DSL in a module of their own, beside the contract. They name both sides as plain
  atoms only: the module that declares them depends on no model, and they are never part
  of the contract's `__schema__/0` or of a file target. The Boundary target checks them
  against the contract and the model, and generates the translations, where both are at
  hand (`AtlasCodeBoundary.Generator.Targets.Boundary`, options `mappings:` and
  `model:`).

      defmodule MyContracts.LendingMappings do
        use AtlasCodeBoundary.Generator.Mappings

        # model entity :loan_record <-> boundary model :loan, both ways
        defmapping :loan_record, :loan,
          rename: [loan_id: :id],
          drop: [:scan_path],
          values: [wear: [badly_worn: :"badly-worn"]],
          supply: [:status]

        # one way only: model entity -> boundary model
        defmapping :ledger_entry, :closing, direction: :from_model, drop: [:member]
      end

  `defmapping model_entity, boundary_model, options`. A mapping only renames and drops;
  it computes nothing. Options:

  - `direction:` `:both` (the default: `from_model` and `to_model`) or `:from_model`;
  - `rename: [model_field: boundary_field]`: a field that has another name in the
    boundary;
  - `drop: [model_field]`: a private field, never in the boundary model, and absent from
    what `to_model` gives (the caller may pass it);
  - `values: [model_field: [model_value: boundary_value]]`: enum values named otherwise in
    the boundary (each value it does not list keeps its name);
  - `supply: [boundary_field]`: a boundary field no model field gives. The caller of
    `from_model` passes it; `to_model` leaves it out.

  Every other field keeps its name on both sides. What else must hold (every model field
  given or dropped, every boundary field given or supplied, the types fitting) is checked
  by the Boundary target, which knows both sides.

  ## The mappings as data

  The module compiles to `__mappings__/0`, a list of mappings in the order written; the
  Boundary target reads only that:

      [%{model: atom, boundary: atom, direction: :both | :from_model,
         rename: [{atom, atom}], drop: [atom], supply: [atom],
         values: [{atom, [{atom, atom}]}], line: pos_integer}]

  Everything but `line` (where the mapping is written, for error messages) is an atom or
  a list of atoms.
  """

  @options [:direction, :rename, :drop, :values, :supply]

  defmacro __using__(_opts) do
    quote do
      import AtlasCodeBoundary.Generator.Mappings, only: [defmapping: 2, defmapping: 3]
      Module.register_attribute(__MODULE__, :mapping_entries, accumulate: true)
      @before_compile AtlasCodeBoundary.Generator.Mappings
    end
  end

  defmacro defmapping(model, boundary, opts \\ []) do
    %{file: file, line: line} = __CALLER__

    quote do
      @mapping_entries AtlasCodeBoundary.Generator.Mappings.__entry__(
                         unquote(model),
                         unquote(boundary),
                         unquote(opts),
                         unquote(file),
                         unquote(line)
                       )
    end
  end

  @doc false
  def __entry__(model, boundary, opts, file, line) do
    fail = &raise(CompileError, file: file, line: line, description: "defmapping: " <> &1)

    unless snake?(model), do: fail.("the model entity #{inspect(model)} is no snake_case atom")

    unless snake?(boundary),
      do: fail.("the boundary model #{inspect(boundary)} is no snake_case atom")

    at = "#{model} -> #{boundary}"

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- @options == [] and
             Enum.uniq(Keyword.keys(opts)) == Keyword.keys(opts),
           do: fail.("#{at}: the options are direction:, rename:, drop:, values: and supply:")

    direction = Keyword.get(opts, :direction, :both)

    unless direction in [:both, :from_model],
      do: fail.("#{at}: direction: is :both or :from_model, got #{inspect(direction)}")

    rename = Keyword.get(opts, :rename, [])
    drop = Keyword.get(opts, :drop, [])
    supply = Keyword.get(opts, :supply, [])
    values = Keyword.get(opts, :values, [])

    unless pairs?(rename), do: fail.("#{at}: rename: is [model_field: boundary_field]")
    unless names?(drop), do: fail.("#{at}: drop: is [model_field]")
    unless names?(supply), do: fail.("#{at}: supply: is [boundary_field]")

    unless Keyword.keyword?(values) and Enum.all?(values, fn {_f, v} -> value_pairs?(v) end),
      do: fail.("#{at}: values: is [model_field: [model_value: boundary_value]]")

    once!(Keyword.keys(rename), "#{at}: rename: names model field", fail)
    once!(Keyword.values(rename), "#{at}: rename: names boundary field", fail)
    once!(drop, "#{at}: drop: names", fail)
    once!(supply, "#{at}: supply: names", fail)
    once!(Keyword.keys(values), "#{at}: values: names", fail)

    for field <- Keyword.keys(rename),
        field in drop,
        do: fail.("#{at}: #{inspect(field)} is both renamed and dropped")

    for field <- Keyword.keys(values),
        field in drop,
        do: fail.("#{at}: #{inspect(field)} is dropped, so it has no values to rename")

    for {field, pairs} <- values do
      once!(Keyword.keys(pairs), "#{at}: values: for #{inspect(field)} names model value", fail)

      once!(
        Keyword.values(pairs),
        "#{at}: values: for #{inspect(field)} names boundary value",
        fail
      )
    end

    %{
      model: model,
      boundary: boundary,
      direction: direction,
      rename: rename,
      drop: drop,
      supply: supply,
      values: values,
      line: line,
      file: file
    }
  end

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:mapping_entries) |> Enum.reverse()

    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      if entry.model in seen,
        do:
          raise(CompileError,
            file: entry.file,
            line: entry.line,
            description: "defmapping: model entity #{inspect(entry.model)} is mapped twice"
          )

      MapSet.put(seen, entry.model)
    end)

    mappings = Enum.map(entries, &Map.delete(&1, :file))

    quote do
      @doc "The mappings as plain data, for the Boundary target (see `AtlasCodeBoundary.Generator.Mappings`)."
      def __mappings__, do: unquote(Macro.escape(mappings))
    end
  end

  defp once!(names, what, fail) do
    for {name, count} <- Enum.frequencies(names),
        count > 1,
        do: fail.("#{what} #{inspect(name)} twice")
  end

  defp pairs?(pairs),
    do: Keyword.keyword?(pairs) and Enum.all?(pairs, fn {k, v} -> snake?(k) and snake?(v) end)

  defp value_pairs?(pairs),
    do: Keyword.keyword?(pairs) and Enum.all?(pairs, fn {_k, v} -> value?(v) end)

  defp names?(names), do: is_list(names) and Enum.all?(names, &snake?/1)

  defp value?(value), do: is_atom(value) and value not in [nil, true, false, :""]

  defp snake?(name),
    do:
      is_atom(name) and name not in [nil, true, false] and
        Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end
