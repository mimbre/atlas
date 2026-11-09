defmodule AtlasBus.Link.Client do
  @moduledoc "Reconnectable Runtime Bus connection; registrations are replayed after reconnect."
  use GenServer
  alias AtlasBus.Link

  # No settings pass through the supervisor: its child spec and start arguments carry no token.
  def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  def sync(pid), do: GenServer.call(__MODULE__, {:sync, pid})
  def forward(envelope, content), do: GenServer.cast(__MODULE__, {:send, envelope, content})
  def status, do: GenServer.call(__MODULE__, :status)

  # The token is kept apart, in a closure called only for `hello`, so printed diagnostics
  # (state, failure arguments, exits) show `#Function<…>`. Code in this VM can still read it.
  def init(:ok) do
    settings = Link.settings()
    token = settings["token"]
    send(self(), :connect)

    {:ok,
     %{
       settings: Map.delete(settings, "token"),
       secret: fn -> token end,
       socket: nil,
       refs: %{},
       delay: 2_000,
       names: %{}
     }}
  end

  def handle_call(:status, _, state), do: {:reply, state.socket != nil, state}

  def handle_call({:sync, pid}, _, state) do
    refs =
      if Map.has_key?(state.refs, pid),
        do: state.refs,
        else: Map.put(state.refs, pid, Process.monitor(pid))

    replay(state.socket, pid)

    {:reply, :ok,
     %{
       state
       | refs: refs,
         names: Map.put(state.names, pid, Registry.keys(AtlasBus.Endpoints, pid))
     }}
  end

  def handle_cast({:send, envelope, content}, state) do
    emit(state.socket, "send", %{
      "endpoint" => envelope.sender,
      "envelope" => Link.envelope_out(envelope),
      "content" => content
    })

    {:noreply, state}
  end

  def handle_info(:connect, state) do
    s = state.settings

    result =
      with {:ok, socket} <-
             AtlasTransport.connect(
               s,
               [:binary, packet: :line, packet_size: 4_194_304, buffer: 4_194_304, active: false],
               2_000
             ) do
        emit(socket, "hello", %{
          "environment" => AtlasBus.environment(),
          "machine" => s["machine"],
          "token" => state.secret.()
        })

        case AtlasTransport.recv(socket, 0, 2_000) do
          {:ok, line} ->
            case JSON.decode(line) do
              {:ok, %{"op" => "welcome"}} ->
                {:ok, socket}

              _ ->
                AtlasTransport.close(socket)
                :error
            end

          _ ->
            AtlasTransport.close(socket)
            :error
        end
      end

    case result do
      {:ok, socket} ->
        Enum.each(Map.keys(state.refs), &replay(socket, &1))
        AtlasTransport.setopts(socket, active: :once)
        {:noreply, %{state | socket: socket, delay: 2_000}}

      _ ->
        {:noreply, reconnect(state)}
    end
  end

  def handle_info({transport, socket, line}, %{socket: socket} = state)
      when transport in [:tcp, :ssl] do
    case JSON.decode(line) do
      {:ok,
       %{"op" => "deliver", "endpoint" => name, "envelope" => %{} = map, "content" => content}} ->
        envelope = Link.envelope_in(map)

        if envelope.environment == AtlasBus.environment() &&
             AtlasBus.Envelope.validate(envelope) == :ok &&
             Link.deliver_allowed?(name, state.settings["machine"], envelope) do
          for {pid, _} <- Registry.lookup(AtlasBus.Endpoints, name),
              do: send(pid, {:atlas_bus, envelope, content})
        end

        AtlasTransport.setopts(socket, active: :once)
        {:noreply, state}

      _ ->
        AtlasTransport.close(socket)
        {:noreply, reconnect(state)}
    end
  end

  def handle_info({event, socket}, %{socket: socket} = state)
      when event in [:tcp_closed, :ssl_closed],
      do: {:noreply, reconnect(state)}

  def handle_info({error, socket, _}, %{socket: socket} = state)
      when error in [:tcp_error, :ssl_error],
      do: {:noreply, reconnect(state)}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    if state.refs[pid] == ref do
      # Registry entries may already be gone: remember the endpoint at sync time instead.
      for name <- Map.get(state.names, pid, []),
          do: emit(state.socket, "detach", %{"endpoint" => name})
    end

    {:noreply, %{state | refs: Map.delete(state.refs, pid), names: Map.delete(state.names, pid)}}
  end

  def handle_info(_, state), do: {:noreply, state}
  def terminate(_, state), do: if(state.socket, do: AtlasTransport.close(state.socket))

  defp reconnect(state) do
    if state.socket, do: AtlasTransport.close(state.socket)
    Process.send_after(self(), :connect, state.delay)
    %{state | socket: nil, delay: min(state.delay * 2, 30_000)}
  end

  defp replay(nil, _), do: :ok

  defp replay(socket, pid) do
    for name <- Registry.keys(AtlasBus.Endpoints, pid) do
      emit(socket, "attach", %{"endpoint" => name})

      for kind <- Registry.keys(AtlasBus.Listeners, pid),
          do: emit(socket, "listen", %{"endpoint" => name, "kind" => kind})
    end
  end

  defp emit(nil, _, _), do: :ok
  defp emit(socket, op, fields), do: AtlasTransport.send(socket, Link.encode(op, fields))
end
