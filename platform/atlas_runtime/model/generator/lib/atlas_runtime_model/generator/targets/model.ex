defmodule AtlasRuntimeModel.Generator.Targets.Model do
  @moduledoc """
  A compile-time target: the private structs of a model contract and their persistence,
  made from its `__schema__/0` when the module that uses it compiles. No file is written
  (ADR-0001).

      defmodule MySystem.Model.Books do
        use AtlasRuntimeModel.Generator.Targets.Model, contract: MyModel
      end

  It defines, under that module, one module per model and record, named after it
  (`MySystem.Model.Books.Author`, `MySystem.Model.Books.Book`). Each has:

  - a plain struct with `@enforce_keys` for its required fields and a precise `@type t`:
    enums are unions of atoms, a `one_of` the union of its models' `t()`, an optional
    field also `nil`;
  - `new/1`: the struct from a map or keyword list with atom keys (or a struct, checked
    again): `{:ok, t}`, or `{:error, error}` for an unknown or missing field, or a value of
    the wrong type (`AtlasRuntimeModel.Generator.Codec` lists the errors); `new!/1` raises.
    A `one_of` value is one of its models' structs, or a map with `kind:` naming one.

  A record's module also has `format_version/0` and `persistence/0` (the form as
  `__schema__/0` has it), and its persistence. For a path with `{field}`s (one record per
  file):

  - `encode/1`: the record as a JSON-ready, string-keyed map with `"format_version"`; it
    raises on an invalid struct, so an invalid record is never written;
  - `decode/1`: the record from such a map: `{:ok, t}`, or `{:error, error}` for another
    (or no) format version, an unknown or missing field, or a wrong value. Never a silent
    migration;
  - `path/1` (from the record, or a map with atom keys): the file, relative to the
    system's home.

  For a path without `{field}` (one file holding all records of the entity):

  - `encode_file/1` and `decode_file/1`: all records of the file, under `"entries"`, with
    one `"format_version"` for the file, refused alike;
  - `path/0`.

  The module that uses it gets `records/0`: `[{name, module}]` in the order written.
  """

  alias AtlasRuntimeModel.Generator.{Codec, Schema}

  defmacro __using__(opts) do
    schema = Macro.expand(opts[:contract], __CALLER__).__schema__()
    parent = __CALLER__.module
    entries = schema.entities
    names = Enum.map(entries, & &1.name)
    module_of = fn name -> Module.concat(parent, Macro.camelize(Atom.to_string(name))) end

    table =
      Map.new(entries, fn entry ->
        {entry.name,
         %{
           module: module_of.(entry.name),
           fields: Enum.map(entry.fields, &{&1.name, norm(&1.type, names), &1.required})
         }}
      end)

    modules =
      for entry <- entries do
        record = entry.persistence

        types =
          for {name, type, required} <- Map.fetch!(table, entry.name).fields,
              do: {name, typespec(type, required, table)}

        required = for %{required: true, name: name} <- entry.fields, do: name

        quote do
          defmodule unquote(module_of.(entry.name)) do
            @moduledoc unquote(moduledoc(entry))
            @table unquote(Macro.escape(table))
            @enforce_keys unquote(required)
            defstruct unquote(Enum.map(entry.fields, & &1.name))

            @type t :: %__MODULE__{unquote_splicing(types)}

            @doc "The struct from a map or keyword list with atom keys, checked."
            @spec new(map() | keyword()) :: {:ok, t()} | {:error, Codec.error()}
            def new(fields), do: Codec.new(@table, unquote(entry.name), fields)

            @doc "`new/1`, raising `ArgumentError` on a refusal."
            @spec new!(map() | keyword()) :: t()
            def new!(fields), do: Codec.new!(@table, unquote(entry.name), fields)

            unquote(if record, do: persistence(entry.name, record))
          end
        end
      end

    quote do
      unquote_splicing(modules)

      @doc "The records of the model, `[{name, module}]`, in the order written."
      def records,
        do:
          unquote(
            for %{persistence: %{}} = r <- schema.entities, do: {r.name, module_of.(r.name)}
          )
    end
  end

  defp persistence(name, record) do
    version = record.format_version

    common =
      quote do
        @doc "The format version written into, and required of, every file of this record."
        @spec format_version() :: pos_integer()
        def format_version, do: unquote(version)

        @doc "The persistence form, as the contract's `__schema__/0` has it."
        def persistence, do: unquote(Macro.escape(record))
      end

    case Schema.params(record.path) do
      [] ->
        quote do
          unquote(common)

          @doc "The file of all records of this entity, relative to the system's home."
          @spec path() :: String.t()
          def path, do: unquote(record.path)

          @doc "All records of the file as its JSON-ready map."
          @spec encode_file([t()]) :: %{String.t() => term()}
          def encode_file(records),
            do: Codec.encode_file(@table, unquote(name), unquote(version), records)

          @doc "All records of the file from its JSON map; another format version or an unknown field is an error."
          @spec decode_file(term()) :: {:ok, [t()]} | {:error, Codec.error()}
          def decode_file(map),
            do: Codec.decode_file(@table, unquote(name), unquote(version), map)
        end

      params ->
        quote do
          unquote(common)

          @doc "The record as a JSON-ready, string-keyed map with \"format_version\"."
          @spec encode(t()) :: %{String.t() => term()}
          def encode(record), do: Codec.encode(@table, unquote(name), unquote(version), record)

          @doc "The record from its JSON map; another format version or an unknown field is an error."
          @spec decode(term()) :: {:ok, t()} | {:error, Codec.error()}
          def decode(map), do: Codec.decode(@table, unquote(name), unquote(version), map)

          @doc "The file of a record (or a map with #{unquote(inspect(params))}), relative to the system's home."
          @spec path(t() | map()) :: String.t()
          def path(values), do: Codec.path(unquote(record.path), unquote(params), values)
        end
    end
  end

  defp moduledoc(entry) do
    kind = if entry.persistence, do: "record", else: "model"
    "The private #{kind} `#{entry.name}` (generated from the model contract)."
  end

  # The schema's types, with an entity reference made explicit for the codec.
  defp norm({:list, inner}, names), do: {:list, norm(inner, names)}
  defp norm({:enum, _} = enum, _names), do: enum
  defp norm({:one_of, _} = one_of, _names), do: one_of
  defp norm(type, names), do: if(type in names, do: {:model, type}, else: type)

  defp typespec(type, true, table), do: spec_ast(type, table)
  defp typespec(type, false, table), do: union([spec_ast(type, table), nil])

  defp spec_ast(:string, _table), do: quote(do: String.t())
  defp spec_ast(:integer, _table), do: quote(do: integer())
  defp spec_ast(:boolean, _table), do: quote(do: boolean())
  defp spec_ast(:datetime, _table), do: quote(do: DateTime.t())
  defp spec_ast({:enum, values}, _table), do: union(values)
  defp spec_ast({:model, name}, table), do: model_t(table, name)
  defp spec_ast({:one_of, names}, table), do: union(Enum.map(names, &model_t(table, &1)))
  defp spec_ast({:list, inner}, table), do: [spec_ast(inner, table)]

  defp model_t(table, name) do
    module = Map.fetch!(table, name).module
    quote(do: unquote(module).t())
  end

  defp union(asts) do
    asts |> Enum.reverse() |> Enum.reduce(fn ast, acc -> {:|, [], [ast, acc]} end)
  end
end
