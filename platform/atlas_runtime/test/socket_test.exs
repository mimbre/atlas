defmodule AtlasRuntime.Entrypoints.SocketTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Entrypoints.Socket
  alias AtlasRuntime.TestHost

  test "socket owns framing, rejects noncommands and requests shutdown after replying" do
    # A Unix socket path is short (104 bytes on macOS); TestHost picks a short enough temp.
    dir = TestHost.short_dir!("ars", "/runtime.sock")
    acceptor = Socket.start(dir, self())
    path = Path.join(dir, "runtime.sock")

    try do
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      :ok = :gen_tcp.send(socket, "{\"command\":\"handoff\"}\n")
      assert_receive {:"$gen_call", from, %{"command" => "handoff"}}
      GenServer.reply(from, {%{handoff: "recorded"}, false})
      assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
      assert JSON.decode!(reply) == %{"handoff" => "recorded"}
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
      # The Service may ask for shutdown with its reply; the socket sends the reply first.
      :ok = :gen_tcp.send(socket, "{\"command\":\"question\"}\n")
      assert_receive {:"$gen_call", from, %{"command" => "question"}}
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

  test "runtime.sock refuses the work commands and the operations, and forwards guidance" do
    dir = TestHost.short_dir!("ars", "/runtime.sock")
    acceptor = Socket.start(dir, self())
    path = Path.join(dir, "runtime.sock")

    send_line = fn request ->
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      :ok = :gen_tcp.send(socket, JSON.encode!(request) <> "\n")
      socket
    end

    try do
      for {command, place} <- [
            {"start", "backend.sock"},
            {"continue", "backend.sock"},
            {"stop", "backend.sock"},
            {"kill", "backend.sock"},
            {"status", "backend.sock"},
            {"output", "backend.sock"},
            {"turns", "backend.sock (GET /v1/turns)"},
            # The operations contract (S2): runtime.sock keeps only guidance (Q10).
            {"service-status", "backend.sock (GET /v1/runtime)"},
            {"service-stop", "backend.sock (POST /v1/control/stop)"},
            {"preferences", "backend.sock (GET /v1/policy"},
            {"release", "backend.sock (POST /v1/slots/{slot}/release)"}
          ] do
        socket = send_line.(%{"command" => command, "worker_id" => "w1"})
        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
        assert %{"command_error" => error} = JSON.decode!(reply)
        assert error =~ "#{command} is not served on runtime.sock"
        assert error =~ place
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        # Refused before the Service is asked: it never sees the command.
        refute_received {:"$gen_call", _, _}
      end

      # Each operation also as the CLI sent it before S2.
      for request <- [
            %{"command" => "service-status"},
            %{"command" => "service-stop"},
            %{"command" => "preferences", "reenable" => "claude"},
            %{"command" => "release", "worker_id" => "w1"}
          ] do
        socket = send_line.(request)
        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
        assert %{"command_error" => error} = JSON.decode!(reply)

        assert error =~
                 "is not served on runtime.sock: use the operations contract on backend.sock"

        refute_received {:"$gen_call", _, _}
      end

      target = %{"worker_id" => "w1", "turn_id" => "t"}
      question = Map.put(target, "question_id", "q")

      # Every guidance command (Q10) still reaches the Service.
      for request <- [
            Map.put(question, "command", "question"),
            Map.merge(question, %{"command" => "answer", "answers" => %{"Which?" => "A"}}),
            Map.put(target, "command", "handoff"),
            Map.merge(target, %{
              "command" => "submit-handoff",
              "handoff" => %{"kind" => "completion"}
            }),
            Map.put(question, "command", "peer-question"),
            Map.merge(question, %{
              "command" => "route-peer-question",
              "peer_worker_id" => "w2",
              "peer_source_turn_id" => "p"
            }),
            Map.merge(question, %{"command" => "bind-peer-reply", "response_turn_id" => "r"})
          ] do
        socket = send_line.(request)
        assert_receive {:"$gen_call", from, ^request}
        GenServer.reply(from, {%{forwarded: request["command"]}, false})
        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
        assert JSON.decode!(reply) == %{"forwarded" => request["command"]}
      end
    after
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end
  end

  test "runtime.sock answers the journal reads and refuses every other runtime.read/1 operation" do
    dir = TestHost.short_dir!("ars", "/runtime.sock")
    acceptor = Socket.start(dir, self())
    path = Path.join(dir, "runtime.sock")

    request = fn line ->
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      :ok = :gen_tcp.send(socket, line <> "\n")
      socket
    end

    try do
      socket = request.(~s({"api":"runtime.read/1","op":"events","limit":2}))
      # A read, never a command.
      assert_receive {:"$gen_call", from, {:read, "events", %{"limit" => 2}}}
      GenServer.reply(from, %{"api" => "runtime.read/1", "op" => "events", "cursor" => "e:2"})
      assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)

      assert JSON.decode!(reply) == %{
               "api" => "runtime.read/1",
               "op" => "events",
               "cursor" => "e:2"
             }

      for line <- [
            ~s({"api":"runtime.read/1","op":"turns"}),
            ~s({"api":"runtime.read/1","op":"turn","turn_id":"turn-0000000000000001"}),
            ~s({"api":"runtime.read/1","op":"workers"}),
            ~s({"api":"runtime.read/1","op":"output","turn_id":"turn-0000000000000001"}),
            ~s({"api":"runtime.read/1"})
          ] do
        socket = request.(line)
        assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)

        assert %{"error" => %{"code" => "not_journal", "message" => message}} =
                 JSON.decode!(reply)

        assert message =~ "events and follow"
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        refute_received {:"$gen_call", _, _}
      end

      # A journal request is validated before the Service sees it.
      socket = request.(~s({"api":"runtime.read/1","op":"events","limit":0}))
      assert {:ok, reply} = :gen_tcp.recv(socket, 0, 1_000)
      assert %{"error" => %{"code" => "invalid_request"}} = JSON.decode!(reply)
      refute_received {:"$gen_call", _, _}
    after
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
    end
  end

  describe "streams" do
    setup do
      # Short: socket paths must fit a Unix socket name.
      dir =
        Path.join(
          System.tmp_dir!(),
          "ars-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    defp connect(path) do
      {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line])
      socket
    end

    defp lines(socket, count), do: for(_ <- 1..count, do: line(socket))

    defp line(socket) do
      assert {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
      JSON.decode!(line)
    end

    defp page(events, cursor, more \\ false),
      do: %{
        "api" => "runtime.read/1",
        "op" => "events",
        "events" => events,
        "cursor" => cursor,
        "more" => more,
        "recording_started_at" => "2026-11-10T00:00:00Z"
      }

    # runtime.sock's follow stream against this test process as the service; `timing` in
    # milliseconds.
    defp follow(dir, timing, fields \\ %{}) do
      acceptor = Socket.start(dir, self(), timing)

      on_exit(fn ->
        Process.unlink(acceptor)
        Process.exit(acceptor, :kill)
      end)

      socket = connect(Path.join(dir, "runtime.sock"))
      request = Map.merge(%{"api" => "runtime.read/1", "op" => "follow"}, fields)
      :ok = :gen_tcp.send(socket, JSON.encode!(request) <> "\n")
      socket
    end

    defp read_call(cursor) do
      assert_receive {:"$gen_call", from,
                      {:read, "events", %{"cursor" => ^cursor, "limit" => 100}}},
                     5_000

      from
    end

    test "a stream handler owns the connection after the request line", %{dir: dir} do
      path = Path.join(dir, "runtime.sock")

      acceptor =
        Socket.serve(path, self(), fn bytes ->
          {:stream,
           fn socket ->
             :gen_tcp.send(socket, bytes)
             :gen_tcp.send(socket, "{\"second\":true}\n")
             :gen_tcp.close(socket)
           end}
        end)

      try do
        socket = connect(path)
        :ok = :gen_tcp.send(socket, "{\"first\":true}\n")
        assert lines(socket, 2) == [%{"first" => true}, %{"second" => true}]
        assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
        refute_received :shutdown
      after
        Process.unlink(acceptor)
        Process.exit(acceptor, :kill)
      end
    end

    test "signals coalesce into one read; pages continue while more; a slow service ends the stream",
         %{dir: dir} do
      socket = follow(dir, [heartbeat: 60_000, service: 100], %{"cursor" => "e:0"})
      assert_receive {:"$gen_call", from, {:follow, follower, "e:0"}}, 5_000
      GenServer.reply(from, page([%{"sequence" => 1}], "e:1", true))
      # `more`: the follower reads on by itself before it waits.
      GenServer.reply(read_call("e:1"), page([%{"sequence" => 2}], "e:2"))

      assert [
               %{
                 "type" => "page",
                 "op" => "follow",
                 "events" => [%{"sequence" => 1}],
                 "more" => true
               },
               %{"type" => "page", "events" => [%{"sequence" => 2}], "cursor" => "e:2"}
             ] = lines(socket, 2)

      for sequence <- 3..5, do: send(follower, {:events_appended, sequence})
      from = read_call("e:2")
      # Signals that arrive while a read is pending are drained into the next single read.
      for sequence <- 6..8, do: send(follower, {:events_appended, sequence})
      GenServer.reply(from, page([%{"sequence" => 3}], "e:3"))
      assert [%{"events" => [%{"sequence" => 3}]}] = lines(socket, 1)
      GenServer.reply(read_call("e:3"), page([], "e:3"))
      refute_received {:"$gen_call", _, _}

      # Unanswered beyond the service timeout: `end`, then EOF.
      send(follower, {:events_appended, 9})
      read_call("e:3")

      assert line(socket) == %{
               "api" => "runtime.read/1",
               "op" => "follow",
               "type" => "end",
               "reason" => "service_unresponsive"
             }

      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    end

    test "heartbeats come only after the service answered; input after the request closes",
         %{dir: dir} do
      socket = follow(dir, heartbeat: 10, service: 5_000)
      assert_receive {:"$gen_call", from, {:follow, follower, nil}}, 5_000
      ref = Process.monitor(follower)
      GenServer.reply(from, page([], "e:4"))
      assert [%{"type" => "page"}] = lines(socket, 1)

      GenServer.reply(read_call("e:4"), page([], "e:4"))

      assert line(socket) == %{
               "api" => "runtime.read/1",
               "op" => "follow",
               "type" => "heartbeat",
               "cursor" => "e:4"
             }

      # A tick that finds events sends them as a page instead.
      GenServer.reply(read_call("e:4"), page([%{"sequence" => 5}], "e:5"))
      assert [%{"type" => "page", "cursor" => "e:5"}] = lines(socket, 1)

      from = read_call("e:5")
      :ok = :gen_tcp.send(socket, "{}\n")
      GenServer.reply(from, page([], "e:5"))
      assert %{"type" => "heartbeat"} = line(socket)
      assert_receive {:DOWN, ^ref, :process, ^follower, _}, 5_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    end

    test "a refused follow is one error line; a stopping service ends the stream",
         %{dir: dir} do
      refused = follow(dir, [], %{"cursor" => "e:9"})
      assert_receive {:"$gen_call", from, {:follow, _, "e:9"}}, 5_000
      GenServer.reply(from, AtlasRuntime.Inspection.Reads.error("invalid_cursor"))
      assert %{"error" => %{"code" => "invalid_cursor"}} = line(refused)
      assert {:error, :closed} = :gen_tcp.recv(refused, 0, 5_000)

      socket = connect(Path.join(dir, "runtime.sock"))
      :ok = :gen_tcp.send(socket, ~s({"api":"runtime.read/1","op":"follow"}\n))
      assert_receive {:"$gen_call", from, {:follow, follower, nil}}, 5_000
      GenServer.reply(from, page([], "e:0"))
      assert [%{"type" => "page"}] = lines(socket, 1)
      send(follower, :service_stopping)
      assert %{"type" => "end", "reason" => "service_stopping"} = line(socket)
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 5_000)
    end
  end
end
