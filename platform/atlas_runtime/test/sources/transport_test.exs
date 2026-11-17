defmodule AtlasRuntime.Sources.TransportTest do
  # Against in-test HTTPS servers on loopback (AtlasRuntime.TLSFixtures). The :httpc profile
  # and the logger's primary filters are global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  require Logger

  alias AtlasRuntime.Sources.Credential
  alias AtlasRuntime.Sources.Transport
  alias AtlasRuntime.TLSFixtures, as: F

  @name "flow-test"

  defmodule RawLog do
    @moduledoc false
    # A logger handler that sends each event, as the primary filters left it and before any
    # formatting, to the test process.
    def log(event, %{config: %{test: test}}), do: send(test, {:raw_log, event})
  end

  defmodule Holder do
    @moduledoc false
    # A process that keeps an open connection in its state, as a puller does.
    use GenServer
    def start_link(conn), do: GenServer.start_link(__MODULE__, conn)
    @impl true
    def init(conn), do: {:ok, %{conn: conn}}
  end

  setup do
    home = Path.join(System.tmp_dir!(), "w3-tr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, "sources", @name]))
    token = "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)
    path = Credential.path(home, @name)
    File.write!(path, token <> "\n")
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(home) end)

    pki = F.pki("localhost")
    %{home: home, token: token, pki: pki, cacertfile: F.cacertfile(pki, home)}
  end

  # An HTTPS server answering with `handler`, and an open connection to it by the name
  # `localhost`, trusting `cacertfile:` (default: the server's CA).
  defp connect(ctx, handler, opts \\ []) do
    server = start_supervised!(F.serve_spec(handler, Keyword.get(opts, :pki, ctx.pki), opts))
    port = F.port(server)
    url = "https://#{Keyword.get(opts, :host, "localhost")}:#{port}"

    assert {:ok, conn} =
             Transport.open(@name, url,
               home: ctx.home,
               cacertfile: Keyword.get(opts, :cacertfile, ctx.cacertfile)
             )

    on_exit(fn -> Transport.close(conn) end)
    conn
  end

  # A handler that reports each request to the test, then answers with `answer`.
  defp served(answer) do
    test = self()

    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:served, conn.method, conn.request_path, conn.req_headers, body})
      answer.(conn)
    end
  end

  defp ok_answer, do: served(&json(&1, 200, %{"ok" => true}))

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json", nil)
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp get(path \\ "/v1/poll"),
    do: %{method: "GET", path: path, query: "", headers: [], body: nil}

  defp full(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  describe "TLS" do
    test "a correct certificate works, with the bearer token on every request", ctx do
      conn = connect(ctx, ok_answer())

      assert {:ok, %{status: 200, body: body}} = Transport.request(get(), conn: conn)
      assert JSON.decode!(body) == %{"ok" => true}
      assert_received {:served, "GET", "/v1/poll", headers, ""}
      assert {"authorization", "Bearer " <> ctx.token} in headers

      post = %{
        method: "POST",
        path: "/v1/report",
        query: "a=1",
        headers: [{"content-type", "application/json"}],
        body: ~s({"x":1})
      }

      assert {:ok, %{status: 200}} = Transport.request(post, conn: conn)
      assert_received {:served, "POST", "/v1/report", headers, ~s({"x":1})}
      assert {"authorization", "Bearer " <> ctx.token} in headers
    end

    test "a stream is read as it arrives", ctx do
      conn =
        connect(
          ctx,
          served(fn c ->
            c = Plug.Conn.send_chunked(c, 200)
            {:ok, c} = Plug.Conn.chunk(c, "abc")
            {:ok, c} = Plug.Conn.chunk(c, "def")
            c
          end)
        )

      assert {:ok, %{status: 200, body: body}} = Transport.stream(get("/v1/blobs/x"), conn: conn)
      assert IO.iodata_to_binary(Enum.to_list(body)) == "abcdef"
    end

    test "the TLS options are TLS 1.3 only, the peer and its host name verified", ctx do
      conn = connect(ctx, ok_answer())
      assert conn.ssl[:verify] == :verify_peer
      assert conn.ssl[:versions] == [:"tlsv1.3"]
      assert conn.ssl[:server_name_indication] == ~c"localhost"
      assert Keyword.has_key?(conn.ssl[:customize_hostname_check], :match_fun)
    end

    test "wrong hostname is refused", ctx do
      pki = F.pki("other.test")
      conn = connect(ctx, ok_answer(), pki: pki, cacertfile: F.cacertfile(pki, ctx.home))

      capture_log(fn ->
        assert {:error, {:failed_connect, {:tls, _}}} = Transport.request(get(), conn: conn)
      end)

      refute_received {:served, _, _, _, _}
    end

    test "an untrusted CA is refused", ctx do
      other = F.pki("localhost")
      conn = connect(ctx, ok_answer(), cacertfile: F.cacertfile(other, ctx.home))

      capture_log(fn ->
        assert {:error, {:failed_connect, {:tls, _}}} = Transport.request(get(), conn: conn)
      end)

      refute_received {:served, _, _, _, _}
    end

    test "TLS 1.2-only server is refused", ctx do
      conn = connect(ctx, ok_answer(), versions: [:"tlsv1.2"])

      capture_log(fn ->
        assert {:error, {:failed_connect, {:tls, _}}} = Transport.request(get(), conn: conn)
      end)

      refute_received {:served, _, _, _, _}
    end

    test "an http:// URL is refused, and nothing falls back to plain text", ctx do
      plain = start_supervised!(F.http_spec(ok_answer()))
      port = F.port(plain)

      for url <- ["http://localhost:#{port}", "ws://localhost:#{port}", "localhost:#{port}"] do
        assert Transport.open(@name, url, home: ctx.home, cacertfile: ctx.cacertfile) ==
                 {:error, {:url, :not_https}}
      end

      refute_received {:served, _, _, _, _}
    end

    test "a URL with a user, query or fragment, or without a host, is refused", ctx do
      for url <- [
            "https://u:p@localhost:1",
            "https://localhost:1/?q=1",
            "https://localhost:1/#f",
            "https:///x",
            "https://localhost:0"
          ] do
        assert {:error, {:url, :invalid}} =
                 Transport.open(@name, url, home: ctx.home, cacertfile: ctx.cacertfile)
      end
    end

    test "a refused credential opens nothing", ctx do
      File.chmod!(Credential.path(ctx.home, @name), 0o644)

      assert Transport.open(@name, "https://localhost:1", home: ctx.home) ==
               {:error, {:credential, :mode}}
    end
  end

  describe "requests" do
    test "redirect is refused, and nothing reaches its Location", ctx do
      test = self()

      elsewhere =
        start_supervised!(
          F.serve_spec(fn c -> send(test, :elsewhere) && json(c, 200, %{}) end, ctx.pki)
        )

      location = "https://localhost:#{F.port(elsewhere)}/v1/poll"

      conn =
        connect(
          ctx,
          served(fn c ->
            status = c |> Plug.Conn.fetch_query_params() |> Map.get(:query_params) |> Map.get("s")

            c
            |> Plug.Conn.put_resp_header("location", location)
            |> Plug.Conn.send_resp(String.to_integer(status), "")
          end)
        )

      capture_log(fn ->
        for status <- [301, 302, 303, 307, 308] do
          request = %{get() | query: "s=#{status}"}
          assert Transport.request(request, conn: conn) == {:error, {:redirect, status}}
          assert Transport.stream(request, conn: conn) == {:error, {:redirect, status}}
        end
      end)

      refute_received :elsewhere
    end

    test "a 304 is not a redirect", ctx do
      conn = connect(ctx, served(&Plug.Conn.send_resp(&1, 304, "")))
      assert {:ok, %{status: 304}} = Transport.request(get(), conn: conn)
    end

    test "no proxy: the profile has none, whatever the environment says", ctx do
      for var <- ["HTTPS_PROXY", "https_proxy", "ALL_PROXY"],
          do: System.put_env(var, "http://127.0.0.1:#{F.closed_port()}")

      on_exit(fn ->
        for var <- ["HTTPS_PROXY", "https_proxy", "ALL_PROXY"], do: System.delete_env(var)
      end)

      conn = connect(ctx, ok_answer())

      assert {:ok, [proxy: {:undefined, []}, https_proxy: {:undefined, []}]} =
               :httpc.get_options([:proxy, :https_proxy], conn.profile)

      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)
    end

    test "the default timeout is above poll_max plus a margin; a slower answer times out",
         ctx do
      assert Transport.timeout_ms() > 25_000

      conn = connect(ctx, served(fn c -> Process.sleep(1_000) && json(c, 200, %{}) end))

      capture_log(fn ->
        assert Transport.request(get(), conn: conn, timeout: 200) == {:error, :timeout}
      end)
    end

    test "a request without an open connection, or with a path that is not one, sends nothing",
         ctx do
      conn = connect(ctx, ok_answer())

      capture_log(fn ->
        assert Transport.request(get(), []) == {:error, :not_open}
        assert Transport.request(get("//evil.test/x"), conn: conn) == {:error, :invalid_path}
        assert Transport.request(get("x"), conn: conn) == {:error, :invalid_path}
      end)

      refute_received {:served, _, _, _, _}
    end
  end

  describe "the token" do
    test "no token in errors", ctx do
      untrusted = connect(ctx, ok_answer(), cacertfile: F.cacertfile(F.pki(), ctx.home))
      slow = connect(ctx, served(fn c -> Process.sleep(1_000) && json(c, 200, %{}) end))

      moved =
        connect(
          ctx,
          served(
            &(&1
              |> Plug.Conn.put_resp_header("location", "/")
              |> Plug.Conn.send_resp(302, ""))
          )
        )

      {:ok, closed} =
        Transport.open(@name, "https://localhost:#{F.closed_port()}",
          home: ctx.home,
          cacertfile: ctx.cacertfile
        )

      on_exit(fn -> Transport.close(closed) end)

      log =
        capture_log(fn ->
          for {conn, opts} <- [{untrusted, []}, {slow, [timeout: 200]}, {moved, []}, {closed, []}] do
            assert {:error, reason} = Transport.request(get(), [conn: conn] ++ opts)
            refute full(reason) =~ ctx.token
            assert {:error, reason} = Transport.stream(get(), [conn: conn] ++ opts)
            refute full(reason) =~ ctx.token
          end
        end)

      assert log =~ "failed"
      refute log =~ ctx.token
    end

    test "is in no :sys.get_state or :sys.get_status of a process that keeps the connection",
         ctx do
      conn = connect(ctx, ok_answer())
      refute full(conn) =~ ctx.token
      assert {:ok, %{status: 200}} = Transport.request(get(), conn: conn)

      holder = start_supervised!({Holder, conn})
      refute full(:sys.get_state(holder)) =~ ctx.token
      refute full(:sys.get_status(holder)) =~ ctx.token

      manager = Process.whereis(:"httpc_#{conn.profile}")
      assert is_pid(manager)
      refute full(:sys.get_status(manager)) =~ ctx.token
    end

    # The test's captured log, and every event of every process as logger's handlers get it
    # (after the primary filters). At :debug, with whole terms: only then does the
    # translator print a crashed process's state uncut.
    defp raw_log(fun) do
      inspect_opts = Application.fetch_env!(:logger, :translator_inspect_opts)
      level = Logger.level()
      Logger.configure(level: :debug)

      Application.put_env(:logger, :translator_inspect_opts,
        limit: :infinity,
        printable_limit: :infinity
      )

      :ok =
        :logger.add_handler(:sources_test_raw, RawLog, %{level: :all, config: %{test: self()}})

      try do
        text = capture_log(fun)
        Process.sleep(100)
        {text, collect_raw([])}
      after
        :logger.remove_handler(:sources_test_raw)
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

    test "is redacted from any log event while open, in a binary or a charlist, at any depth",
         ctx do
      conn = connect(ctx, ok_answer())
      assert [{filter, _} | _] = :logger.get_primary_config().filters
      assert filter == conn.filter
      header = String.to_charlist("Bearer " <> ctx.token)

      {text, events} =
        raw_log(fn ->
          Logger.error("plain #{ctx.token} text")
          :logger.error(~c"format ~p", [[{~c"authorization", header}]])
          :logger.error(%{deep: {:request, [%{headers: [{~c"authorization", header}]}]}})
        end)

      assert length(events) == 3
      assert text =~ "[redacted]"
      refute text =~ ctx.token
      refute full(events) =~ ctx.token

      Transport.close(conn)
      refute List.keymember?(:logger.get_primary_config().filters, conn.filter, 0)
    end

    test "is in no log when :httpc's request handler crashes mid-request", ctx do
      test = self()

      conn =
        connect(ctx, fn c ->
          send(test, {:holding, self()})

          receive do
            :release -> json(c, 200, %{})
          after
            5_000 -> json(c, 200, %{})
          end
        end)

      {text, events} =
        raw_log(fn ->
          {:ok, _caller} =
            Task.start(fn -> send(test, {:answer, Transport.request(get(), conn: conn)}) end)

          assert_receive {:holding, server}, 5_000
          manager = Process.whereis(:"httpc_#{conn.profile}")

          assert [handler] =
                   for(
                     {_, pid, _, _} <- Supervisor.which_children(:httpc_handler_sup),
                     is_pid(pid),
                     {:links, links} = Process.info(pid, :links),
                     manager in links or
                       match?({:https, ~c"localhost", _}, :proc_lib.get_label(pid)) or
                       match?({:https, "localhost", _}, :proc_lib.get_label(pid)),
                     do: pid
                   )

          # The handler's state holds the request, headers and all.
          :ok = :sys.terminate(handler, {:forced_crash, :mid_request})
          send(test, {:crashed, handler})
          assert_receive {:answer, {:error, _}}, 5_000
          send(server, :release)
        end)

      refute text =~ ctx.token
      assert_received {:crashed, handler}

      assert [crash] =
               Enum.filter(
                 events,
                 &match?(%{meta: %{crash_reason: _, domain: [:otp | _], pid: ^handler}}, &1)
               )

      assert full(crash) =~ "forced_crash"
      assert full(crash) =~ "Bearer [redacted]"
      refute full(events) =~ ctx.token
    end
  end
end
