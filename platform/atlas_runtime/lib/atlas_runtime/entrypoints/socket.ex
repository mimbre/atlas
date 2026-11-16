defmodule AtlasRuntime.Entrypoints.Socket do
  @moduledoc """
  `runtime.sock`: one JSON line per connection. A command is forwarded to the Service; it
  keeps the operations (`service-status`, `service-stop`, `preferences`, `release`) and the
  guidance commands (questions, answers, handoffs, peer correlation). The work commands are
  refused here (design 2026-11-16-runtime-backend §11): work is submitted, read and
  cancelled through the work contract on `backend.sock`, and turn history is read on
  `read.sock`. The Service keeps its own `start`, `continue`, `stop`, `kill` and `status`
  clauses, because the work core starts and stops turns through them in-process.

  The journal is served here too (§13.1 Q3), with the same JSON-lines protocol as on
  `read.sock`: a `runtime.read/1` request (one without `command`) for `events` or `follow`,
  with the `epoch:sequence` cursor, page `cursor`, `more` and `reset`. Every other
  `runtime.read/1` operation is refused with `not_journal`, so history is not read here.

  `follow` keeps its connection: the service only signals `{:events_appended, sequence}`, and
  the connection reads the journal pages itself, so a slow reader never holds the service up.
  """
  alias AtlasRuntime.Inspection.Reads

  # Each refused work command, and where it went.
  @moved %{
    "start" => "POST /v1/work",
    "continue" => "POST /v1/work with resume_from",
    "stop" => "POST /v1/work/{work_id}/cancel with mode graceful",
    "kill" => "POST /v1/work/{work_id}/cancel with mode force",
    "status" => "GET /v1/work",
    "output" => "GET /v1/turns/{turn_id}/output"
  }
  @history %{"turns" => "turns"}

  @api "runtime.read/1"
  @journal ["events", "follow"]
  # Milliseconds. `heartbeat`: a tick without a page; `service`: a page read during a tick or
  # after a signal; `send`: a write the reader does not take. Tests pass shorter ones.
  @timing [heartbeat: 15_000, service: 5_000, send: 5_000]
  @page 100

  def start(dir, server, timing \\ []) do
    timing = Keyword.merge(@timing, timing)

    serve(Path.join(dir, "runtime.sock"), server, fn bytes ->
      case JSON.decode(bytes) do
        {:ok, %{"command" => command}} when is_map_key(@moved, command) ->
          {%{
             command_error:
               "#{command} is not served on runtime.sock: use the work contract on " <>
                 "backend.sock (#{@moved[command]}), or atlas-runtime #{command}"
           }, false}

        {:ok, %{"command" => command}} when is_map_key(@history, command) ->
          {%{
             command_error:
               "#{command} is not served on runtime.sock: read it on read.sock " <>
                 "(runtime.read/1 #{@history[command]}), or atlas-runtime #{command}"
           }, false}

        {:ok, %{"command" => _} = request} ->
          GenServer.call(server, request, 30_000)

        {:ok, request} when is_map_key(request, "api") or is_map_key(request, "op") ->
          journal(request, server, timing)

        {:ok, request} when is_map(request) ->
          GenServer.call(server, request, 30_000)

        _ ->
          {%{command_error: "Expected a JSON command"}, false}
      end
    end)
  end

  # Only the journal operations reach `Inspection.Reads`, and only as `{:read, op, args}` or
  # a follow, never as a command.
  defp journal(%{"op" => op} = request, server, timing) when op in @journal do
    case Reads.request(request) do
      {:ok, "follow", args} -> {:stream, &follow(&1, server, args["cursor"], timing)}
      {:ok, op, args} -> {GenServer.call(server, {:read, op, args}, 30_000), false}
      {:error, code} -> {Reads.error(code), false}
    end
  end

  defp journal(_request, _server, _timing), do: {Reads.error("not_journal"), false}

  @doc """
  Serve one JSON line per connection at `path`; `handle` returns `{reply, shutdown?}`, or
  `{:stream, fun}` to hand the connection to `fun.(socket)`, which then owns and closes it.
  """
  def serve(path, server, handle) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        packet: :line,
        packet_size: 1_048_576,
        buffer: 1_048_576,
        active: false
      ])

    File.chmod!(path, 0o600)
    System.at_exit(fn _ -> File.rm(path) end)
    spawn_link(fn -> accept(listener, server, handle) end)
  end

  defp accept(listener, server, handle) do
    {:ok, socket} = :gen_tcp.accept(listener)

    pid =
      spawn(fn ->
        receive do
          {:socket, s} -> connection(s, server, handle)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept(listener, server, handle)
  end

  defp connection(socket, server, handle) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} ->
        case handle.(bytes) do
          {:stream, stream} ->
            stream.(socket)

          {reply, shutdown?} ->
            :gen_tcp.send(socket, JSON.encode!(reply) <> "\n")
            :gen_tcp.close(socket)
            if shutdown?, do: send(server, :shutdown)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end

  # A follow connection, as on read.sock. Registration and the first page are one service
  # call, so no event falls between them.
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

      # A service that began its shutdown admits no follower and sends no page.
      {:ok, :service_stopping} ->
        finish(connection, "service_stopping")

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
