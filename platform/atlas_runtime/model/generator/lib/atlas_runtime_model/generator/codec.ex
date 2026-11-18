defmodule AtlasRuntimeModel.Generator.Codec do
  @moduledoc """
  What the structs `AtlasRuntimeModel.Generator.Targets.Model` generates do at run time:
  build and check them from plain data (`new`), and turn records into JSON-ready maps and
  back (`encode`, `decode`).

  It works on a table made from `__schema__/0` at compile time:
  `%{name => %{module: module, fields: [{name, type, required}]}}`, where a type is
  `:string`, `:integer`, `:boolean`, `:datetime`, `{:enum, [atom]}`, `{:model, name}`,
  `{:one_of, [name]}` or `{:list, type}`.

  ## Errors

  Every refusal names where it is, as a path such as `book.authors[0].name`:

  - `{:unknown_field, at}`: a field the entity does not declare;
  - `{:missing_field, at}`: a required field without a value;
  - `{:invalid, at, expected}`: a value of the wrong type, or no declared enum value;
  - `{:format_version, found}`: a record file without the declared format version
    (`found` is `nil` when it has none). A record is never migrated silently.

  A datetime is kept in UTC: `new` shifts one in another zone to UTC, so a record equals
  itself after `encode` and `decode`.

  The JSON form: string keys; enums as strings; datetimes as ISO-8601 strings in UTC; a `one_of`
  as its model's fields plus `"kind"`, the model's name; an optional field without a value
  is left out (`null` reads as no value).
  """

  @type error ::
          {:unknown_field, String.t()}
          | {:missing_field, String.t()}
          | {:invalid, String.t(), String.t()}
          | {:format_version, term()}

  @doc "The struct of entity `name` from a map or keyword list with atom keys, or a struct."
  def new(table, name, fields) do
    {:ok, build(table, name, fields, Atom.to_string(name))}
  catch
    {__MODULE__, error} -> {:error, error}
  end

  @doc "`new/3`, raising `ArgumentError` on a refusal."
  def new!(table, name, fields) do
    case new(table, name, fields) do
      {:ok, struct} -> struct
      {:error, error} -> raise ArgumentError, "#{inspect(name)} refused: #{inspect(error)}"
    end
  end

  @doc """
  Record `struct` as a JSON-ready, string-keyed map with `"format_version"`. Checks it
  first and raises `ArgumentError` when it is not valid: an invalid record is never written.
  """
  def encode(table, name, version, struct) do
    Map.put(fields(table, name, struct), "format_version", version)
  end

  @doc "A record from its JSON map, refusing any other format version, or an unknown field."
  def decode(table, name, version, map) when is_map(map) do
    at = Atom.to_string(name)

    case Map.fetch(map, "format_version") do
      {:ok, ^version} -> {:ok, load(table, name, Map.delete(map, "format_version"), at)}
      {:ok, other} -> {:error, {:format_version, other}}
      :error -> {:error, {:format_version, nil}}
    end
  catch
    {__MODULE__, error} -> {:error, error}
  end

  def decode(_table, name, _version, _other),
    do: {:error, {:invalid, Atom.to_string(name), "an object"}}

  @doc "A collection's file: `%{\"format_version\" => version, \"entries\" => [entry]}`."
  def encode_file(table, name, version, structs) when is_list(structs) do
    %{"format_version" => version, "entries" => Enum.map(structs, &fields(table, name, &1))}
  end

  @doc "A collection's records from its file's JSON map."
  def decode_file(table, name, version, %{} = map) do
    at = Atom.to_string(name)

    case map do
      %{"format_version" => ^version, "entries" => entries} = file
      when map_size(file) == 2 and is_list(entries) ->
        {:ok,
         entries
         |> Enum.with_index()
         |> Enum.map(fn {entry, i} -> load(table, name, entry, "#{at}[#{i}]") end)}

      %{"format_version" => ^version, "entries" => _} = file when map_size(file) == 2 ->
        {:error, {:invalid, "#{at}.entries", "a list"}}

      %{"format_version" => ^version} = file ->
        case Map.keys(file) -- ["format_version", "entries"] do
          [unknown | _] -> {:error, {:unknown_field, "#{at}.#{unknown}"}}
          [] -> {:error, {:missing_field, "#{at}.entries"}}
        end

      %{"format_version" => other} ->
        {:error, {:format_version, other}}

      _ ->
        {:error, {:format_version, nil}}
    end
  catch
    {__MODULE__, error} -> {:error, error}
  end

  def decode_file(_table, name, _version, _other),
    do: {:error, {:invalid, Atom.to_string(name), "an object"}}

  @doc """
  The file of a record: `pattern` with each `{param}` filled from `values` (the record, or
  a map with atom keys). A value must be a nonempty file name: no `/`, no `.` or `..`.
  """
  def path(pattern, params, values) do
    Enum.reduce(params, pattern, fn param, path ->
      value = Map.get(values, param)

      unless is_binary(value) and value not in ["", ".", ".."] and
               not String.contains?(value, ["/", "\\", <<0>>]),
             do: raise(ArgumentError, "#{param}: #{inspect(value)} is no file name")

      String.replace(path, "{#{param}}", value)
    end)
  end

  defp fail(error), do: throw({__MODULE__, error})

  defp fields(table, name, struct) do
    %{module: module} = Map.fetch!(table, name)

    unless is_struct(struct, module),
      do: raise(ArgumentError, "expected a #{inspect(module)}, got: #{inspect(struct)}")

    case new(table, name, struct) do
      {:ok, struct} -> dump(table, name, struct)
      {:error, error} -> raise ArgumentError, "#{inspect(name)} is invalid: #{inspect(error)}"
    end
  end

  # new: atom keys, Elixir values.

  defp build(table, name, input, at) do
    %{module: module, fields: fields} = Map.fetch!(table, name)

    input =
      cond do
        is_struct(input, module) -> Map.from_struct(input)
        is_struct(input) -> fail({:invalid, at, "a #{inspect(module)}"})
        is_map(input) -> input
        is_list(input) and Keyword.keyword?(input) -> Map.new(input)
        true -> fail({:invalid, at, "a map"})
      end

    known = Enum.map(fields, &elem(&1, 0))

    case Enum.find(Map.keys(input), &(&1 not in known)) do
      nil -> :ok
      unknown -> fail({:unknown_field, "#{at}.#{key(unknown)}"})
    end

    values =
      for {field, type, required} <- fields do
        at = "#{at}.#{field}"

        case Map.get(input, field) do
          nil when required -> fail({:missing_field, at})
          nil -> {field, nil}
          value -> {field, check(table, type, value, at)}
        end
      end

    struct!(module, values)
  end

  defp check(_table, :string, value, _at) when is_binary(value), do: value
  defp check(_table, :integer, value, _at) when is_integer(value), do: value
  defp check(_table, :boolean, value, _at) when is_boolean(value), do: value

  defp check(_table, :datetime, %DateTime{} = value, _at),
    do: DateTime.shift_zone!(value, "Etc/UTC")

  defp check(_table, {:enum, values}, value, at) do
    if is_atom(value) and value in values, do: value, else: fail({:invalid, at, one_of(values)})
  end

  defp check(table, {:model, name}, value, at), do: build(table, name, value, at)

  defp check(table, {:one_of, names}, value, at) do
    tagged =
      Enum.find(names, &is_struct(value, Map.fetch!(table, &1).module)) ||
        (is_map(value) and not is_struct(value) and Map.get(value, :kind) in names and
           Map.get(value, :kind))

    if tagged,
      do: build(table, tagged, drop_kind(value), at),
      else: fail({:invalid, at, "a struct, or a map with kind: " <> one_of(names)})
  end

  defp check(table, {:list, type}, values, at) when is_list(values) do
    values |> Enum.with_index() |> Enum.map(fn {v, i} -> check(table, type, v, "#{at}[#{i}]") end)
  end

  defp check(_table, type, _value, at), do: fail({:invalid, at, expected(type)})

  defp drop_kind(value) when is_struct(value), do: value
  defp drop_kind(value), do: Map.delete(value, :kind)

  # encode: from a checked struct to string keys and JSON values.

  defp dump(table, name, struct) do
    for {field, type, _required} <- Map.fetch!(table, name).fields,
        (value = Map.fetch!(struct, field)) != nil,
        into: %{},
        do: {Atom.to_string(field), dump_value(table, type, value)}
  end

  defp dump_value(_table, :datetime, value), do: DateTime.to_iso8601(value)
  defp dump_value(_table, {:enum, _}, value), do: Atom.to_string(value)
  defp dump_value(table, {:model, name}, value), do: dump(table, name, value)

  defp dump_value(table, {:one_of, names}, value) do
    name = Enum.find(names, &is_struct(value, Map.fetch!(table, &1).module))
    table |> dump(name, value) |> Map.put("kind", Atom.to_string(name))
  end

  defp dump_value(table, {:list, type}, values),
    do: Enum.map(values, &dump_value(table, type, &1))

  defp dump_value(_table, _primitive, value), do: value

  # decode: from string keys and JSON values, strictly.

  defp load(table, name, map, at) when is_map(map) do
    %{module: module, fields: fields} = Map.fetch!(table, name)
    known = Enum.map(fields, &Atom.to_string(elem(&1, 0)))

    case Enum.find(Map.keys(map), &(&1 not in known)) do
      nil -> :ok
      unknown -> fail({:unknown_field, "#{at}.#{key(unknown)}"})
    end

    values =
      for {field, type, required} <- fields do
        at = "#{at}.#{field}"

        case Map.get(map, Atom.to_string(field)) do
          nil when required -> fail({:missing_field, at})
          nil -> {field, nil}
          value -> {field, load_value(table, type, value, at)}
        end
      end

    struct!(module, values)
  end

  defp load(_table, _name, _other, at), do: fail({:invalid, at, "an object"})

  defp load_value(_table, :string, value, _at) when is_binary(value), do: value
  defp load_value(_table, :integer, value, _at) when is_integer(value), do: value
  defp load_value(_table, :boolean, value, _at) when is_boolean(value), do: value

  defp load_value(_table, :datetime, value, at) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> fail({:invalid, at, expected(:datetime)})
    end
  end

  defp load_value(_table, {:enum, values}, value, at) when is_binary(value) do
    Enum.find(values, &(Atom.to_string(&1) == value)) || fail({:invalid, at, one_of(values)})
  end

  defp load_value(table, {:model, name}, value, at), do: load(table, name, value, at)

  defp load_value(table, {:one_of, names}, %{"kind" => kind} = value, at) when is_binary(kind) do
    case Enum.find(names, &(Atom.to_string(&1) == kind)) do
      nil -> fail({:invalid, "#{at}.kind", one_of(names)})
      name -> load(table, name, Map.delete(value, "kind"), at)
    end
  end

  defp load_value(_table, {:one_of, _names}, value, at) when is_map(value),
    do: fail({:missing_field, "#{at}.kind"})

  defp load_value(table, {:list, type}, values, at) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.map(fn {v, i} -> load_value(table, type, v, "#{at}[#{i}]") end)
  end

  defp load_value(_table, type, _value, at), do: fail({:invalid, at, expected(type)})

  defp expected(:datetime), do: "a datetime (ISO-8601)"
  defp expected({:enum, values}), do: one_of(values)
  defp expected({:model, _}), do: "an object"
  defp expected({:one_of, _}), do: "an object with kind"
  defp expected({:list, _}), do: "a list"
  defp expected(:integer), do: "an integer"
  defp expected(type), do: "a #{type}"

  defp one_of(values), do: "one of " <> Enum.map_join(values, ", ", &Atom.to_string/1)

  defp key(key) when is_binary(key), do: key
  defp key(key) when is_atom(key), do: Atom.to_string(key)
  defp key(key), do: inspect(key)
end
