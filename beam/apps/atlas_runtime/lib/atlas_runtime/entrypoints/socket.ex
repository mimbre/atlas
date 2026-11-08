defmodule AtlasRuntime.Entrypoints.Socket do
  def start(dir, server) do
    path = Path.join(dir, "runtime.sock")

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
    spawn_link(fn -> accept(listener, server) end)
  end

  defp accept(listener, server) do
    {:ok, socket} = :gen_tcp.accept(listener)

    pid =
      spawn(fn ->
        receive do
          {:socket, s} -> connection(s, server)
        end
      end)

    :ok = :gen_tcp.controlling_process(socket, pid)
    send(pid, {:socket, socket})
    accept(listener, server)
  end

  defp connection(socket, server) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} ->
        {reply, shutdown?} =
          case JSON.decode(bytes) do
            {:ok, request} when is_map(request) -> GenServer.call(server, request, 30_000)
            _ -> {%{command_error: "Expected a JSON command"}, false}
          end

        :gen_tcp.send(socket, JSON.encode!(reply) <> "\n")
        :gen_tcp.close(socket)
        if shutdown?, do: send(server, :shutdown)

      _ ->
        :gen_tcp.close(socket)
    end
  end
end
