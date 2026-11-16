defmodule AtlasFlow.Runtime.ClientHttpTest do
  @moduledoc """
  `AtlasFlow.Runtime.Client.Http`'s translation (Runtime design §8.3, plan §6 F1.1) against
  a stub HTTP server that answers what each test scripts: every status and problem type,
  the headers it sends, one request per call, and the configuration. The contract test
  (`http_contract_test.exs`) runs the same client against the real Runtime.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Runtime.{Config, Link}
  alias AtlasFlow.Runtime.Client.Http, as: C

  @token_env "ATLAS_FLOW_CLIENT_TEST_TOKEN"

  defmodule Stub do
    @moduledoc false
    # Answers each request with the reply the test set (`reply/1`), and tells the test.
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(owner), do: owner

    @impl true
    def call(conn, owner) do
      {:ok, body, conn} = read_body(conn)
      conn = fetch_query_params(conn)

      send(
        owner,
        {:stub, conn.method, conn.request_path, conn.query_params, conn.req_headers, body}
      )

      {status, headers, reply} = :persistent_term.get({__MODULE__, owner})

      Enum.reduce(headers, conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      |> send_resp(status, reply)
    end
  end

  setup do
    owner = self()
    reply(200, %{})

    {:ok, pid} =
      Bandit.start_link(plug: {Stub, owner}, ip: {127, 0, 0, 1}, port: 0, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    previous = System.get_env(@token_env)
    System.put_env(@token_env, "t0ken")

    on_exit(fn ->
      if previous, do: System.put_env(@token_env, previous), else: System.delete_env(@token_env)
      :persistent_term.erase({Stub, owner})
    end)

    %{m: %Config{name: "stub", url: "http://127.0.0.1:#{port}", token_env: @token_env}}
  end

  defp reply(status, body, headers \\ [])

  defp reply(status, body, headers) when is_map(body) do
    type = if status >= 400, do: "application/problem+json", else: "application/json"
    reply(status, JSON.encode!(body), [{"content-type", type} | headers])
  end

  defp reply(status, body, headers) when is_binary(body),
    do: :persistent_term.put({Stub, self()}, {status, headers, body})

  @work %{"work_id" => "w-1", "revision" => 1, "state" => "buffered", "attempts" => []}

  defp problem(type, extra \\ %{}), do: Map.merge(%{"type" => type, "title" => "x"}, extra)

  describe "§8.3: answers to outcomes" do
    test "submit: 201 accepted, 200 existing", %{m: m} do
      reply(201, @work)
      assert {:accepted, @work} = C.submit(m, "TK-1", %{title: "t"})
      reply(200, @work)
      assert {:existing, @work} = C.submit(m, "TK-1", %{title: "t"})
    end

    test "503 of type at-capacity is at_capacity with Retry-After's seconds", %{m: m} do
      reply(503, problem("at-capacity", %{"reason" => "full", "retry_after" => 7}), [
        {"retry-after", "60"}
      ])

      assert {:at_capacity, 60} = C.submit(m, "TK-1", %{})
      assert {:at_capacity, 60} = C.retry(m, "w-1", false)

      # Without the header, the body's retry_after.
      reply(503, problem("at-capacity", %{"retry_after" => 7}))
      assert {:at_capacity, 7} = C.submit(m, "TK-1", %{})
    end

    test "unreachable: a 503 without type at-capacity, 502, 504, 500, a page that is no answer",
         %{m: m} do
      for {status, body} <- [
            {503, problem("service-unavailable")},
            {503, ""},
            {503, "<html>busy</html>"},
            {502, ""},
            {504, "Bad gateway"},
            {500, problem("internal")},
            {404, "<html>not here</html>"},
            {404, ""},
            {410, ""},
            {400, "bad"},
            {200, "not json"},
            {201, %{"not" => "a work"}},
            {302, ""}
          ] do
        if is_map(body), do: reply(status, body), else: reply(status, body, [])
        assert {:unreachable, _} = C.submit(m, "TK-1", %{}), "#{status} #{inspect(body)}"
        assert {:unreachable, _} = C.find_work(m, "TK-1"), "#{status} #{inspect(body)}"
        assert {:unreachable, _} = C.capacity(m), "#{status} #{inspect(body)}"
      end
    end

    test "a connection error is unreachable", %{m: m} do
      {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, port} = :inet.port(socket)
      :gen_tcp.close(socket)
      closed = %{m | url: "http://127.0.0.1:#{port}"}
      assert {:unreachable, %Req.TransportError{}} = C.submit(closed, "TK-1", %{})
      assert {:unreachable, _} = C.get_work(closed, "w-1")
      assert {:unreachable, _} = C.list_work(closed, 3)
      assert {:unreachable, _} = C.events(closed, nil)
    end

    test "refusals by problem type", %{m: m} do
      for {status, type, reason} <- [
            {409, "idempotency-conflict", :conflict},
            {400, "invalid", :invalid},
            {403, "not-permitted", :not_permitted},
            {422, "policy-forbids", :policy_forbids},
            {422, "no-permitted-option", :no_permitted_option},
            {422, "resume-unavailable", :resume_unavailable},
            {422, "unsupported-workspace", :unsupported_workspace},
            {401, "unauthenticated", :unauthenticated},
            {403, "origin-refused", :origin_refused},
            {404, "no-route", :no_route}
          ] do
        reply(status, problem(type, %{"reason" => "x"}))
        assert {:refused, ^reason} = C.submit(m, "TK-1", %{}), type
      end

      # A problem type the Runtime does not declare is not its answer.
      reply(422, problem("made-up"))
      assert {:unreachable, {:status, 422}} = C.submit(m, "TK-1", %{})
    end

    test "404 not-found is never seen; 410 pruned names the work and its kind", %{m: m} do
      reply(404, problem("not-found"))
      assert :not_found = C.find_work(m, "TK-1")
      assert :not_found = C.get_work(m, "w-1")
      assert :not_found = C.retry(m, "w-1", true)
      assert :not_found = C.cancel(m, "w-1", :force, nil)

      reply(410, problem("pruned", %{"work_id" => "w-1", "kind" => "completed"}))
      assert {:pruned, "w-1", "completed"} = C.find_work(m, "TK-1")
      assert {:pruned, "w-1", "completed"} = C.get_work(m, "w-1")
    end

    test "reads, list, capacity, retry and cancel", %{m: m} do
      reply(200, @work)
      assert {:found, @work} = C.get_work(m, "w-1")
      assert {:found, @work} = C.find_work(m, "TK-1")
      assert {:ended, @work} = C.cancel(m, "w-1", :graceful, nil)
      reply(202, @work)
      assert {:cancelling, @work} = C.cancel(m, "w-1", :force, "unassigned")
      reply(201, @work)
      assert {:accepted, @work} = C.retry(m, "w-1", true)
      reply(200, %{"works" => [@work], "sequence" => 9})
      assert {:works, [@work], 9} = C.list_work(m, 4)
      capacity = %{"slots" => %{"free" => 1}, "accepting" => true}
      reply(200, capacity)
      assert {:capacity, ^capacity} = C.capacity(m)
    end
  end

  describe "what is sent" do
    test "submit: Idempotency-Key is the task key, the body is the request as given without client_key",
         %{m: m} do
      reply(201, @work)
      request = %{title: "t", client_key: "not-this", after_check: %{command: ["bin/check"]}}
      C.submit(m, "TK-pk-1-1", request)

      assert_receive {:stub, "POST", "/v1/work", _, headers, body}
      assert {"idempotency-key", "TK-pk-1-1"} in headers
      assert {"authorization", "Bearer t0ken"} in headers
      assert {"content-type", "application/json"} in headers

      assert JSON.decode!(body) == %{
               "title" => "t",
               "after_check" => %{"command" => ["bin/check"]}
             }

      refute_received {:stub, _, _, _, _, _}
    end

    test "the paths and parameters of each capability", %{m: m} do
      reply(200, @work)
      C.get_work(m, "w/1 x")
      assert_receive {:stub, "GET", "/v1/work/w%2F1%20x", _, _, ""}
      C.find_work(m, "TK-1")
      assert_receive {:stub, "GET", "/v1/work", %{"key" => "TK-1"}, _, ""}
      C.list_work(m, 12)
      assert_receive {:stub, "GET", "/v1/work", %{"changed_since" => "12"}, _, ""}
      C.list_work(m, nil)
      assert_receive {:stub, "GET", "/v1/work", params, _, ""} when params == %{}
      C.capacity(m)
      assert_receive {:stub, "GET", "/v1/capacity", _, _, ""}
      C.retry(m, "w-1", true)
      assert_receive {:stub, "POST", "/v1/work/w-1/attempts", _, _, body}
      assert JSON.decode!(body) == %{"resume" => true}
      C.cancel(m, "w-1", :force, "why")
      assert_receive {:stub, "POST", "/v1/work/w-1/cancel", _, _, body}
      assert JSON.decode!(body) == %{"mode" => "force", "reason" => "why"}
    end

    test "no token in the environment: no Authorization header", %{m: m} do
      System.delete_env(@token_env)
      reply(200, @work)
      C.get_work(m, "w-1")
      assert_receive {:stub, "GET", _, _, headers, _}
      refute List.keymember?(headers, "authorization", 0)
    end

    test "one request per call: the client never retries", %{m: m} do
      for {status, body} <- [
            {503, problem("other")},
            {502, ""},
            {500, ""},
            {503, problem("at-capacity")}
          ] do
        if is_map(body), do: reply(status, body), else: reply(status, body, [])

        for call <- [
              fn -> C.submit(m, "TK-1", %{}) end,
              fn -> C.get_work(m, "w-1") end,
              fn -> C.find_work(m, "TK-1") end,
              fn -> C.list_work(m, 1) end,
              fn -> C.capacity(m) end,
              fn -> C.retry(m, "w-1", false) end,
              fn -> C.cancel(m, "w-1", :graceful, nil) end
            ] do
          call.()
          assert_receive {:stub, _, _, _, _, _}
          refute_receive {:stub, _, _, _, _, _}, 300
        end
      end
    end
  end

  describe "configuration" do
    test "empty by default: no machinery, no link" do
      assert Application.get_env(:atlas_flow, :machinery) == nil
      assert Config.all() == %{}
      assert Link.children() == []
      assert Config.fetch("mac-mini") == :error
    end

    test "a machinery map: name → URL, token variable, optional CONNECT proxy; one link each" do
      Application.put_env(:atlas_flow, :machinery, %{
        "mac-mini" => %{
          "url" => "https://mini.example.ts.net/",
          "token_env" => "T",
          "proxy" => "http://localhost:1055"
        },
        other: [url: "http://127.0.0.1:4000", token_env: "U"]
      })

      on_exit(fn -> Application.delete_env(:atlas_flow, :machinery) end)

      assert {:ok,
              %Config{url: "https://mini.example.ts.net", proxy: {:http, "localhost", 1055}} =
                mini} =
               Config.fetch("mac-mini")

      assert {:ok, %Config{proxy: nil} = other} = Config.fetch("other")

      assert C.new(mini, :get, "/v1/capacity").options.connect_options[:proxy] ==
               {:http, "localhost", 1055, []}

      refute Keyword.has_key?(C.new(other, :get, "/v1/capacity").options.connect_options, :proxy)
      assert C.new(other, :get, "/v1/capacity").options.retry == false

      assert [%{id: {Link, "mac-mini"}}, %{id: {Link, "other"}}] =
               Enum.sort_by(Link.children(), & &1.id)
    end

    test "a malformed machinery is refused" do
      for entry <- [
            %{url: "mini:4000", token_env: "T"},
            %{url: "ftp://mini", token_env: "T"},
            %{url: "https://mini"},
            %{url: "https://mini", token_env: "T", proxy: "localhost"}
          ] do
        assert_raise ArgumentError, fn -> Config.new!("m", entry) end
      end
    end
  end
end
