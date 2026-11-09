Code.require_file("../../../transport/test/support/tls_peer.exs", __DIR__)

defmodule AtlasTui.TLSTest do
  use ExUnit.Case, async: false
  alias AtlasTransport.TLSPeer
  setup_all do: TLSPeer.fixtures()

  test "output admission sends no hello or request to a substituted TLS peer", %{tls_dir: dir} do
    for kind <- [:wrong_name, :untrusted] do
      assert {:closed, :zero_application_bytes} =
               TLSPeer.peer(dir, kind, fn destination ->
                 {:ok, {pid, monitor}} =
                   AtlasTui.WorkerOutputConnection.start_monitor(self(), "test", %{
                     "control" => destination
                   })

                 assert_receive {:worker_output_connection, ^pid, {:closed, {:connect, _}}}, 5_000
                 assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 1_000
                 :closed
               end)
    end
  end

  test "Console initial and reconnect handshakes send no hello to rejected peers", %{tls_dir: dir} do
    for kind <- [:wrong_name, :untrusted], _attempt <- 1..2 do
      assert {:disconnected, :zero_application_bytes} =
               TLSPeer.peer(dir, kind, fn destination ->
                 state = %{
                   model: AtlasTui.Model.new("test"),
                   settings: %{"control" => destination},
                   socket: nil
                 }

                 assert %{socket: nil} = AtlasTui.App.connect(state)
                 :disconnected
               end)
    end
  end

  test "Console hello uses the authenticated socket", %{tls_dir: dir} do
    assert {:connected, true} =
             TLSPeer.peer(
               dir,
               :valid,
               fn destination ->
                 state = %{
                   model: AtlasTui.Model.new("test"),
                   settings: %{"control" => destination},
                   socket: nil
                 }

                 connected = AtlasTui.App.connect(state)
                 assert connected.socket != nil
                 AtlasTransport.close(connected.socket)
                 :connected
               end,
               fn socket ->
                 {:ok, hello} = AtlasTransport.recv(socket, 0, 2_000)
                 JSON.decode!(hello)["op"] == "hello"
               end
             )
  end

  test "output connection admits a verified TLS welcome and receives its page", %{tls_dir: dir} do
    assert {:ready, true} =
             TLSPeer.peer(
               dir,
               :valid,
               fn destination ->
                 {:ok, {pid, monitor}} =
                   AtlasTui.WorkerOutputConnection.start_monitor(self(), "test", %{
                     "control" => destination
                   })

                 assert_receive {:worker_output_connection, ^pid, :ready}, 5_000
                 AtlasTui.WorkerOutputConnection.stop(pid)
                 assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
                 :ready
               end,
               fn socket ->
                 {:ok, hello} = AtlasTransport.recv(socket, 0, 2_000)
                 assert JSON.decode!(hello)["op"] == "hello"

                 for message <- [
                       %{
                         "op" => "welcome",
                         "env" => "test",
                         "spec" => AtlasTui.Protocol.version(),
                         "surface" => "console"
                       },
                       %{
                         "op" => "page",
                         "path" => "/",
                         "title" => "Fixture",
                         "blocks" => [],
                         "reason" => "open"
                       }
                     ] do
                   AtlasTransport.send(socket, [JSON.encode!(message), "\n"])
                 end

                 assert {:error, :closed} = AtlasTransport.recv(socket, 0, 2_000)
                 true
               end
             )
  end
end
