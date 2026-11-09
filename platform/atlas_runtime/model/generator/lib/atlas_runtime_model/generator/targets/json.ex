defmodule AtlasRuntimeModel.Generator.Targets.Json do
  @moduledoc """
  A file target: a model contract as one JSON file, `<name>.json`, the declared persisted
  format. A check of it in CI fails on any unintended change to the format on disk. Keys
  are sorted and indented by two, so diffs stay small. It holds `version`, `entities` (as `__schema__/0` has them; a model's `persistence`
  is `null`) and, when there are records, `encoding`.
  """

  @doc """
  `[{path, body}]`, paths relative to the target's folder, for the contract named `name`
  (its file is `<name>.json`); it takes no options.
  """
  def files(name, schema, _opts \\ []) do
    entity = fn e ->
      %{
        "name" => Atom.to_string(e.name),
        "fields" =>
          Enum.map(e.fields, fn f ->
            %{"name" => Atom.to_string(f.name), "type" => type(f.type), "required" => f.required}
          end),
        "persistence" => persistence(e.persistence)
      }
    end

    body =
      %{"version" => schema.version, "entities" => Enum.map(schema.entities, entity)}
      |> then(fn json ->
        if Enum.any?(schema.entities, & &1.persistence),
          do: Map.put(json, "encoding", encoding()),
          else: json
      end)
      |> pretty()

    [{"#{name}.json", body}]
  end

  defp persistence(nil), do: nil

  defp persistence(p) do
    %{"form" => Atom.to_string(p.form), "path" => p.path, "format_version" => p.format_version}
  end

  # How a record is written; `AtlasRuntimeModel.Generator.Codec` does it.
  defp encoding do
    %{
      "keys" => "strings, the field names",
      "enum" => "the value's name as a string",
      "datetime" => "an ISO-8601 string in UTC",
      "one_of" => "the model's fields plus \"kind\", the model's name",
      "optional" => "a field without a value is left out; null reads as no value",
      "format_version" =>
        "a path with {field}: one record per file, format_version a member of its object; " <>
          "a path without: one file, format_version a member of it, the records under \"entries\"",
      "strict" =>
        "another or no format_version, an unknown field or a wrong value is refused; never migrated silently"
    }
  end

  defp type({:list, inner}), do: "list of " <> type(inner)
  defp type({:enum, values}), do: "enum " <> Enum.map_join(values, " | ", &Atom.to_string/1)
  defp type({:one_of, models}), do: "one of " <> Enum.map_join(models, " | ", &Atom.to_string/1)
  defp type(type), do: Atom.to_string(type)

  defp pretty(value), do: IO.iodata_to_binary(pretty(value, 0)) <> "\n"

  defp pretty(map, level) when is_map(map) do
    inner =
      map
      |> Enum.sort()
      |> Enum.map(fn {k, v} ->
        [indent(level + 1), JSON.encode!(k), ": ", pretty(v, level + 1)]
      end)
      |> Enum.intersperse(",\n")

    ["{\n", inner, "\n", indent(level), "}"]
  end

  defp pretty([], _level), do: "[]"

  defp pretty(list, level) when is_list(list) do
    inner =
      list |> Enum.map(&[indent(level + 1), pretty(&1, level + 1)]) |> Enum.intersperse(",\n")

    ["[\n", inner, "\n", indent(level), "]"]
  end

  defp pretty(value, _level), do: JSON.encode!(value)

  defp indent(level), do: String.duplicate("  ", level)
end
