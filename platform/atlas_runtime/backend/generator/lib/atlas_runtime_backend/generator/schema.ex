defmodule AtlasRuntimeBackend.Generator.Schema do
  @moduledoc """
  The schema of a backend contract, written as a DSL: how a system's boundary contract
  is carried across a process boundary. It names the boundary contract, declares once
  what every target shares (the capabilities exposed, the rights per listener, the
  events), and then, per target, how that exposure is mapped and shaped. Copied in part
  from Control's generator (`defmodel`-style declarations, `__schema__/0`) and written
  for backends.

      defmodule MyBackend.Lending do
        use AtlasRuntimeBackend.Generator.Schema

        version "1.0.0"
        boundary MyContracts.Lending

        expose [:lend, :find_book, :count, :watch]
        not_exposed :audit

        rights :socket, [:lend, :browse]

        event :book, :book_changed, id: :sequence
        event :reset, :restart, id: :current_sequence

        target :rest, carries: :entities do
          resource :post, "/v1/books", capability: :lend, body: :input,
            header: ["Request-Key": :request_key]
          resource :get, "/v1/books/:book_id", capability: :find_book, etag: :edition
          resource :get, "/v1/count", capability: :count
          stream "/v1/events", capability: :watch, events: [:book, :reset],
            resume_header: "Last-Event-ID", into: :from, open: [watching: nil, restart: :reset]

          status :lent, 201, header: [location: "/v1/books/{book.book_id}"]
          status :found, 200, body: :book
          status :busy, 503, type: "busy", header: ["Retry-After": :retry_after]
          status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}]
          status :missing, 404, type: "not-found"

          error :invalid, 400, type: "invalid"
          error :not_permitted, 403, type: "not-permitted"
          error :no_route, 404, type: "no-route"
        end
      end

  Shared, for every target:

  - `boundary Module`: the boundary contract, a module with `__schema__/0`
    (`%{models: [...], capabilities: [...]}`, optionally `targets: [atom]`, the boundary's
    own targets; without it the boundary has one, `:entities`). Only that schema is read.
  - `expose [capability]` and `not_exposed capability_or_list`: every capability of the
    boundary is exactly one of the two. Nothing is left out implicitly.
  - `rights listener, [right]`: the rights a client gets on that listener (a listener
    with its own identity, such as a socket peer, gets these); for a listener whose
    clients carry their own rights, such as a token, it is the ceiling those rights are
    cut to. Every right is a value of the boundary's client rights: the enum of the
    `rights` field (`{:list, {:enum, values}}`) of its `client` model. A boundary without
    that model has no rights to name, so a `rights` entry over it is a mistake.
  - `event name, model, id: field`: a notification the boundary's implementation sends
    to a subscriber, carried as event `name`; `model` is a boundary model; `id:` (optional)
    is an integer field of it that identifies the event for resuming.

  Per target, `target name, carries: boundary_target do ... end` (`carries:` defaults to
  `:entities`). Every boundary target is carried by at least one backend target.

  - `resource method, path, capability:, body:, header:, query:`: `method` is `:get`,
    `:post`, `:put`, `:patch` or `:delete`; `path` follows `AtlasRuntimeBackend.Generator.Paths`,
    and each `:param` is a field of the capability's input. `query: [param: field]` and
    `header: ["Header-Name": field]` bind request parts to input fields; `body: :input`
    takes every input field the path, query and headers do not bind from a JSON object,
    `body: [field]` takes exactly those. Each input field is bound once; a required one
    must be bound. Path, query and header values are text; they are converted to the
    field's type (`:string`, `:integer`, `:boolean`, an enum or a datetime) and then go
    through the input's `new/1` like a body.
    Two resources with the same method and path shape are told apart by their required
    query parameters: at most one of them has none.
    `etag: field` (GET only) makes the resource conditional: its capability has exactly
    one outcome with a status below 400 (a single code), and `field` is a required
    integer field of what that status sends (the `body:` entity, else the outcome). That
    outcome carries `ETag: "<field>"`, and an `If-None-Match` holding that tag (or `*`)
    gets 304 with the `ETag` and no body. Every other outcome, and every other resource,
    is answered as declared, with no `ETag`.
  - `stream path, capability:, events:, resume_header:, into:, open:`: a long-lived
    response that carries `events` (names of shared events) after the capability's
    outcome. `resume_header` is bound to the input field `into:`; `open:` names, for every
    outcome of the capability, the event sent first (`nil` for none), whose model must be
    the outcome's.
  - `status outcome, code, type:, header:`: the status of an outcome (an outcome name means
    the same in every capability of a boundary contract). `code` 400 and up needs a
    problem `type:`, below 400 has none. `header: [name: value]`, where `value` is a field
    of the outcome (left out when it has no value) or a text with `{field.field}`
    placeholders into the outcome. `body: field` (below 400 only): the body is that model
    field of the outcome, serialized directly (the outcome's entity, no envelope); without
    it the body is the outcome's fields.
    `stream: field, content_type: "type/subtype"` (a 2xx status only): the body is the
    outcome's `:stream` field, sent as it is, chunk by chunk, with that content type and
    no JSON. Its other fields go only where `header:` puts them. An outcome whose model
    has a `:stream` field needs it (its fields cannot be JSON), and a model has at most
    one; neither `body:` nor `etag:` goes with it.
    `status outcome, by: field, cases: [value: {code, type_or_nil}], header: ...`: the
    status depends on an enum field of the outcome; `cases` names each value once.
  - `error kind, code, type:`: the target's own refusals, each needed once: `:invalid`
    (a request that does not decode or does not build its input), `:not_permitted` (the
    boundary refused the client's rights) and `:no_route` (no resource has that method and
    path). A listener's refusals, before the router runs, are optional, each at most once:
    `:unauthenticated` (no valid credential; always 401) and `:origin_refused` (a request
    the listener does not take from a browser). A listener sends them, and any other error
    kind, with the router's `__problem__/2`, so it writes no problem body itself.

  Every mistake fails at compile time with a `CompileError` at its line, among them: an
  exposed name that is no boundary capability; a capability neither exposed nor
  `not_exposed`; a target that does not map an exposed capability, or maps one twice; a
  resource naming a capability that is not exposed; an outcome of a mapped capability
  without a status; a boundary target carried by no backend target; a right that is no
  value of the boundary's client rights; an outcome with a `:stream` field whose status
  has no `stream:` (or `stream:` naming no such field); a `:stream` field in an input, an
  event or an outcome of a stream (S5a carries a stream only as an outcome's body).

  ## The schema as data

  A backend contract compiles to `__schema__/0`; targets read only that and the
  boundary's `__schema__/0`:

      %{
        version: "1.0.0",
        file: "/abs/path/to/the/contract.ex",
        boundary: MyContracts.Lending,
        exposed: [atom],
        not_exposed: [atom],
        rights: [%{listener: atom, rights: [atom]}],
        events: [%{name: atom, model: atom, id: atom | nil}],
        targets: [
          %{name: atom, carries: atom,
            resources: [%{method: atom, path: text, capability: atom, params: [atom],
                          query: [{text, atom}], required: [text], headers: [{text, atom}],
                          body: [atom] | nil, etag: atom | nil}],
            streams: [%{path: text, capability: atom, events: [atom], resume_header: text,
                        into: atom, open: [{atom, atom | nil}]}],
            statuses: [%{outcome: atom, status: integer | nil, type: text | nil, by: atom | nil,
                         cases: [%{value: atom, status: integer, type: text | nil}],
                         headers: [{text, atom | text}], body: atom | nil,
                         stream: atom | nil, content_type: text | nil}],
            errors: [%{kind: atom, status: integer, type: text}]}
        ]
      }

  `required` are the query parameters bound to required input fields. Header names are
  lowercase. Everything is in the order written.
  """

  @methods [:get, :post, :put, :patch, :delete]
  @scalars [:string, :integer, :boolean, :datetime]
  @error_kinds [:invalid, :not_permitted, :no_route]
  # A listener's own refusals: optional, each at most once, with the status they must have
  # (nil: any status of 400 or more).
  @listener_error_kinds [unauthenticated: 401, origin_refused: nil]

  defmacro __using__(_opts) do
    quote do
      import AtlasRuntimeBackend.Generator.Schema,
        only: [
          version: 1,
          boundary: 1,
          expose: 1,
          not_exposed: 1,
          rights: 2,
          event: 2,
          event: 3,
          target: 2,
          target: 3
        ]

      Module.register_attribute(__MODULE__, :backend_entries, accumulate: true)
      @before_compile AtlasRuntimeBackend.Generator.Schema
    end
  end

  defmacro version(version), do: quote(do: @backend_version(unquote(version)))

  defmacro boundary(module) do
    %{file: file, line: line} = __CALLER__

    quote do
      require unquote(module)
      @backend_entries {:boundary, unquote(module), unquote(file), unquote(line)}
    end
  end

  defmacro expose(names), do: entry(:expose, names, __CALLER__)
  defmacro not_exposed(names), do: entry(:not_exposed, names, __CALLER__)

  defmacro rights(listener, rights), do: entry(:rights, {listener, rights}, __CALLER__)

  defmacro event(name, model, opts \\ []),
    do: entry(:event, quote(do: {unquote(name), unquote(model), unquote(opts)}), __CALLER__)

  defmacro target(name, opts \\ [], do: body) do
    %{file: file, line: line} = __CALLER__

    quote do
      if Module.get_attribute(__MODULE__, :backend_target_open),
        do:
          AtlasRuntimeBackend.Generator.Schema.__fail__(
            unquote(file),
            unquote(line),
            "a target inside a target"
          )

      Module.put_attribute(__MODULE__, :backend_target_open, true)
      Module.register_attribute(__MODULE__, :backend_target_entries, accumulate: true)

      import AtlasRuntimeBackend.Generator.Schema.Target,
        only: [resource: 3, stream: 2, status: 2, status: 3, error: 3]

      unquote(body)

      @backend_entries {:target,
                        {unquote(name), unquote(opts),
                         Enum.reverse(Module.get_attribute(__MODULE__, :backend_target_entries))},
                        unquote(file), unquote(line)}

      Module.delete_attribute(__MODULE__, :backend_target_entries)
      Module.delete_attribute(__MODULE__, :backend_target_open)
    end
  end

  defp entry(kind, value, %{file: file, line: line}) do
    quote do
      @backend_entries {unquote(kind), unquote(value), unquote(file), unquote(line)}
    end
  end

  @doc false
  def __fail__(file, line, description),
    do: raise(CompileError, file: file, line: line, description: description)

  defmacro __before_compile__(env) do
    entries = env.module |> Module.get_attribute(:backend_entries) |> Enum.reverse()

    version =
      Module.get_attribute(env.module, :backend_version) ||
        __fail__(env.file, 1, "the backend contract needs a version")

    spec = build!(entries, version, env.file)

    quote do
      @doc "The backend contract as plain data, for the targets (see `AtlasRuntimeBackend.Generator.Schema`)."
      def __schema__, do: unquote(Macro.escape(spec))
    end
  end

  ## Validation

  defp build!(entries, version, file) do
    by_kind = Enum.group_by(entries, &elem(&1, 0))

    {boundary, boundary_schema} =
      case Map.get(by_kind, :boundary, []) do
        [{:boundary, module, f, l}] ->
          {module, boundary_schema!(module, f, l)}

        [] ->
          __fail__(file, 1, "the backend contract needs `boundary Module`")

        [_, {:boundary, _module, f, l} | _] ->
          __fail__(f, l, "the backend contract names its boundary twice")
      end

    capabilities = Map.new(boundary_schema.capabilities, &{&1.name, &1})
    models = Map.new(boundary_schema.models, &{&1.name, &1})
    ctx = %{capabilities: capabilities, models: models}

    exposed = names!(Map.get(by_kind, :expose, []), capabilities, "expose")
    not_exposed = names!(Map.get(by_kind, :not_exposed, []), capabilities, "not_exposed")

    for {name, {f, l}} <- exposed, Map.has_key?(not_exposed, name) do
      __fail__(f, l, "capability #{inspect(name)} is both exposed and not_exposed")
    end

    unmarked =
      for c <- boundary_schema.capabilities,
          not Map.has_key?(exposed, c.name) and not Map.has_key?(not_exposed, c.name),
          do: c.name

    if unmarked != [] do
      __fail__(
        file,
        1,
        "capability #{Enum.map_join(unmarked, ", ", &inspect/1)} of #{inspect(boundary)} is " <>
          "neither exposed nor not_exposed"
      )
    end

    exposed_names =
      for c <- boundary_schema.capabilities, Map.has_key?(exposed, c.name), do: c.name

    not_exposed_names =
      for c <- boundary_schema.capabilities, Map.has_key?(not_exposed, c.name), do: c.name

    rights = rights!(Map.get(by_kind, :rights, []), client_rights(models), boundary)
    events = events!(Map.get(by_kind, :event, []), models)

    targets =
      for {:target, value, f, l} <- Map.get(by_kind, :target, []),
          do: target!(value, f, l, ctx, exposed_names, events)

    if targets == [], do: __fail__(file, 1, "the backend contract needs at least one target")

    case Enum.map(targets, & &1.name) -- Enum.uniq(Enum.map(targets, & &1.name)) do
      [] -> :ok
      [twice | _] -> __fail__(file, 1, "target #{inspect(twice)} is declared twice")
    end

    boundary_targets = Map.get(boundary_schema, :targets, [:entities])

    for target <- targets, target.carries not in boundary_targets do
      {f, l} = target.at

      __fail__(
        f,
        l,
        "target #{inspect(target.name)} carries #{inspect(target.carries)}, which is no target of " <>
          "#{inspect(boundary)} (#{Enum.map_join(boundary_targets, ", ", &inspect/1)})"
      )
    end

    for boundary_target <- boundary_targets,
        not Enum.any?(targets, &(&1.carries == boundary_target)) do
      __fail__(
        file,
        1,
        "boundary target #{inspect(boundary_target)} of #{inspect(boundary)} is carried by no backend target"
      )
    end

    %{
      version: version,
      file: file,
      boundary: boundary,
      exposed: exposed_names,
      not_exposed: not_exposed_names,
      rights: rights,
      events: Enum.map(events, &Map.delete(&1, :at)),
      targets: Enum.map(targets, &Map.delete(&1, :at))
    }
  end

  defp boundary_schema!(module, file, line) do
    unless is_atom(module) and Code.ensure_compiled(module) == {:module, module} and
             function_exported?(module, :__schema__, 0),
           do:
             __fail__(
               file,
               line,
               "boundary #{inspect(module)} is no compiled contract with __schema__/0"
             )

    schema = module.__schema__()

    unless is_map(schema) and is_list(Map.get(schema, :models)) and
             is_list(Map.get(schema, :capabilities)),
           do:
             __fail__(
               file,
               line,
               "boundary #{inspect(module)}: __schema__/0 has no models and capabilities"
             )

    schema
  end

  # %{name => {file, line}} for `expose`/`not_exposed` entries, each a boundary capability.
  defp names!(entries, capabilities, what) do
    Enum.reduce(entries, %{}, fn {_kind, names, f, l}, acc ->
      names = List.wrap(names)

      unless names != [] and Enum.all?(names, &is_atom/1),
        do: __fail__(f, l, "#{what} takes a capability or a list of them")

      Enum.reduce(names, acc, fn name, acc ->
        unless Map.has_key?(capabilities, name),
          do: __fail__(f, l, "#{what} #{inspect(name)}: no capability of the boundary")

        if Map.has_key?(acc, name), do: __fail__(f, l, "#{what} names #{inspect(name)} twice")
        Map.put(acc, name, {f, l})
      end)
    end)
  end

  defp rights!(entries, known, boundary) do
    {rights, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn {:rights, {listener, rights}, f, l}, seen ->
        unless snake?(listener), do: __fail__(f, l, "rights: the listener is a snake_case atom")

        if listener in seen,
          do: __fail__(f, l, "rights for #{inspect(listener)} are declared twice")

        unless is_list(rights) and Enum.all?(rights, &snake?/1) and Enum.uniq(rights) == rights,
          do: __fail__(f, l, "rights #{inspect(listener)}: a list of snake_case atoms, each once")

        if is_nil(known),
          do:
            __fail__(
              f,
              l,
              "rights #{inspect(listener)}: #{inspect(boundary)} declares no client rights " <>
                "(a :client model with rights: {:list, {:enum, [right]}})"
            )

        case Enum.reject(rights, &(&1 in known)) do
          [] ->
            :ok

          unknown ->
            __fail__(
              f,
              l,
              "rights #{inspect(listener)}: #{Enum.map_join(unknown, ", ", &inspect/1)} is no " <>
                "client right of #{inspect(boundary)} (#{Enum.map_join(known, ", ", &inspect/1)})"
            )
        end

        {%{listener: listener, rights: rights}, MapSet.put(seen, listener)}
      end)

    rights
  end

  # The values of the boundary's client rights, or nil when it declares none.
  defp client_rights(models) do
    with %{fields: fields} <- models[:client],
         %{type: {:list, {:enum, values}}} <- Enum.find(fields, &(&1.name == :rights)) do
      values
    else
      _ -> nil
    end
  end

  defp events!(entries, models) do
    {events, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn {:event, {name, model, opts}, f, l}, seen ->
        fail = &__fail__(f, l, &1)
        unless snake?(name), do: fail.("event #{inspect(name)} is not a snake_case atom")
        if name in seen, do: fail.("event #{inspect(name)} is declared twice")

        unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:id] == [],
          do: fail.("event #{inspect(name)}: the only option is id:")

        model_spec =
          models[model] || fail.("event #{inspect(name)}: #{inspect(model)} is no boundary model")

        for field <- stream_fields(model_spec) do
          fail.(
            "event #{inspect(name)}: #{inspect(model)}.#{field} is a :stream; an event is JSON"
          )
        end

        id = opts[:id]

        if id do
          case Enum.find(model_spec.fields, &(&1.name == id)) do
            %{type: :integer, required: true} ->
              :ok

            _ ->
              fail.(
                "event #{inspect(name)}: id #{inspect(id)} is no required integer field of #{inspect(model)}"
              )
          end
        end

        {%{name: name, model: model, id: id, at: {f, l}}, MapSet.put(seen, name)}
      end)

    events
  end

  defp target!({name, opts, entries}, file, line, ctx, exposed, events) do
    fail = &__fail__(file, line, &1)
    unless snake?(name), do: fail.("target #{inspect(name)} is not a snake_case atom")

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:carries] == [],
      do: fail.("target #{inspect(name)}: the only option is carries:")

    carries = Keyword.get(opts, :carries, :entities)
    by_kind = Enum.group_by(entries, &elem(&1, 0))

    resources =
      for {:resource, value, f, l} <- Map.get(by_kind, :resource, []),
          do: resource!(value, f, l, ctx)

    streams =
      for {:stream, value, f, l} <- Map.get(by_kind, :stream, []),
          do: stream!(value, f, l, ctx, events)

    mapped = resources ++ streams

    for item <- mapped, item.capability not in exposed do
      {f, l} = item.at

      __fail__(
        f,
        l,
        "capability #{inspect(item.capability)} is not exposed; expose it or leave it out"
      )
    end

    Enum.reduce(mapped, MapSet.new(), fn item, seen ->
      {f, l} = item.at

      if item.capability in seen,
        do:
          __fail__(
            f,
            l,
            "target #{inspect(name)} maps capability #{inspect(item.capability)} twice"
          )

      MapSet.put(seen, item.capability)
    end)

    for capability <- exposed, not Enum.any?(mapped, &(&1.capability == capability)) do
      fail.("target #{inspect(name)} does not map the exposed capability #{inspect(capability)}")
    end

    distinguishable!(resources)

    statuses = statuses!(Map.get(by_kind, :status, []), ctx)

    for item <- resources,
        outcome <- ctx.capabilities[item.capability].outcomes,
        not Enum.any?(statuses, &(&1.outcome == outcome.name)) do
      {f, l} = item.at

      __fail__(
        f,
        l,
        "outcome #{inspect(outcome.name)} of capability #{inspect(item.capability)} has no status in target #{inspect(name)}"
      )
    end

    used =
      MapSet.new(
        for item <- resources, o <- ctx.capabilities[item.capability].outcomes, do: o.name
      )

    for status <- statuses, status.outcome not in used do
      {f, l} = status.at

      __fail__(
        f,
        l,
        "status #{inspect(status.outcome)}: no resource of target #{inspect(name)} has that outcome"
      )
    end

    for item <- resources, item.etag, do: etag!(item, ctx, statuses)

    errors = errors!(Map.get(by_kind, :error, []), file, line)

    %{
      name: name,
      carries: carries,
      at: {file, line},
      resources: Enum.map(resources, &Map.delete(&1, :at)),
      streams: Enum.map(streams, &Map.delete(&1, :at)),
      statuses: Enum.map(statuses, &Map.delete(&1, :at)),
      errors: errors
    }
  end

  defp resource!({method, path, opts}, f, l, ctx) do
    fail = &__fail__(f, l, &1)

    unless method in @methods,
      do:
        fail.(
          "resource #{inspect(path)}: the method is one of #{Enum.map_join(@methods, ", ", &inspect/1)}"
        )

    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:capability, :body, :header, :query, :etag] == [],
           do:
             fail.(
               "resource #{inspect(path)}: the options are capability:, body:, header:, query: and etag:"
             )

    capability = capability!(opts[:capability], ctx, fail)
    input = capability.input && ctx.models[capability.input]
    fields = if input, do: Map.new(input.fields, &{&1.name, &1}), else: %{}
    segments = segments!(path, fail)
    params = for {:param, p} <- segments, do: p

    for field <- stream_fields(input) do
      fail.(
        "resource #{method} #{path}: input field #{inspect(field)} is a :stream; a stream " <>
          "is carried only as an outcome's body"
      )
    end

    for p <- params, not Map.has_key?(fields, p) do
      fail.(
        "resource #{method} #{path}: path parameter :#{p} is no field of #{inspect(capability.input)}"
      )
    end

    query = pairs!(opts[:query] || [], "query", fields, capability, fail, &Atom.to_string/1)

    headers =
      pairs!(
        opts[:header] || [],
        "header",
        fields,
        capability,
        fail,
        &(&1 |> Atom.to_string() |> String.downcase())
      )

    for {kind, list} <- [
          {"query parameter", Enum.map(query, &elem(&1, 0))},
          {"header", Enum.map(headers, &elem(&1, 0))}
        ],
        Enum.uniq(list) != list do
      fail.("resource #{method} #{path}: a #{kind} is named twice")
    end

    for field <- params, do: scalar!(fields[field], "path parameter :#{field}", fail)

    for {_name, field} <- query ++ headers, do: scalar!(fields[field], "#{field}", fail)

    bound = params ++ Enum.map(query, &elem(&1, 1)) ++ Enum.map(headers, &elem(&1, 1))

    case bound -- Enum.uniq(bound) do
      [] ->
        :ok

      [twice | _] ->
        fail.("resource #{method} #{path}: input field #{inspect(twice)} is bound twice")
    end

    body =
      case opts[:body] do
        nil ->
          nil

        :input ->
          unless input,
            do:
              fail.(
                "resource #{method} #{path}: #{inspect(capability.name)} takes no input, so no body"
              )

          for field <- input.fields, field.name not in bound, do: field.name

        list when is_list(list) ->
          for field <- list do
            unless Map.has_key?(fields, field),
              do:
                fail.(
                  "resource #{method} #{path}: body field #{inspect(field)} is no field of #{inspect(capability.input)}"
                )

            if field in bound,
              do:
                fail.("resource #{method} #{path}: input field #{inspect(field)} is bound twice")
          end

          if Enum.uniq(list) != list,
            do: fail.("resource #{method} #{path}: a body field is named twice")

          list

        other ->
          fail.(
            "resource #{method} #{path}: body: is :input or a list of input fields, got #{inspect(other)}"
          )
      end

    if body && method in [:get, :delete],
      do:
        fail.(
          "resource #{method} #{path}: a #{String.upcase(Atom.to_string(method))} takes no body"
        )

    etag = opts[:etag]

    if etag != nil do
      unless snake?(etag),
        do: fail.("resource #{method} #{path}: etag: is a field name, got #{inspect(etag)}")

      unless method == :get,
        do: fail.("resource #{method} #{path}: etag: goes with a GET")
    end

    for field <- Map.values(fields),
        field.required,
        field.name not in bound,
        field.name not in (body || []) do
      fail.(
        "resource #{method} #{path}: required input field #{inspect(field.name)} is bound to nothing"
      )
    end

    %{
      method: method,
      path: path,
      capability: capability.name,
      params: params,
      query: query,
      required: for({name, field} <- query, fields[field].required, do: name),
      headers: headers,
      body: body,
      etag: etag,
      at: {f, l}
    }
  end

  # etag: is a required integer field of what the capability's one success outcome sends.
  defp etag!(item, ctx, statuses) do
    {f, l} = item.at
    at = "resource #{item.method} #{item.path}: etag: #{inspect(item.etag)}"
    by_outcome = Map.new(statuses, &{&1.outcome, &1})

    success =
      for o <- ctx.capabilities[item.capability].outcomes,
          status = by_outcome[o.name],
          Enum.any?([status.status | Enum.map(status.cases, & &1.status)], &(&1 && &1 < 400)),
          do: {o, status}

    {outcome, status} =
      case success do
        [{_o, %{by: nil}} = one] ->
          one

        _ ->
          __fail__(
            f,
            l,
            "#{at}: capability #{inspect(item.capability)} needs exactly one outcome with a " <>
              "single status below 400 to carry the tag"
          )
      end

    if status.stream,
      do:
        __fail__(
          f,
          l,
          "#{at}: outcome #{inspect(outcome.name)} is a stream (stream: #{inspect(status.stream)}); " <>
            "a stream carries no tag"
        )

    model_name =
      if status.body,
        do: Enum.find(ctx.models[outcome.model].fields, &(&1.name == status.body)).type,
        else: outcome.model

    fields = if model_name, do: ctx.models[model_name].fields, else: []

    unless match?(
             %{type: :integer, required: true},
             Enum.find(fields, &(&1.name == item.etag))
           ),
           do:
             __fail__(
               f,
               l,
               "#{at} is no required integer field of #{inspect(model_name)}, which outcome " <>
                 "#{inspect(outcome.name)} sends"
             )

    :ok
  end

  defp stream!({path, opts}, f, l, ctx, events) do
    fail = &__fail__(f, l, &1)

    unless Keyword.keyword?(opts) and
             Enum.sort(Keyword.keys(opts)) == [:capability, :events, :into, :open, :resume_header],
           do:
             fail.(
               "stream #{inspect(path)}: the options are capability:, events:, resume_header:, into: and open:"
             )

    capability = capability!(opts[:capability], ctx, fail)
    segments = segments!(path, fail)

    if Enum.any?(segments, &match?({:param, _}, &1)),
      do: fail.("stream #{path}: a stream path has no parameters")

    input = capability.input && ctx.models[capability.input]
    fields = if input, do: Map.new(input.fields, &{&1.name, &1}), else: %{}
    into = opts[:into]

    case fields[into] do
      %{type: :integer} ->
        :ok

      _ ->
        fail.(
          "stream #{path}: into: #{inspect(into)} is no integer field of #{inspect(capability.input)}"
        )
    end

    for field <- Map.values(fields), field.name != into, field.required do
      fail.("stream #{path}: required input field #{inspect(field.name)} is bound to nothing")
    end

    header = opts[:resume_header]

    unless is_binary(header) and header != "",
      do: fail.("stream #{path}: resume_header: is a header name")

    names = opts[:events]
    by_name = Map.new(events, &{&1.name, &1})

    unless is_list(names) and names != [] and Enum.uniq(names) == names,
      do: fail.("stream #{path}: events: is a list of event names, each once")

    for name <- names,
        not Map.has_key?(by_name, name),
        do: fail.("stream #{path}: #{inspect(name)} is no declared event")

    open = opts[:open]
    unless Keyword.keyword?(open), do: fail.("stream #{path}: open: is [outcome: event or nil]")
    outcomes = capability.outcomes

    for outcome <- outcomes, not Keyword.has_key?(open, outcome.name) do
      fail.(
        "stream #{path}: outcome #{inspect(outcome.name)} of #{inspect(capability.name)} has no open: entry"
      )
    end

    for outcome <- outcomes,
        field <- stream_fields(outcome.model && ctx.models[outcome.model]) do
      fail.(
        "stream #{path}: outcome #{inspect(outcome.name)} has the :stream field #{inspect(field)}; " <>
          "an event stream carries no byte stream"
      )
    end

    for {outcome, event} <- open do
      spec =
        Enum.find(outcomes, &(&1.name == outcome)) ||
          fail.(
            "stream #{path}: #{inspect(outcome)} is no outcome of #{inspect(capability.name)}"
          )

      if event do
        unless event in names,
          do: fail.("stream #{path}: open: #{inspect(event)} is not among its events")

        if by_name[event].model != spec.model,
          do:
            fail.(
              "stream #{path}: outcome #{inspect(outcome)} carries #{inspect(spec.model)}, event #{inspect(event)} carries #{inspect(by_name[event].model)}"
            )
      end
    end

    %{
      path: path,
      capability: capability.name,
      events: names,
      resume_header: String.downcase(header),
      into: into,
      open: open,
      at: {f, l}
    }
  end

  defp statuses!(entries, ctx) do
    outcomes =
      for c <- Map.values(ctx.capabilities), o <- c.outcomes, into: %{}, do: {o.name, o.model}

    {statuses, _seen} =
      Enum.map_reduce(entries, MapSet.new(), fn {:status, {outcome, code, opts}, f, l}, seen ->
        fail = &__fail__(f, l, &1)

        unless Map.has_key?(outcomes, outcome),
          do: fail.("status #{inspect(outcome)}: no outcome of the boundary")

        if outcome in seen, do: fail.("status #{inspect(outcome)} is declared twice")
        model = outcomes[outcome] && ctx.models[outcomes[outcome]]
        fields = if model, do: model.fields, else: []

        {opts, by_opts} =
          case code do
            code when is_integer(code) ->
              {opts, nil}

            by when is_list(by) and opts == [] ->
              {Keyword.drop(by, [:by, :cases]), Keyword.take(by, [:by, :cases])}

            _ ->
              fail.(
                "status #{inspect(outcome)}: status outcome, code, opts or status outcome, by:, cases:"
              )
          end

        unless Keyword.keyword?(opts) and
                 Keyword.keys(opts) -- [:type, :header, :body, :stream, :content_type] == [],
               do:
                 fail.(
                   "status #{inspect(outcome)}: the options are type:, header:, body:, stream: " <>
                     "and content_type: (or by: and cases:)"
                 )

        body = opts[:body]
        stream = stream!(outcome, opts, by_opts, code, model, fail)

        if body do
          unless match?(
                   %{type: model, required: true}
                   when is_atom(model) and is_map_key(ctx.models, model),
                   Enum.find(fields, &(&1.name == body))
                 ),
                 do:
                   fail.(
                     "status #{inspect(outcome)}: body: #{inspect(body)} is no required model field of its model"
                   )

          if by_opts,
            do: fail.("status #{inspect(outcome)}: body: goes with a single status code")
        end

        headers =
          for {name, value} <- opts[:header] || [] do
            header_value!(value, fields, ctx, outcome, fail)
            {name |> to_string() |> String.downcase(), value}
          end

        base = %{
          outcome: outcome,
          status: nil,
          type: nil,
          by: nil,
          cases: [],
          headers: headers,
          body: body,
          stream: stream,
          content_type: stream && opts[:content_type],
          at: {f, l}
        }

        status =
          if by_opts do
            field = by_opts[:by]

            values =
              case Enum.find(fields, &(&1.name == field)) do
                %{type: {:enum, values}, required: true} ->
                  values

                _ ->
                  fail.(
                    "status #{inspect(outcome)}: by: #{inspect(field)} is no required enum field of its model"
                  )
              end

            if opts[:type],
              do: fail.("status #{inspect(outcome)}: with by:, each case has its type")

            cases = by_opts[:cases]

            unless Keyword.keyword?(cases),
              do: fail.("status #{inspect(outcome)}: cases: is [value: {code, type}]")

            for value <- values, not Keyword.has_key?(cases, value) do
              fail.("status #{inspect(outcome)}: #{field} #{inspect(value)} has no case")
            end

            cases =
              for {value, spec} <- cases do
                unless value in values,
                  do:
                    fail.("status #{inspect(outcome)}: #{inspect(value)} is no value of #{field}")

                {code, type} =
                  case spec do
                    {code, type} -> {code, type}
                    code -> {code, nil}
                  end

                code!(code, type, "status #{inspect(outcome)} #{value}", fail)
                %{value: value, status: code, type: type}
              end

            if Enum.uniq_by(cases, & &1.value) != cases,
              do: fail.("status #{inspect(outcome)}: a value has two cases")

            %{base | by: field, cases: cases}
          else
            code!(code, opts[:type], "status #{inspect(outcome)}", fail)

            if body && code >= 400,
              do:
                fail.(
                  "status #{inspect(outcome)}: a problem body is the outcome's fields; no body:"
                )

            %{base | status: code, type: opts[:type]}
          end

        {status, MapSet.put(seen, outcome)}
      end)

    statuses
  end

  # A status's stream: the outcome's one :stream field, sent as the body with its
  # content_type:, from a single 2xx status. Gives the field, or nil.
  defp stream!(outcome, opts, by_opts, code, model, fail) do
    at = "status #{inspect(outcome)}"
    stream = opts[:stream]
    content_type = opts[:content_type]

    case {stream_fields(model), stream} do
      {[], nil} ->
        :ok

      {[field | _], nil} ->
        fail.(
          "#{at}: its model has the :stream field #{inspect(field)}, which is no JSON; " <>
            "send it with stream: #{inspect(field)}, content_type: \"...\""
        )

      {fields, stream} ->
        unless stream in fields and
                 match?(%{required: true}, Enum.find(model.fields, &(&1.name == stream))),
               do:
                 fail.(
                   "#{at}: stream: #{inspect(stream)} is no required :stream field of its model"
                 )

        case fields -- [stream] do
          [] -> :ok
          [other | _] -> fail.("#{at}: its model has a second :stream field, #{inspect(other)}")
        end
    end

    if stream do
      if by_opts, do: fail.("#{at}: stream: goes with a single status code")
      if opts[:body], do: fail.("#{at}: stream: and body: exclude each other")

      unless is_integer(code) and code in 200..299,
        do: fail.("#{at}: a stream is sent with a 2xx status")

      unless is_binary(content_type) and
               Regex.match?(
                 ~r{^[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*$},
                 content_type
               ),
             do: fail.("#{at}: stream: needs content_type: \"type/subtype\" (lowercase)")
    else
      if content_type != nil, do: fail.("#{at}: content_type: goes with stream:")
    end

    stream
  end

  defp stream_fields(nil), do: []
  defp stream_fields(model), do: for(%{type: :stream, name: name} <- model.fields, do: name)

  defp errors!(entries, file, line) do
    errors =
      for {:error, {kind, code, opts}, f, l} <- entries do
        fail = &__fail__(f, l, &1)

        kinds = @error_kinds ++ Keyword.keys(@listener_error_kinds)

        unless kind in kinds,
          do:
            fail.(
              "error #{inspect(kind)}: the kinds are #{Enum.map_join(kinds, ", ", &inspect/1)}"
            )

        unless Keyword.keyword?(opts) and Keyword.keys(opts) == [:type],
          do: fail.("error #{inspect(kind)}: the only option is type:")

        unless is_integer(code) and code >= 400,
          do: fail.("error #{inspect(kind)}: the status is 400 or more")

        code!(code, opts[:type], "error #{inspect(kind)}", fail)

        case @listener_error_kinds[kind] do
          nil -> :ok
          ^code -> :ok
          required -> fail.("error #{inspect(kind)}: the status is #{required}")
        end

        %{kind: kind, status: code, type: opts[:type]}
      end

    for kind <- @error_kinds do
      case Enum.count(errors, &(&1.kind == kind)) do
        1 -> :ok
        0 -> __fail__(file, line, "the target needs `error #{inspect(kind)}, code, type: ...`")
        _ -> __fail__(file, line, "error #{inspect(kind)} is declared twice")
      end
    end

    for {kind, _status} <- @listener_error_kinds,
        Enum.count(errors, &(&1.kind == kind)) > 1 do
      __fail__(file, line, "error #{inspect(kind)} is declared twice")
    end

    errors
  end

  defp code!(code, type, at, fail) do
    unless is_integer(code) and code in 200..599,
      do: fail.("#{at}: #{inspect(code)} is no HTTP status")

    cond do
      code >= 400 and not (is_binary(type) and Regex.match?(~r/^[a-z][a-z0-9-]*$/, type)) ->
        fail.("#{at}: a status of 400 or more needs a problem type: \"kebab-case\"")

      code < 400 and type != nil ->
        fail.("#{at}: a status below 400 has no problem type")

      true ->
        :ok
    end
  end

  defp header_value!(field, fields, _ctx, outcome, fail) when is_atom(field) do
    case Enum.find(fields, &(&1.name == field)) do
      %{type: type} when type in @scalars ->
        :ok

      _ ->
        fail.(
          "status #{inspect(outcome)}: header field #{inspect(field)} is no scalar field of its model"
        )
    end
  end

  defp header_value!(template, fields, ctx, outcome, fail) when is_binary(template) do
    for [_, path] <- Regex.scan(~r/\{([a-z0-9_.]+)\}/, template) do
      path = path |> String.split(".") |> Enum.map(&String.to_atom/1)

      unless field_path?(path, fields, ctx),
        do:
          fail.(
            "status #{inspect(outcome)}: {#{Enum.join(path, ".")}} is no required scalar field of its model"
          )
    end

    :ok
  end

  defp header_value!(other, _fields, _ctx, outcome, fail),
    do:
      fail.(
        "status #{inspect(outcome)}: a header value is a field or a text, got #{inspect(other)}"
      )

  defp field_path?([name], fields, _ctx),
    do:
      match?(
        %{type: type, required: true} when type in @scalars,
        Enum.find(fields, &(&1.name == name))
      )

  defp field_path?([name | rest], fields, ctx) do
    case Enum.find(fields, &(&1.name == name)) do
      %{type: model, required: true} when is_atom(model) and is_map_key(ctx.models, model) ->
        field_path?(rest, ctx.models[model].fields, ctx)

      _ ->
        false
    end
  end

  defp capability!(name, ctx, fail) do
    ctx.capabilities[name] || fail.("#{inspect(name)} is no capability of the boundary")
  end

  defp segments!(path, fail) do
    case AtlasRuntimeBackend.Generator.Paths.parse(path) do
      {:ok, segments} -> segments
      {:error, why} -> fail.(why)
    end
  end

  defp pairs!(pairs, what, fields, capability, fail, name_of) do
    unless Keyword.keyword?(pairs), do: fail.("#{what}: is [name: input_field]")

    for {name, field} <- pairs do
      unless Map.has_key?(fields, field),
        do:
          fail.("#{what} #{name}: #{inspect(field)} is no field of #{inspect(capability.input)}")

      {name_of.(name), field}
    end
  end

  defp scalar!(%{type: type}, _at, _fail) when type in @scalars, do: :ok
  defp scalar!(%{type: {:enum, _}}, _at, _fail), do: :ok

  defp scalar!(_field, at, fail),
    do:
      fail.(
        "#{at}: only a text, integer, boolean, enum or datetime field binds to a path, query or header"
      )

  # Same method and path shape: told apart by the required query parameters.
  defp distinguishable!(resources) do
    resources
    |> Enum.group_by(fn r ->
      {:ok, segments} = AtlasRuntimeBackend.Generator.Paths.parse(r.path)
      {r.method, AtlasRuntimeBackend.Generator.Paths.shape(segments)}
    end)
    |> Enum.each(fn {_key, group} ->
      case for(%{required: []} = r <- group, do: r) do
        [_, second | _] ->
          {f, l} = second.at

          __fail__(
            f,
            l,
            "resource #{second.method} #{second.path}: another resource has the same method and path, " <>
              "and neither needs a query parameter"
          )

        _ ->
          :ok
      end

      group
      |> Enum.reject(&(&1.required == []))
      |> Enum.group_by(&Enum.sort(&1.required))
      |> Enum.each(fn
        {_names, [_one]} ->
          :ok

        {_names, [_, second | _]} ->
          {f, l} = second.at

          __fail__(
            f,
            l,
            "resource #{second.method} #{second.path}: another resource has the same method, path " <>
              "and required query parameters"
          )
      end)
    end)
  end

  defp snake?(name),
    do:
      is_atom(name) and name not in [nil, true, false] and
        Regex.match?(~r/^[a-z][a-z0-9_]*$/, Atom.to_string(name))
end

defmodule AtlasRuntimeBackend.Generator.Schema.Target do
  @moduledoc false
  # What a `target ... do ... end` block of `AtlasRuntimeBackend.Generator.Schema` may say.

  defmacro resource(method, path, opts),
    do: entry(:resource, quote(do: {unquote(method), unquote(path), unquote(opts)}), __CALLER__)

  defmacro stream(path, opts), do: entry(:stream, {path, opts}, __CALLER__)

  defmacro status(outcome, code_or_opts, opts \\ []),
    do:
      entry(
        :status,
        quote(do: {unquote(outcome), unquote(code_or_opts), unquote(opts)}),
        __CALLER__
      )

  defmacro error(kind, code, opts),
    do: entry(:error, quote(do: {unquote(kind), unquote(code), unquote(opts)}), __CALLER__)

  defp entry(kind, value, %{file: file, line: line}) do
    quote do
      unless Module.get_attribute(__MODULE__, :backend_target_open),
        do:
          AtlasRuntimeBackend.Generator.Schema.__fail__(
            unquote(file),
            unquote(line),
            "#{unquote(kind)} outside a target"
          )

      @backend_target_entries {unquote(kind), unquote(value), unquote(file), unquote(line)}
    end
  end
end
