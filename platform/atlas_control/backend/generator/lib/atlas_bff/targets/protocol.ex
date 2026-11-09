defmodule AtlasBFF.Targets.Protocol do
  @moduledoc """
  Compile-time payload and path target consuming only `__schema__/0`.

  `payload/3` validates `takes` and returns string-keyed JSON data. Optional nil
  fields are omitted. `message/3` adds `op` for explicitly chosen pathless calls.
  Optional wire descriptors supply channel/direction, request envelopes and reply
  selectors to `request/3` and `classify/3`. Sockets, deadlines, adapters and
  permissions remain the caller's responsibility.
  """
  defmacro __using__(opts) do
    schema = Macro.expand(opts[:contract], __CALLER__).__schema__()

    AtlasBFF.Wire.validate!(schema)

    quote do
      @protocol_wires unquote(Macro.escape(Map.get(schema, :protocol, [])))
      @protocol_models unquote(Macro.escape(Map.new(schema.models, &{&1.name, &1.fields})))
      @protocol_pages unquote(Macro.escape(schema.pages))
      @protocol_endpoints unquote(Macro.escape(schema.endpoints))
      def version, do: unquote(schema.version)
      def pages, do: @protocol_pages
      def endpoints, do: @protocol_endpoints
      def path(name, params \\ %{}), do: AtlasBFF.Paths.build(@protocol_pages, name, params)
      def match(path), do: AtlasBFF.Paths.match(@protocol_pages, path)

      def wires, do: @protocol_wires

      def request(name, props \\ %{}, channel \\ unquote(opts[:channel])) do
        wire = AtlasBFF.Wire.descriptor!(@protocol_wires, name, channel)
        AtlasBFF.Wire.encode!(wire, props, @protocol_models)
      end

      def classify(name, message, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.classify(@protocol_wires, name, channel, message, @protocol_models)

      def models, do: @protocol_models

      def model(name, props),
        do: AtlasBFF.Targets.Protocol.payload!(@protocol_models, name, props)

      def options(model, argv),
        do: AtlasBFF.Targets.Protocol.options(@protocol_models, model, argv)

      def decode_request(message, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.decode_request(@protocol_wires, channel, message, @protocol_models)

      def decode_event(message, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.decode_event(@protocol_wires, channel, message, @protocol_models)

      def decode_reply(name, message, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.decode_reply(@protocol_wires, name, channel, message, @protocol_models)

      def reply(name, variant, props, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.reply!(@protocol_wires, name, variant, props, channel, @protocol_models)

      def event(name, props, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.event!(@protocol_wires, name, props, channel, @protocol_models)

      def commands(channel \\ unquote(opts[:channel])),
        do:
          Enum.filter(@protocol_wires, &(&1.channel == channel and &1[:cli]))
          |> Enum.map(&%{name: &1.name, words: &1.cli})

      def cli(words, props, channel \\ unquote(opts[:channel])),
        do: AtlasBFF.Wire.cli(@protocol_wires, channel, words, props, @protocol_models)

      def encode_request(name, props, channel \\ unquote(opts[:channel])),
        do: request(name, props, channel) |> JSON.encode!()

      def encode_reply(name, variant, props, channel \\ unquote(opts[:channel])),
        do: reply(name, variant, props, channel) |> JSON.encode!()

      def encode_event(name, props, channel \\ unquote(opts[:channel])),
        do: event(name, props, channel) |> JSON.encode!()

      def decode_reply_json(name, bytes, channel \\ unquote(opts[:channel])) do
        case JSON.decode(bytes) do
          {:ok, message} -> decode_reply(name, message, channel)
          {:error, _} -> {:invalid, "malformed JSON"}
        end
      end

      def decode_event_json(bytes, channel \\ unquote(opts[:channel])) do
        case JSON.decode(bytes) do
          {:ok, message} -> decode_event(message, channel)
          {:error, _} -> {:invalid, "malformed JSON"}
        end
      end

      def decode_request_json(bytes, channel \\ unquote(opts[:channel])) do
        case JSON.decode(bytes) do
          {:ok, message} -> decode_request(message, channel)
          {:error, _} -> {:invalid, "malformed JSON"}
        end
      end

      def endpoint_path(call, name, params \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        if endpoint.path, do: AtlasBFF.Paths.build([endpoint], name, params)
      end

      def payload(call, name, props \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        AtlasBFF.Targets.Protocol.payload!(@protocol_models, endpoint.takes, props)
      end

      def message(call, name, props \\ %{}) do
        endpoint = AtlasBFF.Targets.Protocol.endpoint!(@protocol_endpoints, call, name)
        if endpoint.path, do: raise(ArgumentError, "path endpoint requires a transport envelope")

        if @protocol_wires == [] do
          Map.put(payload(call, name, props), "op", Atom.to_string(endpoint.call))
        else
          request(endpoint.wire, payload(call, name, props))
        end
      end
    end
  end

  @doc false
  def endpoint!(endpoints, call, name) do
    Enum.find(endpoints, &(&1.call == call and &1.name == name)) ||
      raise ArgumentError, "no endpoint #{inspect(name)} (#{call})"
  end

  @doc false
  def options(models, name, argv) do
    fields = Map.fetch!(models, name)

    if Enum.any?(fields, &(&1.type not in [:string, :integer, :boolean])),
      do: raise(ArgumentError, "CLI options require primitive fields")

    {options, rest, invalid} =
      OptionParser.parse(argv, strict: Enum.map(fields, &{&1.name, [&1.type, :keep]}))

    cond do
      rest != [] or invalid != [] ->
        {:invalid, "unknown arguments or invalid options"}

      length(Keyword.keys(options)) != length(Enum.uniq(Keyword.keys(options))) ->
        {:invalid, "duplicate options"}

      true ->
        {:ok, payload!(models, name, options)}
    end
  rescue
    error in ArgumentError -> {:invalid, Exception.message(error)}
  end

  @doc false
  def payload!(models, nil, props), do: model!(models, "payload", [], props)
  def payload!(models, :values, props), do: value!(models, {:map, :string}, props)
  def payload!(models, name, props), do: model!(models, name, Map.fetch!(models, name), props)

  defp model!(models, name, fields, props) when is_map(props) or is_list(props) do
    if is_list(props) and not Enum.all?(props, &(is_tuple(&1) and tuple_size(&1) == 2)),
      do: raise(ArgumentError, "#{name} must be an object or field pairs")

    props = Map.new(props, fn {key, value} -> {to_string(key), value} end)
    known = Enum.map(fields, &Atom.to_string(&1.name))

    if Map.keys(props) -- known != [],
      do: raise(ArgumentError, "#{name} has unknown fields #{inspect(Map.keys(props) -- known)}")

    Enum.reduce(fields, %{}, fn field, acc ->
      key = Atom.to_string(field.name)

      case Map.get(props, key) do
        nil when field.required -> raise ArgumentError, "#{name}.#{key} is required"
        nil -> acc
        value -> Map.put(acc, key, value!(models, field.type, value))
      end
    end)
  end

  defp model!(_models, name, _fields, _props),
    do: raise(ArgumentError, "#{name} must be an object")

  def value!(_models, :string, value) when is_binary(value), do: value
  def value!(_models, :integer, value) when is_integer(value), do: value
  def value!(_models, :boolean, value) when is_boolean(value), do: value

  def value!(models, {:list, type}, values) when is_list(values),
    do: Enum.map(values, &value!(models, type, &1))

  def value!(models, {:map, type}, values) when is_map(values),
    do: Map.new(values, fn {key, value} -> {to_string(key), value!(models, type, value)} end)

  def value!(models, type, value) when is_map_key(models, type),
    do: model!(models, type, Map.fetch!(models, type), value)

  def value!(_models, type, value),
    do: raise(ArgumentError, "expected #{inspect(type)}, got: #{inspect(value)}")

  @doc false
  def validate_value!(models, type, value) do
    # Incoming JSON objects cannot use the constructor's field-pair coercion.
    object_shape!(models, type, value)
    value!(models, type, value)
    :ok
  end

  defp object_shape!(models, type, value) when is_map_key(models, type) do
    if not is_map(value) or not Enum.all?(Map.keys(value), &is_binary/1),
      do: raise(ArgumentError, "#{type} must be a string-keyed object")

    for field <- Map.fetch!(models, type),
        nested = value[Atom.to_string(field.name)],
        not is_nil(nested),
        do: object_shape!(models, field.type, nested)
  end

  defp object_shape!(models, {:list, type}, values) when is_list(values),
    do: Enum.each(values, &object_shape!(models, type, &1))

  defp object_shape!(models, {:map, type}, values) when is_map(values) do
    if not Enum.all?(Map.keys(values), &is_binary/1),
      do: raise(ArgumentError, "expected string-keyed map")

    Enum.each(values, fn {_, value} -> object_shape!(models, type, value) end)
  end

  defp object_shape!(_, _, _), do: :ok
end
