defmodule AtlasRuntimeBackend.Generator.Targets.Json do
  @moduledoc """
  A file target: one backend contract as one JSON file, `<name>.json`, for clients in
  languages other than Elixir: its exposure, rights, events and, per target, its routes
  and the status of each outcome. Names of the boundary's capabilities, models and
  outcomes are as the boundary's own JSON target writes them. Keys are sorted and
  indented by two, so diffs stay small.

      {"version", "exposed": [name], "not_exposed": [name],
       "rights": [{"listener", "rights": [name]}],
       "events": [{"name", "model", "id"?}],
       "targets": [{"name", "carries",
         "resources": [{"method", "path", "capability", "query": {param: field},
                        "headers": {header: field}, "body": [field]?}],
         "streams": [{"path", "capability", "events": [name], "resume_header", "into",
                      "open": {outcome: event | null}}],
         "statuses": [{"outcome", "status"?, "type"?, "by"?,
                       "cases": [{"value", "status", "type"?}]?, "body"?, "headers": {header: field or template}}],
         "errors": [{"kind", "status", "type"}]}]}
  """

  @doc """
  `[{path, body}]`, paths relative to the target's folder. Option `name:` (required) is
  the file's name without `.json`, one per contract.
  """
  def files(schema, opts) do
    name = Keyword.fetch!(opts, :name)

    body =
      %{
        "version" => schema.version,
        "exposed" => texts(schema.exposed),
        "not_exposed" => texts(schema.not_exposed),
        "rights" =>
          Enum.map(
            schema.rights,
            &%{"listener" => text(&1.listener), "rights" => texts(&1.rights)}
          ),
        "events" =>
          Enum.map(schema.events, fn e ->
            put(%{"name" => text(e.name), "model" => text(e.model)}, "id", e.id && text(e.id))
          end),
        "targets" => Enum.map(schema.targets, &target/1)
      }
      |> pretty()

    [{name <> ".json", body}]
  end

  defp target(target) do
    %{
      "name" => text(target.name),
      "carries" => text(target.carries),
      "resources" => Enum.map(target.resources, &resource/1),
      "streams" => Enum.map(target.streams, &stream/1),
      "statuses" => Enum.map(target.statuses, &status/1),
      "errors" =>
        Enum.map(
          target.errors,
          &%{"kind" => text(&1.kind), "status" => &1.status, "type" => &1.type}
        )
    }
  end

  defp resource(r) do
    %{
      "method" => r.method |> text() |> String.upcase(),
      "path" => r.path,
      "capability" => text(r.capability),
      "query" => Map.new(r.query, fn {q, f} -> {q, text(f)} end),
      "headers" => Map.new(r.headers, fn {h, f} -> {h, text(f)} end)
    }
    |> put("body", r.body && texts(r.body))
  end

  defp stream(s) do
    %{
      "path" => s.path,
      "capability" => text(s.capability),
      "events" => texts(s.events),
      "resume_header" => s.resume_header,
      "into" => text(s.into),
      "open" => Map.new(s.open, fn {o, e} -> {text(o), e && text(e)} end)
    }
  end

  defp status(s) do
    %{
      "outcome" => text(s.outcome),
      "headers" => Map.new(s.headers, fn {h, v} -> {h, if(is_atom(v), do: text(v), else: v)} end)
    }
    |> put("status", s.status)
    |> put("type", s.type)
    |> put("by", s.by && text(s.by))
    |> put("body", Map.get(s, :body) && text(s.body))
    |> put(
      "cases",
      s.by &&
        Enum.map(s.cases, fn c ->
          put(%{"value" => text(c.value), "status" => c.status}, "type", c.type)
        end)
    )
  end

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp text(atom), do: Atom.to_string(atom)
  defp texts(atoms), do: Enum.map(atoms, &text/1)

  defp pretty(value), do: IO.iodata_to_binary(pretty(value, 0)) <> "\n"

  defp pretty(map, _level) when map == %{}, do: "{}"

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
