defmodule AtlasRuntimeBackend.Generator.Targets.Openapi do
  @moduledoc """
  A file target: one target block of a backend contract as `openapi.json` (in the folder
  `<name>/` when the option `name:` is given, as for `...Targets.Routes`), an OpenAPI
  3.1 description of what its router (`AtlasRuntimeBackend.Generator.Targets.Rest`)
  serves. Everything comes from the contract's `__schema__/0` and its boundary's:

  - one operation per method and path. Resources the contract tells apart by their
    required query parameters share one operation, listed in `x-capabilities`; its
    `operationId` joins their names with `_or_`;
  - parameters: the path's, the bound query parameters and headers (each with the
    input field's type), a stream's resume header, and `If-None-Match` on a resource
    with an `etag` field;
  - a JSON request body of the bound body fields, closed to others (the router refuses
    unknown members), or, for a streamed body (`body: {:stream, field}`), a required
    body of its `content_type` with `{"type": "string", "format": "binary"}`;
  - per status, every outcome that answers it, with the declared headers, and the
    body: the outcome's entity (`body:`) or its fields as `application/json` below 400
    (`anyOf` when outcomes differ), or, for an outcome sent as bytes (`stream:`), its
    `content_type` with `{"type": "string", "format": "binary"}`; an
    `application/problem+json` (RFC 9457: `type`,
    `title`, `status`, then the outcome's fields) from 400, `oneOf` by problem type. A
    `by:` status gives one problem per case. Answers of one status that share a problem
    type (a `by:` case and an error of the same type) are one branch that accepts each of
    their bodies: its members are theirs (`anyOf` where they differ), required only where
    all require them. So a body matches exactly one branch;
  - every error of the target on every operation, except `:no_route`, which answers a
    path no operation has (it is under `components.responses`), and `:too_large` and
    `:unsupported_media_type`, which only an operation with a streamed body has;
  - on a resource with `etag`, `ETag` on each success outcome whose body has that field,
    and `304` (no body) for a matching `If-None-Match`;
  - a stream as `200 text/event-stream`, with its events in `x-events` (name, `id:` field
    and data schema) and the event each outcome opens with in `x-opens-with`;
  - the boundary models that some operation reaches, under `components.schemas`.

  There is no `servers` entry: where the backend listens is configuration.

  Options:
  - `security: [listener: :bearer]`: listeners whose clients send
    `Authorization: Bearer <token>`. Each becomes an HTTP bearer scheme named after the
    listener, with its rights in the description. A listener the contract declares no
    `rights` for is an `ArgumentError` (a misspelt name would otherwise drop the scheme
    unnoticed). When other listeners exist (their clients need no credentials, as a
    socket's peer), `security` also allows none (`{}`);
  - `title:` the `info.title` (default: the contract's file name, `name:`);
  - `target:` the target block (default: the contract's only one).
  """

  alias AtlasRuntimeBackend.Generator.Targets.Routes

  @options [:name, :title, :security, :target]
  @upload_errors [:too_large, :unsupported_media_type]
  @binary %{"type" => "string", "format" => "binary"}
  @scalars %{
    string: %{"type" => "string"},
    integer: %{"type" => "integer"},
    boolean: %{"type" => "boolean"},
    datetime: %{"type" => "string", "format" => "date-time"}
  }

  @doc "`[{\"<name>/openapi.json\", body}]` (`[{\"openapi.json\", body}]` without `name:`)."
  def files(schema, opts) do
    for {key, _} <- opts,
        key not in @options,
        do: raise(ArgumentError, "openapi: unknown option #{inspect(key)}")

    security = opts[:security] || []

    unless Keyword.keyword?(security) and Enum.all?(security, &match?({_, :bearer}, &1)),
      do: raise(ArgumentError, "openapi: security: is [listener: :bearer]")

    target = Routes.target!(schema, opts[:target])
    boundary = schema.boundary.__schema__()

    ctx = %{
      capabilities: Map.new(boundary.capabilities, &{&1.name, &1}),
      models: Map.new(boundary.models, &{&1.name, &1}),
      statuses: Map.new(target.statuses, &{&1.outcome, &1}),
      events: Map.new(schema.events, &{&1.name, &1}),
      errors: Enum.reject(target.errors, &(&1.kind in [:no_route | @upload_errors])),
      upload_errors: Enum.filter(target.errors, &(&1.kind in @upload_errors))
    }

    items =
      Enum.map(target.resources, &Map.put(&1, :kind, :resource)) ++
        Enum.map(target.streams, &Map.merge(&1, %{kind: :stream, method: :get}))

    paths =
      items
      |> Enum.group_by(&Routes.template(&1.path))
      |> Map.new(fn {path, on_path} ->
        {path,
         on_path
         |> Enum.group_by(& &1.method)
         |> Map.new(fn {method, group} -> {text(method), operation(group, ctx)} end)}
      end)

    bearer =
      for {listener, :bearer} <- security do
        Enum.find(schema.rights, &(&1.listener == listener)) ||
          raise ArgumentError,
                "openapi: security: names #{inspect(listener)}, a listener the contract " <>
                  "declares no rights for"
      end

    title = opts[:title] || opts[:name] || "backend"

    doc =
      %{
        "openapi" => "3.1.0",
        "info" => %{
          "title" => title,
          "version" => schema.version,
          "description" => description(schema, target, bearer)
        },
        "paths" => paths,
        "components" =>
          %{
            "schemas" => components(items, ctx),
            "responses" =>
              Map.new(
                for e <- target.errors,
                    e.kind == :no_route,
                    do: {text(e.kind), response([{:error, e}], ctx)}
              )
          }
          |> put("securitySchemes", bearer != [] && Map.new(bearer, &scheme/1))
      }
      |> put("security", bearer != [] && requirement(schema.rights, bearer))

    [{Routes.file(opts[:name], "openapi.json"), Routes.pretty(doc)}]
  end

  ## Listeners

  defp description(schema, target, bearer) do
    listeners =
      Enum.map_join(schema.rights, "; ", fn r ->
        auth = if r in bearer, do: "bearer token", else: "the listener's own identity"
        "`#{r.listener}` (#{auth}; rights: #{Enum.map_join(r.rights, ", ", &text/1)})"
      end)

    "Target `#{target.name}` of the backend contract, carrying the boundary's " <>
      "`#{target.carries}`. Listeners: #{listeners}. No servers: where it listens is configuration."
  end

  defp scheme(r) do
    {text(r.listener),
     %{
       "type" => "http",
       "scheme" => "bearer",
       "description" =>
         "Listener `#{r.listener}`: `Authorization: Bearer <token>`; a token's rights are at most " <>
           Enum.map_join(r.rights, ", ", &text/1) <> "."
     }}
  end

  defp requirement(rights, bearer) do
    open = if Enum.any?(rights, &(&1 not in bearer)), do: [%{}], else: []
    open ++ Enum.map(bearer, &%{text(&1.listener) => []})
  end

  ## Operation objects

  defp operation(group, ctx) do
    caps = Enum.map(group, &ctx.capabilities[&1.capability])

    %{
      "operationId" => Enum.map_join(caps, "_or_", &text(&1.name)),
      "parameters" => parameters(group, ctx),
      "responses" => responses(group, ctx)
    }
    |> put("x-capabilities", match?([_, _ | _], group) && Enum.map(group, &choice(&1, ctx)))
    |> put("requestBody", request_body(group, ctx))
  end

  defp choice(item, ctx) do
    %{
      "capability" => text(item.capability),
      "right" => text(ctx.capabilities[item.capability].right),
      "required_query" => Map.get(item, :required, [])
    }
  end

  defp parameters(group, ctx) do
    params =
      for item <- group do
        fields = input_fields(item, ctx)

        path =
          for p <- Map.get(item, :params, []),
              do: {{"path", text(p)}, true, type_schema(fields[p].type)}

        query =
          for {q, f} <- Map.get(item, :query, []),
              do: {{"query", q}, q in item.required, type_schema(fields[f].type)}

        headers =
          for {h, f} <- Map.get(item, :headers, []),
              do: {{"header", h}, fields[f].required, type_schema(fields[f].type)}

        resume =
          if item.kind == :stream,
            do: [{{"header", item.resume_header}, false, @scalars.integer}],
            else: []

        etag =
          if Map.get(item, :etag),
            do: [{{"header", "if-none-match"}, false, @scalars.string}],
            else: []

        path ++ query ++ headers ++ resume ++ etag
      end

    names = params |> List.flatten() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    for {place, name} = key <- names do
      found = for list <- params, do: Enum.find(list, &(elem(&1, 0) == key))
      [{_, _, schema} | _] = Enum.reject(found, &is_nil/1)
      required = place == "path" or Enum.all?(found, &match?({_, true, _}, &1))
      %{"in" => place, "name" => name, "required" => required, "schema" => schema}
    end
  end

  defp request_body(group, ctx) do
    bodies =
      for item <- group, body = Map.get(item, :body), uniq: true do
        fields = input_fields(item, ctx)
        object(for f <- body, do: fields[f]) |> Map.put("additionalProperties", false)
      end

    uploads =
      for item <- group, upload = Map.get(item, :upload), uniq: true do
        {upload.content_type,
         %{
           "schema" =>
             Map.put(@binary, "description", "the input's `#{upload.field}`, as a byte stream")
         }}
      end

    json =
      case bodies do
        [] ->
          nil

        [one] ->
          %{
            "required" => one["required"] != [],
            "content" => %{"application/json" => %{"schema" => one}}
          }

        several ->
          %{"content" => %{"application/json" => %{"schema" => %{"oneOf" => several}}}}
      end

    case {json, uploads} do
      {json, []} ->
        json

      {nil, uploads} ->
        %{"required" => true, "content" => Map.new(uploads)}

      {json, uploads} ->
        %{"content" => Map.merge(json["content"], Map.new(uploads))}
    end
  end

  ## Responses

  # Each answer is {:outcome, item, status, case | nil}, {:error, error} or {:not_modified, item}.
  defp responses(group, ctx) do
    answers =
      for item <- group,
          o <- ctx.capabilities[item.capability].outcomes,
          answer <- answers(item, o, ctx) do
        answer
      end

    uploads? = Enum.any?(group, &Map.get(&1, :upload))

    answers =
      answers ++
        Enum.map(ctx.errors, &{:error, &1}) ++
        if(uploads?, do: Enum.map(ctx.upload_errors, &{:error, &1}), else: []) ++
        for(item <- group, Map.get(item, :etag), do: {:not_modified, item})

    answers
    |> Enum.group_by(&code/1)
    |> Map.new(fn {code, list} -> {Integer.to_string(code), response(list, ctx)} end)
  end

  defp answers(%{kind: :stream} = item, outcome, _ctx), do: [{:stream, item, outcome.name}]

  defp answers(item, outcome, ctx) do
    status = ctx.statuses[outcome.name]

    if status.by,
      do: for(c <- status.cases, do: {:outcome, item, status, c}),
      else: [{:outcome, item, status, nil}]
  end

  defp code({:outcome, _item, %{by: nil, status: code}, nil}), do: code
  defp code({:outcome, _item, _status, c}), do: c.status
  defp code({:stream, _item, _outcome}), do: 200
  defp code({:error, e}), do: e.status
  defp code({:not_modified, _item}), do: 304

  defp response(answers, ctx) do
    code = code(hd(answers))

    %{"description" => answers |> Enum.map(&describe/1) |> Enum.uniq() |> Enum.join("; ")}
    |> put("headers", headers(answers, ctx))
    |> put("content", content(code, answers, ctx))
  end

  defp describe({:outcome, _item, s, nil}), do: "outcome `#{s.outcome}`"
  defp describe({:outcome, _item, s, c}), do: "outcome `#{s.outcome}` (#{s.by} `#{c.value}`)"
  defp describe({:stream, item, o}), do: "outcome `#{o}` of `#{item.capability}`: the stream"
  defp describe({:error, e}), do: "error `#{e.kind}`"

  defp describe({:not_modified, item}),
    do: "not modified: `If-None-Match` names the current `ETag` (`#{item.etag}`)"

  defp content(304, _answers, _ctx), do: nil

  defp content(_code, [{:stream, _, _} | _] = answers, ctx) do
    {:stream, item, _} = hd(answers)

    %{
      "text/event-stream" => %{
        "schema" => %{"type" => "string"},
        "x-events" =>
          for name <- item.events do
            event = ctx.events[name]

            %{"name" => text(name), "data" => ref(event.model)}
            |> put("id", event.id && text(event.id))
          end,
        "x-opens-with" => Map.new(item.open, fn {o, e} -> {text(o), e && text(e)} end)
      }
    }
  end

  defp content(code, answers, ctx) do
    {bytes, json} = Enum.split_with(answers, &bytes?/1)

    bytes =
      Map.new(bytes, fn {:outcome, _item, s, nil} -> {s.content_type, %{"schema" => @binary}} end)

    if json == [], do: bytes, else: Map.merge(json_content(code, json, ctx), bytes)
  end

  # An outcome sent as bytes: its stream field is the body, with its content type.
  defp bytes?({:outcome, _item, s, nil}), do: Map.get(s, :stream) != nil
  defp bytes?(_answer), do: false

  defp json_content(code, answers, ctx) do
    schemas = answers |> Enum.map(&payload(&1, ctx)) |> Enum.uniq()
    schemas = if code >= 400, do: by_type(schemas), else: schemas
    # Problems differ by their type; success bodies need not exclude each other.
    schema =
      case schemas do
        [one] -> one
        several when code >= 400 -> %{"oneOf" => several}
        several -> %{"anyOf" => several}
      end

    type = if code >= 400, do: "application/problem+json", else: "application/json"
    %{type => %{"schema" => schema}}
  end

  # The body of one answer.
  defp payload({:error, e}, _ctx) do
    problem(e.type, e.status, %{"detail" => @scalars.string}, [])
  end

  defp payload({:outcome, _item, s, c}, ctx) do
    model = ctx.capabilities |> outcome_model(s.outcome) |> then(&(&1 && ctx.models[&1]))
    fields = if model, do: model.fields, else: []

    cond do
      c != nil ->
        props = Map.new(fields, &{text(&1.name), type_schema(&1.type)})
        props = Map.put(props, text(s.by), %{"const" => text(c.value)})
        problem(c.type, c.status, props, required(fields))

      s.status >= 400 ->
        problem(
          s.type,
          s.status,
          Map.new(fields, &{text(&1.name), type_schema(&1.type)}),
          required(fields)
        )

      s.body ->
        type_schema(Enum.find(fields, &(&1.name == s.body)).type)

      model ->
        ref(model.name)

      true ->
        %{"type" => "object", "properties" => %{}, "additionalProperties" => false}
    end
  end

  # One problem schema per type, in order: those that share a type are merged.
  defp by_type(problems) do
    types = problems |> Enum.map(&problem_type/1) |> Enum.uniq()
    for t <- types, do: problems |> Enum.filter(&(problem_type(&1) == t)) |> merge()
  end

  defp problem_type(problem), do: problem["properties"]["type"]["const"]

  defp merge([one]), do: one

  defp merge([first | _] = several) do
    names = several |> Enum.flat_map(&Map.keys(&1["properties"])) |> Enum.uniq()

    props =
      Map.new(names, fn name ->
        case several
             |> Enum.map(& &1["properties"][name])
             |> Enum.reject(&is_nil/1)
             |> Enum.uniq() do
          [one] -> {name, one}
          differ -> {name, %{"anyOf" => differ}}
        end
      end)

    required =
      Enum.filter(first["required"], fn r -> Enum.all?(several, &(r in &1["required"])) end)

    %{"type" => "object", "properties" => props, "required" => required}
  end

  defp problem(type, status, props, required) do
    %{
      "type" => "object",
      "properties" =>
        Map.merge(props, %{
          "type" => %{"const" => type},
          "title" => @scalars.string,
          "status" => %{"const" => status}
        }),
      "required" => Enum.uniq(["type", "title", "status"] ++ required)
    }
  end

  # Header name => header object, over the answers of one status.
  defp headers(answers, ctx) do
    per_answer = Enum.map(answers, &answer_headers(&1, ctx))
    names = per_answer |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()

    map =
      Map.new(names, fn name ->
        present = per_answer |> Enum.map(&Map.get(&1, name)) |> Enum.reject(&is_nil/1)
        [{schema, _, _} | _] = present

        header =
          %{
            "schema" => schema,
            "description" => present |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.join("; ")
          }
          |> put(
            "required",
            if(length(present) == length(per_answer) and Enum.all?(present, &elem(&1, 2)),
              do: true
            )
          )

        {name, header}
      end)

    if map == %{}, do: nil, else: map
  end

  # %{name => {schema, description, always}}.
  defp answer_headers({:outcome, item, s, _c}, ctx) do
    model_name = outcome_model(ctx.capabilities, s.outcome)
    fields = if model_name, do: ctx.models[model_name].fields, else: []

    declared =
      Map.new(s.headers, fn
        {name, field} when is_atom(field) ->
          f = Enum.find(fields, &(&1.name == field))
          {name, {type_schema(f.type), "`#{s.outcome}`: the outcome's `#{field}`", f.required}}

        {name, template} ->
          schema =
            if String.contains?(template, "{"),
              do: @scalars.string,
              else: %{"type" => "string", "const" => template}

          {name, {schema, "`#{s.outcome}`: `#{template}`", true}}
      end)

    case etag(item, s, fields, ctx) do
      nil -> declared
      header -> Map.put(declared, "etag", header)
    end
  end

  defp answer_headers({:not_modified, item}, _ctx),
    do: %{"etag" => etag_header(item.etag)}

  defp answer_headers(_answer, _ctx), do: %{}

  # ETag on a success outcome of a resource with `etag`, when its body has that field.
  defp etag(item, s, fields, ctx) do
    field = Map.get(item, :etag)
    success = s.by == nil and s.status < 300

    body_fields =
      cond do
        not success or field == nil -> []
        s.body -> fields |> Enum.find(&(&1.name == s.body)) |> model_fields(ctx)
        true -> fields
      end

    if Enum.any?(body_fields, &(&1.name == field)), do: etag_header(field)
  end

  defp model_fields(%{type: model}, ctx) when is_atom(model), do: ctx.models[model].fields
  defp model_fields(_field, _ctx), do: []

  defp etag_header(field),
    do:
      {@scalars.string,
       "the body's `#{field}`, quoted (`\"<#{field}>\"`); send it as `If-None-Match`", true}

  ## Schemas

  defp components(items, ctx) do
    roots =
      for item <- items, reduce: [] do
        acc ->
          capability = ctx.capabilities[item.capability]

          # An outcome sent as bytes has no JSON body: its model is no schema of its own.
          outcomes =
            for o <- capability.outcomes,
                o.model,
                not (Map.has_key?(ctx.statuses, o.name) and
                       Map.get(ctx.statuses[o.name], :stream) != nil),
                do: o.model

          inputs =
            for f <- input_fields_list(item, ctx),
                f.name in (Map.get(item, :body) || []),
                model <- refs(f.type),
                do: model

          events = for e <- Map.get(item, :events, []), do: ctx.events[e].model
          acc ++ outcomes ++ inputs ++ events
      end

    roots
    |> reach(ctx, MapSet.new())
    |> Map.new(fn name -> {text(name), object(ctx.models[name].fields)} end)
  end

  defp reach([], _ctx, seen), do: seen

  defp reach([name | rest], ctx, seen) do
    if name in seen do
      reach(rest, ctx, seen)
    else
      inner = for f <- ctx.models[name].fields, model <- refs(f.type), do: model
      reach(inner ++ rest, ctx, MapSet.put(seen, name))
    end
  end

  defp refs({:list, type}), do: refs(type)
  defp refs({:one_of, models, _tag}), do: models
  defp refs({:map, _}), do: []
  defp refs({:enum, _}), do: []
  defp refs(:stream), do: []
  defp refs(type) when is_map_key(@scalars, type), do: []
  defp refs(model) when is_atom(model), do: [model]

  defp object(fields) do
    %{
      "type" => "object",
      "properties" => Map.new(fields, &{text(&1.name), type_schema(&1.type)}),
      "required" => required(fields)
    }
  end

  defp required(fields), do: for(f <- fields, f.required, do: text(f.name))

  defp type_schema(type) when is_map_key(@scalars, type), do: @scalars[type]
  defp type_schema(:stream), do: Map.put(@binary, "description", "byte stream")
  defp type_schema({:enum, values}), do: %{"type" => "string", "enum" => texts(values)}
  defp type_schema({:list, type}), do: %{"type" => "array", "items" => type_schema(type)}

  defp type_schema({:map, type}),
    do: %{"type" => "object", "additionalProperties" => type_schema(type)}

  defp type_schema({:one_of, models, tag: tag}) do
    %{
      "oneOf" =>
        for m <- models do
          %{
            "allOf" => [
              ref(m),
              %{
                "type" => "object",
                "properties" => %{text(tag) => %{"const" => text(m)}},
                "required" => [text(tag)]
              }
            ]
          }
        end,
      "discriminator" => %{"propertyName" => text(tag)}
    }
  end

  defp type_schema(model) when is_atom(model), do: ref(model)

  defp ref(model), do: %{"$ref" => "#/components/schemas/#{model}"}

  ## Helpers

  defp outcome_model(capabilities, outcome) do
    Enum.find_value(Map.values(capabilities), fn c ->
      Enum.find_value(c.outcomes, &(&1.name == outcome && (&1.model || false)))
    end)
  end

  defp input_fields(item, ctx), do: Map.new(input_fields_list(item, ctx), &{&1.name, &1})

  defp input_fields_list(item, ctx) do
    case ctx.capabilities[item.capability].input do
      nil -> []
      input -> ctx.models[input].fields
    end
  end

  defp put(map, _key, nil), do: map
  defp put(map, _key, false), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp text(atom), do: Atom.to_string(atom)
  defp texts(atoms), do: Enum.map(atoms, &text/1)
end
