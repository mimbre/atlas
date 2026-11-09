defmodule RelaDSL.Facts.Served do
  @moduledoc """
  The schema as the pinned rela (26.11.2) serves it at `GET /_schema`, worked out from the
  schema a composition writes (`schema.yaml` and the files it includes), so a store can
  check at boot that rela runs the schema it was built with. Only `entities`, `relations`
  and `types`: what rela adds of its own (`worlds`, `capabilities`) is no part of a
  schema.

  What rela does to the written schema:

    * a kind loses its `aliases`, gets `id_prefixes` (`[id_prefix]`) when it has an
      `id_prefix`, and a `primary` field when it names none: among its required text
      fields `title`, else `name`, else the first by name;
    * a field loses `unique`, is `required: false` unless it is required, serves its
      `default` as text, and carries the `values` and `labels` of its type;
    * a type loses its `description`, `descriptions` and `validations`, and has
      `values` (nil when it has none);
    * relations are served as written; a schema without types has no `types`.
  """

  @doc "The schema (`%{\"entities\", \"relations\", \"types\"}`, plain maps) as rela serves it."
  def of(schema) do
    types = schema["types"] || %{}

    served = %{
      "entities" => Map.new(schema["entities"] || %{}, fn {k, s} -> {k, entity(s, types)} end),
      "relations" => schema["relations"] || %{}
    }

    # A schema without types is served without the key.
    if types == %{},
      do: served,
      else: Map.put(served, "types", Map.new(types, fn {k, t} -> {k, type(t)} end))
  end

  defp entity(spec, types) do
    properties =
      Map.new(spec["properties"] || %{}, fn {name, prop} -> {name, property(prop, types)} end)

    spec =
      spec
      |> Map.delete("aliases")
      |> Map.put("properties", properties)

    spec =
      if is_binary(spec["id_prefix"]) and not Map.has_key?(spec, "id_prefixes"),
        do: Map.put(spec, "id_prefixes", [spec["id_prefix"]]),
        else: spec

    if spec["primary"], do: spec, else: put_primary(spec)
  end

  defp property(prop, types) do
    type = types[prop["type"]] || %{}

    prop =
      prop
      |> Map.delete("unique")
      |> Map.put_new("required", false)

    prop =
      case prop do
        %{"default" => default} when not is_binary(default) and default != nil ->
          Map.put(prop, "default", to_string(default))

        _ ->
          prop
      end

    prop = if is_list(type["values"]), do: Map.put_new(prop, "values", type["values"]), else: prop
    if is_map(type["labels"]), do: Map.put_new(prop, "labels", type["labels"]), else: prop
  end

  defp type(type) do
    type
    |> Map.drop(["description", "descriptions", "validations"])
    |> Map.put_new("values", nil)
  end

  # Among the required text fields: `title`, else `name`, else the first by name.
  defp put_primary(spec) do
    required =
      for {name, %{"type" => "string", "required" => true}} <- spec["properties"] || %{},
          do: name

    case Enum.find(["title", "name"], &(&1 in required)) || List.first(Enum.sort(required)) do
      nil -> spec
      primary -> Map.put(spec, "primary", primary)
    end
  end
end
