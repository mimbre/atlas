defmodule AtlasRuntime.Entrypoints.SocketTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Entrypoints.Socket

  test "socket owns framing, rejects noncommands and requests shutdown after replying" do
    dir = Path.join("/tmp", "atlas-runtime-socket-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    acceptor = Socket.start(dir, self())
    path = Path.join(dir, "runtime.sock")

    try do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      :ok = :gen_tcp.send(socket, "{\"command\":\"service-status\"}\n")
      assert_receive {:"$gen_call", from, %{"command" => "service-status"}}
      GenServer.reply(from, {%{service: "running"}, false})
      assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
      assert JSON.decode!(reply) == %{"service" => "running"}
      assert String.ends_with?(reply, "\n")
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

      for bytes <- ["not-json\n", "[]\n"] do
        {:ok, socket} =
          :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])

        :ok = :gen_tcp.send(socket, bytes)
        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
        assert JSON.decode!(reply) == %{"command_error" => "Expected a JSON command"}
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        refute_received {:"$gen_call", _, _}
      end

      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      :ok = :gen_tcp.send(socket, "{\"command\":\"service-stop\"}\n")
      assert_receive {:"$gen_call", from, %{"command" => "service-stop"}}
      GenServer.reply(from, {%{service: "stopping"}, true})
      assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
      assert JSON.decode!(reply) == %{"service" => "stopping"}
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      assert_receive :shutdown
    after
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end
  end
end
