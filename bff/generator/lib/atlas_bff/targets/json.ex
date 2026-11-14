defmodule AtlasBFF.Targets.Json do
  @moduledoc """
  A file target: the contract as one JSON file, `blocks.json`, for clients in languages
  other than Elixir. Keys are sorted and indented by two, so diffs stay small.
  """

  alias AtlasBFF.Names

  @doc "`[{path, body}]`, paths relative to the target's folder; it takes no options."
  def files(schema, _opts \\ []) do
    markup = Names.markup()

    entry = fn e ->
      %{
        "name" => Atom.to_string(e.name),
        "fields" =>
          Enum.map(e.fields, fn f ->
            %{"name" => Atom.to_string(f.name), "type" => type(f.type), "required" => f.required}
          end)
      }
    end

    body =
      %{
        "version" => schema.version,
        "protocol" => wire_data(Map.get(schema, :protocol, [])),
        "wire" => %{
          "block" => ~s({"id": "<id>", "type": "<block>", "props": {...}}),
          markup =>
            ~s({"kind": "<kind>", "start": "<block id>", "end": "<block id>", "group": "<id, on a piece of split #{markup}>", "props": {...}}),
          to_string(Names.view_model_fun()) =>
            ~s({"blocks": [<block>], "#{markup}": [<#{markup}>]}; all #{markup} nests),
          "props" => "an optional prop without a value is left out"
        },
        "models" => Enum.map(schema.models, entry),
        "blocks" => Enum.map(schema.blocks, entry),
        markup => Enum.map(schema.markup, entry),
        "pages" =>
          Enum.map(schema.pages, fn page ->
            %{
              "name" => Atom.to_string(page.name),
              "path" => page.path,
              "params" => Enum.map(page.params, &Atom.to_string/1),
              "returns" => Names.view_model()
            }
          end),
        "endpoints" =>
          Enum.map(schema.endpoints, fn endpoint ->
            %{
              "name" => Atom.to_string(endpoint.name),
              "call" => Atom.to_string(endpoint.call),
              "wire" => endpoint[:wire],
              "path" => endpoint.path || "",
              "params" => Enum.map(endpoint.params, &Atom.to_string/1),
              "replies" =>
                Map.new(endpoint.replies, &{Atom.to_string(&1.name), returns(&1.returns)})
            }
            |> then(
              &if(endpoint.page, do: Map.put(&1, "page", Atom.to_string(endpoint.page)), else: &1)
            )
            |> then(
              &if(endpoint.takes,
                do: Map.put(&1, "takes", Atom.to_string(endpoint.takes)),
                else: &1
              )
            )
          end)
      }
      |> pretty()

    [{"blocks.json", body}]
  end

  defp wire_data({kind, type}), do: "#{kind} of #{type}"
  defp wire_data(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, wire_data(v)} end)
  defp wire_data(list) when is_list(list), do: Enum.map(list, &wire_data/1)
  defp wire_data(value), do: value

  defp returns(:view_model), do: Names.view_model()
  defp returns(other), do: Atom.to_string(other)

  defp type({:list, inner}), do: "list of " <> type(inner)
  defp type({:map, inner}), do: "map of " <> type(inner)
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
