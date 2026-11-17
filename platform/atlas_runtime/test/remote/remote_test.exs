defmodule AtlasRuntime.RemoteTest do
  # Through an in-test HTTP CONNECT proxy to an in-test HTTPS server, both on loopback
  # (AtlasRuntime.RemoteFixtures). The OS environment and the :httpc profile are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias AtlasRuntime.Remote
  alias AtlasRuntime.Remote.Config
  alias AtlasRuntime.Remote.Transport
  alias AtlasRuntime.RemoteFixtures, as: F
  alias AtlasRuntime.RemoteFixtures.Proxy

  defmodule RawLog do
    @moduledoc false
    # A logger handler that sends each event, as the primary filters left it and before any
    # formatting, to the test process.
    def log(event, %{config: %{test: test}}), do: send(test, {:raw_log, event})
  end

  @url "ATLAS_RUNTIME_BACKEND_URL"
  @token "ATLAS_RUNTIME_BACKEND_TOKEN"

  setup do
    token = "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

    on_exit(fn ->
      System.delete_env(@url)
      System.delete_env(@token)
    end)

    %{token: token, pki: F.pki()}
  end

  # The HTTPS stand-in answering with `handler`, a proxy in `proxy:` mode, and the client
  # configured to reach the server's host name through the proxy (or `proxy_port:`),
  # trusting `cacerts:` (default: the server's CA).
  defp connect(ctx, handler, opts \\ []) do
    pki = Keyword.get(opts, :pki, ctx.pki)
    serve = start_supervised!(F.serve_spec(handler, pki))
    port = F.serve_port(serve)
    proxy = start_supervised!({Proxy, mode: Keyword.get(opts, :proxy, :tunnel)})
    proxy_port = Keyword.get_lazy(opts, :proxy_port, fn -> Proxy.port(proxy) end)

    System.put_env(@url, "https://#{F.host()}:#{port}")
    System.put_env(@token, ctx.token)

    start_supervised!(
      {Config,
       proxy: {"localhost", proxy_port}, cacerts: Keyword.get(opts, :cacerts, pki.cacerts)}
    )

    %{proxy: proxy, target: "#{F.host()}:#{port}"}
  end

  # A handler that reports each request to the test, then answers with `answer`.
  defp served(answer) do
    test = self()

    fn conn ->
      send(test, {:served, conn.method, conn.request_path, conn.req_headers})
      answer.(conn)
    end
  end

  defp capacity_answer, do: served(&F.json(&1, 200, F.capacity_json()))

  defp request do
    %{
      title: "t",
      instructions: "do it",
      profile: "deep_coding",
      cost_class: :standard,
      # A remote client never names a path on the Runtime's machine (D44): repository only.
      workspace: %{
        kind: :repository,
        url: "https://example.test/atlas.git",
        branch: "s3",
        base: "develop"
      }
    }
  end

  describe "the probe" do
    test "reads the capacity through one CONNECT to the server's host and port, with the token",
         ctx do
      path = connect(ctx, capacity_answer())

      assert {:ok, capacity} = Remote.probe()
      assert capacity.slots == %{total: 2, busy: 1, free: 1}
      assert capacity.incarnation == "inc-1"
      assert capacity.retry_after == nil

      assert_received {:served, "GET", "/v1/capacity", headers}
      assert {"authorization", "Bearer " <> ctx.token} in headers
      assert Proxy.requests(path.proxy) == [{:connect, path.target}]
    end

    test "makes one GET /v1/capacity and nothing else (it never submits)", ctx do
      connect(ctx, capacity_answer())

      assert {:ok, _} = Remote.probe()
      assert_received {:served, "GET", "/v1/capacity", _}
      refute_received {:served, _, _, _}
    end

    test "is not_configured when the remote client is off" do
      refute Config.configured?()
      assert Remote.probe() == {:error, :not_configured}
    end
  end

  describe "unreachable, never another outcome" do
    test "a server certificate from a CA the client does not trust", ctx do
      connect(ctx, capacity_answer(), cacerts: F.pki().cacerts)

      capture_log(fn -> assert Remote.probe() == {:error, :unreachable} end)
      refute_received {:served, _, _, _}
    end

    test "a trusted server certificate for another host name", ctx do
      connect(ctx, capacity_answer(), pki: F.pki("other.tailnet.test"))

      capture_log(fn -> assert Remote.probe() == {:error, :unreachable} end)
      refute_received {:served, _, _, _}
    end

    test "the proxy is down", ctx do
      connect(ctx, capacity_answer(), proxy_port: F.closed_port())

      capture_log(fn -> assert Remote.probe() == {:error, :unreachable} end)
      refute_received {:served, _, _, _}
    end

    test "the proxy answers 403 to CONNECT", ctx do
      path = connect(ctx, capacity_answer(), proxy: :refuse)

      capture_log(fn -> assert Remote.probe() == {:error, :unreachable} end)
      assert Proxy.requests(path.proxy) == [{:connect, path.target}]
      refute_received {:served, _, _, _}
    end

    test "502 and 504 from serve (its backend is down), and a 503 without at-capacity", ctx do
      {:ok, status} = Agent.start_link(fn -> 502 end)
      connect(ctx, served(&Plug.Conn.send_resp(&1, Agent.get(status, fn s -> s end), "")))

      for code <- [502, 504, 503] do
        Agent.update(status, fn _ -> code end)
        capture_log(fn -> assert Remote.probe() == {:error, :unreachable} end)
        capture_log(fn -> assert Remote.submit(request()) == {:error, :unreachable} end)
      end

      capture_log(fn ->
        Agent.update(status, fn _ -> 503 end)
        assert Remote.get_work(%{work_id: "w1"}) == {:error, :unreachable}
      end)
    end
  end

  describe "each request is sent once" do
    test "a connection that drops after the request reached the server: unreachable, not re-sent",
         ctx do
      test = self()

      connect(ctx, fn conn ->
        send(test, {:served, conn.method, conn.request_path, conn.req_headers})

        case conn.method do
          "GET" -> F.json(conn, 200, F.capacity_json())
          # The request arrived, and the connection goes before any answer.
          "POST" -> Process.exit(self(), :kill)
        end
      end)

      capture_log(fn ->
        assert {:ok, _} = Remote.probe()
        assert Remote.submit(Map.put(request(), :client_key, "flow-18")) == {:error, :unreachable}
        Process.sleep(300)
      end)

      assert_received {:served, "GET", "/v1/capacity", _}
      assert_received {:served, "POST", "/v1/work", _}
      refute_received {:served, _, _, _}
    end
  end

  describe "typed answers through the tunnel" do
    test "503 at-capacity is at_capacity with its retry_after, not unreachable", ctx do
      body = %{"reason" => "full", "retry_after" => 30, "capacity" => F.capacity_json()}

      connect(
        ctx,
        served(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("retry-after", "30")
          |> F.problem(503, "at-capacity", body)
        end)
      )

      assert {:at_capacity, at_capacity} =
               Remote.submit(Map.put(request(), :client_key, "flow-17"))

      assert at_capacity.retry_after == 30
      assert at_capacity.reason == :full
      assert at_capacity.capacity.accepting == true
      assert_received {:served, "POST", "/v1/work", headers}
      assert {"idempotency-key", "flow-17"} in headers
    end

    test "401 is unauthenticated, never unreachable", ctx do
      connect(
        ctx,
        served(fn conn ->
          conn
          |> Plug.Conn.put_resp_header("www-authenticate", "Bearer")
          |> F.problem(401, "unauthenticated")
        end)
      )

      log = capture_log(fn -> assert Remote.probe() == {:error, :unauthenticated} end)
      refute log =~ ctx.token
    end

    test "404 not-found and 410 pruned stay apart from each other and from unreachable", ctx do
      connect(
        ctx,
        served(fn conn ->
          case List.last(conn.path_info) do
            "gone" ->
              F.problem(conn, 410, "pruned", %{"work_id" => "gone", "kind" => "completed"})

            _never ->
              F.problem(conn, 404, "not-found")
          end
        end)
      )

      assert Remote.get_work(%{work_id: "never"}) == {:not_found, %{}}
      assert {:pruned, %{work_id: "gone", kind: :completed}} = Remote.get_work(%{work_id: "gone"})
    end
  end

  describe "the event stream" do
    # The stand-in streams `frames` one at a time, each when the test says so, and reports
    # the Last-Event-ID it was asked to resume from.
    defp events_answer do
      test = self()

      fn conn ->
        send(test, {:resume, self(), Plug.Conn.get_req_header(conn, "last-event-id")})

        conn =
          conn
          |> Plug.Conn.put_resp_content_type("text/event-stream", nil)
          |> Plug.Conn.send_chunked(200)

        stream_frames(conn)
      end
    end

    defp stream_frames(conn) do
      receive do
        {:frame, frame} ->
          case Plug.Conn.chunk(conn, frame) do
            {:ok, conn} -> stream_frames(conn)
            {:error, _closed} -> conn
          end

        :end ->
          conn
      after
        10_000 -> conn
      end
    end

    defp work_changed(sequence),
      do:
        F.frame("work", sequence, %{
          "sequence" => sequence,
          "work_id" => "w1",
          "revision" => sequence,
          "state" => "running"
        })

    test "streams typed events through the proxy, and resumes with Last-Event-ID", ctx do
      path = connect(ctx, events_answer())

      assert {:ok, events} = Remote.subscribe(%{from: 7})
      assert_receive {:resume, server, ["7"]}, 5_000

      send(server, {:frame, work_changed(8)})

      send(
        server,
        {:frame, F.frame("capacity", 9, %{"sequence" => 9, "capacity" => F.capacity_json()})}
      )

      # Two events while the server still holds the stream open.
      assert [
               {:work, %{sequence: 8, work_id: "w1", state: :running}},
               {:capacity, %{sequence: 9, capacity: %{incarnation: "inc-1"}}}
             ] = Enum.take(events, 2)

      # Resume after the last event seen.
      assert {:ok, events} = Remote.subscribe(%{from: 9})
      assert_receive {:resume, server, ["9"]}, 5_000
      send(server, {:frame, work_changed(10)})
      send(server, :end)
      assert [{:work, %{sequence: 10}}] = Enum.to_list(events)

      # Every request went through the proxy, as a CONNECT to the server.
      assert Enum.uniq(Proxy.requests(path.proxy)) == [{:connect, path.target}]
    end

    test "the stream through a refused CONNECT is unreachable", ctx do
      connect(ctx, events_answer(), proxy: :refuse)
      capture_log(fn -> assert Remote.subscribe(%{}) == {:error, :unreachable} end)
    end
  end

  describe "a redirect is never followed" do
    # A second in-test host behind the same proxy, with a certificate for the same name, so
    # following a redirect to it would succeed. It reports every TCP connection and whether
    # the request it got carried an Authorization header, and answers a capacity.
    defp second_host(pki) do
      test = self()

      {:ok, listen} =
        :ssl.listen(
          0,
          [:binary, ip: {127, 0, 0, 1}, active: false, reuseaddr: true] ++ pki.server
        )

      {:ok, {_ip, port}} = :ssl.sockname(listen)
      acceptor = spawn_link(fn -> second_accept(listen, test) end)
      :ok = :ssl.controlling_process(listen, acceptor)
      port
    end

    defp second_accept(listen, test) do
      case :ssl.transport_accept(listen) do
        {:ok, socket} ->
          send(test, {:second_host, :connected})

          with {:ok, socket} <- :ssl.handshake(socket, 5_000),
               {:ok, head} <- second_head(socket, "") do
            send(test, {:second_host, {:authorization, head =~ ~r/^authorization:/im}})
            body = JSON.encode!(F.capacity_json())

            :ssl.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n" <>
                "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
            )
          end

          second_accept(listen, test)

        {:error, _closed} ->
          :ok
      end
    end

    defp second_head(socket, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        {:ok, acc}
      else
        case :ssl.recv(socket, 0, 5_000) do
          {:ok, data} -> second_head(socket, acc <> data)
          error -> error
        end
      end
    end

    test "301, 302, 303, 307 and 308 to another host: unreachable, and nothing reaches it", ctx do
      location = "https://#{F.host()}:#{second_host(ctx.pki)}/v1/capacity"
      {:ok, status} = Agent.start_link(fn -> 301 end)

      path =
        connect(
          ctx,
          served(fn conn ->
            conn
            |> Plug.Conn.put_resp_header("location", location)
            |> Plug.Conn.send_resp(Agent.get(status, & &1), "")
          end)
        )

      get = %{method: "GET", path: "/v1/capacity", query: "", headers: [], body: nil}
      codes = [301, 302, 303, 307, 308]

      log =
        capture_log(fn ->
          for code <- codes do
            Agent.update(status, fn _ -> code end)
            assert Remote.probe() == {:error, :unreachable}
            # 307 and 308 would repeat the POST, body and all.
            assert Remote.submit(request()) == {:error, :unreachable}
            assert Remote.subscribe(%{}) == {:error, :unreachable}
            assert Transport.request(get, []) == {:error, {:redirect, code}}
          end

          Process.sleep(300)
        end)

      assert log =~ "{:redirect, 307}"
      refute log =~ ctx.token
      refute_received {:second_host, _}
      # Every CONNECT went to the first server; none to the Location's host.
      assert Proxy.connects(path.proxy) == List.duplicate(path.target, 4 * length(codes))
    end

    test "a 304 is not a redirect", ctx do
      connect(ctx, served(&Plug.Conn.send_resp(&1, 304, "")))
      get = %{method: "GET", path: "/v1/work/w1", query: "", headers: [], body: nil}
      assert {:ok, %{status: 304}} = Transport.request(get, [])
    end
  end

  describe "the token" do
    test "is in no log, no error term and no :sys.get_status", ctx do
      connect(ctx, capacity_answer(), proxy: :refuse)

      log =
        capture_log(fn ->
          assert Remote.probe() == {:error, :unreachable}

          request = %{method: "GET", path: "/v1/capacity", query: "", headers: [], body: nil}
          assert {:error, reason} = Transport.request(request, [])
          refute inspect(reason, limit: :infinity, printable_limit: :infinity) =~ ctx.token
        end)

      assert log =~ "unreachable"
      refute log =~ ctx.token

      status = inspect(:sys.get_status(Config), limit: :infinity, printable_limit: :infinity)
      refute status =~ ctx.token
      assert status =~ "[redacted]"
    end

    # The test's captured log, and every event of every process as logger's handlers get it
    # (after the primary filters: the translator's text, the metadata).
    # At :debug, with whole terms: only then does the translator print a crashed process's
    # state, and the default inspect limits would cut it before the request's headers. Both
    # would hide a leak.
    defp raw_log(fun) do
      inspect_opts = Application.fetch_env!(:logger, :translator_inspect_opts)
      level = Logger.level()
      Logger.configure(level: :debug)

      Application.put_env(:logger, :translator_inspect_opts,
        limit: :infinity,
        printable_limit: :infinity
      )

      :ok =
        :logger.add_handler(:remote_test_raw, RawLog, %{level: :all, config: %{test: self()}})

      try do
        text = capture_log(fun)
        Process.sleep(100)
        {text, collect_raw([])}
      after
        :logger.remove_handler(:remote_test_raw)
        Application.put_env(:logger, :translator_inspect_opts, inspect_opts)
        Logger.configure(level: level)
      end
    end

    defp collect_raw(acc) do
      receive do
        {:raw_log, event} -> collect_raw([event | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    defp full(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

    # The stand-in holds each request until the test releases it.
    defp held_answer do
      test = self()

      fn conn ->
        send(test, {:holding, self()})

        receive do
          :release -> F.json(conn, 200, F.capacity_json())
        after
          5_000 -> F.json(conn, 200, F.capacity_json())
        end
      end
    end

    defp handler_for(target) do
      [host, port] = String.split(target, ":")

      for {_, pid, _, _} <- Supervisor.which_children(:httpc_handler_sup),
          is_pid(pid),
          :proc_lib.get_label(pid) == {:https, host, String.to_integer(port)},
          do: pid
    end

    test "is in no log when :httpc's request handler crashes mid-request", ctx do
      path = connect(ctx, held_answer())
      test = self()

      {text, events} =
        raw_log(fn ->
          {:ok, caller} = Task.start(fn -> send(test, {:probe, Remote.probe()}) end)
          assert_receive {:holding, server}, 5_000
          assert [handler] = handler_for(path.target)
          # The handler's state holds the request, headers and all.
          :ok = :sys.terminate(handler, {:forced_crash, :mid_request})
          send(test, {:crashed, handler})
          assert_receive {:probe, {:error, :unreachable}}, 5_000
          send(server, :release)
          refute Process.alive?(caller)
        end)

      refute text =~ ctx.token

      # The handler's crash report (from :httpc's own group leader, so only the raw
      # handler sees it), with its state and the request's headers, redacted. Only the
      # handler's own OTP report: on :release the stand-in's Bandit may log a transport
      # error of its own (domain [:elixir, :bandit]), which the last line still covers.
      assert_received {:crashed, handler}

      assert [crash] =
               Enum.filter(
                 events,
                 &match?(%{meta: %{crash_reason: _, domain: [:otp | _], pid: ^handler}}, &1)
               )

      assert full(crash) =~ "terminating"
      assert full(crash) =~ "forced_crash"
      assert full(crash) =~ "\\nState: "
      assert full(crash) =~ "Bearer [redacted]"
      refute full(events) =~ ctx.token
    end

    test "is in no log and no error term when :httpc's manager dies with the request queued",
         ctx do
      connect(ctx, capacity_answer())
      manager = Process.whereis(:httpc_atlas_runtime_remote)
      test = self()

      {text, events} =
        raw_log(fn ->
          :ok = :sys.suspend(manager)
          {:ok, caller} = Task.start(fn -> send(test, {:probe, Remote.probe()}) end)
          ref = Process.monitor(caller)

          # The request (headers and all) waits in the manager's mailbox, in a gen_server
          # call; the manager's exit is the caller's.
          wait_until(fn -> Process.info(manager, :message_queue_len) |> elem(1) > 0 end)
          :ok = :sys.terminate(manager, {:forced_crash, :queued})

          assert_receive {:probe, {:error, :unreachable}}, 5_000
          assert_receive {:DOWN, ^ref, :process, ^caller, reason}, 5_000
          refute full(reason) =~ ctx.token
        end)

      assert text =~ "client_failed"
      refute text =~ ctx.token
      refute full(events) =~ ctx.token
    end

    test "is redacted from any log event, in a binary or a charlist, at any depth", ctx do
      connect(ctx, capacity_answer())
      header = String.to_charlist("Bearer " <> ctx.token)

      {text, events} =
        raw_log(fn ->
          Logger.error("plain #{ctx.token} text")
          :logger.error(~c"format ~p", [[{~c"authorization", header}]])
          :logger.error(%{deep: {:request, [%{headers: [{~c"authorization", header}]}]}})
          :logger.error(~c"charlist ~s", [header])
        end)

      assert length(events) == 4
      assert text =~ "[redacted]"
      refute text =~ ctx.token
      refute full(events) =~ ctx.token
    end

    defp wait_until(fun, tries \\ 100) do
      cond do
        fun.() -> :ok
        tries == 0 -> flunk("timed out")
        true -> Process.sleep(10) && wait_until(fun, tries - 1)
      end
    end
  end
end
