defmodule AtlasRuntimeBackend.Generator.Targets.Routes do
  @moduledoc """
  A file target: one target block of a backend contract as `routes.json`, the route
  table for clients in languages other than Elixir: per route its method, path, the
  request parts bound to input fields, and the status, problem type and headers of each
  outcome; the target's own errors; and the events its streams carry. It is the same
  table the router of `AtlasRuntimeBackend.Generator.Targets.Rest` answers by
  (`__routes__/0`), as JSON. Keys are sorted and indented by two.

      {"version", "target", "carries",
       "listeners": [{"name", "rights": [name]}],
       "events": [{"name", "model", "id"?}],
       "errors": [{"kind", "status", "type"}],
       "routes": [{"method", "path", "capability", "right", "params": [name],
                   "query": {param: {"field", "required"}},
                   "headers": {header: {"field", "required"}}, "body": [field]?,
                   "etag": {"field", "request_header", "not_modified"}?,
                   "stream": {"events", "resume_header", "into"}?,
                   "outcomes": [{"outcome", "status"?, "type"?, "by"?,
                                 "cases": [{"value", "status", "type"?}]?, "body"?,
                                 "stream"?, "content_type"?,
                                 "headers": {header: field or template},
                                 "opens_with"?}]}]}

  A path is written with `{name}` for each parameter (`/v1/books/{book_id}`). Header
  names are lowercase. A header's value is an outcome field's name, or a text whose
  `{field.field}` placeholders are filled from the outcome. A route with `etag` answers
  `ETag` on its success outcomes and `not_modified` (304, no body) to a matching
  `If-None-Match`. A stream route's outcomes are 200 `text/event-stream`, opened by the
  event `opens_with` (or none). An outcome with `"stream": field` is sent as bytes: its
  body is that field's byte stream with the outcome's `content_type` (chunked, no JSON),
  and its other fields are only in its `headers`.

  Options: `target:` the target block (default: the contract's only one). `name:` (the
  contract's name, as `mix runtime_backend.gen` gives it) puts the file in a folder of
  that name, `<name>/routes.json`, so the contracts of one router each have their own;
  without it the file is `routes.json`.
  """

  @options [:name, :target]

  @doc "`[{\"<name>/routes.json\", body}]` (`[{\"routes.json\", body}]` without `name:`)."
  def files(schema, opts) do
    for {key, _} <- opts,
        key not in @options,
        do: raise(ArgumentError, "routes: unknown option #{inspect(key)}")

    target = target!(schema, opts[:target])
    boundary = schema.boundary.__schema__()
    capabilities = Map.new(boundary.capabilities, &{&1.name, &1})
    models = Map.new(boundary.models, &{&1.name, &1})
    statuses = Map.new(target.statuses, &{&1.outcome, &1})

    routes =
      Enum.map(target.resources, &resource(&1, capabilities, models, statuses)) ++
        Enum.map(target.streams, &stream(&1, capabilities))

    body =
      %{
        "version" => schema.version,
        "target" => text(target.name),
        "carries" => text(target.carries),
        "listeners" =>
          Enum.map(schema.rights, &%{"name" => text(&1.listener), "rights" => texts(&1.rights)}),
        "events" =>
          Enum.map(schema.events, fn e ->
            put(%{"name" => text(e.name), "model" => text(e.model)}, "id", e.id && text(e.id))
          end),
        "errors" =>
          Enum.map(
            target.errors,
            &%{"kind" => text(&1.kind), "status" => &1.status, "type" => &1.type}
          ),
        "routes" => routes
      }
      |> pretty()

    [{file(opts[:name], "routes.json"), body}]
  end

  @doc false
  # A file of a contract's own: in the folder named after the contract, if it has a name.
  def file(nil, file), do: file
  def file(name, file), do: Path.join(to_string(name), file)

  @doc false
  # The target block `name` of a contract's schema (`nil`: its only one).
  def target!(schema, nil) do
    case schema.targets do
      [only] -> only
      _ -> raise ArgumentError, "the contract has several targets; name one with target:"
    end
  end

  def target!(schema, name),
    do:
      Enum.find(schema.targets, &(&1.name == name)) ||
        raise(ArgumentError, "the contract has no target #{inspect(name)}")

  @doc false
  # A contract path with `{name}` for each `:name` parameter.
  def template(path), do: Regex.replace(~r/:([a-z][a-z0-9_]*)/, path, "{\\1}")

  defp resource(r, capabilities, models, statuses) do
    capability = capabilities[r.capability]
    fields = input_fields(capability, models)
    bound = fn {name, field} -> {name, %{"field" => text(field), "required" => fields[field]}} end
    etag = Map.get(r, :etag)

    %{
      "method" => r.method |> text() |> String.upcase(),
      "path" => template(r.path),
      "capability" => text(capability.name),
      "right" => text(capability.right),
      "params" => texts(r.params),
      "query" => Map.new(r.query, bound),
      "headers" => Map.new(r.headers, bound),
      "outcomes" => Enum.map(capability.outcomes, &outcome(statuses[&1.name]))
    }
    |> put("body", r.body && texts(r.body))
    |> put(
      "etag",
      etag &&
        %{"field" => text(etag), "request_header" => "if-none-match", "not_modified" => 304}
    )
  end

  defp stream(s, capabilities) do
    capability = capabilities[s.capability]

    %{
      "method" => "GET",
      "path" => template(s.path),
      "capability" => text(capability.name),
      "right" => text(capability.right),
      "params" => [],
      "query" => %{},
      "headers" => %{},
      "stream" => %{
        "events" => texts(s.events),
        "resume_header" => s.resume_header,
        "into" => text(s.into)
      },
      "outcomes" =>
        for {outcome, event} <- s.open do
          %{
            "outcome" => text(outcome),
            "status" => 200,
            "headers" => %{"content-type" => "text/event-stream"},
            "opens_with" => event && text(event)
          }
        end
    }
  end

  defp outcome(s) do
    %{
      "outcome" => text(s.outcome),
      "headers" => Map.new(s.headers, fn {h, v} -> {h, if(is_atom(v), do: text(v), else: v)} end)
    }
    |> put("status", s.status)
    |> put("type", s.type)
    |> put("by", s.by && text(s.by))
    |> put("body", Map.get(s, :body) && text(s.body))
    |> put("stream", Map.get(s, :stream) && text(s.stream))
    |> put("content_type", Map.get(s, :content_type))
    |> put(
      "cases",
      s.by &&
        Enum.map(s.cases, fn c ->
          put(%{"value" => text(c.value), "status" => c.status}, "type", c.type)
        end)
    )
  end

  defp input_fields(%{input: nil}, _models), do: %{}

  defp input_fields(%{input: input}, models),
    do: Map.new(models[input].fields, &{&1.name, &1.required})

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp text(atom), do: Atom.to_string(atom)
  defp texts(atoms), do: Enum.map(atoms, &text/1)

  @doc false
  # JSON with sorted keys, indented by two, ending in a newline: small diffs.
  def pretty(value), do: IO.iodata_to_binary(pretty(value, 0)) <> "\n"

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
