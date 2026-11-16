defmodule AtlasRuntimeBackend.Generator.Targets.Rest do
  @moduledoc """
  A compile-time target: a Plug router for one target block of a backend contract, made
  from its `__schema__/0` and the boundary's when the module that uses it compiles. No
  file is written, and no route, status code or serialization is written by hand.

      defmodule MySystem.Backend.Rest do
        use AtlasRuntimeBackend.Generator.Targets.Rest,
          contract: MyBackend.Lending,
          facade: MySystem.Boundary.Lending,
          stream: MySystem.Backend.Events
      end

  Options:
  - `contract:` the backend contract (`AtlasRuntimeBackend.Generator.Schema`);
  - `facade:` the boundary's facade, the only module the router calls into. For a
    capability `name` with input model `m` and outcomes `o`, the router calls
    `facade.name(client, input)` (or `facade.name(client)` without input), builds
    `input` with `facade.M.new/1` (`M` is `m` camelized; `{:ok, struct}` or
    `{:error, [reason]}`), and encodes an outcome struct `facade.Outcome.O` with its
    `dump/1` (JSON-ready data: string keys, enums as text, `one_of` tagged, ISO-8601
    datetimes). An event's model `e` is `facade.E`, also with `dump/1`. Anything else the
    facade returns is a refusal when the client lacks the capability's right, and raises
    otherwise;
  - `stream:` the module that keeps a stream open (needed when the target has a
    stream): `stream(conn, router)`, called with the chunked conn after the opening
    event, returning the conn when the stream ends. It turns a notification into a
    frame with `router.__event__/1`;
  - `target:` the target block it serves (default: the contract's only target).

  The module it generates is a Plug (`init/1`, `call/2`). For each request it:
  1. takes the client from `conn.assigns.client`, an opaque `{id, rights}` set by the
     listener (it raises without one);
  2. matches method and path (`AtlasRuntimeBackend.Generator.Paths`), then the query
     parameters, which must all be declared; no match is the `:no_route` error;
  3. decodes strictly: the query, the bound headers and the body (a JSON object holding
     only the declared body fields, at most 1 MiB) become the input map, which goes
     through the facade's `new/1`. Any failure is the `:invalid` error;
  4. calls the facade;
  5. answers with the outcome's declared status and headers. A status of 400 or more
     has an `application/problem+json` body (RFC 9457: `type`, `title`, `status`, then
     the outcome's fields); one below is `application/json`: the outcome's entity named by
     the status's `body:`, serialized directly, else the outcome's fields.
     A stream answers `text/event-stream`: the opening event, if any, then the stream
     module's frames.

  It also has `__routes__/0` (the route × outcome → status table as data),
  `__rights__/1` (a listener's rights, from the contract), `__event__/1` (a frame
  for an event model struct: `{:ok, iodata}`, or `:error` for anything else) and
  `__problem__/2`: `__problem__(kind, conn)` sends the target's error `kind` (one the
  contract declares, such as a listener's `:unauthenticated` or `:origin_refused`) as
  its status with an `application/problem+json` body of `type`, `title` and `status`
  only, and halts the conn. A listener plug uses it to refuse a request before the
  router runs, so the listener writes no problem body itself; the body never depends on
  the request, so every refusal of one kind is the same.
  """

  alias AtlasRuntimeBackend.Generator.Paths
  alias AtlasRuntimeBackend.Generator.Targets.Rest.Runtime

  @max_body 1_048_576

  defmacro __using__(opts) do
    caller = __CALLER__
    fail = &raise(CompileError, file: caller.file, line: caller.line, description: &1)

    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:contract, :facade, :stream, :target] == [] and
             Keyword.has_key?(opts, :contract) and Keyword.has_key?(opts, :facade),
           do:
             fail.(
               "use #{inspect(__MODULE__)} takes contract:, facade: and optionally stream: and target:"
             )

    contract = Macro.expand(opts[:contract], caller)
    facade = Macro.expand(opts[:facade], caller)
    stream_module = opts[:stream] && Macro.expand(opts[:stream], caller)

    compiled? = fn module, function ->
      is_atom(module) and Code.ensure_compiled(module) == {:module, module} and
        function_exported?(module, function, 0)
    end

    unless compiled?.(contract, :__schema__),
      do: fail.("contract: #{Macro.to_string(opts[:contract])} is no compiled backend contract")

    unless is_atom(facade) and Code.ensure_compiled(facade) == {:module, facade},
      do: fail.("facade: #{Macro.to_string(opts[:facade])} is not available")

    schema = contract.__schema__()
    boundary = schema.boundary.__schema__()

    target =
      case {opts[:target], schema.targets} do
        {nil, [only]} ->
          only

        {nil, _several} ->
          fail.("the contract has several targets; name one with target:")

        {name, targets} ->
          Enum.find(targets, &(&1.name == name)) ||
            fail.("the contract has no target #{inspect(name)}")
      end

    if target.streams != [] and is_nil(stream_module),
      do: fail.("target #{inspect(target.name)} has a stream; name its loop with stream:")

    capabilities = Map.new(boundary.capabilities, &{&1.name, &1})
    models = Map.new(boundary.models, &{&1.name, &1})
    model_module = &Module.concat(facade, Macro.camelize(Atom.to_string(&1)))
    outcome_module = &Module.concat([facade, Outcome, Macro.camelize(Atom.to_string(&1))])

    exports! = fn module, function, arity, what ->
      unless Code.ensure_compiled(module) == {:module, module} and
               function_exported?(module, function, arity),
             do:
               fail.(
                 "facade #{inspect(facade)} has no #{what} (#{inspect(module)}.#{function}/#{arity})"
               )
    end

    mapped =
      Enum.map(target.resources, & &1.capability) ++ Enum.map(target.streams, & &1.capability)

    for name <- mapped do
      capability = capabilities[name]
      arity = if capability.input, do: 2, else: 1
      exports!.(facade, name, arity, "capability #{name}")

      if capability.input,
        do: exports!.(model_module.(capability.input), :new, 1, "input #{capability.input}")

      for o <- capability.outcomes,
          do: exports!.(outcome_module.(o.name), :dump, 1, "outcome #{o.name}")
    end

    events = Map.new(schema.events, &{&1.name, &1})
    stream_events = target.streams |> Enum.flat_map(& &1.events) |> Enum.uniq()

    for name <- stream_events,
        do:
          exports!.(
            model_module.(events[name].model),
            :dump,
            1,
            "event model #{events[name].model}"
          )

    errors = Map.new(target.errors, &{&1.kind, &1})
    statuses = Map.new(target.statuses, &{&1.outcome, &1})

    # Routes: resources by index, then streams.
    items =
      Enum.with_index(
        Enum.map(target.resources, &{:resource, &1}) ++ Enum.map(target.streams, &{:stream, &1})
      )

    routes =
      for {{kind, item}, key} <- items do
        {:ok, segments} = Paths.parse(item.path)

        method =
          if kind == :stream, do: "GET", else: item.method |> Atom.to_string() |> String.upcase()

        query = if kind == :stream, do: [], else: Enum.map(item.query, &elem(&1, 0))
        required = if kind == :stream, do: [], else: item.required

        %{key: key, method: method, segments: segments, query: query, required: required}
      end

    field_type = fn capability, field ->
      Enum.find(models[capability.input].fields, &(&1.name == field)).type
    end

    {handlers, openings} =
      for {{kind, item}, key} <- items do
        capability = capabilities[item.capability]
        modules = for o <- capability.outcomes, do: outcome_module.(o.name)
        input = capability.input && model_module.(capability.input)

        case kind do
          :resource ->
            {resource_handler(key, item, capability, input, modules, facade, field_type), []}

          :stream ->
            stream_handler(
              key,
              item,
              capability,
              input,
              modules,
              facade,
              stream_module,
              events,
              outcome_module
            )
        end
      end
      |> Enum.unzip()

    used_outcomes =
      for item <- target.resources,
          o <- capabilities[item.capability].outcomes,
          uniq: true,
          do: o.name

    responders = for name <- used_outcomes, do: responder(outcome_module.(name), statuses[name])

    event_clauses =
      for name <- stream_events do
        event = events[name]

        quote do
          def __event__(%{__struct__: unquote(model_module.(event.model))} = value) do
            data = unquote(model_module.(event.model)).dump(value)
            {:ok, Runtime.frame(unquote(Atom.to_string(name)), unquote(id_expr(event.id)), data)}
          end
        end
      end

    table =
      for {{kind, item}, _key} <- items do
        capability = capabilities[item.capability]

        outcomes =
          for o <- capability.outcomes do
            if kind == :stream do
              %{
                outcome: o.name,
                status: 200,
                type: nil,
                by: nil,
                cases: [],
                headers: [{"content-type", "text/event-stream"}],
                opens_with: Keyword.fetch!(item.open, o.name)
              }
            else
              Map.delete(statuses[o.name], :outcome) |> Map.put(:outcome, o.name)
            end
          end

        %{
          method: if(kind == :stream, do: :get, else: item.method),
          path: item.path,
          capability: item.capability,
          stream: kind == :stream,
          outcomes: outcomes
        }
      end

    rights = Map.new(schema.rights, &{&1.listener, &1.rights})

    quote do
      require unquote(contract)
      require unquote(facade)
      @behaviour Plug
      @compile {:nowarn_unused_function, read_json: 2, header: 3, read_headers: 2, with_conn: 2}

      @routes unquote(Macro.escape(routes))
      @errors unquote(Macro.escape(errors))

      @doc "The routes, with each outcome's status, problem type and headers, as data."
      def __routes__, do: unquote(Macro.escape(table))

      @doc "The rights a client gets on `listener`, as the contract declares them."
      def __rights__(listener), do: Map.fetch!(unquote(Macro.escape(rights)), listener)

      @doc """
      Sends the target's error `kind` as its declared status and a problem+json body
      (`type`, `title`, `status`), and halts `conn`. Raises for a kind the contract does
      not declare.
      """
      def __problem__(kind, %Plug.Conn{} = conn) do
        %{status: status, type: type} =
          case Map.fetch(@errors, kind) do
            {:ok, error} ->
              error

            :error ->
              raise ArgumentError,
                    "#{inspect(__MODULE__)}: the contract declares no error #{inspect(kind)}"
          end

        body = Runtime.problem(status, type, Plug.Conn.Status.reason_phrase(status))

        conn
        |> send_json(status, "application/problem+json", body)
        |> Plug.Conn.halt()
      end

      @doc "A Server-Sent Events frame for an event model struct: `{:ok, iodata}` or `:error`."
      unquote_splicing(event_clauses)
      def __event__(_other), do: :error

      @impl Plug
      def init(opts), do: opts

      @impl Plug
      def call(%Plug.Conn{} = conn, _opts) do
        client =
          case conn.assigns do
            %{client: client} -> client
            _ -> raise ArgumentError, "#{inspect(__MODULE__)}: no client in conn.assigns"
          end

        case Runtime.select(@routes, conn.method, conn.path_info, conn.query_string) do
          {:ok, key, params, query} -> handle(key, conn, client, params, query)
          :no_route -> error(conn, :no_route, "no resource #{conn.method} #{conn.request_path}")
          {:error, reasons} -> error(conn, :invalid, Enum.join(reasons, "; "))
        end
      end

      unquote_splicing(handlers)
      unquote_splicing(List.flatten(openings))
      unquote_splicing(responders)

      defp with_conn({:ok, value}, _conn), do: {:ok, value}
      defp with_conn({:error, reasons}, conn), do: {:error, conn, reasons}

      defp read_json(conn, fields) do
        case Plug.Conn.read_body(conn, length: unquote(@max_body)) do
          {:ok, binary, conn} ->
            case Runtime.body(fields, binary) do
              {:ok, map} -> {:ok, conn, map}
              {:error, reasons} -> {:error, conn, reasons}
            end

          {:more, _partial, conn} ->
            {:error, conn, ["the body is larger than #{unquote(@max_body)} bytes"]}

          {:error, reason} ->
            {:error, conn, ["the body could not be read (#{inspect(reason)})"]}
        end
      end

      defp header(conn, name, type) do
        case Plug.Conn.get_req_header(conn, name) do
          [] -> {:ok, nil}
          [text] -> {:ok, Runtime.coerce(type, text)}
          _ -> {:error, ["header #{name} is given twice"]}
        end
      end

      # The bound headers as {field, value}; a header given twice is an error.
      defp read_headers(conn, reads) do
        Enum.reduce_while(reads, {:ok, []}, fn {field, name, type}, {:ok, acc} ->
          case header(conn, name, type) do
            {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
            {:error, reasons} -> {:halt, {:error, conn, reasons}}
          end
        end)
      end

      defp other(conn, client, right, value) do
        if Enum.member?(Runtime.rights(client), right),
          do:
            raise(
              ArgumentError,
              "#{inspect(__MODULE__)}: the facade returned #{inspect(value)}, which is no declared outcome"
            ),
          else: error(conn, :not_permitted, "this needs the right #{right}")
      end

      defp error(conn, kind, detail) do
        %{status: status, type: type} = Map.fetch!(@errors, kind)

        body =
          Runtime.problem(status, type, Plug.Conn.Status.reason_phrase(status), %{
            "detail" => detail
          })

        send_json(conn, status, "application/problem+json", body)
      end

      defp send_json(conn, status, content_type, body) do
        conn
        |> Plug.Conn.put_resp_header("content-type", content_type)
        |> Plug.Conn.send_resp(status, JSON.encode!(body))
      end
    end
  end

  defp id_expr(nil), do: nil
  defp id_expr(field), do: quote(do: Map.fetch!(value, unquote(field)))

  defp resource_handler(key, item, capability, input, modules, facade, field_type) do
    name = capability.name
    right = capability.right

    param_values =
      for p <- item.params do
        type = field_type.(capability, p)

        quote(
          do:
            {unquote(Atom.to_string(p)),
             Runtime.coerce(unquote(Macro.escape(type)), Map.fetch!(params, unquote(p)))}
        )
      end

    query_values =
      for {q, field} <- item.query do
        type = field_type.(capability, field)

        quote do
          {unquote(Atom.to_string(field)),
           case Map.fetch(query, unquote(q)) do
             {:ok, text} -> Runtime.coerce(unquote(Macro.escape(type)), text)
             :error -> nil
           end}
        end
      end

    header_reads =
      for {h, field} <- item.headers do
        type = field_type.(capability, field)
        {Atom.to_string(field), h, Macro.escape(type)}
      end

    body_fields = item.body && Enum.map(item.body, &Atom.to_string/1)

    call =
      if input,
        do: quote(do: unquote(facade).unquote(name)(client, input)),
        else: quote(do: unquote(facade).unquote(name)(client))

    build =
      if input do
        quote do
          case unquote(input).new(Map.reject(values, fn {_k, v} -> is_nil(v) end)) do
            {:ok, input} -> {:ok, input}
            {:error, reasons} -> {:error, reasons}
          end
        end
      else
        quote(do: {:ok, nil})
      end

    quote do
      defp handle(unquote(key), conn, client, params, query) do
        _ = params
        _ = query

        result =
          with {:ok, conn, body} <- read_json(conn, unquote(body_fields)),
               {:ok, headers} <- read_headers(conn, unquote(Macro.escape(header_reads))) do
            values =
              body
              |> Map.merge(Map.new(unquote(param_values)))
              |> Map.merge(Map.new(unquote(query_values)))
              |> Map.merge(Map.new(headers))

            _ = values

            case unquote(build) do
              {:ok, input} ->
                _ = input
                {:called, conn, unquote(call)}

              {:error, reasons} ->
                {:error, conn, reasons}
            end
          end

        case result do
          {:called, conn, %{__struct__: module} = outcome} when module in unquote(modules) ->
            respond(conn, outcome)

          {:called, conn, other} ->
            other(conn, client, unquote(right), other)

          {:error, conn, reasons} ->
            error(conn, :invalid, Enum.join(reasons, "; "))
        end
      end
    end
  end

  defp stream_handler(
         key,
         item,
         capability,
         input,
         modules,
         facade,
         stream_module,
         events,
         outcome_module
       ) do
    name = capability.name
    right = capability.right
    into = Atom.to_string(item.into)
    header = item.resume_header

    openings =
      for {outcome, event} <- item.open do
        module = outcome_module.(outcome)

        frame =
          if event do
            spec = events[event]

            quote do
              data = unquote(module).dump(value)
              Runtime.frame(unquote(Atom.to_string(event)), unquote(id_expr(spec.id)), data)
            end
          end

        quote do
          defp opening(unquote(key), %{__struct__: unquote(module)} = value) do
            _ = value
            unquote(frame)
          end
        end
      end

    call =
      if input,
        do: quote(do: unquote(facade).unquote(name)(client, input)),
        else: quote(do: unquote(facade).unquote(name)(client))

    handler =
      quote do
        defp handle(unquote(key), conn, client, _params, _query) do
          with {:ok, conn, _body} <- read_json(conn, nil),
               {:ok, resume} <- header(conn, unquote(header), :integer) |> with_conn(conn),
               {:ok, input} <-
                 unquote(input).new(if(is_nil(resume), do: %{}, else: %{unquote(into) => resume}))
                 |> with_conn(conn) do
            _ = input

            case unquote(call) do
              %{__struct__: module} = outcome when module in unquote(modules) ->
                conn =
                  conn
                  |> Plug.Conn.put_resp_header("content-type", "text/event-stream")
                  |> Plug.Conn.put_resp_header("cache-control", "no-cache")
                  |> Plug.Conn.send_chunked(200)

                case opening(unquote(key), outcome) do
                  nil ->
                    unquote(stream_module).stream(conn, __MODULE__)

                  frame ->
                    case Plug.Conn.chunk(conn, frame) do
                      {:ok, conn} -> unquote(stream_module).stream(conn, __MODULE__)
                      {:error, _closed} -> conn
                    end
                end

              other ->
                other(conn, client, unquote(right), other)
            end
          else
            {:error, conn, reasons} -> error(conn, :invalid, Enum.join(reasons, "; "))
          end
        end
      end

    {handler, openings}
  end

  defp responder(module, status) do
    headers =
      for {name, value} <- status.headers do
        text =
          if is_atom(value),
            do: quote(do: Runtime.header_text(Map.get(dumped, unquote(Atom.to_string(value))))),
            else: quote(do: Runtime.template(unquote(value), dumped))

        quote(do: {unquote(name), unquote(text)})
      end

    {code, type} =
      if status.by do
        cases = for c <- status.cases, do: {c.value, {c.status, c.type}}

        {quote(
           do: elem(Keyword.fetch!(unquote(cases), Map.fetch!(outcome, unquote(status.by))), 0)
         ),
         quote(
           do: elem(Keyword.fetch!(unquote(cases), Map.fetch!(outcome, unquote(status.by))), 1)
         )}
      else
        {status.status, status.type}
      end

    quote do
      defp respond(conn, %{__struct__: unquote(module)} = outcome) do
        dumped = unquote(module).dump(outcome)
        code = unquote(code)
        type = unquote(type)

        conn =
          Enum.reduce(unquote(headers), conn, fn
            {_name, nil}, conn -> conn
            {name, text}, conn -> Plug.Conn.put_resp_header(conn, name, text)
          end)

        payload =
          unquote(
            if status.body,
              do: quote(do: Map.fetch!(dumped, unquote(Atom.to_string(status.body)))),
              else: quote(do: dumped)
          )

        if code >= 400,
          do:
            send_json(
              conn,
              code,
              "application/problem+json",
              Runtime.problem(code, type, Plug.Conn.Status.reason_phrase(code), dumped)
            ),
          else: send_json(conn, code, "application/json", payload)
      end
    end
  end
end
