defmodule AtlasRuntimeBackend.Generator.Targets.Client.Transport do
  @moduledoc """
  How a client made by `AtlasRuntimeBackend.Generator.Targets.Client` reaches its server.
  The client builds every request from the contract and decodes every answer; a transport
  only carries them (connection, proxy, TLS, credentials). A transport never retries, and
  neither does the client: a failure goes back to the caller as `{:error, :unreachable}`.

  A request is `%{method: "GET" | "POST" | ..., path: text, query: text, headers:
  [{lowercase_name, text}], body: binary | nil}`: `path` is percent-encoded, `query` is an
  encoded query string (`""` for none) and `body` is JSON or `nil` for none.
  """

  @type request :: %{
          method: String.t(),
          path: String.t(),
          query: String.t(),
          headers: [{String.t(), String.t()}],
          body: binary() | nil
        }

  @type response :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @typedoc """
  A streamed answer: the status and headers, and the body as an enumerable of binaries
  read as they arrive. A failure while reading is one last element `{:error, reason}`.
  """
  @type streamed :: %{
          status: non_neg_integer(),
          headers: [{String.t(), String.t()}],
          body: Enumerable.t()
        }

  @doc "One request and its whole answer, or `{:error, reason}` when there is none."
  @callback request(request(), opts :: keyword()) :: {:ok, response()} | {:error, term()}

  @doc "One long-lived request (a stream), answered as it arrives."
  @callback stream(request(), opts :: keyword()) :: {:ok, streamed()} | {:error, term()}
end

defmodule AtlasRuntimeBackend.Generator.Targets.Client do
  @moduledoc """
  A compile-time target: typed Elixir calls for one target block of a backend contract,
  made from its `__schema__/0` and the boundary's when the module that uses it compiles.
  It is the other direction of `AtlasRuntimeBackend.Generator.Targets.Rest`: the same
  routes, statuses and serialization, so client and server come from one contract. No file
  is written.

      defmodule MyClient.Lending do
        use AtlasRuntimeBackend.Generator.Targets.Client,
          contract: MyBackend.Lending,
          transport: MyClient.Transport
      end

  Options:
  - `contract:` the backend contract (`AtlasRuntimeBackend.Generator.Schema`);
  - `transport:` a module with the behaviour
    `AtlasRuntimeBackend.Generator.Targets.Client.Transport` (`stream/2` only when the
    target has a stream);
  - `target:` the target block it calls (default: the contract's only target).

  ## The calls

  One function per exposed capability, named after it: `name(input \\\\ %{}, opts \\\\ [])`,
  or `name(opts \\\\ [])` for a capability without input. `input` is the capability's input
  model as a map with atom keys (see Values). The client checks it against the model
  (unknown or unbound fields, required fields, types) and answers
  `{:error, {:invalid, [reason]}}` without a request when it does not fit. It then puts each
  field where the resource binds it (path, query, header or JSON body). A header bound to an
  input field is sent only when the field has a value: the client never makes one up.

  `opts`:
  - `transport:` options passed on to the transport as they are;
  - `if_none_match:` (only on a resource that declares an entity tag, `etag:`): the tag
    the caller holds, as the integer it is made of (sent as `"7"`) or as the tag's text.

  ## The answers

  The client sends each request exactly once. It never retries; the caller decides
  (and can send the same request again, with the same values, after `:unreachable`).

  - An outcome of the capability: `name` when its model is `nil`, else `{name, fields}`,
    `fields` being the outcome model's fields. A status with `body:` carries only its
    entity, so `fields` is that one field (`%{book: ...}`): the model's other fields are not
    on the wire and are left out, not `nil` (the contract says where a caller finds them,
    if in the entity). An outcome is recognised by its declared status, and from 400
    up also by its problem `type` and, for a status `by:` a field, by that field's value.
  - `:not_modified`: 304 on a resource with an entity tag.
  - `{:error, :unauthenticated}`: 401, whatever its body.
  - One of the target's own errors (`error kind, code, type:`), by status and type:
    `{:error, {:invalid, detail}}` for `:invalid`, `{:error, kind}` for any other.
  - `{:error, :unreachable}`: the transport failed, or the status and type are none of
    the above. That includes a 502, 503 or 504 without a declared problem type (a proxy
    in front of a server that is down), which is never an outcome.
  - `{:error, {:invalid_response, [reason]}}`: an outcome was recognised, but its body
    does not decode into the outcome's model.

  A stream's function answers `{:ok, events}` (or an error as above, before the stream
  opens): `events` is a lazy enumerable of `{event_name, fields}` (the event's model
  fields), the opening event first when the capability's outcome opens with one. It ends
  when the transport's body ends; a failure while reading ends it with
  `{:error, :unreachable}`, and an event that does not decode with
  `{:error, {:invalid_response, [reason]}}`. An event name the contract does not declare
  is skipped. The stream's resume header is the input field the contract binds it to.

  ## Values

  As the boundary schema types them: text, integers, booleans, `DateTime`, an enum value
  as its atom, a model as a map with atom keys (every field present, `nil` when absent),
  `{:list, t}` as a list, `{:map, t}` as a map with text keys, and a `one_of` as its
  member model's map with the tag field (an atom key) naming the member as an atom
  (`%{kind: :shelf, row: 2}`). Decoding ignores fields the model does not declare.

  ## At compile time

  Each of these is a `CompileError`: an exposed capability that the target maps to no
  resource or stream (the client would miss it); an outcome of a resource without a
  status; two outcomes of one capability that the client cannot tell apart (the same
  status below 400, or the same status and type from 400 up); a transport without the
  callbacks it needs.

  The generated module also has `__capabilities__/0`, the names of its calls in order.
  """

  alias AtlasRuntimeBackend.Generator.Paths

  defmacro __using__(opts) do
    caller = __CALLER__
    fail = &raise(CompileError, file: caller.file, line: caller.line, description: &1)

    unless Keyword.keyword?(opts) and
             Keyword.keys(opts) -- [:contract, :transport, :target] == [] and
             Keyword.has_key?(opts, :contract) and Keyword.has_key?(opts, :transport),
           do:
             fail.(
               "use #{inspect(__MODULE__)} takes contract:, transport: and optionally target:"
             )

    contract = Macro.expand(opts[:contract], caller)
    transport = Macro.expand(opts[:transport], caller)

    unless is_atom(contract) and Code.ensure_compiled(contract) == {:module, contract} and
             function_exported?(contract, :__schema__, 0),
           do:
             fail.(
               "contract: #{Macro.to_string(opts[:contract])} is no compiled backend contract"
             )

    unless is_atom(transport) and Code.ensure_compiled(transport) == {:module, transport},
      do: fail.("transport: #{Macro.to_string(opts[:transport])} is not available")

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

    needs = [request: 2] ++ if(target.streams != [], do: [stream: 2], else: [])

    for {function, arity} <- needs, not function_exported?(transport, function, arity) do
      fail.("transport #{inspect(transport)} has no #{function}/#{arity}")
    end

    specs = specs!(schema, boundary, target, fail)
    models = Map.new(boundary.models, &{&1.name, &1.fields})

    functions =
      for spec <- specs do
        doc = doc(spec)

        if spec.input do
          quote do
            @doc unquote(doc)
            def unquote(spec.name)(input \\ %{}, opts \\ []),
              do:
                AtlasRuntimeBackend.Generator.Targets.Client.Runtime.call(
                  unquote(Macro.escape(spec)),
                  @client_models,
                  unquote(transport),
                  input,
                  opts
                )
          end
        else
          quote do
            @doc unquote(doc)
            def unquote(spec.name)(opts \\ []) when is_list(opts),
              do:
                AtlasRuntimeBackend.Generator.Targets.Client.Runtime.call(
                  unquote(Macro.escape(spec)),
                  @client_models,
                  unquote(transport),
                  %{},
                  opts
                )
          end
        end
      end

    quote do
      require unquote(contract)
      require unquote(transport)
      @client_models unquote(Macro.escape(models))

      @doc "The names of this client's calls, one per exposed capability, in order."
      def __capabilities__, do: unquote(Enum.map(specs, & &1.name))

      unquote_splicing(functions)
    end
  end

  # One spec per exposed capability, in the boundary's order: what Runtime.call/5 needs.
  defp specs!(schema, boundary, target, fail) do
    capabilities = Map.new(boundary.capabilities, &{&1.name, &1})
    statuses = Map.new(target.statuses, &{&1.outcome, &1})
    events = Map.new(schema.events, &{&1.name, &1})

    for name <- schema.exposed do
      capability = capabilities[name]
      resource = Enum.find(target.resources, &(&1.capability == name))
      stream = Enum.find(target.streams, &(&1.capability == name))

      cond do
        resource ->
          outcomes =
            for o <- capability.outcomes do
              status =
                statuses[o.name] ||
                  fail.(
                    "outcome #{inspect(o.name)} of #{inspect(name)} has no status in target #{inspect(target.name)}"
                  )

              %{
                name: o.name,
                model: o.model,
                status: status.status,
                type: status.type,
                by: status.by,
                cases: Enum.map(status.cases, &Map.take(&1, [:value, :status, :type])),
                body: status.body
              }
            end

          distinguishable!(name, outcomes, fail)
          {:ok, segments} = Paths.parse(resource.path)

          %{
            name: name,
            kind: :resource,
            input: capability.input,
            method: resource.method |> Atom.to_string() |> String.upcase(),
            path: resource.path,
            segments: segments,
            params: resource.params,
            query: resource.query,
            headers: resource.headers,
            body: resource.body,
            etag: Map.get(resource, :etag) != nil,
            outcomes: outcomes,
            errors: target.errors
          }

        stream ->
          %{
            name: name,
            kind: :stream,
            input: capability.input,
            method: "GET",
            path: stream.path,
            segments: elem(Paths.parse(stream.path), 1),
            into: stream.into,
            resume_header: stream.resume_header,
            events: Map.new(stream.events, &{Atom.to_string(&1), {&1, events[&1].model}}),
            outcomes: [],
            errors: target.errors
          }

        true ->
          fail.(
            "target #{inspect(target.name)} maps no resource or stream for the exposed capability " <>
              "#{inspect(name)}, so the client would miss it"
          )
      end
    end
  end

  # Below 400 an outcome is known by its status alone; from 400 up by status and type.
  # Cases of one `by:` status are told apart by the field, so they may share a key.
  defp distinguishable!(capability, outcomes, fail) do
    keyed =
      for o <- outcomes,
          {status, type} <-
            if(o.by, do: Enum.map(o.cases, &{&1.status, &1.type}), else: [{o.status, o.type}]),
          uniq: true,
          do: {if(status < 400, do: {status, nil}, else: {status, type}), o.name}

    keyed
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.each(fn
      {_key, [_one]} ->
        :ok

      {{status, type}, names} ->
        fail.(
          "outcomes #{Enum.map_join(names, " and ", &inspect/1)} of #{inspect(capability)} both answer " <>
            "#{status}#{if type, do: " #{type}", else: ""}; the client cannot tell them apart"
        )
    end)
  end

  defp doc(spec) do
    answers =
      Enum.map_join(spec.outcomes, ", ", fn o ->
        if o.model, do: "`{#{inspect(o.name)}, fields}`", else: "`#{inspect(o.name)}`"
      end)

    case spec.kind do
      :resource ->
        "`#{spec.method} #{spec.path}` (capability `#{spec.name}`): #{answers}, or an error " <>
          "(see `AtlasRuntimeBackend.Generator.Targets.Client`)."

      :stream ->
        "`GET #{spec.path}` (capability `#{spec.name}`), a stream: `{:ok, events}` or an error " <>
          "(see `AtlasRuntimeBackend.Generator.Targets.Client`)."
    end
  end
end

defmodule AtlasRuntimeBackend.Generator.Targets.Client.Runtime do
  @moduledoc """
  What a client generated by `AtlasRuntimeBackend.Generator.Targets.Client` calls at run
  time: encoding the input, building the request, calling the transport once and decoding
  the answer. Plain functions on the spec the client was compiled with.
  """

  alias AtlasRuntimeBackend.Generator.Paths

  @problem_keys ["type", "title", "status"]

  @doc "One call: `spec` and `models` as compiled, the transport module, the input and options."
  def call(spec, models, transport, input, opts) do
    allowed = [:transport] ++ if(spec[:etag], do: [:if_none_match], else: [])

    unless Keyword.keyword?(opts) and Keyword.keys(opts) -- allowed == [],
      do:
        raise(
          ArgumentError,
          "#{spec.name}: the options are #{Enum.map_join(allowed, ", ", &"#{&1}:")}, got #{inspect(opts)}"
        )

    with {:ok, values} <- input(spec, models, input) do
      request = request(spec, values, opts)
      transport_opts = Keyword.get(opts, :transport, [])

      case spec.kind do
        :resource -> answer(spec, models, transport.request(request, transport_opts))
        :stream -> opened(spec, models, transport.stream(request, transport_opts))
      end
    end
  end

  ## The request

  # The input as {field => JSON-ready value}, only the fields given.
  defp input(spec, models, input) when is_map(input) and not is_struct(input) do
    fields = if spec.input, do: Map.fetch!(models, spec.input), else: []
    carried = carried(spec)
    names = Map.new(fields, &{&1.name, &1})

    unknown =
      for {key, _} <- input, not Map.has_key?(names, key), do: "no field #{inspect(key)}"

    unbound =
      for {key, value} <- input,
          Map.has_key?(names, key),
          value != nil,
          key not in carried,
          do: "#{key} is not carried by this request"

    {values, errors} =
      Enum.flat_map_reduce(fields, unknown ++ unbound, fn field, errors ->
        case {Map.get(input, field.name), field.required and field.name in carried} do
          {nil, true} ->
            {[], errors ++ ["#{field.name} is required"]}

          {nil, false} ->
            {[], errors}

          {value, _} ->
            case encode(field.type, value, models) do
              {:ok, json} -> {[{field.name, json}], errors}
              {:error, why} -> {[], errors ++ ["#{field.name} #{why}"]}
            end
        end
      end)

    if errors == [], do: {:ok, Map.new(values)}, else: {:error, {:invalid, errors}}
  end

  defp input(_spec, _models, input),
    do: {:error, {:invalid, ["the input is no map: #{inspect(input)}"]}}

  defp carried(%{kind: :stream} = spec), do: [spec.into]

  defp carried(spec),
    do:
      spec.params ++
        Enum.map(spec.query, &elem(&1, 1)) ++
        Enum.map(spec.headers, &elem(&1, 1)) ++ (spec.body || [])

  defp request(%{kind: :stream} = spec, values, _opts) do
    resume =
      case Map.fetch(values, spec.into) do
        {:ok, value} -> [{spec.resume_header, text(value)}]
        :error -> []
      end

    %{
      method: "GET",
      path: Paths.build(spec.segments, %{}),
      query: "",
      headers: [{"accept", "text/event-stream"} | resume],
      body: nil
    }
  end

  defp request(spec, values, opts) do
    params = Map.new(spec.params, &{&1, text(Map.fetch!(values, &1))})

    query =
      for {name, field} <- spec.query,
          Map.has_key?(values, field),
          do: {name, text(values[field])}

    headers =
      for {name, field} <- spec.headers,
          Map.has_key?(values, field),
          do: {name, text(values[field])}

    tag =
      case Keyword.get(opts, :if_none_match) do
        nil -> []
        revision when is_integer(revision) -> [{"if-none-match", ~s("#{revision}")}]
        tag when is_binary(tag) -> [{"if-none-match", tag}]
      end

    body =
      spec.body &&
        JSON.encode!(
          Map.new(Map.take(values, spec.body), fn {k, v} -> {Atom.to_string(k), v} end)
        )

    content = if body, do: [{"content-type", "application/json"}], else: []

    %{
      method: spec.method,
      path: Paths.build(spec.segments, params),
      query: URI.encode_query(query),
      headers: [{"accept", "application/json"}] ++ content ++ headers ++ tag,
      body: body
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(value), do: to_string(value)

  ## Encoding a value (to JSON-ready data)

  defp encode(:string, v, _m) when is_binary(v), do: {:ok, v}
  defp encode(:integer, v, _m) when is_integer(v), do: {:ok, v}
  defp encode(:boolean, v, _m) when is_boolean(v), do: {:ok, v}
  defp encode(:datetime, %DateTime{} = v, _m), do: {:ok, DateTime.to_iso8601(v)}

  defp encode({:enum, values}, v, _m) when is_atom(v) and not is_nil(v) do
    if v in values, do: {:ok, Atom.to_string(v)}, else: {:error, "is invalid: #{inspect(v)}"}
  end

  defp encode({:list, inner}, v, m) when is_list(v) do
    Enum.reduce_while(v, {:ok, []}, fn item, {:ok, acc} ->
      case encode(inner, item, m) do
        {:ok, json} -> {:cont, {:ok, acc ++ [json]}}
        error -> {:halt, error}
      end
    end)
  end

  defp encode({:map, inner}, v, m) when is_map(v) and not is_struct(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn
      {key, item}, {:ok, acc} when is_binary(key) ->
        case encode(inner, item, m) do
          {:ok, json} -> {:cont, {:ok, Map.put(acc, key, json)}}
          error -> {:halt, error}
        end

      {key, _}, _acc ->
        {:halt, {:error, "has a key that is no text: #{inspect(key)}"}}
    end)
  end

  defp encode({:one_of, members, opts}, v, m) when is_map(v) and not is_struct(v) do
    tag = Keyword.fetch!(opts, :tag)
    member = Map.get(v, tag)

    if member in members do
      with {:ok, json} <- encode(member, Map.delete(v, tag), m),
           do: {:ok, Map.put(json, Atom.to_string(tag), Atom.to_string(member))}
    else
      {:error, "is invalid: #{inspect(tag)} names none of #{inspect(members)}"}
    end
  end

  defp encode(model, v, m)
       when is_atom(model) and is_map_key(m, model) and is_map(v) and not is_struct(v) do
    fields = Map.fetch!(m, model)
    names = Map.new(fields, &{&1.name, &1})

    case for {key, _} <- v, not Map.has_key?(names, key), do: key do
      [] ->
        Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, acc} ->
          case {Map.get(v, field.name), field.required} do
            {nil, true} ->
              {:halt, {:error, "is invalid: #{field.name} is required"}}

            {nil, false} ->
              {:cont, {:ok, acc}}

            {item, _} ->
              case encode(field.type, item, m) do
                {:ok, json} -> {:cont, {:ok, Map.put(acc, Atom.to_string(field.name), json)}}
                {:error, why} -> {:halt, {:error, "is invalid: #{field.name} #{why}"}}
              end
          end
        end)

      unknown ->
        {:error, "is invalid: no field #{Enum.map_join(unknown, ", ", &inspect/1)}"}
    end
  end

  defp encode(_type, v, _m), do: {:error, "is invalid: #{inspect(v)}"}

  ## The answer

  defp answer(_spec, _models, {:error, _reason}), do: {:error, :unreachable}

  defp answer(spec, models, {:ok, %{status: status, body: body}}) do
    json = parse(body)

    cond do
      outcome = outcome(spec, status, json) ->
        decode_outcome(outcome, models, json)

      status == 304 and spec[:etag] ->
        :not_modified

      true ->
        failure(spec, status, json)
    end
  end

  defp opened(_spec, _models, {:error, _reason}), do: {:error, :unreachable}

  defp opened(spec, models, {:ok, %{status: 200, body: chunks}}),
    do: {:ok, events(spec, models, chunks)}

  defp opened(spec, _models, {:ok, %{status: status, body: chunks}}) do
    case Enum.reduce_while(chunks, [], fn
           {:error, _}, _acc -> {:halt, :error}
           chunk, acc -> {:cont, [acc, chunk]}
         end) do
      :error -> {:error, :unreachable}
      body -> failure(spec, status, parse(IO.iodata_to_binary(body)))
    end
  end

  defp failure(spec, status, json) do
    type = if is_map(json), do: json["type"]

    cond do
      status == 401 ->
        {:error, :unauthenticated}

      error = Enum.find(spec.errors, &(&1.status == status and &1.type == type)) ->
        case error.kind do
          :invalid -> {:error, {:invalid, json["detail"]}}
          kind -> {:error, kind}
        end

      true ->
        {:error, :unreachable}
    end
  end

  defp parse(body) when is_binary(body) and body != "" do
    case JSON.decode(body) do
      {:ok, json} -> json
      {:error, _} -> nil
    end
  end

  defp parse(_body), do: nil

  # The outcome a status (and, from 400 up, its problem type) declares, or nil.
  defp outcome(spec, status, json) do
    type = if is_map(json), do: json["type"]

    Enum.find(spec.outcomes, fn o ->
      if o.by do
        Enum.any?(o.cases, fn c ->
          c.status == status and (status < 400 or c.type == type) and is_map(json) and
            json[Atom.to_string(o.by)] == Atom.to_string(c.value)
        end)
      else
        o.status == status and (status < 400 or o.type == type)
      end
    end)
  end

  defp decode_outcome(%{model: nil} = o, _models, _json), do: o.name

  # A status with `body:` carries that one field of the outcome model, its entity, and
  # nothing else: the value holds only that field (`%{work: ...}`). The model's other
  # fields are not on the wire, so they are not in the value either (never nil for them).
  defp decode_outcome(%{body: body} = o, models, json) when not is_nil(body) do
    field = Enum.find(Map.fetch!(models, o.model), &(&1.name == body))

    case is_map(json) && decode(field.type, json, models) do
      false -> {:error, {:invalid_response, ["the body of #{o.name} is no JSON object"]}}
      {:ok, value} -> {o.name, %{body => value}}
      {:error, why} -> {:error, {:invalid_response, ["#{o.name}: #{body} #{why}"]}}
    end
  end

  defp decode_outcome(o, models, json) do
    case is_map(json) && decode(o.model, Map.drop(json, @problem_keys), models) do
      false -> {:error, {:invalid_response, ["the body of #{o.name} is no JSON object"]}}
      {:ok, value} -> {o.name, value}
      {:error, why} -> {:error, {:invalid_response, ["#{o.name}: #{why}"]}}
    end
  end

  ## Decoding a value (from JSON data)

  defp decode(:string, v, _m) when is_binary(v), do: {:ok, v}
  defp decode(:integer, v, _m) when is_integer(v), do: {:ok, v}
  defp decode(:boolean, v, _m) when is_boolean(v), do: {:ok, v}

  defp decode(:datetime, v, _m) when is_binary(v) do
    case DateTime.from_iso8601(v) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, "is no datetime: #{inspect(v)}"}
    end
  end

  defp decode({:enum, values}, v, _m) when is_binary(v) do
    case Enum.find(values, &(Atom.to_string(&1) == v)) do
      nil -> {:error, "is no value of the enum: #{inspect(v)}"}
      atom -> {:ok, atom}
    end
  end

  defp decode({:list, inner}, v, m) when is_list(v) do
    Enum.reduce_while(v, {:ok, []}, fn item, {:ok, acc} ->
      case decode(inner, item, m) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode({:map, inner}, v, m) when is_map(v) do
    Enum.reduce_while(v, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case decode(inner, item, m) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode({:one_of, members, opts}, v, m) when is_map(v) do
    tag = Keyword.fetch!(opts, :tag)
    name = v[Atom.to_string(tag)]

    case Enum.find(members, &(Atom.to_string(&1) == name)) do
      nil ->
        {:error, "#{tag} names no member: #{inspect(name)}"}

      member ->
        with {:ok, value} <- decode(member, Map.delete(v, Atom.to_string(tag)), m),
             do: {:ok, Map.put(value, tag, member)}
    end
  end

  defp decode(model, v, m) when is_atom(model) and is_map_key(m, model) and is_map(v) do
    Enum.reduce_while(Map.fetch!(m, model), {:ok, %{}}, fn field, {:ok, acc} ->
      case {Map.get(v, Atom.to_string(field.name)), field.required} do
        {nil, true} ->
          {:halt, {:error, "#{field.name} is required"}}

        {nil, false} ->
          {:cont, {:ok, Map.put(acc, field.name, nil)}}

        {item, _} ->
          case decode(field.type, item, m) do
            {:ok, value} -> {:cont, {:ok, Map.put(acc, field.name, value)}}
            {:error, why} -> {:halt, {:error, "#{field.name} #{why}"}}
          end
      end
    end)
  end

  defp decode(_type, v, _m), do: {:error, "is invalid: #{inspect(v)}"}

  ## Server-Sent Events

  defp events(spec, models, chunks) do
    Stream.transform(chunks, "", fn
      _chunk, :done ->
        {:halt, :done}

      {:error, _reason}, _buffer ->
        {[{:error, :unreachable}], :done}

      chunk, buffer ->
        {frames, rest} = frames(buffer <> String.replace(chunk, "\r\n", "\n"))

        Enum.reduce_while(frames, {[], rest}, fn frame, {acc, rest} ->
          case event(spec, models, frame) do
            :skip -> {:cont, {acc, rest}}
            {:error, _} = error -> {:halt, {acc ++ [error], :done}}
            event -> {:cont, {acc ++ [event], rest}}
          end
        end)
    end)
  end

  # Complete frames (ended by an empty line) and what is left of the next.
  defp frames(text) do
    parts = String.split(text, "\n\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp event(spec, models, frame) do
    lines = String.split(frame, "\n")

    field = fn name ->
      for line <- lines, String.starts_with?(line, name <> ":") do
        line |> String.replace_prefix(name <> ":", "") |> String.replace_prefix(" ", "")
      end
    end

    name = List.last(field.("event")) || "message"
    data = Enum.join(field.("data"), "\n")

    case Map.fetch(spec.events, name) do
      :error ->
        :skip

      {:ok, {event, model}} ->
        with {:ok, json} when is_map(json) <- JSON.decode(data),
             {:ok, value} <- decode(model, json, models) do
          {event, value}
        else
          {:error, why} when is_binary(why) ->
            {:error, {:invalid_response, ["event #{name}: #{why}"]}}

          _ ->
            {:error, {:invalid_response, ["event #{name}: the data is no JSON object"]}}
        end
    end
  end
end
