defmodule AtlasRuntime.Entrypoints.ReadSocket do
  @moduledoc """
  `read.sock`, the runtime.read/1 entrypoint. Only the operations `Inspection.Reads.request/1`
  admits reach the service, as `{:read, op, args}` and never as a command, so this socket
  cannot start, stop, assign, answer, hand off or change preferences. Everything else is
  refused here.

  `follow` keeps its connection: the service only signals `{:events_appended, sequence}`, and
  the connection reads the journal pages itself, so a slow reader never holds the service up.
  """
  alias AtlasRuntime.Entrypoints.Socket
  alias AtlasRuntime.Inspection.Reads

  @api "runtime.read/1"
  # Milliseconds. `heartbeat`: a tick without a page; `service`: a page read during a tick or
  # after a signal; `send`: a write the reader does not take. Tests pass shorter ones.
  @timing [heartbeat: 15_000, service: 5_000, send: 5_000]
  @page 100

  def start(dir, server, timing \\ []) do
    path = Path.join(dir, "read.sock")
    # Started after runtime.sock is bound, so no other service owns this directory: a
    # read.sock left by an ended one has no listener.
    File.rm(path)
    timing = Keyword.merge(@timing, timing)
    Socket.serve(path, server, &handle(&1, server, timing))
  end

  defp handle(bytes, server, timing) do
    with {:ok, request} when is_map(request) <- JSON.decode(bytes),
         {:ok, op, args} <- Reads.request(request) do
      if op == "follow",
        do: {:stream, &follow(&1, server, args["cursor"], timing)},
        else: {GenServer.call(server, {:read, op, args}, 30_000), false}
    else
      {:error, code} when is_binary(code) -> {Reads.error(code), false}
      _ -> {Reads.error("invalid_request"), false}
    end
  end

  # Registration and the first page are one service call, so no event falls between them.
  defp follow(socket, server, cursor, timing) do
    :ok =
      :inet.setopts(socket,
        send_timeout: timing[:send],
        send_timeout_close: true,
        active: :once
      )

    connection = %{
      socket: socket,
      server: server,
      timing: timing,
      monitor: Process.monitor(server)
    }

    case call(connection, {:follow, self(), cursor}) do
      {:ok, %{"error" => _} = error} ->
        write(connection, error)

      {:ok, page} ->
        with {:ok, cursor} <- pages(connection, page),
             do: wait(connection, cursor, deadline(connection))

      :unresponsive ->
        finish(connection, "service_unresponsive")
    end

    :gen_tcp.close(socket)
  end

  defp wait(%{socket: socket, monitor: monitor} = connection, cursor, deadline) do
    receive do
      {:events_appended, _sequence} ->
        drain()
        next(connection, cursor, deadline, false)

      :service_stopping ->
        finish(connection, "service_stopping")

      # A crashed service says nothing; the client sees EOF without `end`.
      {:DOWN, ^monitor, :process, _, _} ->
        :closed

      # Input after the request is a protocol error; a closed reader frees its slot.
      {:tcp, ^socket, _} ->
        :closed

      {:tcp_closed, ^socket} ->
        :closed

      {:tcp_error, ^socket, _} ->
        :closed
    after
      max(deadline - now(), 0) -> next(connection, cursor, deadline, true)
    end
  end

  # A tick reads through the service like a signal does, so a heartbeat proves it answered.
  defp next(connection, cursor, deadline, tick?) do
    case call(connection, {:read, "events", %{"cursor" => cursor, "limit" => @page}}) do
      {:ok, %{"error" => _} = error} ->
        write(connection, error)

      {:ok, page} ->
        cond do
          page["events"] != [] or Map.has_key?(page, "reset") ->
            with {:ok, cursor} <- pages(connection, page),
                 do: wait(connection, cursor, deadline(connection))

          tick? ->
            with :ok <- frame(connection, "heartbeat", %{"cursor" => page["cursor"]}),
                 do: wait(connection, page["cursor"], deadline(connection))

          true ->
            wait(connection, cursor, deadline)
        end

      :unresponsive ->
        finish(connection, "service_unresponsive")
    end
  end

  # Writes `page` and every page after it while `more`; returns the last cursor written.
  defp pages(connection, page) do
    with :ok <- frame(connection, "page", Map.drop(page, ["api", "op"])) do
      if page["more"] do
        case call(connection, {:read, "events", %{"cursor" => page["cursor"], "limit" => @page}}) do
          {:ok, %{"error" => _} = error} -> write(connection, error)
          {:ok, next} -> pages(connection, next)
          :unresponsive -> finish(connection, "service_unresponsive")
        end
      else
        {:ok, page["cursor"]}
      end
    end
  end

  # Best effort: a reader that is gone or too slow simply misses it.
  defp finish(connection, reason) do
    send_line(connection, frame_line("end", %{"reason" => reason}))
    :closed
  end

  defp frame(connection, type, fields), do: write(connection, frame_line(type, fields))

  defp frame_line(type, fields),
    do: Map.merge(fields, %{"api" => @api, "op" => "follow", "type" => type})

  defp write(connection, line) do
    case send_line(connection, line) do
      :ok -> :ok
      {:error, :timeout} -> finish(connection, "too_slow")
      {:error, _} -> :closed
    end
  end

  defp send_line(connection, line),
    do: :gen_tcp.send(connection.socket, JSON.encode!(line) <> "\n")

  defp call(connection, request) do
    {:ok, GenServer.call(connection.server, request, connection.timing[:service])}
  catch
    :exit, _ -> :unresponsive
  end

  defp drain do
    receive do
      {:events_appended, _sequence} -> drain()
    after
      0 -> :ok
    end
  end

  defp deadline(connection), do: now() + connection.timing[:heartbeat]
  defp now, do: System.monotonic_time(:millisecond)
end
