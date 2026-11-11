defmodule AtlasTui.WorkerOutputConnectionTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.{Console, Protocol, WorkerOutputConnection}

  @moduletag timeout: 20_000

  setup do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :line,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    %{
      listener: listener,
      settings: %{"control" => %{"host" => "127.0.0.1", "port" => port}}
    }
  end

  test "uses the actual Console hello on a distinct Control socket and drains compatibility",
       context do
    {ordinary, ordinary_server} = ordinary_connection(context)
    {pid, socket} = start_connection(context)

    assert {:ok, ordinary_peer} = :inet.peername(ordinary_server)
    assert {:ok, output_peer} = :inet.peername(socket)
    refute ordinary_peer == output_peer

    assert_rejected(pid, inspect_request(), :not_ready)
    send_message(socket, page())
    refute_receive {:worker_output_connection, ^pid, :ready}, 30

    send_message(socket, welcome())
    send_message(socket, %{"op" => "hint", "path" => "/"})
    refute_receive {:worker_output_connection, ^pid, :ready}, 30
    assert_rejected(pid, inspect_request(), :not_ready)

    send_message(socket, page())
    assert_receive {:worker_output_connection, ^pid, :ready}, 1_000
    # No boot, open, subscribe, refresh, or poll is implicit in becoming ready.
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)

    assert :ok = WorkerOutputConnection.stop(pid)
    assert_receive {:worker_output_connection, ^pid, {:closed, :stopped}}
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)

    # Closing the viewer leaves the independently owned Console connection alive.
    send_message(ordinary_server, page())
    assert read_message(ordinary) == page()
  end

  for {field, value} <- [
        {"env", "other-environment"},
        {"spec", "incompatible-version"},
        {"surface", "other-surface"},
        {"surface", nil}
      ] do
    test "rejects incompatible welcome #{field}=#{inspect(value)}", context do
      {pid, socket} = start_connection(context)
      send_message(socket, Map.put(welcome(), unquote(field), unquote(value)))

      assert_receive {:worker_output_connection, ^pid, {:closed, :incompatible_welcome}}, 1_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      refute_receive {:worker_output_connection, ^pid, :ready}
      assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
    end
  end

  test "admits inspect and all generated output operations without changing their wire maps",
       context do
    {pid, socket} = ready_connection(context)

    requests = [
      inspect_request(),
      Wire.request(:worker_output_subscribe, %{
        "id" => "subscribe",
        "execution" => execution(),
        "cursor" => "accepted-output-cursor"
      }),
      next_request(),
      Wire.request(:worker_output_unsubscribe, %{"id" => "unsubscribe", "subscription" => "sub-1"})
    ]

    for request <- requests do
      assert :ok = WorkerOutputConnection.send_request(pid, request)
      assert read_message(socket) == request
      name = Enum.find(Wire.wires(), &(&1.request.select["op"] == request["op"])).name

      reply =
        Wire.reply(name, :error, %{
          "id" => request["id"],
          "error" => %{
            "code" => "output_unavailable",
            "message" => "Not retained",
            "retryable" => false
          }
        })

      send_message(socket, reply)
      assert_receive {:worker_output_connection, ^pid, {:message, ^reply}}, 1_000
      assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)
    end
  end

  test "forwards exactly one correlated reply and suppresses page, hint, stale and duplicate frames",
       context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    reply = next_result(request)

    # Even a well-typed output reply cannot produce an unsolicited owner message.
    send_message(socket, reply)
    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 30

    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert read_message(socket) == request

    wrong_operation =
      Wire.reply(:worker_output_unsubscribe, :result, %{
        "id" => request["id"],
        "subscription" => "sub-1"
      })

    send_messages(socket, [
      Map.put(page(), "id", request["id"]),
      %{"op" => "hint", "id" => request["id"]},
      Map.put(reply, "id", "old-request"),
      wrong_operation
    ])

    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 30
    assert_rejected(pid, next_request("new-request"), :busy)

    send_message(socket, reply)
    assert_receive {:worker_output_connection, ^pid, {:message, ^reply}}, 1_000
    send_messages(socket, List.duplicate(reply, 100))
    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 60
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)

    next = next_request("new-request")
    assert :ok = WorkerOutputConnection.send_request(pid, next)
    assert read_message(socket) == next
    send_message(socket, reply)
    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 30
    next_reply = next_result(next)
    send_message(socket, next_reply)
    assert_receive {:worker_output_connection, ^pid, {:message, ^next_reply}}, 1_000
  end

  test "busy sends are rejected rather than retained for later transmission", context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert read_message(socket) == request

    for index <- 1..256 do
      assert_rejected(pid, next_request("rejected-#{index}"), :busy)
    end

    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)
    reply = next_result(request)
    send_message(socket, reply)
    assert_receive {:worker_output_connection, ^pid, {:message, ^reply}}, 1_000
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 60)
    assert {:message_queue_len, 0} = Process.info(pid, :message_queue_len)

    accepted = next_request("explicitly-admitted")
    assert :ok = WorkerOutputConnection.send_request(pid, accepted)
    assert read_message(socket) == accepted
  end

  test "leaves typed and semantic reply validation to the reducer", context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert read_message(socket) == request

    invalid_reply =
      request
      |> next_result()
      |> Map.put("version", "wrong-version")
      |> Map.put("subscription", "wrong-subscription")
      |> Map.put("events", "not-an-event-list")

    send_message(socket, invalid_reply)
    assert_receive {:worker_output_connection, ^pid, {:message, ^invalid_reply}}, 1_000
    send_message(socket, invalid_reply)
    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 30
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)
  end

  test "rejects non-output commands and invalid generated requests without sending traffic",
       context do
    {pid, socket} = ready_connection(context)

    requests = [
      %{"op" => "worker_stop", "id" => "stop"},
      Protocol.request(:open, %{"to" => "/"}),
      Wire.request(:worker_submit, %{
        "id" => "guidance",
        "execution" => execution(),
        "guidance" => %{"client_key" => "key", "body" => "literal", "cause" => "test"}
      }),
      Map.put(next_request(), "version", "wrong-version"),
      Map.put(next_request(), "id", ""),
      Map.delete(next_request(), "cursor"),
      nil
    ]

    for request <- requests, do: assert_rejected(pid, request, :invalid_request)

    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)
    assert :ok = WorkerOutputConnection.send_request(pid, next_request())
    assert read_message(socket) == next_request()
  end

  test "accepts approved 64 KiB event batches with envelope and fragmented TCP delivery",
       context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert read_message(socket) == request

    events =
      for sequence <- 1..4,
          do: %{"sequence" => sequence, "kind" => "text", "text" => String.duplicate("x", 16_000)}

    assert byte_size(JSON.encode!(events)) <= 65_536
    reply = next_result(request, events)
    bytes = JSON.encode!(reply) <> "\n"
    <<first::binary-size(17_000), second::binary-size(17_000), rest::binary>> = bytes
    assert :ok = :gen_tcp.send(socket, first)
    assert :ok = :gen_tcp.send(socket, second)
    refute_receive {:worker_output_connection, ^pid, {:message, _}}, 30
    assert :ok = :gen_tcp.send(socket, rest)
    assert_receive {:worker_output_connection, ^pid, {:message, ^reply}}, 1_000
  end

  test "bounds incomplete incoming lines before JSON decoding", context do
    {pid, socket} = ready_connection(context)
    # There is deliberately no newline: packet_size must bound partial frames too.
    assert :ok = :gen_tcp.send(socket, String.duplicate("x", 262_145))
    assert_receive {:worker_output_connection, ^pid, {:closed, _reason}}, 1_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    refute_receive {:worker_output_connection, ^pid, {:message, _}}
  end

  test "rejects oversized outgoing requests without consuming the request slot", context do
    {pid, socket} = ready_connection(context)
    oversized = Map.put(next_request(), "cursor", String.duplicate("x", 262_144))
    assert_rejected(pid, oversized, :request_too_large)
    assert {:error, :timeout} = :gen_tcp.recv(socket, 0, 30)
    assert :ok = WorkerOutputConnection.send_request(pid, next_request())
    assert read_message(socket) == next_request()
  end

  for phase <- [:welcome, :compatibility] do
    test "times out an incomplete #{phase} handshake and never reconnects", context do
      {pid, socket} = start_connection(context)
      if unquote(phase) == :compatibility, do: send_message(socket, welcome())
      send_message(socket, %{"op" => "hint"})
      assert_receive {:worker_output_connection, ^pid, {:closed, :handshake_timeout}}, 6_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      refute_receive {:worker_output_connection, ^pid, :ready}
      assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
    end
  end

  test "times out an outstanding request despite irrelevant frames or rejected sends", context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert read_message(socket) == request
    send_messages(socket, List.duplicate(page(), 100))
    assert_rejected(pid, next_request("busy"), :busy)

    assert_receive {:worker_output_connection, ^pid, {:closed, :request_timeout}}, 6_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    assert :ok = WorkerOutputConnection.send_request(pid, next_request())
    refute_receive {:worker_output_connection, ^pid, {:message, _}}
    assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
  end

  for outstanding <- [false, true] do
    test "reports a disconnect with outstanding=#{outstanding} without retrying", context do
      {pid, socket} = ready_connection(context)
      monitor = Process.monitor(pid)

      if unquote(outstanding) do
        assert :ok = WorkerOutputConnection.send_request(pid, next_request())
        assert read_message(socket) == next_request()
      end

      :gen_tcp.close(socket)
      assert_receive {:worker_output_connection, ^pid, {:closed, :closed}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      refute_receive {:worker_output_connection, ^pid, _}
      assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
    end
  end

  test "reports a refused Control connection without fallback or reconnect", context do
    :gen_tcp.close(context.listener)
    {:ok, pid} = WorkerOutputConnection.start(self(), "test", context.settings)
    monitor = Process.monitor(pid)
    assert_receive {:worker_output_connection, ^pid, {:closed, {:connect, :econnrefused}}}, 3_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 1_000
    refute_receive {:worker_output_connection, ^pid, :ready}
  end

  for phase <- [:handshake, :ready, :request] do
    test "owner death closes the socket during #{phase}", context do
      parent = self()
      owner = spawn(fn -> forward_messages(parent) end)
      on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
      {pid, socket} = start_connection(context, owner)
      monitor = Process.monitor(pid)

      if unquote(phase) != :handshake do
        send_messages(socket, [welcome(), page()])
        assert_receive {:worker_output_connection, ^pid, :ready}, 1_000
      end

      if unquote(phase) == :request do
        assert :ok = WorkerOutputConnection.send_request(pid, next_request())
        assert read_message(socket) == next_request()
      end

      Process.exit(owner, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      # recv sees EOF, not an unsubscribe, interrupt, or worker-stop frame.
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
    end
  end

  for outstanding <- [false, true] do
    test "explicit stop with outstanding=#{outstanding} sends no lifecycle or unsubscribe traffic",
         context do
      {pid, socket} = ready_connection(context)
      monitor = Process.monitor(pid)

      if unquote(outstanding) do
        assert :ok = WorkerOutputConnection.send_request(pid, next_request())
        assert read_message(socket) == next_request()
      end

      assert :ok = WorkerOutputConnection.stop(pid)
      assert_receive {:worker_output_connection, ^pid, {:closed, :stopped}}, 1_000
      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 1_000
      assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
      assert :ok = WorkerOutputConnection.stop(pid)
      refute_receive {:worker_output_connection, ^pid, _}
      assert {:error, :timeout} = :gen_tcp.accept(context.listener, 30)
    end
  end

  test "stop also closes an incomplete handshake without sending commands", context do
    {pid, socket} = start_connection(context)
    assert :ok = WorkerOutputConnection.stop(pid)
    assert_receive {:worker_output_connection, ^pid, {:closed, :stopped}}, 1_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    refute_receive {:worker_output_connection, ^pid, :ready}
  end

  test "malformed JSON closes once instead of forwarding or recovering silently", context do
    {pid, socket} = ready_connection(context)
    assert :ok = :gen_tcp.send(socket, "not-json\n")
    assert_receive {:worker_output_connection, ^pid, {:closed, :invalid_frame}}, 1_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
    refute_receive {:worker_output_connection, ^pid, _}
  end

  test "request and stop APIs return without waiting for a suspended transport", context do
    {pid, socket} = ready_connection(context)
    request = next_request()
    :ok = :sys.suspend(pid)

    caller =
      Task.async(fn ->
        {WorkerOutputConnection.send_request(pid, request), WorkerOutputConnection.stop(pid)}
      end)

    try do
      assert Task.await(caller, 1_000) == {:ok, :ok}
    after
      :sys.resume(pid)
    end

    assert read_message(socket) == request
    assert_receive {:worker_output_connection, ^pid, {:closed, :stopped}}, 1_000
    assert {:error, :closed} = :gen_tcp.recv(socket, 0, 1_000)
  end

  defp assert_rejected(pid, request, reason) do
    id = if is_map(request), do: request["id"], else: nil
    assert :ok = WorkerOutputConnection.send_request(pid, request)
    assert_receive {:worker_output_connection, ^pid, {:rejected, ^id, ^reason}}, 1_000
  end

  defp start_connection(context, owner \\ self()) do
    {:ok, pid} = WorkerOutputConnection.start(owner, "test", context.settings)
    on_exit(fn -> WorkerOutputConnection.stop(pid) end)
    {:ok, socket} = :gen_tcp.accept(context.listener, 3_000)
    assert read_message(socket) == Console.hello(%{env: "test"})
    {pid, socket}
  end

  defp ready_connection(context) do
    {pid, socket} = start_connection(context)
    send_messages(socket, [welcome(), page()])
    assert_receive {:worker_output_connection, ^pid, :ready}, 1_000
    {pid, socket}
  end

  defp ordinary_connection(context) do
    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", context.settings["control"]["port"], [
        :binary,
        packet: :line,
        active: false
      ])

    {:ok, server} = :gen_tcp.accept(context.listener, 1_000)
    send_message(socket, Console.hello(%{env: "test"}))
    assert read_message(server) == Console.hello(%{env: "test"})
    send_messages(server, [welcome(), page()])
    assert read_message(socket) == welcome()
    assert read_message(socket) == page()
    {socket, server}
  end

  defp read_message(socket) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 1_000)
    JSON.decode!(bytes)
  end

  defp send_message(socket, message), do: send_messages(socket, [message])

  defp send_messages(socket, messages) do
    assert :ok = :gen_tcp.send(socket, Enum.map(messages, &[JSON.encode!(&1), "\n"]))
  end

  defp welcome do
    %{"op" => "welcome", "env" => "test", "spec" => Protocol.version(), "surface" => "console"}
  end

  defp page do
    %{
      "op" => "page",
      "path" => "/",
      "title" => "Compatibility",
      "blocks" => [],
      "reason" => "open"
    }
  end

  defp execution do
    %{
      "worker" => %{"environment" => "test", "machine" => "machine-1", "worker" => "worker-1"},
      "turn" => "turn-1",
      "attempt" => "attempt-1"
    }
  end

  defp inspect_request,
    do: Wire.request(:worker_inspect, %{"id" => "inspect", "execution" => execution()})

  defp next_request(id \\ "next") do
    Wire.request(:worker_output_next, %{
      "id" => id,
      "subscription" => "sub-1",
      "cursor" => "cursor-0"
    })
  end

  defp next_result(request, events \\ []) do
    Wire.reply(:worker_output_next, :result, %{
      "id" => request["id"],
      "subscription" => "sub-1",
      "stream" => %{
        "execution" => execution(),
        "epoch" => "epoch-1",
        "first_sequence" => 1,
        "watermark" => length(events),
        "ended" => false
      },
      "events" => events,
      "cursor" => "cursor-1",
      "more" => false
    })
  end

  defp forward_messages(parent) do
    receive do
      message ->
        send(parent, message)
        forward_messages(parent)
    end
  end
end
