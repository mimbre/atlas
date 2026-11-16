defmodule AtlasCodeBoundary.Generator.Targets.Json do
  @moduledoc """
  A file target: one contract as one JSON file, `<name>.json`, for clients in languages
  other than Elixir. It has exactly the sections the schema has (`version`, `models`,
  `capabilities`, and `invalid_input` when the contract declares it) and nothing about a
  transport. Keys are sorted and indented by two, so
  diffs stay small.

  A field is `{"name", "type", "required"}`, plus:
  - `"values"` (the names, in order) when its type is or holds an `enum`;
  - `"models"` and `"tag"` when its type is or holds a `one_of`: the value is an object
    of one of the models, with the tag as a member naming that model;
  - `"format": "ISO-8601"` when its type is or holds a `datetime`, a string such as
    `"2026-01-02T03:04:05Z"`.

  `"type"` is `string`, `integer`, `boolean`, `datetime`, `enum`, `one_of`, a model's
  name, `list of <type>` or `map of <type>`. A capability is
  `{"name", "right", "outcomes": [{"name", "model"?}], "input"?}`; `input` and an
  outcome's `model` are left out when there is none. An optional field without a value is
  left out of a value.

  `invalid_input` is `{"outcome", "set": {field: value}, "detail"?}`: the outcome a
  capability that declares it answers on an invalid input, with those field values and the
  reasons as text in the `detail` field.
  """

  @doc """
  `[{path, body}]`, paths relative to the target's folder. Option `name:` (required) is
  the file's name without `.json`, one per contract.
  """
  def files(schema, opts) do
    name = Keyword.fetch!(opts, :name)

    sections =
      [
        models: fn models -> Enum.map(models, &model/1) end,
        capabilities: fn capabilities -> Enum.map(capabilities, &capability/1) end,
        invalid_input: &invalid_input/1
      ]
      |> Enum.filter(fn {key, _render} -> Map.get(schema, key) != nil end)
      |> Map.new(fn {key, render} -> {Atom.to_string(key), render.(Map.fetch!(schema, key))} end)

    body = sections |> Map.put("version", schema.version) |> pretty()
    [{name <> ".json", body}]
  end

  defp model(model),
    do: %{"name" => Atom.to_string(model.name), "fields" => Enum.map(model.fields, &field/1)}

  defp field(field) do
    {type, extra} = type(field.type)

    Map.merge(
      %{"name" => Atom.to_string(field.name), "type" => type, "required" => field.required},
      extra
    )
  end

  defp capability(capability) do
    %{
      "name" => Atom.to_string(capability.name),
      "right" => Atom.to_string(capability.right),
      "outcomes" =>
        Enum.map(capability.outcomes, fn outcome ->
          put_name(%{"name" => Atom.to_string(outcome.name)}, "model", outcome.model)
        end)
    }
    |> put_name("input", capability.input)
  end

  defp invalid_input(%{outcome: outcome, set: set, detail: detail}) do
    %{
      "outcome" => Atom.to_string(outcome),
      "set" => Map.new(set, fn {field, value} -> {Atom.to_string(field), text(value)} end)
    }
    |> put_name("detail", detail)
  end

  defp text(value) when is_atom(value) and not is_boolean(value), do: Atom.to_string(value)
  defp text(value), do: value

  defp put_name(map, _key, nil), do: map
  defp put_name(map, key, name), do: Map.put(map, key, Atom.to_string(name))

  defp type({:list, inner}), do: wrap("list of ", type(inner))
  defp type({:map, inner}), do: wrap("map of ", type(inner))

  defp type({:enum, values}),
    do: {"enum", %{"values" => Enum.map(values, &Atom.to_string/1)}}

  defp type({:one_of, models, tag: tag}),
    do:
      {"one_of", %{"models" => Enum.map(models, &Atom.to_string/1), "tag" => Atom.to_string(tag)}}

  defp type(:datetime), do: {"datetime", %{"format" => "ISO-8601"}}
  defp type(type), do: {Atom.to_string(type), %{}}

  defp wrap(prefix, {type, extra}), do: {prefix <> type, extra}

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
