defmodule AtlasBus.Link.Server do
  @moduledoc "The private, opt-in Bus listener. Tokens are bound to machine names."
  use GenServer
  alias AtlasBus.Link

  def start_link(settings), do: GenServer.start_link(__MODULE__, settings, name: __MODULE__)
  def port, do: GenServer.call(__MODULE__, :port)

  def init(settings) do
    Process.flag(:trap_exit, true)
    host = settings["host"] || "127.0.0.1"
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    {:ok, socket} =
      :gen_tcp.listen(settings["port"], [
        family,
        :binary,
        packet: :line,
        packet_size: 4_194_304,
        buffer: 4_194_304,
        active: false,
        ip: ip,
        reuseaddr: true
      ])

    owner = self()

    {acceptor, ref} =
      :erlang.spawn_opt(fn -> accept(socket, settings, owner) end, [:link, :monitor])

    {:ok, %{socket: socket, acceptor: acceptor, ref: ref, connections: MapSet.new()}}
  end

  def handle_call(:port, _from, state), do: {:reply, elem(:inet.port(state.socket), 1), state}

  def handle_info({:connection, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | connections: MapSet.put(state.connections, pid)}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{ref: ref} = state),
    do: {:stop, {:acceptor, reason}, state}

  def handle_info({:DOWN, _, :process, pid, _}, state),
    do: {:noreply, %{state | connections: MapSet.delete(state.connections, pid)}}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def terminate(_, state) do
    :gen_tcp.close(state.socket)
    Process.exit(state.acceptor, :shutdown)
    Enum.each(state.connections, &Process.exit(&1, :shutdown))
  end

  defp accept(listener, settings, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        pid =
          spawn_link(fn ->
            receive do
              {:socket, s} -> connection(s, settings)
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, pid)
        send(owner, {:connection, pid})
        send(pid, {:socket, socket})
        accept(listener, settings, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp connection(socket, settings) do
    Process.flag(:trap_exit, true)

    try do
      with {:ok, line} <- :gen_tcp.recv(socket, 0, 5_000),
           {:ok, %{"op" => "hello", "environment" => env, "machine" => machine, "token" => token}} <-
             JSON.decode(line),
           true <- env == AtlasBus.environment(),
           true <- is_binary(machine) and Regex.match?(~r/^[a-zA-Z0-9_.-]+$/, machine),
           true <- Link.same_token?(token, (settings["tokens"] || %{})[machine]) do
        :ok = :gen_tcp.send(socket, Link.encode("welcome", %{}))
        :inet.setopts(socket, active: :once)
        loop(socket, machine, %{})
      else
        _ -> :gen_tcp.send(socket, Link.encode("refused", %{"reason" => "hello refused"}))
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp loop(socket, machine, endpoints) do
    receive do
      {:tcp, ^socket, line} ->
        case JSON.decode(line) do
          {:ok, %{} = frame} ->
            case frame(socket, machine, endpoints, frame) do
              {:ok, next} ->
                :inet.setopts(socket, active: :once)
                loop(socket, machine, next)

              :close ->
                stop(endpoints)
            end

          _ ->
            stop(endpoints)
        end

      {:deliver, name, envelope, content} ->
        if Link.deliver_allowed?(name, machine, envelope) do
          :gen_tcp.send(
            socket,
            Link.encode("deliver", %{
              "endpoint" => name,
              "envelope" => Link.envelope_out(envelope),
              "content" => content
            })
          )
        end

        loop(socket, machine, endpoints)

      {:tcp_closed, ^socket} ->
        stop(endpoints)

      {:tcp_error, ^socket, _} ->
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
    # A remote Runtime cannot forge State acknowledgements or invoke failure controls.
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
    :gen_tcp.send(socket, Link.encode("refused", %{"reason" => "frame refused"}))
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
