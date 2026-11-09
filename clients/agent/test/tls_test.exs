Code.require_file("../../../transport/test/support/tls_peer.exs", __DIR__)

defmodule AtlasAgent.TLSTest do
  use ExUnit.Case, async: false
  alias AtlasTransport.TLSPeer
  setup_all do: TLSPeer.fixtures()

  test "a substituted plaintext peer cannot obtain a hello or discovery grant" do
    :inet_db.add_host({127, 0, 0, 1}, [~c"eyra-atlas", ~c"core.security-fixture.ts.net"])
    System.put_env("ATLAS_RUNTIME_READ_TOKEN", "synthetic-read-grant")
    on_exit(fn -> System.delete_env("ATLAS_RUNTIME_READ_TOKEN") end)

    for host <- ["eyra-atlas", "core.security-fixture.ts.net"] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)

      peer =
        Task.async(fn ->
          case :gen_tcp.accept(listener, 500) do
            {:error, :timeout} ->
              ""

            {:ok, socket} ->
              # The same unauthenticated welcome/page used by the original reproduction.
              for message <- [
                    AtlasAgent.Protocol.reply(:hello, :welcome,
                      env: "test",
                      spec: AtlasAgent.Protocol.version()
                    ),
                    AtlasAgent.Protocol.reply(:hello, :page,
                      path: "/",
                      title: "Substituted peer",
                      blocks: [],
                      markup: []
                    )
                  ] do
                :gen_tcp.send(socket, [JSON.encode!(message), "\n"])
              end

              bytes =
                for _ <- 1..2, reduce: "" do
                  captured ->
                    case :gen_tcp.recv(socket, 0, 1_000) do
                      {:ok, bytes} -> captured <> bytes
                      _ -> captured
                    end
                end

              :gen_tcp.close(socket)
              bytes
          end
        end)

      try do
        result =
          with {:ok, client} <-
                 AtlasAgent.Client.connect("test", %{
                   "control" => %{"host" => host, "port" => port, "tls" => %{}}
                 }) do
            AtlasAgent.RuntimeDiscovery.read(client, "fixture-machine")
          end

        assert {:error, _} = result
        captured = Task.await(peer, 4_000)
        refute captured =~ "synthetic-read-grant"
        refute captured =~ ~s("op":"hello")
      after
        :gen_tcp.close(listener)
      end
    end
  end

  test "direct discovery never sends hello or read grant to wrong-name or untrusted peers", %{
    tls_dir: dir
  } do
    System.put_env("ATLAS_RUNTIME_READ_TOKEN", "synthetic-read-grant")
    on_exit(fn -> System.delete_env("ATLAS_RUNTIME_READ_TOKEN") end)

    for kind <- [:wrong_name, :untrusted] do
      assert {{:error, _}, :zero_application_bytes} =
               TLSPeer.peer(dir, kind, fn destination ->
                 with {:ok, client} <-
                        AtlasAgent.Client.connect("test", %{"control" => destination}) do
                   AtlasAgent.RuntimeDiscovery.read(client, "fixture-machine")
                 end
               end)
    end
  end

  test "authenticated discovery sends its grant only inside the verified TLS connection", %{
    tls_dir: dir
  } do
    System.put_env("ATLAS_RUNTIME_READ_TOKEN", "synthetic-read-grant")
    on_exit(fn -> System.delete_env("ATLAS_RUNTIME_READ_TOKEN") end)

    assert {{:runtime_discovery, _, 2}, true} =
             TLSPeer.peer(
               dir,
               :valid,
               fn destination ->
                 {:ok, client} = AtlasAgent.Client.connect("test", %{"control" => destination})
                 AtlasAgent.RuntimeDiscovery.read(client, "fixture-machine")
               end,
               fn socket ->
                 {:ok, hello} = AtlasTransport.recv(socket, 0, 2_000)
                 assert JSON.decode!(hello)["op"] == "hello"

                 for message <- [
                       AtlasAgent.Protocol.reply(:hello, :welcome,
                         env: "test",
                         spec: AtlasAgent.Protocol.version()
                       ),
                       AtlasAgent.Protocol.reply(:hello, :page,
                         path: "/",
                         title: "Fixture",
                         blocks: [],
                         markup: []
                       )
                     ] do
                   :ok = AtlasTransport.send(socket, [JSON.encode!(message), "\n"])
                 end

                 {:ok, request} = AtlasTransport.recv(socket, 0, 2_000)
                 JSON.decode!(request)["grant"] == "synthetic-read-grant"
               end
             )
  end
end
