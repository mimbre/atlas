Code.require_file("../../../../transport/test/support/tls_peer.exs", __DIR__)
Code.require_file("../../../../transport/test/support/listener_checks.exs", __DIR__)

defmodule AtlasBus.TLSTest do
  use ExUnit.Case, async: false
  alias AtlasTransport.TLSPeer
  setup_all do: TLSPeer.fixtures()

  test "TLS admission survives probes, stalled peers and child loss with bounded ownership", %{
    tls_dir: dir
  } do
    server =
      start_supervised!(
        {AtlasBus.Link.Server,
         %{
           "host" => "127.0.0.1",
           "port" => 0,
           "tls" => %{
             "certfile" => Path.join(dir, "valid.crt"),
             "keyfile" => Path.join(dir, "valid.key")
           },
           "tokens" => %{"fixture-machine" => "synthetic-bus-token"}
         }}
      )

    port = AtlasBus.Link.Server.port()

    destination = %{
      "host" => "core.security-fixture.ts.net",
      "port" => port,
      "tls" => %{"cacertfile" => Path.join(dir, "trusted.crt")}
    }

    :ok = AtlasBus.attach("control/listener-proof")

    connect = fn ->
      {:ok, socket} =
        AtlasTransport.connect(destination, [:binary, packet: :line, active: false], 2_000)

      :ok =
        AtlasTransport.send(
          socket,
          AtlasBus.Link.encode("hello", %{
            "environment" => AtlasBus.environment(),
            "machine" => "fixture-machine",
            "token" => "synthetic-bus-token"
          })
        )

      {:ok, reply} = AtlasTransport.recv(socket, 0, 2_000)
      assert JSON.decode!(reply)["op"] == "welcome"
      socket
    end

    endpoint = "runtime@fixture-machine/output"

    ping = fn socket ->
      :ok = AtlasTransport.send(socket, AtlasBus.Link.encode("attach", %{"endpoint" => endpoint}))

      AtlasTransport.ListenerChecks.eventually(fn ->
        Registry.lookup(AtlasBus.Endpoints, endpoint) != []
      end)

      id = "proof-#{System.unique_integer([:positive])}"

      :ok =
        AtlasBus.send(
          %AtlasBus.Envelope{
            id: id,
            environment: AtlasBus.environment(),
            class: "request",
            kind: "runtime.output",
            address: endpoint
          },
          %{"proof" => id}
        )

      {:ok, reply} = AtlasTransport.recv(socket, 0, 2_000)
      frame = JSON.decode!(reply)
      assert frame["op"] == "deliver"
      assert frame["envelope"]["id"] == id
      assert frame["content"] == %{"proof" => id}
    end

    AtlasTransport.ListenerChecks.exercise(server, port, connect, ping, fn ->
      stop_supervised!(AtlasBus.Link.Server)
    end)

    AtlasTransport.ListenerChecks.eventually(fn ->
      Registry.lookup(AtlasBus.Endpoints, endpoint) == []
    end)
  end

  test "initial connection and reconnection never evaluate the token for rejected peers", %{
    tls_dir: dir
  } do
    for kind <- [:wrong_name, :untrusted], _attempt <- 1..2 do
      assert {:disconnected, :zero_application_bytes} =
               TLSPeer.peer(dir, kind, fn destination ->
                 state = %{
                   settings: destination,
                   secret: fn -> flunk("token evaluated before peer authentication") end,
                   socket: nil,
                   refs: %{},
                   names: %{},
                   delay: 2_000
                 }

                 assert {:noreply, %{socket: nil}} =
                          AtlasBus.Link.Client.handle_info(:connect, state)

                 :disconnected
               end)
    end
  end

  test "a verified Bus connection sends the token and receives welcome", %{tls_dir: dir} do
    assert {:connected, true} =
             TLSPeer.peer(
               dir,
               :valid,
               fn destination ->
                 state = %{
                   settings: Map.put(destination, "machine", "fixture-machine"),
                   secret: fn -> "synthetic-bus-token" end,
                   socket: nil,
                   refs: %{},
                   names: %{},
                   delay: 2_000
                 }

                 assert {:noreply, %{socket: socket}} =
                          AtlasBus.Link.Client.handle_info(:connect, state)

                 assert socket != nil
                 AtlasTransport.close(socket)
                 :connected
               end,
               fn socket ->
                 {:ok, hello} = AtlasTransport.recv(socket, 0, 2_000)
                 assert JSON.decode!(hello)["token"] == "synthetic-bus-token"
                 AtlasTransport.send(socket, AtlasBus.Link.encode("welcome", %{}))
                 true
               end
             )
  end

  test "the real Bus TLS listener retains machine token authorization", %{tls_dir: dir} do
    start_supervised!(
      {AtlasBus.Link.Server,
       %{
         "host" => "127.0.0.1",
         "port" => 0,
         "tls" => %{
           "certfile" => Path.join(dir, "valid.crt"),
           "keyfile" => Path.join(dir, "valid.key")
         },
         "tokens" => %{"fixture-machine" => "synthetic-bus-token"}
       }}
    )

    destination = %{
      "host" => "core.security-fixture.ts.net",
      "port" => AtlasBus.Link.Server.port(),
      "tls" => %{"cacertfile" => Path.join(dir, "trusted.crt")}
    }

    for {token, expected} <- [{"wrong", "refused"}, {"synthetic-bus-token", "welcome"}] do
      {:ok, socket} =
        AtlasTransport.connect(destination, [:binary, packet: :line, active: false], 2_000)

      AtlasTransport.send(
        socket,
        AtlasBus.Link.encode("hello", %{
          "environment" => AtlasBus.environment(),
          "machine" => "fixture-machine",
          "token" => token
        })
      )

      {:ok, reply} = AtlasTransport.recv(socket, 0, 2_000)
      assert JSON.decode!(reply)["op"] == expected
      AtlasTransport.close(socket)
    end
  end
end
