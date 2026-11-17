defmodule AtlasBus.Link do
  @moduledoc """
  The Bus between nodes (IS-Atlas-91): a machine's node, which runs Runtime, reaches the
  core's Bus over one TCP connection, never by Erlang distribution. Only envelopes and
  their content cross, as JSON lines.

  - The core listens (`AtlasBus.Link.Server`), when its settings name a port. Each
    connection says `hello` with the environment, its machine and the link token; then it
    may attach only endpoints of its own machine's Runtime (`runtime@<machine>` and
    `runtime@<machine>/...`), listen to kinds, and send as one of those endpoints.
  - The machine's Bus runs in link mode (`AtlasBus.Link.Client`): `AtlasBus.attach/1`,
    `listen/1` and `send/2` keep their meaning, over the connection. While it is down, a
    send is dropped (delivery is not promised; a sender asks again), and once it is back,
    everything attached and listened to is attached and listened to again.
  - Addressed requests cross only from Control (`control/<name>`) to the authenticated
    machine's exact `runtime@<machine>/output` endpoint, with kind `runtime.output`.
    That endpoint may answer Control with the same kind. Neither direction carries a
    Facts position. Remote machines cannot send requests. Other read/fact/answer
    permissions stay unchanged. The Bus preserves IDs and content; callers correlate
    replies against the requested ID and exact Runtime sender.

  The wire, one JSON object per line: `hello`, `welcome`, `bye`, `attach`, `detach`,
  `listen`, `send` (machine to core), `deliver` (core to machine), `refused`.
  """

  alias AtlasBus.Envelope

  @doc "The link settings of this node, or nil: `%{\"mode\" => \"server\" | \"client\", ...}`."
  def settings, do: Application.get_env(:atlas_bus, :link)

  @doc "Whether this node's Bus runs in link mode: its store is on another node."
  def client?, do: match?(%{"mode" => "client"}, settings())

  @doc "Whether `name` is an endpoint `machine`'s Runtime may attach over a link."
  def allowed?(name, machine) when is_binary(name) and is_binary(machine) and machine != "" do
    own = "runtime@" <> machine
    name == own or String.starts_with?(name, own <> "/")
  end

  def allowed?(_name, _machine), do: false

  @doc false
  def send_allowed?(name, machine, %Envelope{kind: "runtime.output"} = envelope) do
    envelope.class == "answer" and name == "runtime@" <> machine <> "/output" and
      control?(envelope.address) and is_nil(envelope.position)
  end

  def send_allowed?(_name, _machine, %Envelope{class: class}), do: class in ~w(read fact answer)

  @doc false
  def deliver_allowed?(name, machine, %Envelope{class: "request"} = envelope) do
    envelope.kind == "runtime.output" and name == "runtime@" <> machine <> "/output" and
      envelope.address == name and control?(envelope.sender) and is_nil(envelope.position)
  end

  def deliver_allowed?(_name, _machine, %Envelope{kind: "runtime.output"}), do: false
  def deliver_allowed?(_name, _machine, %Envelope{}), do: true

  defp control?("control/" <> name), do: name != ""
  defp control?(_name), do: false

  @doc false
  def encode(op, fields), do: [JSON.encode!(Map.put(fields, "op", op)), "\n"]

  @doc false
  def envelope_out(%Envelope{} = envelope),
    do: envelope |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

  @doc false
  def envelope_in(%{} = map) do
    fields =
      for key <- Map.keys(%Envelope{id: nil, environment: nil, class: nil, kind: nil}),
          key != :__struct__,
          do: {key, map[Atom.to_string(key)]}

    struct(Envelope, fields)
  end

  @doc "A link token compared in constant time."
  def same_token?(given, token) when is_binary(given) and is_binary(token) and token != "",
    do: byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)

  def same_token?(_given, _token), do: false
end
