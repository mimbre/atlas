defmodule AtlasRuntimeBackend.Generator.Targets.Rest do
  @moduledoc """
  A compile-time target: one Plug router for one target block of each of several backend
  contracts, made from their `__schema__/0` and their boundaries' when the module that
  uses it compiles. No file is written, and no route, status code or serialization is
  written by hand.

      defmodule MySystem.Backend.Rest do
        use AtlasRuntimeBackend.Generator.Targets.Rest,
          contracts: [
            lending: {MyBackend.Lending, facade: MySystem.Boundary.Lending, stream: MySystem.Backend.Events},
            desk: {MyBackend.Desk, facade: MySystem.Boundary.Desk}
          ]
      end

  `contracts:` names each contract once, `name: {contract, options}`, in the order its
  routes are listed. One contract may also be given on its own, as
  `contract: C, facade: F, stream: S, target: T` (its name is `C`'s last part in
  snake_case). Options per contract:
  - the contract itself, a backend contract (`AtlasRuntimeBackend.Generator.Schema`);
  - `facade:` the boundary's facade, the only module the router calls into for that
    contract's routes. For a capability `name` with input model `m` and outcomes `o`, the
    router calls `facade.name(client, input)` (or `facade.name(client)` without input),
    builds `input` with `facade.M.new/1` (`M` is `m` camelized; `{:ok, struct}` or
    `{:error, [reason]}`), and encodes an outcome struct `facade.Outcome.O` with its
    `dump/1` (JSON-ready data: string keys, enums as text, `one_of` tagged, ISO-8601
    datetimes). An event's model `e` is `facade.E`, also with `dump/1`. Besides an
    outcome, a facade may answer with one of its two refusals, for every capability alike:
    a struct with exactly the fields `capability` and `right` (the client lacks the right),
    or exactly `capability` and `reasons` (the input does not validate). Anything else
    raises;
  - `stream:` the module that keeps a stream open (needed when the target has a
    stream): `stream(conn, router)`, called with the chunked conn after the opening
    event, returning the conn when the stream ends. It turns a notification into a
    frame with `router.__event__/1`;
  - `target:` the target block it serves (default: the contract's only target).

  Each contract is checked on its own as before; across them, these are `CompileError`s:
  a name, contract or facade given twice; two routes that overlap; more than one stream
  (a router has one event stream); and errors (`error :invalid`, …) that differ, since the
  router answers them alike. Two routes of different contracts overlap when their method
  is the same, they have as many segments, and at every position the segments are the
  same literal or at least one is a parameter. Within one contract the contract's own
  rules decide (a literal beats a parameter; one path is told apart by required query
  parameters).

  The module it generates is a Plug (`init/1`, `call/2`). For each request it:
  1. takes the client from `conn.assigns.client`, an opaque `{id, rights}` set by the
     listener (it raises without one);
  2. matches method and path (`AtlasRuntimeBackend.Generator.Paths`), then the query
     parameters, which must all be declared; no match is the `:no_route` error (its
     detail names the method only: no router text repeats the request's path);
  3. decodes strictly: the query, the bound headers and the body (a JSON object holding
     only the declared body fields, at most 1 MiB) become the input map, which goes
     through the facade's `new/1`. Any failure is the `:invalid` error;
     A resource with a streamed body (`body: {:stream, field}`) reads no JSON. Its
     request must have the declared `Content-Type` (parameters aside), else the
     `:unsupported_media_type` error (415), and a `Content-Length` above the limit
     (`max_bytes:`, asked for each request) is the `:too_large` error (413); in both
     cases the facade is not called. Otherwise the input's `field` is a lazy
     `Stream.resource` over `Plug.Conn.read_body/2`: each element is the next chunk of
     the body, at most 1 MiB, read (with a 60 s timeout per read) only when the facade
     enumerates it, never held whole by the router. It must be enumerated in the
     process that called the facade, before the facade returns. Reading past the limit
     raises `AtlasRuntimeBackend.Generator.Targets.Rest.BodyError` (`kind: :too_large`),
     and a read that fails raises it with `kind: :unreadable`; a facade lets it pass (an
     `after` may clean up), and the router answers the `:too_large` error, or the
     `:invalid` error, instead of an outcome. When the router answers before the body
     has been read to its end (an outcome given early, a refusal, any of those errors),
     it adds `connection: close` and reads no more of it. No text of these answers
     repeats what the request sent;
  4. calls the route's facade;
  5. answers with the outcome's declared status and headers. A status of 400 or more
     has an `application/problem+json` body (RFC 9457: `type`, `title`, `status`, then
     the outcome's fields); one below is `application/json`: the outcome's entity named by
     the status's `body:`, serialized directly, else the outcome's fields.
     A status with `stream: field` answers chunked, with its `content_type:` and its
     declared headers: one chunk per element of the outcome's stream, in order, no JSON.
     The status and headers go out only once the facade has answered, so a refusal is
     still problem+json. The stream is never held whole. When a chunk cannot be sent (the
     client is gone), the enumeration halts, so the stream's own clean-up (the `after` of
     a `Stream.resource`, a file's close) runs, and no further element is read. An element
     that raises is not caught: the response then never ends as complete.
     A stream answers `text/event-stream`: the opening event, if any, then the stream
     module's frames. A facade's refusal is the `:not_permitted` or the `:invalid` error,
     whichever contract the route is in.
     A resource with `etag: field` adds `ETag: "<field>"` to its one success outcome,
     and answers 304 with that `ETag` and no body when the request's `If-None-Match`
     holds the tag (or `*`). Its other outcomes, and other resources, get no `ETag`.

  It also has `__routes__/0` (the route × outcome → status table as data, each route
  with its contract's name and its `etag` field or `nil`), `__rights__/1` (a listener's
  rights: those every contract declares for it, in contract order, each once),
  `__event__/1` (a frame for an event model struct: `{:ok, iodata}`, or `:error` for
  anything else) and
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
  # A streamed body's errors: each contract answers its own, so routers of several
  # contracts need not agree on them.
  @upload_errors [:too_large, :unsupported_media_type]

  defmacro __using__(opts) do
    caller = __CALLER__
    fail = &raise(CompileError, file: caller.file, line: caller.line, description: &1)

    prepared =
      opts
      |> contracts!(caller, fail)
      |> Enum.map(&prepare!(&1, fail))

    across!(prepared, fail)

    # Every route of every contract, numbered once: resources by index, then streams, per
    # contract in the order given.
    items =
      prepared
      |> Enum.flat_map(fn c ->
        Enum.map(c.target.resources, &{c, :resource, &1}) ++
          Enum.map(c.target.streams, &{c, :stream, &1})
      end)
      |> Enum.with_index()

    routes = for {{c, kind, item}, key} <- items, do: route(c, kind, item, key)
    overlap!(routes, fail)

    {handlers, openings} =
      for {{c, kind, item}, key} <- items do
        capability = c.capabilities[item.capability]
        modules = for o <- capability.outcomes, do: c.outcome_module.(o.name)
        input = capability.input && c.model_module.(capability.input)

        field_type = fn capability, field ->
          Enum.find(c.models[capability.input].fields, &(&1.name == field)).type
        end

        case {kind, Map.get(item, :upload)} do
          {:resource, upload} when upload != nil ->
            {upload_handler(
               key,
               item,
               capability,
               input,
               modules,
               c.facade,
               field_type,
               c.errors
             ), []}

          {:resource, nil} ->
            tagged = tagged(item, capability, c.statuses, c.outcome_module)

            {resource_handler(
               key,
               item,
               capability,
               input,
               modules,
               c.facade,
               field_type,
               tagged
             ), []}

          {:stream, _} ->
            stream_handler(
              key,
              item,
              capability,
              input,
              modules,
              c.facade,
              c.stream,
              c.events,
              c.outcome_module
            )
        end
      end
      |> Enum.unzip()

    responders =
      for c <- prepared,
          name <-
            Enum.uniq(
              for item <- c.target.resources,
                  o <- c.capabilities[item.capability].outcomes,
                  do: o.name
            ),
          do: responder(c.outcome_module.(name), c.statuses[name])

    event_clauses =
      for c <- prepared, name <- c.stream_events do
        event = c.events[name]
        model = c.model_module.(event.model)

        quote do
          def __event__(%{__struct__: unquote(model)} = value) do
            data = unquote(model).dump(value)
            {:ok, Runtime.frame(unquote(Atom.to_string(name)), unquote(id_expr(event.id)), data)}
          end
        end
      end

    table = for {{c, kind, item}, _key} <- items, do: table_row(c, kind, item)

    # A listener's rights: every contract's, in contract order, each once.
    rights =
      prepared
      |> Enum.flat_map(& &1.schema.rights)
      |> Enum.group_by(& &1.listener, & &1.rights)
      |> Map.new(fn {listener, lists} -> {listener, lists |> Enum.concat() |> Enum.uniq()} end)

    errors = Map.drop(hd(prepared).errors, @upload_errors)

    quote do
      unquote_splicing(for c <- prepared, do: quote(do: require(unquote(c.contract))))
      unquote_splicing(for c <- prepared, do: quote(do: require(unquote(c.facade))))
      @behaviour Plug
      @compile {:nowarn_unused_function,
                read_json: 2,
                header: 3,
                read_headers: 2,
                with_conn: 2,
                refused: 2,
                send_stream: 2,
                close: 1}

      @routes unquote(Macro.escape(Enum.map(routes, &Map.drop(&1, [:contract, :path]))))
      @errors unquote(Macro.escape(errors))

      @doc "The routes, with each outcome's status, problem type and headers, as data."
      def __routes__, do: unquote(Macro.escape(table))

      @doc "The rights a client gets on `listener`: what every contract declares for it."
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
          # The method and path are request data: never repeated (D44).
          :no_route -> error(conn, :no_route, "no resource for this method and path")
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

          {:error, _reason} ->
            {:error, conn, ["the body could not be read"]}
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

      # A facade's answer that is no outcome: one of its refusals, the same for every
      # contract, or a value it should never give.
      defp refused(conn, value) do
        case Runtime.refusal(value) do
          {:not_permitted, right} ->
            error(conn, :not_permitted, "this needs the right #{right}")

          {:invalid, reasons} ->
            error(conn, :invalid, Enum.join(reasons, "; "))

          :none ->
            raise ArgumentError,
                  "#{inspect(__MODULE__)}: the facade returned #{inspect(value)}, which is no declared outcome"
        end
      end

      defp error(conn, kind, detail) do
        %{status: status, type: type} = Map.fetch!(@errors, kind)
        problem(conn, status, type, detail)
      end

      defp problem(conn, status, type, detail) do
        body =
          Runtime.problem(status, type, Plug.Conn.Status.reason_phrase(status), %{
            "detail" => detail
          })

        send_json(conn, status, "application/problem+json", body)
      end

      # An answer given before a streamed body was read to its end: the connection is
      # closed after it, so nothing more of the body is read.
      defp close(conn), do: Plug.Conn.put_resp_header(conn, "connection", "close")

      defp send_json(conn, status, content_type, body) do
        conn
        |> Plug.Conn.put_resp_header("content-type", content_type)
        |> Plug.Conn.send_resp(status, JSON.encode!(body))
      end

      # A stream outcome's body on a chunked conn: one chunk per element, as it is read.
      # A chunk that cannot be sent halts the enumeration, so its clean-up runs.
      defp send_stream(conn, content) do
        Enum.reduce_while(content, conn, fn piece, conn ->
          case Plug.Conn.chunk(conn, piece) do
            {:ok, conn} -> {:cont, conn}
            {:error, _closed} -> {:halt, conn}
          end
        end)
      end
    end
  end

  ## The contracts, each on its own

  @contract_options [:facade, :stream, :target]

  # [{name, contract, opts}] from `contracts:` or from the one-contract form.
  defp contracts!(opts, caller, fail) do
    unless Keyword.keyword?(opts), do: fail.(usage())

    cond do
      Keyword.has_key?(opts, :contracts) ->
        unless Keyword.keys(opts) == [:contracts], do: fail.(usage())
        list = opts[:contracts]

        unless is_list(list) and list != [] and Keyword.keyword?(list),
          do: fail.("contracts: is [name: {Contract, facade: ..., stream: ..., target: ...}]")

        for {name, spec} <- list do
          unless snake?(name), do: fail.("contracts: #{inspect(name)} is no snake_case name")

          case spec do
            {contract, contract_opts} when is_list(contract_opts) ->
              unless Keyword.keyword?(contract_opts) and
                       Keyword.keys(contract_opts) -- @contract_options == [] and
                       Keyword.has_key?(contract_opts, :facade),
                     do:
                       fail.(
                         "contracts: #{name} takes facade: and optionally stream: and target:"
                       )

              {name, Macro.expand(contract, caller), expand(contract_opts, caller)}

            _ ->
              fail.("contracts: #{name} is {Contract, facade: ...}, got #{Macro.to_string(spec)}")
          end
        end

      Keyword.keys(opts) -- [:contract | @contract_options] == [] and
        Keyword.has_key?(opts, :contract) and Keyword.has_key?(opts, :facade) ->
        contract = Macro.expand(opts[:contract], caller)

        name =
          if is_atom(contract),
            do:
              contract |> Module.split() |> List.last() |> Macro.underscore() |> String.to_atom()

        {_, contract_opts} = Keyword.pop(opts, :contract)
        [{name, contract, expand(contract_opts, caller)}]

      true ->
        fail.(usage())
    end
  end

  defp usage,
    do:
      "use #{inspect(__MODULE__)} takes contracts: [name: {Contract, facade: ...}], " <>
        "or contract:, facade: and optionally stream: and target:"

  defp expand(opts, caller),
    do: for({key, value} <- opts, do: {key, value && Macro.expand(value, caller)})

  defp prepare!({name, contract, opts}, fail) do
    facade = opts[:facade]
    stream_module = opts[:stream]
    at = "contracts: #{name}:"

    compiled? = fn module, function ->
      is_atom(module) and Code.ensure_compiled(module) == {:module, module} and
        function_exported?(module, function, 0)
    end

    unless compiled?.(contract, :__schema__),
      do: fail.("#{at} #{inspect(contract)} is no compiled backend contract")

    unless is_atom(facade) and Code.ensure_compiled(facade) == {:module, facade},
      do: fail.("#{at} facade: #{inspect(facade)} is not available")

    schema = contract.__schema__()
    boundary = schema.boundary.__schema__()

    target =
      case {opts[:target], schema.targets} do
        {nil, [only]} ->
          only

        {nil, _several} ->
          fail.("#{at} the contract has several targets; name one with target:")

        {target_name, targets} ->
          Enum.find(targets, &(&1.name == target_name)) ||
            fail.("#{at} the contract has no target #{inspect(target_name)}")
      end

    if target.streams != [] and is_nil(stream_module),
      do: fail.("#{at} target #{inspect(target.name)} has a stream; name its loop with stream:")

    capabilities = Map.new(boundary.capabilities, &{&1.name, &1})
    models = Map.new(boundary.models, &{&1.name, &1})
    model_module = &Module.concat(facade, Macro.camelize(Atom.to_string(&1)))
    outcome_module = &Module.concat([facade, Outcome, Macro.camelize(Atom.to_string(&1))])

    exports! = fn module, function, arity, what ->
      unless Code.ensure_compiled(module) == {:module, module} and
               function_exported?(module, function, arity),
             do:
               fail.(
                 "#{at} facade #{inspect(facade)} has no #{what} (#{inspect(module)}.#{function}/#{arity})"
               )
    end

    mapped =
      Enum.map(target.resources, & &1.capability) ++ Enum.map(target.streams, & &1.capability)

    for capability_name <- mapped do
      capability = capabilities[capability_name]
      arity = if capability.input, do: 2, else: 1
      exports!.(facade, capability_name, arity, "capability #{capability_name}")

      if capability.input,
        do: exports!.(model_module.(capability.input), :new, 1, "input #{capability.input}")

      for o <- capability.outcomes,
          do: exports!.(outcome_module.(o.name), :dump, 1, "outcome #{o.name}")
    end

    events = Map.new(schema.events, &{&1.name, &1})
    stream_events = target.streams |> Enum.flat_map(& &1.events) |> Enum.uniq()

    for event_name <- stream_events,
        do:
          exports!.(
            model_module.(events[event_name].model),
            :dump,
            1,
            "event model #{events[event_name].model}"
          )

    %{
      name: name,
      contract: contract,
      facade: facade,
      stream: stream_module,
      schema: schema,
      target: target,
      capabilities: capabilities,
      models: models,
      model_module: model_module,
      outcome_module: outcome_module,
      events: events,
      stream_events: stream_events,
      errors: Map.new(target.errors, &{&1.kind, Map.take(&1, [:kind, :status, :type])}),
      statuses: Map.new(target.statuses, &{&1.outcome, &1})
    }
  end

  ## Across the contracts

  defp across!(prepared, fail) do
    for {key, what} <- [name: "name", contract: "contract", facade: "facade"] do
      prepared
      |> Enum.group_by(&Map.fetch!(&1, key), & &1.name)
      |> Enum.each(fn
        {_value, [_one]} ->
          :ok

        {value, names} ->
          fail.(
            "contracts: the #{what} #{inspect(value)} is given twice (#{Enum.map_join(names, ", ", &inspect/1)})"
          )
      end)
    end

    streams =
      for c <- prepared, s <- c.target.streams, do: "#{s.path} (#{c.name})"

    if length(streams) > 1,
      do:
        fail.("more than one stream: #{Enum.join(streams, ", ")}; a router has one event stream")

    [first | others] = prepared

    for c <- others,
        Map.drop(c.errors, @upload_errors) != Map.drop(first.errors, @upload_errors) do
      fail.(
        "contracts #{first.name} and #{c.name} declare different errors " <>
          "(#{errors_text(first.errors)} against #{errors_text(c.errors)}); one router answers them alike"
      )
    end

    :ok
  end

  defp errors_text(errors),
    do:
      errors
      |> Map.drop(@upload_errors)
      |> Map.values()
      |> Enum.sort()
      |> Enum.map_join(", ", &"#{&1.kind} #{&1.status} #{&1.type}")

  defp route(c, kind, item, key) do
    {:ok, segments} = Paths.parse(item.path)

    method =
      if kind == :stream, do: "GET", else: item.method |> Atom.to_string() |> String.upcase()

    %{
      key: key,
      method: method,
      segments: segments,
      query: if(kind == :stream, do: [], else: Enum.map(item.query, &elem(&1, 0))),
      required: if(kind == :stream, do: [], else: item.required),
      contract: c.name,
      path: item.path
    }
  end

  # Two routes of different contracts overlap when one request could match both: the same
  # method, as many segments, and at every position the same literal or a parameter.
  defp overlap!(routes, fail) do
    for {a, i} <- Enum.with_index(routes),
        b <- Enum.drop(routes, i + 1),
        a.contract != b.contract,
        overlap?(a, b) do
      fail.(
        "overlapping paths: #{a.method} #{a.path} (#{a.contract}) and #{b.method} #{b.path} (#{b.contract})"
      )
    end

    :ok
  end

  @doc false
  def overlap?(a, b) do
    a.method == b.method and length(a.segments) == length(b.segments) and
      Enum.all?(Enum.zip(a.segments, b.segments), fn
        {{:param, _}, _} -> true
        {_, {:param, _}} -> true
        {literal, literal} -> true
        _ -> false
      end)
  end

  defp table_row(c, kind, item) do
    capability = c.capabilities[item.capability]

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
          Map.delete(c.statuses[o.name], :outcome) |> Map.put(:outcome, o.name)
        end
      end

    row = %{
      contract: c.name,
      method: if(kind == :stream, do: :get, else: item.method),
      path: item.path,
      capability: item.capability,
      stream: kind == :stream,
      etag: if(kind == :stream, do: nil, else: item.etag),
      outcomes: outcomes
    }

    # A streamed body: its field and content type, and the errors only it answers.
    case kind == :resource && Map.get(item, :upload) do
      upload when is_map(upload) ->
        Map.put(row, :upload, %{
          field: upload.field,
          content_type: upload.content_type,
          errors: for(error <- @upload_errors, do: Map.fetch!(c.errors, error))
        })

      _none ->
        row
    end
  end

  defp snake?(name),
    do:
      is_atom(name) and name not in [nil, true, false] and
        Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))

  defp id_expr(nil), do: nil
  defp id_expr(field), do: quote(do: Map.fetch!(value, unquote(field)))

  # For a resource with etag: the outcome module that carries the tag, and how to read
  # the tag's field from its dump (the body: entity's field, else the outcome's).
  defp tagged(%{etag: nil}, _capability, _statuses, _outcome_module), do: nil

  defp tagged(item, capability, statuses, outcome_module) do
    [outcome] =
      for o <- capability.outcomes,
          %{by: nil, status: code} <- [statuses[o.name]],
          code < 400,
          do: o.name

    path = Enum.reject([statuses[outcome].body, item.etag], &is_nil/1)
    {outcome_module.(outcome), Enum.map(path, &Atom.to_string/1)}
  end

  # The declared headers as quoted {name, text} pairs, read from `dumped`.
  defp header_values(status) do
    for {name, value} <- status.headers do
      text =
        if is_atom(value),
          do: quote(do: Runtime.header_text(Map.get(dumped, unquote(Atom.to_string(value))))),
          else: quote(do: Runtime.template(unquote(value), dumped))

      quote(do: {unquote(name), unquote(text)})
    end
  end

  defp respond_call(nil), do: quote(do: respond(conn, outcome))

  defp respond_call({module, path}) do
    quote do
      case outcome do
        %{__struct__: unquote(module)} ->
          tag = Runtime.etag(get_in(unquote(module).dump(outcome), unquote(path)))
          conn = Plug.Conn.put_resp_header(conn, "etag", tag)

          if Runtime.not_modified?(Plug.Conn.get_req_header(conn, "if-none-match"), tag),
            do: Plug.Conn.send_resp(conn, 304, ""),
            else: respond(conn, outcome)

        _other ->
          respond(conn, outcome)
      end
    end
  end

  defp resource_handler(key, item, capability, input, modules, facade, field_type, tagged) do
    name = capability.name

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
            unquote(respond_call(tagged))

          {:called, conn, other} ->
            refused(conn, other)

          {:error, conn, reasons} ->
            error(conn, :invalid, Enum.join(reasons, "; "))
        end
      end
    end
  end

  # A resource whose body is the input's :stream field (`body: {:stream, field}`).
  defp upload_handler(key, item, capability, input, modules, facade, field_type, errors) do
    name = capability.name

    %{field: field, content_type: content_type, max_bytes: {limit_module, limit_function}} =
      item.upload

    %{status: large_status, type: large_type} = Map.fetch!(errors, :too_large)
    %{status: media_status, type: media_type} = Map.fetch!(errors, :unsupported_media_type)

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
      for {q, f} <- item.query do
        type = field_type.(capability, f)

        quote do
          {unquote(Atom.to_string(f)),
           case Map.fetch(query, unquote(q)) do
             {:ok, text} -> Runtime.coerce(unquote(Macro.escape(type)), text)
             :error -> nil
           end}
        end
      end

    header_reads =
      for {h, f} <- item.headers do
        type = field_type.(capability, f)
        {Atom.to_string(f), h, Macro.escape(type)}
      end

    quote do
      defp handle(unquote(key), conn, client, params, query) do
        _ = params
        _ = query

        limit =
          Runtime.limit!(
            unquote(limit_module).unquote(limit_function)(),
            unquote(limit_module),
            unquote(limit_function)
          )

        cond do
          not Runtime.media_type?(
            Plug.Conn.get_req_header(conn, "content-type"),
            unquote(content_type)
          ) ->
            conn
            |> close()
            |> problem(
              unquote(media_status),
              unquote(media_type),
              unquote("the body's content type is not #{content_type}")
            )

          Runtime.longer?(Plug.Conn.get_req_header(conn, "content-length"), limit) ->
            conn
            |> close()
            |> problem(
              unquote(large_status),
              unquote(large_type),
              "the body is larger than #{limit} bytes"
            )

          true ->
            case read_headers(conn, unquote(Macro.escape(header_reads))) do
              {:ok, headers} ->
                {ref, body} = Runtime.upload(conn, limit, &Plug.Conn.read_body/2)

                values =
                  Map.new(unquote(param_values))
                  |> Map.merge(Map.new(unquote(query_values)))
                  |> Map.merge(Map.new(headers))
                  |> Map.reject(fn {_k, v} -> is_nil(v) end)
                  |> Map.put(unquote(Atom.to_string(field)), body)

                try do
                  case unquote(input).new(values) do
                    {:ok, input} ->
                      outcome = unquote(facade).unquote(name)(client, input)
                      {conn, read?} = Runtime.uploaded(ref)
                      conn = if read?, do: conn, else: close(conn)

                      case outcome do
                        %{__struct__: module} when module in unquote(modules) ->
                          respond(conn, outcome)

                        other ->
                          refused(conn, other)
                      end

                    {:error, reasons} ->
                      conn |> close() |> error(:invalid, Enum.join(reasons, "; "))
                  end
                rescue
                  e in AtlasRuntimeBackend.Generator.Targets.Rest.BodyError ->
                    unless e.ref == ref, do: reraise(e, __STACKTRACE__)
                    {conn, _read?} = Runtime.uploaded(ref)
                    conn = close(conn)

                    case e.kind do
                      :too_large ->
                        problem(
                          conn,
                          unquote(large_status),
                          unquote(large_type),
                          "the body is larger than #{limit} bytes"
                        )

                      :unreadable ->
                        error(conn, :invalid, "the body could not be read to its end")
                    end
                after
                  Runtime.discard(ref)
                end

              {:error, conn, reasons} ->
                conn |> close() |> error(:invalid, Enum.join(reasons, "; "))
            end
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
                refused(conn, other)
            end
          else
            {:error, conn, reasons} -> error(conn, :invalid, Enum.join(reasons, "; "))
          end
        end
      end

    {handler, openings}
  end

  defp responder(module, %{stream: field} = status) when not is_nil(field) do
    quote do
      defp respond(conn, %{__struct__: unquote(module)} = outcome) do
        content = Map.fetch!(outcome, unquote(field))
        # Every field but the stream, for the headers: a stream is never dumped.
        dumped = unquote(module).dump(Map.put(outcome, unquote(field), nil))
        _ = dumped

        conn =
          Enum.reduce(unquote(header_values(status)), conn, fn
            {_name, nil}, conn -> conn
            {name, text}, conn -> Plug.Conn.put_resp_header(conn, name, text)
          end)

        conn
        |> Plug.Conn.put_resp_header("content-type", unquote(status.content_type))
        |> Plug.Conn.send_chunked(unquote(status.status))
        |> send_stream(content)
      end
    end
  end

  defp responder(module, status) do
    headers = header_values(status)

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
