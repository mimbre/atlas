defmodule AtlasBFF.Wire do
  @moduledoc """
  Data-only wire descriptors, shared by compile-time validation and protocol targets.

  A descriptor names a channel, direction (`request`, `push`, `stream`), an optional
  request envelope and its replies. Envelopes declare `select` literal string fields,
  `present`/`absent` discriminator fields, and `required`/`optional` field types.
  Reply effects are `complete`, `progress`, `error`, or `terminal`. `requires` names
  earlier replies in the same exchange (e.g. a greeting before an initial page).
  Streaming exchanges require an explicit adapter; they have no inferred completion.
  No predicate, permission, replay or workflow policy is executable here.
  """

  def validate!(schema, sources \\ %{}) do
    wires = Map.get(schema, :protocol, [])
    models = Map.new(Map.get(schema, :models, []), &{&1.name, &1.fields})
    wire_sources = Map.get(sources, :wires, %{})
    endpoint_sources = Map.get(sources, :endpoints, %{})
    names = Enum.map(wires, & &1.name)
    ensure!(length(names) == length(Enum.uniq(names)), "duplicate wire descriptor")

    for wire <- wires do
      at!(wire_sources[wire.name], fn -> validate_wire!(wire, models) end)
    end

    for wire <- wires, wire.direction != :push do
      replies = Enum.map(wire.replies, &{&1, wire_sources[wire.name]})

      pushes =
        for w <- wires,
            w.channel == wire.channel and w.direction == :push,
            r <- w.replies,
            do: {r, wire_sources[w.name]}

      disjoint_at!(Enum.uniq_by(replies ++ pushes, &elem(&1, 0)))
    end

    for channel <- Enum.uniq(Enum.map(wires, & &1.channel)) do
      validate_channel!(channel, wires, wire_sources)
    end

    if wires != [] do
      for endpoint <- schema.endpoints do
        at!(endpoint_sources[{endpoint.name, endpoint[:call]}], fn ->
          validate_endpoint!(endpoint, wires)
        end)
      end
    end

    :ok
  end

  defp validate_wire!(wire, models) do
    ensure!(identifier?(wire.name) and identifier?(wire.channel), "invalid wire name/channel")

    ensure!(
      Map.keys(wire) -- [:name, :channel, :direction, :request, :replies, :cli] == [],
      "unknown wire metadata"
    )

    ensure!(wire.direction in [:request, :push, :stream], "invalid wire direction")
    ensure!(wire.replies != [], "wire replies are incomplete")

    if wire.direction != :push do
      ensure!(
        Map.keys(wire.request) -- [:select, :required, :optional] == [],
        "unknown request metadata"
      )

      envelope!(wire.request, models)
    end

    reply_names = Enum.map(wire.replies, & &1.name)
    ensure!(length(reply_names) == length(Enum.uniq(reply_names)), "duplicate reply name")

    for reply <- wire.replies do
      ensure!(identifier?(reply.name), "invalid reply name")

      ensure!(
        Map.keys(reply) --
          [:name, :select, :present, :absent, :required, :optional, :effect, :requires] == [],
        "unknown reply metadata"
      )

      envelope!(reply, models)
      ensure!(reply.effect in [:complete, :progress, :error, :terminal], "invalid reply effect")
      ensure!(Map.get(reply, :requires, []) -- reply_names == [], "unknown required reply")

      for prerequisite <- Map.get(reply, :requires, []) do
        prior = Enum.find(wire.replies, &(&1.name == prerequisite))

        ensure!(
          prior.effect == :progress and Map.get(prior, :requires, []) == [],
          "invalid reply prerequisite"
        )
      end

      ensure!(reply.name not in Map.get(reply, :requires, []), "self-dependent reply")
    end

    if wire.direction == :request,
      do: ensure!(Enum.any?(wire.replies, &(&1.effect == :complete)), "no completion reply")

    if command = wire[:cli] do
      ensure!(wire.direction == :request, "CLI binding requires a request")

      ensure!(
        is_list(command) and command != [] and
          Enum.all?(command, &(is_binary(&1) and &1 != "")),
        "invalid CLI binding"
      )
    end

    disjoint!(wire.replies)
  end

  defp validate_channel!(channel, wires, sources) do
    wires = Enum.filter(wires, &(&1.channel == channel))

    disjoint_at!(
      for wire <- wires,
          wire.direction == :push,
          reply <- wire.replies,
          do: {reply, sources[wire.name]}
    )

    Enum.reduce(wires, MapSet.new(), fn wire, commands ->
      if command = wire[:cli] do
        at!(sources[wire.name], fn ->
          ensure!(not MapSet.member?(commands, command), "duplicate CLI binding")
        end)

        MapSet.put(commands, command)
      else
        commands
      end
    end)

    disjoint_at!(
      for wire <- wires, wire.direction != :push, do: {wire.request, sources[wire.name]}
    )
  end

  defp validate_endpoint!(endpoint, wires) do
    wire = Enum.find(wires, &(&1.name == endpoint[:wire]))
    ensure!(wire != nil, "unclassified endpoint #{endpoint.name}")

    selectors = if wire.direction == :push, do: wire.replies, else: [wire.request]

    ensure!(
      Enum.all?(selectors, &(&1.select["op"] == to_string(endpoint.call))),
      "endpoint wire call mismatch"
    )

    available =
      wire.replies ++
        for w <- wires,
            w.channel == wire.channel and w.direction == :push,
            r <- w.replies,
            do: r

    for reply <- Map.get(endpoint, :replies, []) do
      ensure!(
        Enum.any?(available, &(&1.name == reply.name)),
        "unclassified endpoint reply #{reply.name}"
      )
    end
  end

  defp at!(nil, validate), do: validate.()

  defp at!({file, line}, validate) do
    validate.()
  rescue
    error in [ArgumentError, KeyError, BadMapError, Protocol.UndefinedError] ->
      raise CompileError, file: file, line: line, description: Exception.message(error)
  end

  defp disjoint_at!([]), do: :ok

  defp disjoint_at!([{head, _} | tail]) do
    for {other, source} <- tail do
      at!(source, fn -> ensure!(not overlap?(head, other), "overlapping reply selectors") end)
    end

    disjoint_at!(tail)
  end

  defp identifier?(value), do: is_atom(value) and value not in [nil, true, false]

  defp envelope!(envelope, models) do
    select = Map.get(envelope, :select, %{})
    present = Map.get(envelope, :present, [])
    absent = Map.get(envelope, :absent, [])
    ensure!(is_map(select) and is_binary(select["op"]), "selector needs an op")

    ensure!(
      Enum.all?(select, fn {k, v} -> is_binary(k) and is_binary(v) end),
      "invalid selector literal"
    )

    ensure!(
      is_list(present) and is_list(absent) and Enum.all?(present ++ absent, &is_binary/1),
      "invalid presence selector"
    )

    ensure!(Enum.all?(Map.keys(select) ++ present, &(&1 not in absent)), "contradictory selector")
    required = Map.get(envelope, :required, %{})
    optional = Map.get(envelope, :optional, %{})
    ensure!(is_map(required) and is_map(optional), "invalid envelope fields")
    ensure!(Enum.all?(Map.keys(required), &(&1 not in absent)), "absent required field")

    ensure!(
      Enum.all?(Map.keys(required), &(not Map.has_key?(optional, &1))),
      "duplicate envelope field"
    )

    for key <- [:required, :optional], {name, type} <- Map.get(envelope, key, %{}) do
      ensure!(is_binary(name) and valid_type?(type, models), "invalid envelope field")
    end
  end

  defp valid_type?(type, _) when type in [:string, :integer, :boolean, :map, :list], do: true
  defp valid_type?({:map, type}, _), do: type in [:string, :integer, :boolean]
  defp valid_type?({:list, type}, models), do: valid_type?(type, models)
  defp valid_type?(type, models), do: Map.has_key?(models, type)

  defp disjoint!([]), do: :ok

  defp disjoint!([head | tail]) do
    for other <- tail, do: ensure!(not overlap?(head, other), "overlapping reply selectors")
    disjoint!(tail)
  end

  defp overlap?(a, b) do
    literals_disagree =
      Enum.any?(a.select, fn {k, v} -> Map.has_key?(b.select, k) and b.select[k] != v end)

    a_present = Map.keys(a.select) ++ Map.get(a, :present, [])
    b_present = Map.keys(b.select) ++ Map.get(b, :present, [])

    literals_disagree == false and
      Enum.all?(a_present, &(&1 not in Map.get(b, :absent, []))) and
      Enum.all?(b_present, &(&1 not in Map.get(a, :absent, [])))
  end

  defp ensure!(true, _), do: :ok
  defp ensure!(false, why), do: raise(ArgumentError, why)

  def descriptor!(wires, name, channel) do
    wire = Enum.find(wires, &(&1.name == name)) || raise(ArgumentError, "unknown wire #{name}")

    ensure!(
      wire.channel == channel and wire.direction == :request,
      "not a request on this channel"
    )

    wire
  end

  def encode!(wire, props, models \\ %{}), do: encode_envelope!(wire.request, props, models)

  defp encode_envelope!(envelope, props, models) do
    message = Map.new(props, fn {k, v} -> {to_string(k), v} end)

    known =
      Map.keys(Map.get(envelope, :required, %{})) ++
        Map.keys(Map.get(envelope, :optional, %{}))

    ensure!(Map.keys(message) -- known == [], "unknown envelope fields")

    message =
      message
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()
      |> Map.merge(envelope.select)

    fields = Map.merge(Map.get(envelope, :required, %{}), Map.get(envelope, :optional, %{}))

    message =
      Enum.reduce(fields, message, fn {key, type}, acc ->
        case Map.fetch(acc, key) do
          {:ok, value} -> Map.put(acc, key, normalize!(value, type, models))
          :error -> acc
        end
      end)

    check!(envelope, message, models)
    message
  end

  defp normalize!(values, {:list, type}, models) when is_list(values),
    do: Enum.map(values, &normalize!(&1, type, models))

  defp normalize!(value, type, models) when is_map_key(models, type),
    do: AtlasBFF.Targets.Protocol.value!(models, type, value)

  # Existing primitives and opaque/primitive-map fields keep their wire semantics;
  # check! validates them below, including the original string-key requirement.
  defp normalize!(value, _, _), do: value

  def classify(wires, name, channel, message, models \\ %{})

  def classify(wires, name, channel, message, models) when is_map(message) do
    wire = descriptor!(wires, name, channel)

    pushes =
      for w <- wires, w.channel == channel and w.direction == :push, reply <- w.replies, do: reply

    case Enum.find(wire.replies ++ pushes, &matches?(&1, message)) do
      nil ->
        :ignore

      reply ->
        try do
          check!(reply, message, models)
          {:reply, reply}
        rescue
          e in ArgumentError -> {:invalid, Exception.message(e)}
        end
    end
  end

  def classify(_, _, _, _, _), do: {:invalid, "expected an object"}

  defp matches?(selector, message) do
    Enum.all?(selector.select, fn {k, v} -> message[k] == v end) and
      Enum.all?(Map.get(selector, :present, []), &Map.has_key?(message, &1)) and
      Enum.all?(Map.get(selector, :absent, []), &(not Map.has_key?(message, &1)))
  end

  defp check!(envelope, message, models) do
    for {key, type} <- Map.get(envelope, :required, %{}) do
      ensure!(
        Map.has_key?(message, key) and typed?(message[key], type, models),
        "missing or invalid #{key}"
      )
    end

    for {key, type} <- Map.get(envelope, :optional, %{}),
        Map.has_key?(message, key) and message[key] != nil do
      ensure!(typed?(message[key], type, models), "invalid #{key}")
    end
  end

  defp typed?(v, :map, _), do: is_map(v)
  defp typed?(v, :list, _), do: is_list(v)

  defp typed?(v, {:map, type}, models),
    do:
      is_map(v) and
        Enum.all?(v, fn {key, value} -> is_binary(key) and typed?(value, type, models) end)

  defp typed?(v, {:list, type}, models),
    do: is_list(v) and Enum.all?(v, &typed?(&1, type, models))

  defp typed?(v, type, models) do
    AtlasBFF.Targets.Protocol.validate_value!(models, type, v)
    true
  rescue
    ArgumentError -> false
  end

  @doc "Validate and identify an incoming request, without executing it. Unknown frames fail closed."
  def decode_request(wires, channel, message, models) when is_map(message) do
    candidates =
      Enum.filter(
        wires,
        &(&1.channel == channel and &1.direction != :push and matches?(&1.request, message))
      )

    decode_candidates(Enum.map(candidates, &{&1.name, &1.request}), message, models)
  end

  def decode_request(_, _, _, _), do: {:invalid, "expected an object"}

  def decode_event(wires, channel, message, models) when is_map(message) do
    candidates =
      for w <- wires,
          w.channel == channel and w.direction == :push,
          r <- w.replies,
          matches?(r, message),
          do: {w.name, r}

    decode_candidates(candidates, message, models)
  end

  def decode_event(_, _, _, _), do: {:invalid, "expected an object"}

  def decode_reply(wires, name, channel, message, models) when is_map(message) do
    wire = descriptor!(wires, name, channel)
    candidates = for r <- wire.replies, matches?(r, message), do: {r.name, r}
    decode_candidates(candidates, message, models)
  end

  def decode_reply(_, _, _, _, _), do: {:invalid, "expected an object"}

  defp decode_candidates([{name, envelope}], message, models) do
    known =
      Map.keys(envelope.select) ++
        Map.keys(envelope[:required] || %{}) ++ Map.keys(envelope[:optional] || %{})

    ensure!(Map.keys(message) -- known == [], "unknown envelope fields")
    check!(envelope, message, models)
    {:ok, name, message}
  rescue
    e in ArgumentError -> {:invalid, Exception.message(e)}
  end

  defp decode_candidates([], _, _), do: {:invalid, "unknown message or protocol version"}
  defp decode_candidates(_, _, _), do: {:invalid, "ambiguous message"}

  def reply!(wires, name, variant, props, channel, models) do
    wire =
      Enum.find(wires, &(&1.name == name and &1.channel == channel)) ||
        raise(ArgumentError, "unknown wire")

    envelope =
      Enum.find(wire.replies, &(&1.name == variant)) || raise(ArgumentError, "unknown reply")

    encode_envelope!(envelope, props, models)
  end

  def event!(wires, name, props, channel, models) do
    wire =
      Enum.find(wires, &(&1.name == name and &1.channel == channel and &1.direction == :push)) ||
        raise(ArgumentError, "unknown event")

    [envelope] = wire.replies
    encode_envelope!(envelope, props, models)
  end

  def cli(wires, channel, words, props, models) do
    case Enum.find(wires, &(&1.channel == channel and &1[:cli] == words)) do
      nil -> {:invalid, "unknown command"}
      wire -> {:ok, wire.name, encode!(wire, props, models)}
    end
  rescue
    e in ArgumentError -> {:invalid, Exception.message(e)}
  end
end
