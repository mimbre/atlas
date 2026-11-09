defmodule AtlasRuntimeBoundary.Generator.ModelSchema do
  @moduledoc """
  The model schema shape: the one data shape this generator shares with a model generator
  (a system's private model of entities and their persistence). The Boundary target reads
  it through its `model:` option to check mappings and generate translations
  (`AtlasRuntimeBoundary.Generator.Targets.Boundary`). The two generators share no code,
  only this shape; `validate/1` holds it, and a fixture in this project's tests keeps it
  in step. Change it only together with the model generator.

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

  - Every map has exactly these keys.
  - `persistence` is a map for an entity stored on its own (a record), and `nil` for one
    that exists only inside another.
  - A `type` is `:string`, `:integer`, `:boolean`, `:datetime`, `{:enum, [atom]}`,
    `{:one_of, [entity]}` (at least two), `{:list, type}` or an entity's name.
  - Names are snake_case atoms; entity names are unique, and so are field names within an
    entity.
  """

  @primitives [:string, :integer, :boolean, :datetime]

  @type type ::
          :string
          | :integer
          | :boolean
          | :datetime
          | {:enum, [atom()]}
          | {:one_of, [atom()]}
          | {:list, type()}
          | atom()

  @type t :: %{
          version: String.t(),
          entities: [
            %{
              name: atom(),
              fields: [%{name: atom(), type: type(), required: boolean()}],
              persistence:
                %{form: :json_file, path: String.t(), format_version: pos_integer()} | nil
            }
          ]
        }

  @doc "`:ok` when `schema` has the model schema shape, else `{:error, [reason]}`."
  @spec validate(term()) :: :ok | {:error, [String.t()]}
  def validate(schema) do
    case top(schema) do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp top(%{} = schema) when not is_struct(schema) do
    keys(schema, [:entities, :version], "schema") ++
      version(Map.get(schema, :version)) ++ entities(Map.get(schema, :entities))
  end

  defp top(other), do: ["the schema must be a map, got #{inspect(other)}"]

  defp version(version) when is_binary(version) and version != "", do: []
  defp version(other), do: ["version must be a nonempty string, got #{inspect(other)}"]

  defp entities(entities) when is_list(entities) do
    names = for %{name: name} <- entities, do: name

    duplicates =
      for {name, count} <- Enum.frequencies(names), count > 1, do: "entity #{inspect(name)} twice"

    duplicates ++ Enum.flat_map(entities, &entity(&1, names))
  end

  defp entities(other), do: ["entities must be a list, got #{inspect(other)}"]

  defp entity(%{} = entity, names) when not is_struct(entity) do
    at = "entity #{inspect(Map.get(entity, :name))}"

    keys(entity, [:fields, :name, :persistence], at) ++
      name(Map.get(entity, :name), at) ++
      fields(Map.get(entity, :fields), names, at) ++
      persistence(Map.get(entity, :persistence), at)
  end

  defp entity(other, _names), do: ["an entity must be a map, got #{inspect(other)}"]

  defp fields(fields, names, at) when is_list(fields) do
    duplicates =
      for {name, count} <- Enum.frequencies(for %{name: n} <- fields, do: n),
          count > 1,
          do: "#{at}: field #{inspect(name)} twice"

    duplicates ++
      Enum.flat_map(fields, fn
        %{} = field when not is_struct(field) ->
          at = "#{at}, field #{inspect(Map.get(field, :name))}"

          keys(field, [:name, :required, :type], at) ++
            name(Map.get(field, :name), at) ++
            type(Map.get(field, :type), names, at) ++
            if(is_boolean(Map.get(field, :required)),
              do: [],
              else: ["#{at}: required must be a boolean"]
            )

        other ->
          ["#{at}: a field must be a map, got #{inspect(other)}"]
      end)
  end

  defp fields(other, _names, at), do: ["#{at}: fields must be a list, got #{inspect(other)}"]

  defp persistence(nil, _at), do: []

  defp persistence(%{} = persistence, at) when not is_struct(persistence) do
    at = "#{at}, persistence"

    keys(persistence, [:form, :format_version, :path], at) ++
      if(Map.get(persistence, :form) == :json_file,
        do: [],
        else: ["#{at}: form must be :json_file"]
      ) ++
      if(is_binary(Map.get(persistence, :path)), do: [], else: ["#{at}: path must be a string"]) ++
      case Map.get(persistence, :format_version) do
        version when is_integer(version) and version > 0 -> []
        _ -> ["#{at}: format_version must be a positive integer"]
      end
  end

  defp persistence(other, at),
    do: ["#{at}: persistence must be a map or nil, got #{inspect(other)}"]

  defp type(type, _names, _at) when type in @primitives, do: []

  defp type({:enum, values}, _names, at) do
    if is_list(values) and values != [] and Enum.all?(values, &(is_atom(&1) and &1 != nil)) and
         Enum.uniq(values) == values,
       do: [],
       else: ["#{at}: an enum is {:enum, [atom]}, each value once"]
  end

  defp type({:one_of, members}, names, at) do
    if is_list(members) and length(members) >= 2 and Enum.uniq(members) == members,
      do: for(member <- members, member not in names, do: "#{at}: no entity #{inspect(member)}"),
      else: ["#{at}: a one_of is {:one_of, [entity]}, at least two, each once"]
  end

  defp type({:list, inner}, names, at), do: type(inner, names, at)

  defp type(type, names, at) do
    if is_atom(type) and type in names,
      do: [],
      else: ["#{at}: unknown type #{inspect(type)}"]
  end

  defp name(name, at) do
    if is_atom(name) and name not in [nil, true, false] and
         Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name)),
       do: [],
       else: ["#{at}: a name is a snake_case atom"]
  end

  defp keys(map, expected, at) do
    case Map.keys(map) |> Enum.sort() do
      ^expected ->
        []

      found ->
        missing = expected -- found
        extra = found -- expected

        [
          "#{at} has keys #{inspect(found)}, expected #{inspect(expected)}" <>
            if(missing != [], do: " (missing #{inspect(missing)})", else: "") <>
            if(extra != [], do: " (unknown #{inspect(extra)})", else: "")
        ]
    end
  end
end
