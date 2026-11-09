defmodule AtlasBus.Link.Server do
  @moduledoc "The private, opt-in Bus listener. Tokens are bound to machine names."
  use GenServer
  alias AtlasBus.Link
  require Logger

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)

  def init(settings) do
    Process.flag(:trap_exit, true)

    {:ok, socket} =
      AtlasTransport.listen(Map.put_new(settings, "host", "127.0.0.1"), [
        :binary,
        packet: :line,
        packet_size: 4_194_304,
        buffer: 4_194_304,
        active: false,
        reuseaddr: true
      ])

    {:ok, peers} = Task.Supervisor.start_link(max_children: 64)
    {acceptor, ref} = start_acceptor(socket, settings, peers)
    {:ok, %{socket: socket, acceptor: acceptor, ref: ref, peers: peers, settings: settings}}
  end

  def handle_call(:port, _from, state),
    do: {:reply, elem(AtlasTransport.port(state.socket), 1), state}

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = state) do
    case AtlasTransport.port(state.socket) do
      {:ok, _} ->
        Logger.warning("Bus acceptor exited: #{inspect(reason)}; restarting")
        {acceptor, ref} = start_acceptor(state.socket, state.settings, state.peers)
        {:noreply, %{state | acceptor: acceptor, ref: ref}}

      _ ->
        {:stop, :listener_closed, state}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{peers: pid} = state),
    do: {:stop, {:peers, reason}, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def terminate(_, state) do
    AtlasTransport.close(state.socket)
    Process.exit(state.acceptor, :shutdown)
    if Process.alive?(state.peers), do: Supervisor.stop(state.peers)
  end

  defp start_acceptor(socket, settings, peers),
    do: :erlang.spawn_opt(fn -> accept(socket, settings, peers) end, [:link, :monitor])

  defp accept(listener, settings, peers) do
    case AtlasTransport.accept_peer(listener) do
      {:ok, socket} ->
        AtlasTransport.start_peer(peers, socket, &connection(&1, settings))
        accept(listener, settings, peers)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(listener, settings, peers)
    end
  end

  defp connection(socket, settings) do
    Process.flag(:trap_exit, true)

    try do
      with {:ok, line} <- AtlasTransport.recv(socket, 0, 5_000),
           {:ok, %{"op" => "hello", "environment" => env, "machine" => machine, "token" => token}} <-
             JSON.decode(line),
           true <- env == AtlasBus.environment(),
           true <- is_binary(machine) and Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, machine),
           true <- Link.same_token?(token, (settings["tokens"] || %{})[machine]) do
        :ok = AtlasTransport.send(socket, Link.encode("welcome", %{}))
        AtlasTransport.setopts(socket, active: :once)
        loop(socket, machine, %{})
      else
        _ -> AtlasTransport.send(socket, Link.encode("refused", %{"reason" => "hello refused"}))
      end
    after
      AtlasTransport.close(socket)
    end
  end

  defp loop(socket, machine, endpoints) do
    receive do
      {transport, ^socket, line} when transport in [:tcp, :ssl] ->
        case JSON.decode(line) do
          {:ok, %{} = frame} ->
            case frame(socket, machine, endpoints, frame) do
              {:ok, next} ->
                AtlasTransport.setopts(socket, active: :once)
                loop(socket, machine, next)

              :close ->
                stop(endpoints)
            end

          _ ->
            stop(endpoints)
        end

      {:deliver, name, envelope, content} ->
        if Link.deliver_allowed?(name, machine, envelope) do
          AtlasTransport.send(
            socket,
            Link.encode("deliver", %{
              "endpoint" => name,
              "envelope" => Link.envelope_out(envelope),
              "content" => content
            })
          )
        end

        loop(socket, machine, endpoints)

      {closed, ^socket} when closed in [:tcp_closed, :ssl_closed] ->
        stop(endpoints)

      {error, ^socket, _} when error in [:tcp_error, :ssl_error] ->
        stop(endpoints)

      {:EXIT, pid, _} ->
        stop(Map.reject(endpoints, fn {_, p} -> p == pid end))
    end
  end

  defp frame(socket, machine, endpoints, %{"op" => "attach", "endpoint" => name}) do
    if Link.allowed?(name, machine) and not Map.has_key?(endpoints, name) do
      owner = self()

      pid =
        spawn_link(fn ->
          case AtlasBus.attach(name) do
            :ok ->
              Process.monitor(owner)
              proxy(owner, name)

            _ ->
              :taken
          end
        end)

      {:ok, Map.put(endpoints, name, pid)}
    else
      if Map.has_key?(endpoints, name), do: {:ok, endpoints}, else: refuse(socket)
    end
  end

  defp frame(_socket, _machine, endpoints, %{"op" => "detach", "endpoint" => name}) do
    if pid = endpoints[name] do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    {:ok, Map.delete(endpoints, name)}
  end

  defp frame(socket, _machine, endpoints, %{"op" => "listen", "endpoint" => name, "kind" => kind})
       when is_binary(kind) and kind != "" do
    if pid = endpoints[name],
      do:
        (
          send(pid, {:listen, kind})
          {:ok, endpoints}
        ),
      else: refuse(socket)
  end

  defp frame(socket, machine, endpoints, %{
         "op" => "send",
         "endpoint" => name,
         "envelope" => %{} = map,
         "content" => content
       }) do
    envelope = Link.envelope_in(map)
    # A remote Runtime cannot forge Facts acknowledgements or invoke failure controls.
    if endpoints[name] && Link.send_allowed?(name, machine, envelope) &&
         AtlasBus.Envelope.validate(envelope) == :ok &&
         envelope.environment == AtlasBus.environment() do
      send(endpoints[name], {:send, envelope, content})
      {:ok, endpoints}
    else
      refuse(socket)
    end
  end

  defp frame(socket, _, _, _), do: refuse(socket)

  defp refuse(socket) do
    AtlasTransport.send(socket, Link.encode("refused", %{"reason" => "frame refused"}))
    :close
  end

  defp stop(endpoints),
    do:
      Enum.each(endpoints, fn {_, pid} ->
        Process.unlink(pid)
        Process.exit(pid, :shutdown)
      end)

  defp proxy(owner, name) do
    receive do
      {:DOWN, _, :process, ^owner, _} -> exit(:normal)
      {:listen, kind} -> AtlasBus.listen(kind)
      {:send, envelope, content} -> AtlasBus.send(envelope, content)
      {:atlas_bus, envelope, content} -> send(owner, {:deliver, name, envelope, content})
    end

    proxy(owner, name)
  end
end
