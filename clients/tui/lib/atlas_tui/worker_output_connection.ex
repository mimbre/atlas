defmodule AtlasTui.WorkerOutputConnection do
  @moduledoc """
  An owner-monitored Control connection for demand-driven worker output.

  Uses the Console hello and configured Control address, independently of the
  main Console socket. Ready means a compatible welcome and its ordinary page
  have both arrived; this connection never boots or navigates the Console.

  `send_request/2` and `stop/1` enqueue commands and return `:ok` immediately,
  keeping TCP writes off the Console loop. Admission failures are reported as
  `{:rejected, request_id, reason}`. The owner keeps at most one request pending;
  additional requests are rejected, never retained for later transmission.
  There is no automatic subscription, polling, or reconnect.
  Only one reply with the outstanding request's ID and generated reply operation
  is forwarded. The owner/reducer still validates its complete typed envelope,
  execution, subscription and cursor before accepting it.

  Owner messages are `{:worker_output_connection, pid, :ready}`, or the same
  tuple with `{:message, wire_map}`, `{:rejected, request_id, reason}` or
  `{:closed, reason}` as its last element. Closing is confirmed asynchronously.
  Stop closes only this socket; Control owns subscription cleanup. It sends no
  unsubscribe or worker lifecycle command. All state is session-local.
  """
  use GenServer

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.{Console, Protocol}

  # Match App's connect/handshake conventions without adding user settings.
  @connect_timeout 2_000
  @handshake_timeout 5_000
  @request_timeout 5_000
  @send_timeout 2_000
  # Fits the approved <=64 KiB encoded event batch plus its typed envelope.
  # packet_size also bounds an incomplete line before JSON decoding occurs.
  @line_limit 262_144
  @operations [
    :worker_inspect,
    :worker_output_subscribe,
    :worker_output_next,
    :worker_output_unsubscribe
  ]

  def start(owner, env, settings) when is_pid(owner) and is_binary(env),
    do: GenServer.start(__MODULE__, {owner, env, settings})

  def send_request(pid, wire_map), do: GenServer.cast(pid, {:send_request, wire_map})

  def stop(pid), do: GenServer.cast(pid, :stop)

  @impl true
  def init({owner, env, settings}) do
    state = %{
      owner: owner,
      monitor: Process.monitor(owner),
      env: env,
      host: String.to_charlist(settings["control"]["host"]),
      port: settings["control"]["port"],
      socket: nil,
      phase: :connecting,
      pending: nil,
      deadline: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    options = [
      :binary,
      packet: :line,
      packet_size: @line_limit,
      buffer: @line_limit,
      active: false,
      send_timeout: @send_timeout,
      send_timeout_close: true
    ]

    case :gen_tcp.connect(state.host, state.port, options, @connect_timeout) do
      {:ok, socket} ->
        state = %{state | socket: socket, phase: :welcome}

        case send_wire(socket, Console.hello(%{env: state.env})) do
          :ok ->
            state |> deadline(:handshake_timeout, @handshake_timeout) |> listen()

          {:error, reason} ->
            finish(state, {:send, reason})
        end

      {:error, reason} ->
        finish(state, {:connect, reason})
    end
  end

  @impl true
  def handle_cast(:stop, state), do: finish(state, :stopped)

  def handle_cast({:send_request, message}, %{phase: phase} = state)
      when phase != :ready,
      do: reject(state, message, :not_ready)

  def handle_cast({:send_request, message}, %{pending: pending} = state)
      when pending != nil,
      do: reject(state, message, :busy)

  def handle_cast({:send_request, message}, state) do
    with {:ok, pending} <- request(message),
         {:ok, bytes} <- encode(message) do
      case :gen_tcp.send(state.socket, bytes) do
        :ok ->
          state = deadline(%{state | pending: pending}, :request_timeout, @request_timeout)
          {:noreply, state}

        {:error, reason} ->
          finish(state, {:send, reason})
      end
    else
      {:error, reason} -> reject(state, message, reason)
    end
  end

  @impl true
  def handle_info({:tcp, socket, line}, %{socket: socket} = state) do
    case JSON.decode(line) do
      {:ok, message} when is_map(message) -> receive_message(state, message)
      _ -> finish(state, :invalid_frame)
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: finish(state, :closed)

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: finish(state, {:tcp, reason})

  def handle_info({:deadline, token}, %{deadline: {_timer, token, reason}} = state),
    do: finish(state, reason)

  def handle_info(
        {:DOWN, monitor, :process, owner, _reason},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.socket, do: :gen_tcp.close(state.socket)
    cancel_deadline(state)
    :ok
  end

  defp receive_message(%{phase: :welcome} = state, %{"op" => "welcome"} = message) do
    if message["env"] == state.env and message["surface"] == "console" and
         message["spec"] == Protocol.version() do
      listen(%{state | phase: :compatibility})
    else
      finish(state, :incompatible_welcome)
    end
  end

  defp receive_message(%{phase: :compatibility} = state, %{"op" => "page"}) do
    notify(state, :ready)
    listen(%{cancel_deadline(state) | phase: :ready})
  end

  defp receive_message(state, %{"op" => "bye"}), do: finish(state, :server_bye)

  defp receive_message(%{phase: :ready, pending: pending} = state, message)
       when pending != nil do
    if message["id"] == pending.id and message["op"] in pending.replies do
      notify(state, {:message, message})
      listen(%{cancel_deadline(state) | pending: nil})
    else
      listen(state)
    end
  end

  # Ordinary pages/hints and unsolicited or stale output never reach the owner.
  defp receive_message(state, _message), do: listen(state)

  defp request(message) do
    case Wire.decode_request(message) do
      {:ok, name, %{"id" => id}} when name in @operations and is_binary(id) and id != "" ->
        wire = Enum.find(Wire.wires(), &(&1.name == name))
        {:ok, %{id: id, replies: Enum.map(wire.replies, & &1.select["op"])}}

      _ ->
        {:error, :invalid_request}
    end
  end

  defp encode(message) do
    bytes = [JSON.encode!(message), "\n"]

    if IO.iodata_length(bytes) <= @line_limit,
      do: {:ok, bytes},
      else: {:error, :request_too_large}
  end

  defp send_wire(socket, message) do
    with {:ok, bytes} <- encode(message), do: :gen_tcp.send(socket, bytes)
  end

  defp listen(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state}
      {:error, reason} -> finish(state, {:tcp, reason})
    end
  end

  defp deadline(state, reason, milliseconds) do
    token = make_ref()
    timer = Process.send_after(self(), {:deadline, token}, milliseconds)
    %{state | deadline: {timer, token, reason}}
  end

  defp cancel_deadline(%{deadline: nil} = state), do: state

  defp cancel_deadline(%{deadline: {timer, _token, _reason}} = state) do
    Process.cancel_timer(timer)
    %{state | deadline: nil}
  end

  defp finish(state, reason), do: {:stop, :normal, close(state, reason)}

  defp close(state, reason) do
    state = cancel_deadline(state)
    if state.socket, do: :gen_tcp.close(state.socket)
    notify(state, {:closed, reason})
    %{state | socket: nil, pending: nil}
  end

  defp notify(state, event), do: send(state.owner, {:worker_output_connection, self(), event})

  defp reject(state, message, reason) do
    id =
      case message do
        %{"id" => id} when is_binary(id) -> id
        _ -> nil
      end

    notify(state, {:rejected, id, reason})
    {:noreply, state}
  end
end
