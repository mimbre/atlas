defmodule AtlasAgent.TransportTest do
  use ExUnit.Case, async: false
  alias AtlasAgent.{Client, Protocol}

  # The peer writes literal protocol maps, independently of the generated encoder.
  defp page(reason),
    do: %{
      "op" => "page",
      "reason" => reason,
      "path" => "/k/sample/X",
      "title" => "Sample",
      "blocks" => [],
      "markup" => [],
      "count" => "1 item",
      "back" => nil,
      "position" => nil
    }

  defp notice, do: %{"op" => "notice", "tone" => "ok", "text" => "not an acknowledgement"}
  defp send_line(socket, map), do: :gen_tcp.send(socket, [JSON.encode!(map), "\n"])

  defp receive_line(socket) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    JSON.decode!(line)
  end

  defp peer(script, run) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: :line, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)

        try do
          script.(socket)
        after
          :gen_tcp.close(socket)
        end
      end)

    try do
      run.(port)
      Task.await(task, 3_000)
    after
      :gen_tcp.close(listener)
    end
  end

  defp raw(port) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, packet: :line, active: false])
    %Client{socket: socket, env: "test"}
  end

  test "exact fact reads retain values and relation keys and report failures" do
    data = %{
      "fact" => %{"key" => "X", "values" => %{"ready" => true}, "links" => %{"replaces" => ["Y"]}}
    }

    peer(
      fn socket ->
        assert receive_line(socket) == %{"op" => "facts_read", "kind" => "_", "key" => "X"}
        send_line(socket, %{"op" => "facts_read", "data" => data})
        assert receive_line(socket) == %{"op" => "facts_read", "kind" => "unknown"}
        send_line(socket, %{"op" => "facts_read", "error" => "unknown kind"})
      end,
      fn port ->
        client = raw(port)
        assert Client.facts(client, "_", "X") == {:ok, data}
        assert Client.facts(client, "unknown", nil) == {:error, "unknown kind"}
        Client.close(client)
      end
    )
  end

  test "open and submit preserve envelope, cause, refusal extraction and unsolicited traffic" do
    peer(
      fn socket ->
        assert receive_line(socket) == %{"op" => "open", "to" => "/arbitrary"}
        send_line(socket, notice())
        send_line(socket, page("hint"))
        send_line(socket, page("reconcile"))
        send_line(socket, page("open"))

        for reason <- ["stored", "refused"] do
          assert receive_line(socket) == %{
                   "op" => "submit",
                   "endpoint" => "update",
                   "params" => %{"key" => "X"},
                   "values" => %{"text" => "α\n"},
                   "cause" => "why"
                 }

          send_line(socket, notice())
          send_line(socket, page("hint"))
          send_line(socket, page("reconcile"))
          send_line(socket, Map.put(page(reason), "refused", ["not permitted"]))
        end

        assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
      end,
      fn port ->
        client = raw(port)
        assert {:ok, %{"reason" => "open"}} = Client.open(client, "/arbitrary")
        to = %{"endpoint" => "update", "params" => %{"key" => "X"}}

        assert {:stored, %{"reason" => "stored"}} =
                 Client.submit(client, to, %{"text" => "α\n"}, "why")

        assert Client.submit(client, to, %{"text" => "α\n"}, "why") ==
                 {:refused, ["not permitted"]}

        Client.close(client)
      end
    )
  end

  test "bye, malformed JSON, nonobject JSON and malformed required replies close without replay" do
    for operation <- [:open, :submit, :turn, :turn_end],
        failure <- [:bye, :malformed, :nonobject, :missing, :eof] do
      request =
        case operation do
          :open -> %{"op" => "open", "to" => "/"}
          :submit -> %{"op" => "submit", "endpoint" => "update", "params" => %{}, "values" => %{}}
          :turn -> %{"op" => "turn"}
          :turn_end -> %{"op" => "turn_end", "key" => "T", "outcome" => "done"}
        end

      peer(
        fn socket ->
          assert receive_line(socket) == request

          case failure do
            :bye ->
              send_line(socket, %{"op" => "bye", "text" => "go away"})

            :malformed ->
              :gen_tcp.send(socket, "{bad\n")

            :nonobject ->
              :gen_tcp.send(socket, "[]\n")

            :missing ->
              send_line(
                socket,
                if(operation == :turn,
                  do: %{"op" => "turn"},
                  else: %{
                    "op" => "page",
                    "reason" => if(operation == :open, do: "open", else: "stored")
                  }
                )
              )

            :eof ->
              :gen_tcp.shutdown(socket, :write)
          end

          assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
        end,
        fn port ->
          client = raw(port)
          assert {:error, why} = Client.exchange(client, operation, request, 300)
          assert is_binary(why)
          if failure == :bye, do: assert(why == "go away")
          assert :inet.sockname(client.socket) == {:error, :einval}
        end
      )
    end
  end

  test "hints and notices cannot extend total deadline and timed out submit is never resent" do
    peer(
      fn socket ->
        assert receive_line(socket) == %{
                 "op" => "submit",
                 "endpoint" => "create",
                 "params" => %{},
                 "values" => %{}
               }

        # A small timed transcript, no load generator or repeated requests.
        for _ <- 1..12 do
          send_line(socket, notice())
          send_line(socket, page("hint"))
          send_line(socket, page("reconcile"))
          Process.sleep(10)
        end

        assert :gen_tcp.recv(socket, 0, 0) == {:error, :closed}
      end,
      fn port ->
        client = raw(port)
        start = System.monotonic_time(:millisecond)

        assert {:error, why} =
                 Client.exchange(
                   client,
                   :submit,
                   Protocol.request(:submit, endpoint: "create", params: %{}, values: %{}),
                   60
                 )

        assert why =~ "did not answer in time"
        assert System.monotonic_time(:millisecond) - start < 250
      end
    )
  end

  test "handshake requires welcome then complete initial page; failures release socket" do
    for failure <- [
          :bye,
          :malformed,
          :missing_welcome_fields,
          :missing_page_fields,
          :reversed,
          :eof
        ] do
      peer(
        fn socket ->
          assert receive_line(socket)["op"] == "hello"
          welcome = %{"op" => "welcome", "env" => "test", "spec" => "0.14.0"}

          case failure do
            :bye ->
              send_line(socket, %{"op" => "bye", "text" => "too old"})

            :malformed ->
              :gen_tcp.send(socket, "broken\n")

            :missing_welcome_fields ->
              send_line(socket, %{"op" => "welcome"})

            :missing_page_fields ->
              send_line(socket, welcome)
              send_line(socket, %{"op" => "page", "reason" => "open"})

            :reversed ->
              send_line(socket, page("open"))
              send_line(socket, welcome)

            :eof ->
              :gen_tcp.shutdown(socket, :write)
          end

          assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
        end,
        fn port ->
          assert {:error, _} =
                   Client.connect("test", %{"control" => %{"host" => "127.0.0.1", "port" => port}})
        end
      )
    end
  end

  test "handshake shares one deadline across welcome and initial page" do
    peer(
      fn socket ->
        assert receive_line(socket)["op"] == "hello"
        Process.sleep(80)
        send_line(socket, %{"op" => "welcome", "env" => "test", "spec" => "0.14.0"})
        Process.sleep(80)
        assert :gen_tcp.recv(socket, 0, 0) == {:error, :closed}
      end,
      fn port ->
        client = raw(port)
        assert {:error, why} = Client.exchange(client, :hello, Client.hello("test", "agent"), 120)
        assert why =~ "did not answer in time"
      end
    )
  end

  test "a missing matching reply times out and unrelated traffic is not success" do
    peer(
      fn socket ->
        assert receive_line(socket) == %{"op" => "turn"}
        send_line(socket, %{"op" => "future"})
        send_line(socket, page("stored"))
        assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
      end,
      fn port ->
        assert {:error, why} = Client.exchange(raw(port), :turn, %{"op" => "turn"}, 50)
        assert why =~ "did not answer in time"
      end
    )
  end

  test "machine discovery replies bind request id and outer/nested exact machine identity" do
    target = %{"environment" => "test", "machine" => "fixture"}

    request =
      Protocol.request(:runtime_machine_discover, id: "read-1", target: target, grant: "private")

    valid =
      Protocol.reply(:runtime_machine_discover, :result,
        id: "read-1",
        target: target,
        availability: %{target: target, registered: true, basis: "bus_endpoint_registry"}
      )

    error =
      Protocol.reply(:runtime_machine_discover, :error,
        id: "read-1",
        target: target,
        error: %{code: "unauthorized", message: "refused", retryable: false}
      )

    for bad <- [
          Map.put(valid, "id", "other"),
          put_in(valid, ["target", "machine"], "other"),
          put_in(valid, ["availability", "target", "environment"], "prod"),
          put_in(error, ["target", "machine"], "other"),
          Map.delete(error, "target"),
          put_in(valid, ["availability", "registered"], "true")
        ] do
      peer(
        fn socket ->
          assert receive_line(socket) == request
          send_line(socket, bad)
          assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
        end,
        fn port ->
          assert {:error, _} = Client.exchange(raw(port), :runtime_machine_discover, request, 100)
        end
      )
    end

    peer(
      fn socket ->
        assert receive_line(socket) == request
        send_line(socket, notice())
        send_line(socket, page("hint"))
        send_line(socket, valid)
      end,
      fn port ->
        client = raw(port)
        assert {:ok, ^valid} = Client.exchange(client, :runtime_machine_discover, request, 100)
        Client.close(client)
      end
    )
  end

  test "discovery distinguishes malformed data and deadline expiry from machine absence" do
    request =
      Protocol.request(:runtime_machine_discover,
        id: "deadline",
        target: %{environment: "test", machine: "fixture"}
      )

    for {kind, code} <- [{:malformed, "malformed_reply"}, {:timeout, "timeout"}] do
      peer(
        fn socket ->
          assert receive_line(socket) == request
          if kind == :malformed, do: :gen_tcp.send(socket, "{\n"), else: Process.sleep(100)
          assert :gen_tcp.recv(socket, 0, 1_000) == {:error, :closed}
        end,
        fn port ->
          assert {:error, %{"code" => ^code}} =
                   Client.exchange(raw(port), :runtime_machine_discover, request, 50)
        end
      )
    end
  end
end
