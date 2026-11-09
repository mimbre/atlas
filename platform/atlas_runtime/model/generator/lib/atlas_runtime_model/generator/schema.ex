defmodule AtlasRuntimeModel.Generator.Schema do
  @moduledoc """
  The schema of a private model, written as a DSL: entities a system keeps for itself,
  and how each record is persisted. Nothing here is seen by a caller of the system.

      defmodule MyModel do
        use AtlasRuntimeModel.Generator.Schema

        version "0.1.0"

        type :genre, values: [:novel, :poetry]

        defmodel :author do
          field :name, :string, required: true
        end

        defmodel :paper do
          field :pages, :integer, required: true
        end

        defmodel :ebook do
          field :bytes, :integer, required: true
        end

        defrecord :book,
          persist: [form: :json_file, path: "books/{book_id}.json", format_version: 1] do
          field :book_id, :string, required: true
          field :genre, :genre, required: true
          field :authors, {:list, :author}, required: true
          field :edition, {:one_of, [:paper, :ebook]}, required: true
          field :printed_at, :datetime
        end

        defrecord :shelf_entry,
          persist: [form: :json_file, path: "books/shelf.json", format_version: 1] do
          field :book_id, :string, required: true
        end
      end

  - `version`: the model's version, a nonempty string; required.
  - `type`: a named enum, `type :name, values: [atoms]`. A shorthand only: in the schema a
    field of that type is `{:enum, atoms}`. JSON holds a value's name as a string.
  - `defmodel`: an entity a record or another entity holds; it has no file of its own.
  - `defrecord`: an entity persisted on its own, with its persistence form (`persist:`):
    - `form: :json_file`, the only form for now;
    - `path:`, relative to the system's home. Each `{field}` is filled from a required
      string field of the record: one record per file (`books/{book_id}.json`). A path
      without `{field}` is one file holding all records of the entity, under `"entries"`
      (`books/shelf.json`);
    - `format_version:`, a positive integer written into every file of the record and
      checked when one is read.
  - `field`: a snake_case name, a type and `required: true | false` (default `false`).
    Types: `:string`, `:integer`, `:boolean`, `:datetime`, a named enum, an inline enum
    `{:enum, [atoms]}`, a model by its name, `{:one_of, [models]}` (a union of models,
    tagged by the model's name) or `{:list, type}`. A record is never a field's type: it
    is stored on its own.

  Reserved: a record has no field `format_version`, a model in a `one_of` no field `kind`.
  A mistake fails at compile time and points at its line.

  ## The schema as data: the model schema shape

  A contract compiles to one function, `__schema__/0`, and the targets read only that. Its
  value is the documented model schema shape (design §1.7, D36), which another generator
  (the boundary's) reads too; change it only together with that one:

      %{
        version: String.t(),
        entities: [
          %{
            name: atom,
            fields: [%{name: atom, type: type, required: boolean}],
            persistence: %{form: :json_file, path: String.t(), format_version: pos_integer}
                         | nil
          }
        ]
      }

  Entities and fields are in the order written. `persistence` is `nil` for a model (held
  inside a record, no file of its own). A `type` is a primitive (`:string`, `:integer`,
  `:boolean`, `:datetime`), `{:enum, [atom]}` (named enums resolved), `{:one_of, [entity]}`,
  `{:list, type}`, or an entity's name.
  """

  @primitives [:string, :integer, :boolean, :datetime]
  @persist_keys [:form, :path, :format_version]

  @doc "The primitive types."
  def primitives, do: @primitives

  @doc """
  The fields a persistence path is filled from, in order: `"books/{book_id}.json"` gives
  `[:book_id]`. A path without any holds all records of its entity in one file.
  """
  def params(path) do
    for [_, param] <- Regex.scan(~r/\{([^}]*)\}/, path),
        do: if(Regex.match?(~r/^[a-z][a-z0-9_]*$/, param), do: String.to_atom(param), else: param)
  end

  defmacro __using__(_opts) do
    quote do
      import AtlasRuntimeModel.Generator.Schema,
        only: [version: 1, type: 2, defmodel: 2, defrecord: 3, field: 2, field: 3]

      Module.register_attribute(__MODULE__, :model_entries, accumulate: true)
      Module.register_attribute(__MODULE__, :model_version, accumulate: true)
      @before_compile AtlasRuntimeModel.Generator.Schema
    end
  end

  defmacro version(version) do
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      AtlasRuntimeModel.Generator.Schema.__outside__!(__MODULE__, unquote(file), unquote(line))
      @model_version {unquote(version), unquote(file), unquote(line)}
    end
  end

  defmacro type(name, opts) do
    file = __CALLER__.file
    line = __CALLER__.line

    quote do
      AtlasRuntimeModel.Generator.Schema.__outside__!(__MODULE__, unquote(file), unquote(line))

      @model_entries %{
        type: :enum,
        name: unquote(name),
        opts: unquote(opts),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  defmacro defmodel(name, do: body), do: entry(:model, name, [], body, __CALLER__)

  defmacro defrecord(name, opts, do: body), do: entry(:record, name, opts, body, __CALLER__)

  defp entry(type, name, opts, body, %{file: file, line: line}) do
    quote do
      AtlasRuntimeModel.Generator.Schema.__outside__!(__MODULE__, unquote(file), unquote(line))
      Module.put_attribute(__MODULE__, :model_open, unquote(name))
      Module.register_attribute(__MODULE__, :model_fields, accumulate: true)
      unquote(body)

      @model_entries %{
        type: unquote(type),
        name: unquote(name),
        opts: unquote(opts),
        file: unquote(file),
        line: unquote(line),
        fields: Enum.reverse(Module.get_attribute(__MODULE__, :model_fields))
      }

      Module.delete_attribute(__MODULE__, :model_fields)
      Module.delete_attribute(__MODULE__, :model_open)
    end
  end

  defmacro field(name, type, opts \\ []) do
    file = __CALLER__.file
    line = __CALLER__.line

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:required] == [] and
             is_boolean(Keyword.get(opts, :required, false)) do
      __fail__(file, line, "field #{inspect(name)}: the only option is required: true | false")
    end

    quote do
      unless Module.get_attribute(__MODULE__, :model_open) do
        AtlasRuntimeModel.Generator.Schema.__fail__(
          unquote(file),
          unquote(line),
          "field #{inspect(unquote(name))} outside a model or record"
        )
      end

      @model_fields %{
        name: unquote(name),
        type: unquote(type),
        required: unquote(Keyword.get(opts, :required, false)),
        file: unquote(file),
        line: unquote(line)
      }
    end
  end

  @doc false
  def __outside__!(module, file, line) do
    if open = Module.get_attribute(module, :model_open),
      do: __fail__(file, line, "a declaration inside #{inspect(open)}")
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:model_entries) |> Enum.reverse()
    version = version!(env)
    names(entries)

    enums = Map.new(for %{type: :enum} = e <- entries, do: {e.name, enum!(e)})
    kinds = kinds(entries)

    one_of_variants =
      for %{type: t} = m when t in [:model, :record] <- entries,
          f <- m.fields,
          v <- variants(f.type),
          uniq: true,
          do: v

    for %{type: :model} = e <- entries,
        e.name in one_of_variants,
        f <- e.fields,
        f.name == :kind,
        do: __fail__(f.file, f.line, "#{e.name}.kind: a model in a one_of has no field kind")

    entities =
      for %{type: t} = e <- entries, t in [:model, :record] do
        fields!(e, kinds)

        %{
          name: e.name,
          fields:
            Enum.map(e.fields, fn f ->
              %{name: f.name, type: resolve(f.type, enums), required: f.required}
            end),
          persistence: if(t == :record, do: persistence!(e))
        }
      end

    spec = %{version: version, entities: entities}

    quote do
      @doc "The model as plain data, the model schema shape (see `AtlasRuntimeModel.Generator.Schema`)."
      def __schema__, do: unquote(Macro.escape(spec))
    end
  end

  defp version!(env) do
    case Module.get_attribute(env.module, :model_version) do
      [{version, file, line}] ->
        unless is_binary(version) and version != "",
          do: __fail__(file, line, "version: a nonempty string")

        version

      [] ->
        __fail__(env.file, 1, "the model needs a version: version \"0.1.0\"")

      [{_, file, line} | _] ->
        __fail__(file, line, "version is given twice")
    end
  end

  # A named enum becomes {:enum, values}; the schema shape has no named enums.
  defp resolve({:list, inner}, enums), do: {:list, resolve(inner, enums)}
  defp resolve(type, enums) when is_map_key(enums, type), do: {:enum, Map.fetch!(enums, type)}
  defp resolve(type, _enums), do: type

  defp variants({:one_of, models}) when is_list(models), do: models
  defp variants({:list, inner}), do: variants(inner)
  defp variants(_), do: []

  # Names are snake_case and unique across enums, models and records, and clash with no
  # primitive.
  defp names(entries) do
    Enum.reduce(entries, MapSet.new(), fn entry, seen ->
      fail = &__fail__(entry.file, entry.line, &1)
      unless snake?(entry.name), do: fail.("#{inspect(entry.name)} is not a snake_case atom")
      if entry.name in seen, do: fail.("#{inspect(entry.name)} is defined twice")

      if entry.name in @primitives,
        do: fail.("#{inspect(entry.name)} clashes with a primitive type")

      MapSet.put(seen, entry.name)
    end)
  end

  defp kinds(entries) do
    names = fn type -> for %{type: ^type, name: name} <- entries, do: name end
    %{enums: names.(:enum), models: names.(:model), records: names.(:record)}
  end

  defp enum!(%{name: name, opts: opts, file: file, line: line}) do
    fail = &__fail__(file, line, &1)

    unless Keyword.keyword?(opts) and Keyword.keys(opts) == [:values],
      do: fail.("type #{inspect(name)}: the only option is values: [atoms]")

    values!(opts[:values], "type #{inspect(name)}", fail)
  end

  defp values!(values, at, fail) do
    unless is_list(values) and values != [] and Enum.all?(values, &snake?/1),
      do: fail.("#{at}: values are a nonempty list of snake_case atoms")

    if Enum.uniq(values) != values, do: fail.("#{at}: a value is listed twice")

    if Enum.any?(values, &(&1 in [nil, true, false])),
      do: fail.("#{at}: nil, true and false are no enum values")

    values
  end

  defp fields!(entry, kinds) do
    Enum.reduce(entry.fields, MapSet.new(), fn field, names ->
      fail = &__fail__(field.file, field.line, &1)
      at = "#{entry.name}.#{field.name}"

      unless snake?(field.name),
        do: fail.("field #{inspect(field.name)} is not a snake_case atom")

      if field.name in names,
        do: fail.("#{inspect(entry.name)} has field #{inspect(field.name)} twice")

      if entry.type == :record and field.name == :format_version,
        do: fail.("#{at}: format_version is reserved for the persistence form")

      check_type!(field.type, kinds, at, fail)
      MapSet.put(names, field.name)
    end)

    :ok
  end

  defp check_type!(type, _kinds, _at, _fail) when type in @primitives, do: :ok
  defp check_type!({:list, inner}, kinds, at, fail), do: check_type!(inner, kinds, at, fail)

  defp check_type!({:enum, values}, _kinds, at, fail) do
    values!(values, at, fail)
    :ok
  end

  defp check_type!({:one_of, models}, kinds, at, fail) do
    unless is_list(models) and length(models) >= 2 and Enum.uniq(models) == models,
      do: fail.("#{at}: a one_of names two or more distinct models")

    for model <- models,
        model not in kinds.models,
        do: fail.("#{at}: one_of variant #{inspect(model)} is no model")

    :ok
  end

  defp check_type!(type, kinds, at, fail) do
    cond do
      type in kinds.enums or type in kinds.models ->
        :ok

      type in kinds.records ->
        fail.("#{at} holds record #{inspect(type)}; a record is stored on its own")

      true ->
        fail.("#{at} has unknown type #{inspect(type)}")
    end
  end

  defp persistence!(%{name: name, opts: opts, fields: fields, file: file, line: line}) do
    fail = &__fail__(file, line, "record #{inspect(name)}: " <> &1)
    persist = Keyword.keyword?(opts) && Keyword.keys(opts) == [:persist] && opts[:persist]

    unless Keyword.keyword?(persist || nil) and Keyword.keys(persist) -- @persist_keys == [],
      do: fail.("needs persist: [form:, path:, format_version:]")

    unless persist[:form] == :json_file, do: fail.("form: :json_file is the only form")
    path = persist[:path]

    unless is_binary(path) and path != "" and not String.starts_with?(path, "/") and
             ".." not in Path.split(path),
           do: fail.("path: a relative path inside the system's home")

    version = persist[:format_version]

    unless is_integer(version) and version > 0,
      do: fail.("format_version: a positive integer")

    for param <- params(path),
        not Enum.any?(fields, &(&1.name == param and &1.type == :string and &1.required)),
        do: fail.("path #{path}: {#{param}} is no required string field")

    %{form: :json_file, path: path, format_version: version}
  end

  defp snake?(name),
    do: is_atom(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end
