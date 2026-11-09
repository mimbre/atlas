Code.require_file("../../../transport/test/support/tls_fixture.ex", __DIR__)

defmodule AtlasAgent.ControlTLSTest do
  use ExUnit.Case, async: false
  alias AtlasAgent.{Client, Protocol, RuntimeDiscovery}
  alias AtlasControlTLSFixture, as: TLS

  setup do
    TLS.setup()
  end

  test "hello, reads and discovery use selected TLS despite unusable default settings", %{
    dir: dir
  } do
    {:ok, listener} = TLS.listener(dir)
    TLS.select(listener)
    System.put_env("ATLAS_RUNTIME_READ_TOKEN", "synthetic-grant")
    on_exit(fn -> System.delete_env("ATLAS_RUNTIME_READ_TOKEN") end)

    task =
      Task.async(fn ->
        {:ok, accepted} = :ssl.transport_accept(listener, 2_000)
        {:ok, socket} = :ssl.handshake(accepted, 2_000)
        assert TLS.read(socket)["op"] == "hello"
        TLS.send_line(socket, %{"op" => "welcome", "env" => "test", "spec" => Protocol.version()})
        TLS.send_line(socket, TLS.page())
        assert TLS.read(socket) == %{"op" => "open", "to" => "/private"}
        TLS.send_line(socket, TLS.page())
        request = TLS.read(socket)
        assert request["grant"] == "synthetic-grant"
        assert request["target"]["machine"] == "private"

        TLS.send_line(
          socket,
          Protocol.reply(:runtime_machine_discover, :error,
            id: request["id"],
            target: request["target"],
            error: %{
              "code" => "unavailable",
              "message" => "private fixture",
              "retryable" => false
            }
          )
        )

        assert {:error, :closed} = :ssl.recv(socket, 0, 2_000)
      end)

    assert {:ok, client} =
             Client.connect("test", %{"control" => %{"host" => "127.0.0.1", "port" => 1}})

    assert {:ok, _} = Client.open(client, "/private")
    assert {:runtime_discovery, _, _} = RuntimeDiscovery.read(client, "private")
    Client.close(client)
    Task.await(task)
    :ssl.close(listener)
  end

  test "TLS rejection closes before agent hello or discovery grant", %{dir: dir} do
    {:ok, listener} = TLS.listener(dir)
    TLS.select(listener, "wrong.tail8263c4.ts.net")

    task =
      Task.async(fn ->
        {:ok, socket} = :ssl.transport_accept(listener, 2_000)
        assert {:error, _} = :ssl.handshake(socket, 2_000)
        :ssl.close(socket)
      end)

    assert {:error, _} =
             Client.connect("test", %{"control" => %{"host" => "127.0.0.1", "port" => 1}})

    Task.await(task)
    :ssl.close(listener)
  end
end
