Code.require_file("support.exs", __DIR__)

defmodule AtlasRuntime.Backend.TestTcp do
  @moduledoc false
  # Raw HTTP/1.1 on 127.0.0.1:<port>, so every header (or its absence) is the test's own.

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  def request(port, method, path, headers \\ [], body \\ "") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    lines = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

    _ =
      :gen_tcp.send(socket, [
        method,
        " ",
        path,
        " HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        lines,
        "\r\n",
        body
      ])

    raw = recv_all(socket, "")
    :gen_tcp.close(socket)
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", code | _] = String.split(status_line, " ")

    headers =
      for line <- header_lines do
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end

    %{status: String.to_integer(code), headers: headers, body: body}
  end

  defp recv_all(socket, seen) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> recv_all(socket, seen <> data)
      {:error, _closed} -> seen
    end
  end

  def open(port, path, headers) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)
    lines = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]
    :ok = :gen_tcp.send(socket, ["GET ", path, " HTTP/1.1\r\nhost: localhost\r\n", lines, "\r\n"])
    {socket, ""}
  end
end

defmodule AtlasRuntime.Backend.TestCrashingRouter do
  @moduledoc false
  # The work router, except that `call/2` has no clause for any request: a bug downstream
  # of the guard, crashing with the conn as its argument.
  defdelegate __rights__(listener), to: AtlasRuntime.Test.WorkRest
  defdelegate __problem__(problem, conn), to: AtlasRuntime.Test.WorkRest
  def init(opts), do: opts
  def call(%Plug.Conn{method: "NO-SUCH-METHOD"} = conn, _opts), do: conn
end

defmodule AtlasRuntime.Backend.TestRawLog do
  @moduledoc false
  # A :logger handler that sends every event, whole, to the test.
  def log(event, %{config: %{test: test}}), do: send(test, {:raw_log, event})
end

defmodule AtlasRuntime.BackendTest.TcpListener do
  @moduledoc """
  The loopback TCP listener (design §8.1, §9; S3 plan P2, B1–B5): 127.0.0.1 only, the
  port from `clients.json`, Origin refused before auth, Bearer tokens looked up in a file
  read on every request, rights cut to the TCP ceiling, the router's body cap, and a
  stream that ends at the heartbeat after its token is revoked. The socket's client is
  unchanged.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AtlasRuntime.Backend.{Clients, Listener, TcpListener, TestSocket, TestTcp}
  alias AtlasRuntime.Test.{FakeWork, WorkRest}
  alias AtlasRuntime.Test.WorkFacade, as: F

  @flow "Zmxvdy1lbmdpbmUtdG9rZW4tZm9yLXRlc3Rz"
  @reader "cmVhZGVyLXRva2VuLWZvci10ZXN0cy0xMjM"
  @off "ZGlzYWJsZWQtdG9rZW4tZm9yLXRlc3Rz"

  @request %{
    "title" => "Fix it",
    "instructions" => "Fix the bug.",
    "profile" => "deep_coding",
    "cost_class" => "standard",
    "workspace" => %{
      "kind" => "repository",
      "url" => "https://example.test/r.git",
      "branch" => "fix",
      "base" => "develop"
    }
  }

  setup do
    FakeWork.reset_all()
    FakeWork.owner(self())
    on_exit(&FakeWork.reset_all/0)
    home = TestSocket.home()
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home, port: TestTcp.free_port()}
  end

  defp sha(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp entries do
    [
      %{"name" => "flow", "token_sha256" => sha(@flow), "rights" => ["submit", "cancel", "read"]},
      %{"name" => "reader", "token_sha256" => sha(@reader), "rights" => ["read"]},
      %{"name" => "off", "token_sha256" => sha(@off), "rights" => ["read"], "disabled" => true}
    ]
  end

  defp write!(home, port, clients \\ entries(), mode \\ 0o600) do
    path = Clients.path(home)
    File.rm(path)

    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "listen" => %{"port" => port}, "clients" => clients})
    )

    File.chmod!(path, mode)
  end

  defp update!(home, port, name, changes) do
    write!(
      home,
      port,
      for(e <- entries(), do: if(e["name"] == name, do: Map.merge(e, changes), else: e))
    )
  end

  defp start(home, opts \\ []) do
    {:ok, pid} =
      start_supervised({TcpListener, Keyword.merge([home: home, router: WorkRest], opts)})

    pid
  end

  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  defp get(port, path, headers), do: TestTcp.request(port, "GET", path, headers)

  defp problem(%{status: status, headers: headers, body: body}, code, type) do
    assert status == code, "#{status}: #{body}"
    assert {"content-type", "application/problem+json"} in headers
    decoded = JSON.decode!(body)
    assert decoded["type"] == type
    assert decoded["status"] == code
    decoded
  end

  defp me do
    {name, 0} = System.cmd("id", ["-un"])
    "local:" <> String.trim(name)
  end

  describe "start" do
    test "no clients.json: nothing starts and nothing listens on the port", %{
      home: home,
      port: port
    } do
      assert :ignore = GenServer.start(TcpListener, home: home, router: WorkRest)
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
    end

    test "it binds 127.0.0.1 only, at the file's port", %{home: home, port: port} do
      write!(home, port)
      pid = start(home)
      assert TcpListener.address(pid) == {{127, 0, 0, 1}, port}
      assert %{status: 401} = get(port, "/v1/capacity", [])
    end

    test "any ip but 127.0.0.1 is refused at init", %{home: home, port: port} do
      write!(home, port)

      for ip <- [{0, 0, 0, 0}, {127, 0, 0, 2}, {0, 0, 0, 0, 0, 0, 0, 1}, {:local, "/x"}] do
        assert {:error, {:not_loopback, ^ip}} =
                 GenServer.start(TcpListener, home: home, router: WorkRest, ip: ip)
      end

      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
    end

    test "a 0644 file is refused at start, naming the mode", %{home: home, port: port} do
      write!(home, port, entries(), 0o644)

      assert {:error, {:clients, why}} =
               GenServer.start(TcpListener, home: home, router: WorkRest)

      assert why =~ "mode 644; it must be 0600"
      assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
    end

    test "choose_slot or choose_path in an entry makes the file invalid at start",
         %{home: home, port: port} do
      for right <- ["choose_slot", "choose_path"] do
        write!(home, port, [
          %{"name" => "core", "token_sha256" => sha(@flow), "rights" => ["read", right]}
        ])

        assert {:error, {:clients, why}} =
                 GenServer.start(TcpListener, home: home, router: WorkRest)

        assert why =~ "outside the TCP listener's rights", right
      end
    end
  end

  describe "a request" do
    setup %{home: home, port: port} do
      write!(home, port)
      start(home)
      :ok
    end

    test "a valid token: submit is served, as client token:<name> with its rights", %{port: port} do
      FakeWork.answer(:submit, fn {id, _rights}, _input ->
        %F.Outcome.Accepted{work: FakeWork.a_work(client: id)}
      end)

      response =
        TestTcp.request(
          port,
          "POST",
          "/v1/work",
          auth(@flow) ++ [{"content-type", "application/json"}, {"idempotency-key", "k-1"}],
          JSON.encode!(@request)
        )

      assert response.status == 201, response.body
      assert JSON.decode!(response.body)["client"] == "token:flow"
      assert_received {:fake_work, :submit, {"token:flow", [:submit, :cancel, :read]}, input}
      assert input.client_key == "k-1"
    end

    test "missing, unknown, disabled and malformed tokens: the same 401, nothing called",
         %{port: port} do
      cases = [
        [],
        auth("unknown-token"),
        auth(@off),
        [{"authorization", "Bearer"}],
        [{"authorization", "Bearer "}],
        [{"authorization", "Bearer  " <> @flow}],
        [{"authorization", "Bearer " <> @flow <> " x"}],
        [{"authorization", @flow}],
        [{"authorization", "Basic " <> @flow}],
        [{"authorization", "bearer" <> @flow}],
        [{"authorization", "Bearer " <> sha(@flow)}],
        auth(@flow) ++ auth(@flow)
      ]

      log =
        capture_log(fn ->
          bodies =
            for headers <- cases do
              response = get(port, "/v1/capacity", headers)
              problem(response, 401, "unauthenticated")
              assert {"www-authenticate", "Bearer"} in response.headers, inspect(headers)
              response.body
            end

          assert [_one] = Enum.uniq(bodies)
        end)

      refute_received {:fake_work, _, _, _}
      # Neither a token nor its hash is ever logged or echoed.
      for secret <- [@flow, @off, sha(@flow), sha(@off)], do: refute(log =~ secret)
    end

    test "Origin is refused with 403 origin-refused, whatever its value, even with a valid token",
         %{port: port} do
      for origin <- ["x", "null", "http://127.0.0.1", "https://mini.example.ts.net"] do
        response = get(port, "/v1/capacity", auth(@flow) ++ [{"origin", origin}])
        problem(response, 403, "origin-refused")
        refute response.body =~ @flow
      end

      # Before auth: no token at all is still 403, not 401.
      problem(get(port, "/v1/capacity", [{"origin", "x"}]), 403, "origin-refused")
      refute_received {:fake_work, _, _, _}
    end

    test "a read-only token: submit is 403 not-permitted, before the implementation", %{
      port: port
    } do
      response =
        TestTcp.request(port, "POST", "/v1/work", auth(@reader), JSON.encode!(@request))

      problem(response, 403, "not-permitted")
      refute_received {:fake_work, :submit, _, _}

      assert %{status: 200} = get(port, "/v1/capacity", auth(@reader))
      assert_received {:fake_work, :capacity, {"token:reader", [:read]}, nil}
    end

    test "a 1 MiB + 1 byte body is 400 invalid; the implementation is not called", %{port: port} do
      body = String.duplicate(" ", 1_048_577)
      response = TestTcp.request(port, "POST", "/v1/work", auth(@flow), body)
      assert problem(response, 400, "invalid")["detail"] =~ "larger than 1048576 bytes"
      refute_received {:fake_work, :submit, _, _}
    end

    test "the file is read on every request: revoking, restoring and adding apply on the next",
         %{home: home, port: port} do
      assert %{status: 200} = get(port, "/v1/capacity", auth(@reader))

      update!(home, port, "reader", %{"disabled" => true})
      problem(get(port, "/v1/capacity", auth(@reader)), 401, "unauthenticated")

      update!(home, port, "reader", %{"disabled" => false})
      assert %{status: 200} = get(port, "/v1/capacity", auth(@reader))

      new = "bmV3LXRva2VuLWFkZGVkLWxhdGVy"
      problem(get(port, "/v1/capacity", auth(new)), 401, "unauthenticated")

      write!(
        home,
        port,
        entries() ++ [%{"name" => "new", "token_sha256" => sha(new), "rights" => ["read"]}]
      )

      assert %{status: 200} = get(port, "/v1/capacity", auth(new))
      assert_received {:fake_work, :capacity, {"token:new", [:read]}, nil}
    end

    test "a file broken after start: every request 401, one line naming the problem, never its contents",
         %{home: home, port: port} do
      broken = [
        {fn ->
           write!(home, port, [
             %{
               "name" => "flow",
               "token_sha256" => sha(@flow),
               "rights" => ["read", "choose_slot"]
             }
           ])
         end, "clients.json is invalid: clients[0].rights names a right outside"},
        {fn -> File.chmod!(Clients.path(home), 0o644) end, "clients.json has mode 644"},
        {fn -> File.write!(Clients.path(home), "{\"clients\": \"#{sha(@flow)}\"") end,
         "clients.json is no JSON"},
        {fn -> File.rm!(Clients.path(home)) end, "clients.json is gone"}
      ]

      for {break, expected} <- broken do
        write!(home, port)
        assert %{status: 200} = get(port, "/v1/capacity", auth(@flow))
        break.()

        log =
          capture_log(fn ->
            problem(get(port, "/v1/capacity", auth(@flow)), 401, "unauthenticated")
          end)

        assert log =~ expected

        assert [_one] =
                 for(
                   line <- String.split(log, "\n"),
                   line =~ "TCP requests are refused",
                   do: line
                 )

        for secret <- [@flow, sha(@flow), @reader, sha(@reader)], do: refute(log =~ secret)
      end
    end

    test "the socket client is unchanged next to the TCP listener", %{home: home, port: port} do
      start_supervised!({Listener, home: home, router: WorkRest})
      stream = TestSocket.open(Listener.path(home), "/v1/capacity")
      {stream, _} = TestSocket.await(stream, "\r\n\r\n")
      TestSocket.close(stream)

      assert_receive {:fake_work, :capacity, {id, rights}, nil}
      assert id == me()

      assert rights == [
               :submit,
               :cancel,
               :read,
               :read_all,
               :choose_slot,
               :choose_path,
               :inspect,
               :operate
             ]

      assert %{status: 200} = get(port, "/v1/capacity", auth(@flow))
      assert_received {:fake_work, :capacity, {"token:flow", [:submit, :cancel, :read]}, nil}
    end
  end

  describe "a crash downstream of the guard (P2)" do
    test "500, and neither the token nor its hash is in the log, metadata and all", %{
      home: home,
      port: port
    } do
      write!(home, port)
      start(home, router: AtlasRuntime.Backend.TestCrashingRouter)
      inspect_opts = Application.fetch_env!(:logger, :translator_inspect_opts)
      Application.put_env(:logger, :translator_inspect_opts, limit: :infinity)

      :ok =
        :logger.add_handler(:tcp_listener_test_raw, AtlasRuntime.Backend.TestRawLog, %{
          level: :all,
          config: %{test: self()}
        })

      log =
        try do
          capture_log([metadata: :all], fn ->
            response = get(port, "/v1/capacity", auth(@flow))
            assert response.status == 500
            Process.sleep(100)
          end)
        after
          :logger.remove_handler(:tcp_listener_test_raw)
          Application.put_env(:logger, :translator_inspect_opts, inspect_opts)
        end

      events = for {:raw_log, event} <- Process.info(self(), :messages) |> elem(1), do: event
      raw = inspect(events, limit: :infinity, printable_limit: :infinity)

      # The crash was logged, with the conn.
      assert log =~ "FunctionClauseError"
      assert raw =~ "Plug.Conn"

      for secret <- [@flow, sha(@flow)] do
        refute log =~ secret
        refute raw =~ secret
      end
    end
  end

  describe "rights" do
    test "an already-loaded entry is cut to the ceiling (second line of defence)" do
      ceiling = WorkRest.__rights__(:tcp)

      entry = %{
        name: "x",
        token_sha256: "",
        rights: [:read, :choose_slot, :choose_path, :operate],
        disabled: false
      }

      assert TcpListener.client(entry, ceiling) == {"token:x", [:read]}
      assert TcpListener.client(%{entry | rights: [:choose_slot]}, ceiling) == {"token:x", []}
      assert TcpListener.client(%{entry | rights: [:choose_path]}, ceiling) == {"token:x", []}
    end

    # D44: a TCP client never names a path on the Runtime's machine.
    test "a token with every TCP right still has no choose_path", %{home: home, port: port} do
      refute :choose_path in WorkRest.__rights__(:tcp)

      write!(home, port, [
        %{
          "name" => "all",
          "token_sha256" => sha(@flow),
          "rights" => ["submit", "cancel", "read", "read_all"]
        }
      ])

      start(home)
      assert %{status: 200} = get(port, "/v1/capacity", auth(@flow))
      assert_received {:fake_work, :capacity, {"token:all", rights}, nil}
      assert rights == [:submit, :cancel, :read, :read_all]
    end
  end

  # S2 BK2 item 6 (§13.1 Q4, D44), now that S3 has the TCP listener: the one router serves
  # the work, operations and history contracts on every listener, but only the socket's
  # owner operates or inspects the Runtime. A TCP token never holds inspect, operate,
  # choose_slot or choose_path.
  describe "operations over TCP (S2 BK2 item 6)" do
    @operations [
      {"GET", "/v1/runtime", ""},
      {"GET", "/v1/policy", ""},
      {"POST", "/v1/control/pause", ""},
      {"POST", "/v1/control/resume", ""},
      {"POST", "/v1/control/drain", ""},
      {"POST", "/v1/control/stop", ~s({"force":true})},
      {"POST", "/v1/slots/s1/release", ""},
      {"POST", "/v1/harnesses/claude/clear-quota-mark", ""}
    ]

    test "the TCP ceiling has none of inspect, operate, choose_slot, choose_path; the socket has all" do
      ceiling = WorkRest.__rights__(:tcp)
      socket = WorkRest.__rights__(:socket)

      for right <- [:inspect, :operate, :choose_slot, :choose_path] do
        refute right in ceiling, inspect(right)
        assert right in socket, inspect(right)
      end

      assert ceiling == AtlasRuntime.Backend.Rest.__rights__(:tcp)
    end

    test "inspect or operate in an entry makes the file invalid at start (never cut down)",
         %{home: home, port: port} do
      for right <- ["inspect", "operate"] do
        write!(home, port, [
          %{"name" => "ops", "token_sha256" => sha(@flow), "rights" => ["read", right]}
        ])

        assert {:error, {:clients, why}} =
                 GenServer.start(TcpListener, home: home, router: WorkRest)

        assert why =~ "outside the TCP listener's rights", right
        assert {:error, :econnrefused} = :gen_tcp.connect({127, 0, 0, 1}, port, [], 1_000)
      end
    end

    test "an already-loaded entry with inspect or operate is cut to the ceiling" do
      entry = %{name: "x", token_sha256: "", rights: [:inspect, :operate], disabled: false}
      assert TcpListener.client(entry, WorkRest.__rights__(:tcp)) == {"token:x", []}
    end

    test "a token with every TCP right is refused every operations route, and nothing runs",
         %{home: home, port: port} do
      write!(home, port, [
        %{
          "name" => "all",
          "token_sha256" => sha(@flow),
          "rights" => ["submit", "cancel", "read", "read_all"]
        }
      ])

      start(home)

      for {method, path, body} <- @operations do
        headers =
          if body == "",
            do: auth(@flow),
            else: [{"content-type", "application/json"} | auth(@flow)]

        response = TestTcp.request(port, method, path, headers, body)
        # 403 not-permitted (the facade's refusal), never 404 no-route: the route is there.
        problem(response, 403, "not-permitted")
      end

      refute_received {:fake_operations, _, _, _}

      # The same router still serves the token its work routes.
      assert %{status: 200} = get(port, "/v1/capacity", auth(@flow))

      assert_received {:fake_work, :capacity, {"token:all", [:submit, :cancel, :read, :read_all]},
                       nil}
    end

    test "the history routes are served on the token's own rights, never more",
         %{home: home, port: port} do
      write!(home, port)
      start(home)

      assert %{status: 200} = get(port, "/v1/turns", auth(@reader))
      assert_received {:fake_history, :list_turns, {"token:reader", [:read]}, _input}

      # Without read, the history facade refuses before anything runs.
      update!(home, port, "reader", %{"rights" => ["submit"]})
      problem(get(port, "/v1/turns", auth(@reader)), 403, "not-permitted")
      refute_received {:fake_history, _, _, _}
    end
  end

  describe "the event stream" do
    setup %{home: home, port: port} do
      write!(home, port)
      start_supervised!(FakeWork.window(10))
      start(home)
      :ok
    end

    defp subscribe(port, token) do
      stream = TestTcp.open(port, "/v1/events", auth(token))
      assert_receive {:fake_work, :subscribe, client, _input}, 2_000
      {stream, _} = TestSocket.await(stream, "\r\n\r\n")
      {stream, client}
    end

    defp heartbeat do
      FakeWork.broadcast(fn _client ->
        %F.Heartbeat{at: ~U[2026-11-16 10:00:15Z], capacity: FakeWork.a_capacity(), running: []}
      end)
    end

    defp changed(owner, work_id),
      do:
        FakeWork.notify(
          owner,
          &%F.WorkChanged{sequence: &1, work_id: work_id, revision: &1, state: :running}
        )

    defp count(seen, pattern), do: length(String.split(seen, pattern)) - 1

    test "a token without read_all sees neither socket-owned work nor its events", %{port: port} do
      {stream, client} = subscribe(port, @reader)
      assert client == {"token:reader", [:read]}

      changed(me(), "w-socket")
      changed("token:reader", "w-own")
      {stream, seen} = TestSocket.await(stream, ~s("work_id":"w-own"))
      refute seen =~ "w-socket"
      TestSocket.close(stream)
    end

    test "unchanged, the stream goes on across heartbeats", %{port: port} do
      {stream, _} = subscribe(port, @reader)
      heartbeat()
      {stream, _} = TestSocket.await(stream, "event: heartbeat\n")
      heartbeat()
      {socket, seen} = TestSocket.drain(stream, 300)
      assert count(seen, "event: heartbeat\n") == 2
      refute seen =~ "\r\n0\r\n\r\n"
      :gen_tcp.close(socket)
    end

    test "revoked: the stream ends at the next heartbeat, which is not sent", %{
      home: home,
      port: port
    } do
      {stream, _} = subscribe(port, @reader)
      heartbeat()
      {stream, _} = TestSocket.await(stream, "event: heartbeat\n")

      update!(home, port, "reader", %{"disabled" => true})
      # Between heartbeats nothing is re-checked; the next one ends the stream.
      heartbeat()
      {stream, seen} = TestSocket.await(stream, "\r\n0\r\n\r\n")
      assert count(seen, "event: heartbeat\n") == 1
      TestSocket.close(stream)
    end

    test "rights changed: the stream ends at the next heartbeat", %{home: home, port: port} do
      {stream, _} = subscribe(port, @reader)
      update!(home, port, "reader", %{"rights" => ["read", "read_all"]})
      heartbeat()
      {stream, seen} = TestSocket.await(stream, "\r\n0\r\n\r\n")
      refute seen =~ "event: heartbeat"
      TestSocket.close(stream)
    end
  end
end
