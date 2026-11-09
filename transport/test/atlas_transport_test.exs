Code.require_file("support/tls_peer.exs", __DIR__)

defmodule AtlasTransportTest do
  use ExUnit.Case, async: false
  alias AtlasTransport.TLSPeer
  setup_all do: TLSPeer.fixtures()
  @options [:binary, packet: :line, active: false]

  test "a trusted exact-name peer receives application bytes only after TLS", %{tls_dir: dir} do
    assert {:ok, {:ok, "hello\n"}} =
             TLSPeer.peer(dir, :valid, fn destination ->
               {:ok, socket} = AtlasTransport.connect(destination, @options, 2_000)
               :ok = AtlasTransport.send(socket, "hello\n")
               AtlasTransport.close(socket)
               :ok
             end)
  end

  test "wrong name and unknown trust receive zero application bytes", %{tls_dir: dir} do
    for kind <- [:wrong_name, :untrusted] do
      assert {{:error, _}, :zero_application_bytes} =
               TLSPeer.peer(dir, kind, fn destination ->
                 AtlasTransport.connect(destination, @options, 2_000)
               end)
    end
  end

  test "missing destination, short names, and remote plaintext fail before connecting" do
    for destination <- [
          %{"port" => 1, "tls" => %{}},
          %{"host" => "eyra-atlas", "port" => 1, "tls" => %{}},
          %{"host" => "core.security-fixture.ts.net", "port" => 1},
          %{"host" => "127.0.0.1", "port" => 1, "tls" => %{}}
        ] do
      assert {:error, _} = AtlasTransport.connect(destination, @options, 50)
    end

    assert {:error, :authenticated_listener_required} =
             AtlasTransport.listen(%{"host" => "::", "port" => 0}, @options)

    assert {:error, _} =
             AtlasTransport.listen(%{"host" => "::", "port" => 0, "tls" => %{}}, @options)
  end
end
