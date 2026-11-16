defmodule AtlasControlTransportTest do
  use ExUnit.Case, async: false
  alias AtlasControlTransport, as: Transport
  alias AtlasControlTLSFixture, as: TLS

  setup context do
    fallback = if context[:without_tmpdir], do: TLS.without_tmpdir()
    fixture = TLS.setup()
    if fallback, do: assert(Path.dirname(fixture.dir) == fallback)
    fixture
  end

  @options [:binary, packet: :line, active: false]
  @settings %{"host" => "127.0.0.1", "port" => 1}

  test "selection is strict, including explicit empty values" do
    for endpoint <- [
          "",
          "tcp://fixture.tail8263c4.ts.net:443",
          "tls://short:443",
          "tls://fixture.tail8263c4.ts.net:0",
          "tls://fixture.tail8263c4.ts.net:65536",
          "tls://fixture.tail8263c4.ts.net:443/",
          "tls://user@fixture.tail8263c4.ts.net:443",
          " tls://fixture.tail8263c4.ts.net:443",
          "tls://a..tail8263c4.ts.net:443"
        ] do
      System.put_env("ATLAS_CONTROL_ENDPOINT", endpoint)
      assert {:error, :invalid_control_endpoint} = Transport.connect(@settings, @options, 100)
    end

    assert {:ok, {:tls, "fixture.tail8263c4.ts.net", 443}} =
             Transport.parse("tls://fixture.tail8263c4.ts.net:00443")
  end

  test "absent selection uses existing TCP settings" do
    System.delete_env("ATLAS_CONTROL_ENDPOINT")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    assert {:ok, socket} = Transport.connect(%{@settings | "port" => port}, @options, 500)
    {:ok, peer} = :gen_tcp.accept(listener, 500)
    assert :ok = Transport.send(socket, "original\n")
    assert {:ok, "original\n"} = :gen_tcp.recv(peer, 0, 500)
    Transport.close(socket)
    :gen_tcp.close(peer)
    :gen_tcp.close(listener)
  end

  @tag :without_tmpdir
  test "trusted TLS checks full SNI and supports send, recv, active once and closure", %{dir: dir} do
    {:ok, listener} = TLS.listener(dir)
    TLS.select(listener)

    task =
      Task.async(fn ->
        {:ok, accepted} = :ssl.transport_accept(listener, 2_000)
        {:ok, peer} = :ssl.handshake(accepted, 2_000)
        {:ok, info} = :ssl.connection_information(peer, [:sni_hostname])
        assert to_string(info[:sni_hostname]) == TLS.host()
        assert {:ok, "passive\n"} = :ssl.recv(peer, 0, 500)
        :ssl.send(peer, "reply\n")
        assert {:ok, "active\n"} = :ssl.recv(peer, 0, 500)
        :ssl.send(peer, "event\n")
        :ssl.close(peer)
      end)

    assert {:ok, socket} = Transport.connect(@settings, @options, 2_000)
    assert :ok = Transport.send(socket, "passive\n")
    assert {:ok, "reply\n"} = Transport.recv(socket, 0, 500)
    assert :ok = Transport.setopts(socket, active: :once)
    assert :ok = Transport.send(socket, "active\n")
    assert_receive {:ssl, ^socket, "event\n"}, 1_000
    assert :ok = Transport.setopts(socket, active: :once)
    assert_receive {:ssl_closed, ^socket}, 1_000
    Transport.close(socket)
    Task.await(task)
    :ssl.close(listener)
  end

  for failure <- [:hostname, :untrusted] do
    test "rejects #{failure} before application bytes", %{dir: dir} do
      {:ok, fallback} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, fallback_port}} = :inet.sockname(fallback)
      {:ok, listener} = TLS.listener(dir)

      TLS.select(
        listener,
        if(unquote(failure) == :hostname, do: "wrong.tail8263c4.ts.net", else: TLS.host())
      )

      if unquote(failure) == :untrusted,
        do: :public_key.cacerts_load(String.to_charlist(Path.join(dir, "other.pem")))

      task =
        Task.async(fn ->
          {:ok, accepted} = :ssl.transport_accept(listener, 2_000)
          result = :ssl.handshake(accepted, 2_000)
          :ssl.close(accepted)
          result
        end)

      assert {:error, _} =
               Transport.connect(%{@settings | "port" => fallback_port}, @options, 2_000)

      assert {:error, _} = Task.await(task)
      assert {:error, :timeout} = :gen_tcp.accept(fallback, 30)
      :gen_tcp.close(fallback)
      :ssl.close(listener)
    end
  end

  test "plaintext peer never receives hello or grants" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    System.put_env("ATLAS_CONTROL_ENDPOINT", "tls://#{TLS.host()}:#{port}")

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 1_000)
        refute bytes =~ "hello"
        refute bytes =~ "synthetic-grant"
        :gen_tcp.send(socket, "plaintext\n")
        :gen_tcp.close(socket)
      end)

    assert {:error, _} = Transport.connect(@settings, @options, 2_000)
    Task.await(task)
    :gen_tcp.close(listener)
  end
end
