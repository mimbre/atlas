defmodule AtlasRuntime.Entrypoints.ReadSocket do
  @moduledoc """
  `read.sock`, the runtime.read/1 entrypoint. Only the operations `Inspection.Reads.request/1`
  admits reach the service, as `{:read, op, args}` and never as a command, so this socket
  cannot start, stop, assign, answer, hand off or change preferences. Everything else is
  refused here.
  """
  alias AtlasRuntime.Entrypoints.Socket
  alias AtlasRuntime.Inspection.Reads

  def start(dir, server) do
    path = Path.join(dir, "read.sock")
    # Started after runtime.sock is bound, so no other service owns this directory: a
    # read.sock left by an ended one has no listener.
    File.rm(path)
    Socket.serve(path, server, &{handle(&1, server), false})
  end

  defp handle(bytes, server) do
    with {:ok, request} when is_map(request) <- JSON.decode(bytes),
         {:ok, op, args} <- Reads.request(request) do
      GenServer.call(server, {:read, op, args}, 30_000)
    else
      {:error, code} when is_binary(code) -> Reads.error(code)
      _ -> Reads.error("invalid_request")
    end
  end
end
