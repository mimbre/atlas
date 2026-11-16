defmodule AtlasAgent.ProtocolTest do
  use ExUnit.Case, async: false
  alias AtlasAgent.{Client, Protocol}

  setup do
    previous = System.get_env("ATLAS_AS")
    System.delete_env("ATLAS_AS")

    on_exit(fn ->
      if previous, do: System.put_env("ATLAS_AS", previous), else: System.delete_env("ATLAS_AS")
    end)

    :ok
  end

  test "hello preserves version, environment, category and actor isolation" do
    version = AtlasBFFContract.Contract.__schema__().version

    assert Client.hello("prod", "agent") == %{
             "op" => "hello",
             "env" => "prod",
             "client" => "agent",
             "spec" => version
           }

    System.put_env("ATLAS_AS", "worker-α")
    assert Client.hello("test", "agent")["as"] == "worker-α"

    assert Client.hello("test", "migration") == %{
             "op" => "hello",
             "env" => "test",
             "client" => "migration",
             "spec" => version
           }

    System.put_env("ATLAS_AS", "")
    refute Map.has_key?(Client.hello("test", "agent"), "as")
  end

  test "independent TCP transcript preserves requests and existing turn reply adapter" do
    System.put_env("ATLAS_AS", "worker-α")
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false, reuseaddr: true])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    version = AtlasBFFContract.Contract.__schema__().version

    peer =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          assert receive_line(socket) == %{
                   "op" => "hello",
                   "env" => "test",
                   "client" => "agent",
                   "as" => "worker-α",
                   "spec" => version
                 }

          send_line(socket, %{"op" => "welcome", "env" => "test", "spec" => version})
          send_line(socket, %{"op" => "page", "reason" => "open", "path" => "/", "blocks" => []})
          assert receive_line(socket) == %{"op" => "turn"}
          send_line(socket, %{"op" => "notice", "tone" => "pending", "text" => "wait"})
          send_line(socket, %{"op" => "page", "reason" => "hint"})
          send_line(socket, %{"op" => "turn", "key" => "T-1", "on" => "X-1"})

          for reply <- [
                %{"op" => "page", "reason" => "stored"},
                %{"op" => "turn", "error" => "stale turn"},
                %{"op" => "page", "reason" => "refused"}
              ] do
            assert receive_line(socket) == %{
                     "op" => "turn_end",
                     "key" => "T-1",
                     "outcome" => "Done α\nnext"
                   }

            send_line(socket, %{"op" => "notice", "tone" => "ok", "text" => "pending storage"})
            send_line(socket, reply)
          end

          assert :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}
        after
          :gen_tcp.close(socket)
        end
      end)

    {:ok, client} =
      Client.connect("test", %{"control" => %{"host" => "127.0.0.1", "port" => port}})

    assert Client.turn(client) == {:ok, %{"op" => "turn", "key" => "T-1", "on" => "X-1"}}
    message = Protocol.message(:turn_end, :turn_end, key: "T-1", outcome: "Done α\nnext")
    assert {:ok, %{"op" => "page", "reason" => "stored"}} = Client.turn(client, message)
    assert Client.turn(client, message) == {:error, "stale turn"}
    assert Client.turn(client, message) == {:error, "Facts refused the outcome"}
    Client.close(client)
    Task.await(peer)
  end

  test "CLI turn end preserves literal input, JSON/text output, error status and one write" do
    previous = System.get_env("ATLAS_ENV_FILE")

    file =
      Path.join(System.tmp_dir!(), "atlas-protocol-#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(file)

      if previous,
        do: System.put_env("ATLAS_ENV_FILE", previous),
        else: System.delete_env("ATLAS_ENV_FILE")
    end)

    for {reply, json?, status, expected} <- [
          {%{"op" => "page", "reason" => "stored"}, true, 0,
           %{"turn" => "T-1", "outcome" => "-"}},
          {%{"op" => "page", "reason" => "stored"}, false, 0, "Outcome stored for T-1: -\n"},
          {%{"op" => "turn", "error" => "not the owner"}, true, 2, %{"error" => "not the owner"}},
          {%{"op" => "page", "reason" => "refused"}, true, 2,
           %{"error" => "Facts refused the outcome"}}
        ] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
      {:ok, {_, port}} = :inet.sockname(listener)

      File.write!(
        file,
        JSON.encode!(%{"env" => "test", "control" => %{"host" => "127.0.0.1", "port" => port}})
      )

      System.put_env("ATLAS_ENV_FILE", file)

      peer =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)

          try do
            assert receive_line(socket)["op"] == "hello"
            send_line(socket, %{"op" => "welcome"})
            send_line(socket, %{"op" => "page", "reason" => "open"})
            assert receive_line(socket) == %{"op" => "turn"}
            send_line(socket, %{"op" => "turn", "key" => "T-1", "on" => "X-1"})
            assert receive_line(socket) == %{"op" => "turn_end", "key" => "T-1", "outcome" => "-"}
            send_line(socket, reply)
            assert :gen_tcp.recv(socket, 0, 2_000) == {:error, :closed}
          after
            :gen_tcp.close(socket)
            :gen_tcp.close(listener)
          end
        end)

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          stdout =
            ExUnit.CaptureIO.capture_io(fn ->
              args = ["turn", "end", "-", "--env", "test"] ++ if(json?, do: ["--json"], else: [])
              assert AtlasAgent.CLI.main(args) == status
            end)

          if json?, do: assert(JSON.decode!(stdout) == expected), else: assert(stdout == expected)
        end)

      if status == 0, do: assert(stderr == ""), else: assert(stderr =~ "atlas: ")
      Task.await(peer)
    end
  end

  test "encoding leaves semantic outcome checks to Control" do
    assert Protocol.message(:turn_end, :turn_end, key: "stale", outcome: "  ") ==
             %{"op" => "turn_end", "key" => "stale", "outcome" => "  "}

    assert_raise ArgumentError, fn ->
      Protocol.message(:turn_end, :turn_end, key: "T-1", outcome: 3)
    end
  end

  defp receive_line(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    JSON.decode!(line)
  end

  defp send_line(socket, message) do
    message =
      case message["op"] do
        "page" ->
          Map.merge(%{"path" => "/", "title" => "Test", "blocks" => [], "markup" => []}, message)

        "welcome" ->
          Map.merge(%{"env" => "test", "spec" => AtlasAgent.Protocol.version()}, message)

        _ ->
          message
      end

    :gen_tcp.send(socket, [JSON.encode!(message), "\n"])
  end
end
