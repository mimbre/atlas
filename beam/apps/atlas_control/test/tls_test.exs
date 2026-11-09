Code.require_file("../../../../transport/test/support/tls_peer.exs", __DIR__)
Code.require_file("../../../../transport/test/support/listener_checks.exs", __DIR__)

defmodule AtlasControl.TLSTest do
  use ExUnit.Case, async: false
  setup_all do: AtlasTransport.TLSPeer.fixtures()

  test "TLS admission survives probes, stalled peers and child loss with bounded ownership", %{
    tls_dir: dir
  } do
    Application.put_env(:atlas_bus, :store, "listener-#{System.unique_integer([:positive])}")
    start_supervised!(AtlasControl.FakeStore)

    gateway =
      start_supervised!(
        {AtlasControl.Gateway,
         port: 0,
         host: "127.0.0.1",
         name: :tls_gateway,
         model: AtlasControl.Shop,
         tls: %{
           "certfile" => Path.join(dir, "valid.crt"),
           "keyfile" => Path.join(dir, "valid.key")
         }}
      )

    port = AtlasControl.Gateway.port(:tls_gateway)

    destination = %{
      "host" => "core.security-fixture.ts.net",
      "port" => port,
      "tls" => %{"cacertfile" => Path.join(dir, "trusted.crt")}
    }

    connect = fn ->
      {:ok, socket} =
        AtlasTransport.connect(destination, [:binary, packet: :line, active: false], 2_000)

      :ok =
        AtlasTransport.send(
          socket,
          JSON.encode!(%{
            "op" => "hello",
            "env" => "test",
            "client" => "agent",
            "spec" => "0.16.0"
          }) <> "\n"
        )

      {:ok, welcome} = AtlasTransport.recv(socket, 0, 2_000)
      assert JSON.decode!(welcome)["op"] == "welcome"
      {:ok, page} = AtlasTransport.recv(socket, 0, 2_000)
      assert JSON.decode!(page)["op"] == "page"
      socket
    end

    ping = fn socket ->
      :ok =
        AtlasTransport.send(
          socket,
          JSON.encode!(%{
            "op" => "machine_discover",
            "channel" => "control",
            "version" => "0.1.0",
            "id" => "held-session",
            "target" => %{"environment" => "test", "machine" => "fixture"},
            "grant" => "wrong"
          }) <> "\n"
        )

      {:ok, reply} = AtlasTransport.recv(socket, 0, 2_000)
      assert JSON.decode!(reply)["error"]["code"] == "unauthorized"
    end

    AtlasTransport.ListenerChecks.exercise(gateway, port, connect, ping, fn ->
      stop_supervised!(AtlasControl.Gateway)
    end)

    AtlasTransport.ListenerChecks.eventually(fn ->
      DynamicSupervisor.which_children(AtlasControl.Sessions) == []
    end)
  end

  test "the real private Gateway serves Control only after TLS ownership transfer", %{
    tls_dir: dir
  } do
    Application.put_env(:atlas_bus, :store, "tls-#{System.unique_integer([:positive])}")
    start_supervised!(AtlasControl.FakeStore)

    start_supervised!(
      {AtlasControl.Gateway,
       port: 0,
       host: "127.0.0.1",
       name: :tls_gateway,
       model: AtlasControl.Shop,
       tls: %{"certfile" => Path.join(dir, "valid.crt"), "keyfile" => Path.join(dir, "valid.key")}}
    )

    destination = %{
      "host" => "core.security-fixture.ts.net",
      "port" => AtlasControl.Gateway.port(:tls_gateway),
      "tls" => %{"cacertfile" => Path.join(dir, "trusted.crt")}
    }

    {:ok, socket} =
      AtlasTransport.connect(destination, [:binary, packet: :line, active: false], 2_000)

    on_exit(fn ->
      AtlasTransport.close(socket)

      for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasControl.Sessions),
          do: DynamicSupervisor.terminate_child(AtlasControl.Sessions, pid)
    end)

    AtlasTransport.send(
      socket,
      JSON.encode!(%{"op" => "hello", "env" => "test", "client" => "agent", "spec" => "0.16.0"}) <>
        "\n"
    )

    {:ok, welcome} = AtlasTransport.recv(socket, 0, 2_000)
    assert JSON.decode!(welcome)["op"] == "welcome"
    {:ok, page} = AtlasTransport.recv(socket, 0, 2_000)
    assert JSON.decode!(page)["op"] == "page"

    AtlasTransport.send(
      socket,
      JSON.encode!(%{
        "op" => "machine_discover",
        "channel" => "control",
        "version" => "0.1.0",
        "id" => "private-tls-proof",
        "target" => %{"environment" => "test", "machine" => "fixture"},
        "grant" => "wrong"
      }) <> "\n"
    )

    {:ok, refused} = AtlasTransport.recv(socket, 0, 2_000)
    assert JSON.decode!(refused)["error"]["code"] == "unauthorized"
  end
end
