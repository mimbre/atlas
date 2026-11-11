defmodule AtlasRuntime.Entrypoints.Socket do
  def start(dir, server) do
    serve(Path.join(dir, "runtime.sock"), server, fn bytes ->
      case JSON.decode(bytes) do
        {:ok, request} when is_map(request) -> GenServer.call(server, request, 30_000)
        _ -> {%{command_error: "Expected a JSON command"}, false}
      end
    end)
  end

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
end
