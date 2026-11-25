defmodule AtlasFlow.Backend.RouterTest do
  # Plan m3 A3: the carriage itself. The credential before the router (401), the routes'
  # bodies and their limits (an oversized body, a second poll, too many streams, the
  # request rate), the streamed put_blob body, a long-poll answered early by a grant and
  # at poll_max empty, and the loopback-only bind. A stand-in work source records what
  # reaches it; the long-poll cases run on the real Dispatch (FakeFacts, a manual
  # clock). Asserted on statuses, problem types, headers, calls and counts; never on text.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.Backend.{Listener, Router}
  alias AtlasFlow.Backend.Listener.Limits
  alias AtlasFlow.FakeFacts
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Credentials
  require AtlasTestAwait, as: Await

  @mib 1_048_576

  defmodule Source do
    @moduledoc "A work source that tells the test what reached it, and answers as told."
    def poll(client, input, opts), do: answer(:poll, client, input, opts)
    def report(client, input, opts), do: answer(:report, client, input, opts)
    def get_blob(client, input, opts), do: answer(:get_blob, client, input, opts)
    def put_blob(client, input, opts), do: answer(:put_blob, client, input, opts)

    defp answer(capability, client, input, opts) do
      send(opts[:test], {capability, client, input, self()})

      case opts[capability] do
        nil -> default(capability)
        fun -> fun.(input)
      end
    end

    defp default(:poll),
      do:
        {:polled,
         %{leases: [], cancel: [], lease_lost: [], timing: %{lease_ttl: 900, poll_max: 25}}}

    defp default(:report), do: {:recorded, %{missing: []}}
    defp default(:get_blob), do: :not_found
    defp default(:put_blob), do: :stored
  end

  @credentials %{
    "mini" => %{holder: "ada", token_sha256: Credentials.token_sha256("tok-mini")},
    "laptop" => %{holder: "bea", token_sha256: Credentials.token_sha256("tok-laptop")}
  }

  defp plug(router), do: %{credentials: @credentials, router: Router.init(router)}

  defp stub(extra \\ []),
    do: [source: Source, source_opts: Keyword.merge([test: self()], extra)]

  defp request(method, path, body, opts) do
    conn = Plug.Test.conn(method, path, body)

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {k, v}, conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    conn =
      case Keyword.get(opts, :token, "tok-mini") do
        nil -> conn
        token -> Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
      end

    Listener.call(conn, Keyword.get_lazy(opts, :plug, fn -> plug(stub()) end))
  end

  defp poll_body(runtime_id \\ "mini"),
    do:
      JSON.encode!(%{
        runtime_id: runtime_id,
        incarnation: "inc-1",
        build: "test",
        policy_version: 1,
        offer: %{"deep_coding" => 1},
        holdings: []
      })

  defp problem_type(conn), do: JSON.decode!(conn.resp_body)["type"]

  defp content_type(conn), do: Plug.Conn.get_resp_header(conn, "content-type")

  describe "the credential comes before the router" do
    test "without a valid bearer token: 401 unauthenticated, and the router never runs" do
      for token <- [nil, "", "nope", "tok-min", "tok-mini-x"] do
        conn = request(:post, "/v1/poll", poll_body(), token: token)
        assert conn.status == 401
        assert problem_type(conn) == "unauthenticated"
        assert content_type(conn) == ["application/problem+json"]
      end

      # Not even an unknown route is told apart: the router has not run.
      conn = request(:get, "/v1/elsewhere", "", token: "nope")
      assert {conn.status, problem_type(conn)} == {401, "unauthenticated"}

      wrong_scheme =
        request(:post, "/v1/poll", poll_body(),
          token: nil,
          headers: [{"authorization", "Basic tok-mini"}]
        )

      assert wrong_scheme.status == 401
      refute_received {_, _, _, _}
    end

    test "a valid token is its Runtime and holder, from the credential only" do
      conn = request(:post, "/v1/poll", poll_body("mini"), token: "tok-laptop")
      assert conn.status == 200
      assert_received {:poll, {"laptop", "bea"}, %{"runtime_id" => "mini"}, _}

      conn = request(:post, "/v1/poll", poll_body(), headers: [], token: "tok-mini")
      assert conn.status == 200
      assert_received {:poll, {"mini", "ada"}, _, _}
    end
  end

  describe "routes" do
    test "an unknown route or method is no-route; nothing reaches the source" do
      for {method, path} <- [
            {:get, "/v1/poll"},
            {:post, "/v1/elsewhere"},
            {:delete, "/v1/leases/L/blobs/abc"},
            {:post, "/v1/leases/L/blobs/abc"},
            {:get, "/v1/leases/L/reports"},
            {:get, "/v1/leases//blobs/abc"}
          ] do
        conn = request(method, path, "", [])
        assert {conn.status, problem_type(conn)} == {404, "no-route"}, "#{method} #{path}"
      end

      refute_received {_, _, _, _}
    end

    test "a body that is no JSON object of the route's fields is invalid; nothing reaches the source" do
      for body <- ["", "[]", "nope", JSON.encode!(%{runtime_id: "mini", extra: 1})] do
        conn = request(:post, "/v1/poll", body, [])
        assert {conn.status, problem_type(conn)} == {400, "invalid"}
        refute Map.has_key?(JSON.decode!(conn.resp_body), "reason")
      end

      conn =
        request(:post, "/v1/leases/L/reports", JSON.encode!(%{lease_id: "M", revision: 1}), [])

      assert {conn.status, problem_type(conn)} == {400, "invalid"}
      refute_received {_, _, _, _}
    end

    test "IS-Atlas-27: a poll may report a refused configuration, and its answer carry one" do
      refused = %{"version" => 3, "reason" => "invalid: slots"}

      body =
        poll_body()
        |> JSON.decode!()
        |> Map.put("configuration_refused", refused)
        |> JSON.encode!()

      polled =
        {:polled,
         %{
           leases: [],
           cancel: [],
           lease_lost: [],
           timing: %{lease_ttl: 900, poll_max: 25},
           configuration: ~s({"version":4})
         }}

      conn = request(:post, "/v1/poll", body, plug: plug(stub(poll: fn _ -> polled end)))
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["configuration"] == ~s({"version":4})
      assert_received {:poll, _, %{"configuration_refused" => ^refused}, _}

      # None served: the answer has no such field.
      conn = request(:post, "/v1/poll", poll_body(), [])
      refute Map.has_key?(JSON.decode!(conn.resp_body), "configuration")
    end

    test "IS-Atlas-26: a poll may report an upgrade, and its answer carry one" do
      report = %{"id" => "RU-01", "step" => "draining", "busy" => ["dev1"], "mode" => "draining"}
      body = poll_body() |> JSON.decode!() |> Map.put("upgrade", report) |> JSON.encode!()

      polled =
        {:polled,
         %{
           leases: [],
           cancel: [],
           lease_lost: [],
           timing: %{lease_ttl: 900, poll_max: 25},
           upgrade: %{id: "RU-01", build: "b2", extra: "dropped"}
         }}

      conn = request(:post, "/v1/poll", body, plug: plug(stub(poll: fn _ -> polled end)))
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["upgrade"] == %{"id" => "RU-01", "build" => "b2"}
      assert_received {:poll, _, %{"upgrade" => ^report}, _}

      conn = request(:post, "/v1/poll", poll_body(), [])
      refute Map.has_key?(JSON.decode!(conn.resp_body), "upgrade")
    end

    test "the path's parameters go to the source with the body's fields" do
      body = JSON.encode!(%{revision: 2, report: %{state: "started"}})
      conn = request(:post, "/v1/leases/L~1~x/reports", body, [])
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{"missing" => []}

      assert_received {:report, _,
                       %{
                         "lease_id" => "L~1~x",
                         "revision" => 2,
                         "report" => %{"state" => "started"}
                       }, _}
    end

    test "an outcome from 400 up is problem+json with its type and its fields" do
      conn =
        request(
          :post,
          "/v1/leases/L/reports",
          JSON.encode!(%{revision: 3, report: %{state: "started"}}),
          plug: plug(stub(report: fn _ -> {:rejected, :conflict} end))
        )

      assert conn.status == 409
      assert content_type(conn) == ["application/problem+json"]

      assert %{"type" => "revision-conflict", "status" => 409, "reason" => "conflict"} =
               JSON.decode!(conn.resp_body)
    end
  end

  describe "body limits" do
    test "a poll body past 1 MiB is too-large, before the source" do
      big = JSON.encode!(%{runtime_id: String.duplicate("x", @mib)})
      conn = request(:post, "/v1/poll", big, [])
      assert {conn.status, problem_type(conn)} == {413, "too-large"}

      declared =
        request(:post, "/v1/poll", poll_body(), headers: [{"content-length", "#{@mib + 1}"}])

      assert {declared.status, problem_type(declared)} == {413, "too-large"}
      refute_received {_, _, _, _}
    end

    test "a report body may hold up to 8 MiB, not more" do
      report = fn bytes ->
        JSON.encode!(%{
          revision: 1,
          report: %{state: "refused", reason: "invalid", detail: bytes}
        })
      end

      fits = request(:post, "/v1/leases/L/reports", report.(String.duplicate("x", 2 * @mib)), [])
      assert fits.status == 200
      assert_received {:report, _, _, _}

      over = request(:post, "/v1/leases/L/reports", report.(String.duplicate("x", 8 * @mib)), [])
      assert {over.status, problem_type(over)} == {413, "too-large"}
      refute_received {:report, _, _, _}
    end
  end

  describe "put_blob's streamed body" do
    defp put(body, headers, router \\ stub()) do
      request(:put, "/v1/leases/L/blobs/#{L.sha256("abc")}", body,
        headers: headers,
        plug: plug(router)
      )
    end

    @octets [{"content-type", "application/octet-stream"}]

    test "it goes to the source as a lazy stream, with the declared size" do
      read = fn input ->
        send(self(), {:read, Enum.to_list(input["content"])})
        :stored
      end

      conn = put("abc", @octets ++ [{"blob-size", "3"}], stub(put_blob: read))
      assert conn.status == 200
      assert JSON.decode!(conn.resp_body) == %{}

      assert_received {:put_blob, {"mini", "ada"},
                       %{"lease_id" => "L", "size" => 3, "content" => content}, _}

      refute is_binary(content)
      assert_received {:read, chunks}
      assert IO.iodata_to_binary(chunks) == "abc"
      assert Plug.Conn.get_resp_header(conn, "connection") == []
    end

    test "nothing is read before the source reads; at most Blob-Size + 1 bytes are" do
      untouched = fn _input -> :lease_lost end
      conn = put("abc", @octets ++ [{"blob-size", "3"}], stub(put_blob: untouched))
      assert {conn.status, problem_type(conn)} == {410, "lease-lost"}
      # Answered before the body was read: the connection is closed.
      assert Plug.Conn.get_resp_header(conn, "connection") == ["close"]

      greedy = fn input ->
        send(self(), {:read, IO.iodata_to_binary(Enum.to_list(input["content"]))})
        {:rejected, :digest_mismatch}
      end

      conn =
        put(String.duplicate("x", 100), @octets ++ [{"blob-size", "3"}], stub(put_blob: greedy))

      # Past Blob-Size the body is too-large, whatever the source made of its bytes.
      assert {conn.status, problem_type(conn)} == {413, "too-large"}
      assert Plug.Conn.get_resp_header(conn, "connection") == ["close"]
      assert_received {:read, read}
      assert byte_size(read) == 4
    end

    test "another content type is unsupported-media-type; no or a bad Blob-Size is invalid" do
      for headers <- [[], [{"content-type", "application/json"}]] do
        conn = put("abc", headers ++ [{"blob-size", "3"}])
        assert {conn.status, problem_type(conn)} == {415, "unsupported-media-type"}
      end

      for size <- [nil, "x", "-1", "3.0"] do
        headers = if size, do: @octets ++ [{"blob-size", size}], else: @octets
        conn = put("abc", headers)
        assert {conn.status, problem_type(conn)} == {400, "invalid"}
      end

      ok = put("abc", [{"content-type", "Application/Octet-Stream; x=y"}, {"blob-size", "3"}])
      assert ok.status == 200
      assert_received {:put_blob, _, _, _}
      refute_received {:put_blob, _, _, _}
    end

    test "a declared length past the blob limit is too-large, before the source" do
      headers = @octets ++ [{"blob-size", "3"}, {"content-length", "20000001"}]
      conn = put("abc", headers)
      assert {conn.status, problem_type(conn)} == {413, "too-large"}

      # The Runtime's router's order: 415, then 413 by Content-Length, then 400 (Blob-Size).
      both = put("abc", @octets ++ [{"blob-size", "x"}, {"content-length", "20000001"}])
      assert {both.status, problem_type(both)} == {413, "too-large"}
      refute_received {:put_blob, _, _, _}
    end

    test "the source's outcomes are their declared statuses and types" do
      for {answer, status, type} <- [
            {:too_large, 413, "too-large"},
            {:not_referenced, 409, "not-referenced"},
            {:lease_lost, 410, "lease-lost"},
            {{:rejected, :invalid}, 400, "invalid"}
          ] do
        conn = put("abc", @octets ++ [{"blob-size", "3"}], stub(put_blob: fn _ -> answer end))
        assert {conn.status, problem_type(conn)} == {status, type}
      end
    end
  end

  describe "get_blob's answer" do
    test "chunked, one chunk per element, with Blob-Sha256 and Blob-Size" do
      sha = L.sha256("abcdef")
      content = Stream.map(["ab", "cd", "ef"], &(send(self(), {:chunk, &1}) && &1))
      blob = fn _ -> {:blob, %{sha256: sha, size: 6, content: content}} end

      conn = request(:get, "/v1/leases/L/blobs/#{sha}", "", plug: plug(stub(get_blob: blob)))
      assert conn.status == 200
      assert conn.state == :chunked
      assert content_type(conn) == ["application/octet-stream"]
      assert Plug.Conn.get_resp_header(conn, "blob-sha256") == [sha]
      assert Plug.Conn.get_resp_header(conn, "blob-size") == ["6"]
      assert conn.resp_body == "abcdef"
      for c <- ~w(ab cd ef), do: assert_received({:chunk, ^c})
      assert_received {:get_blob, _, %{"lease_id" => "L", "sha256" => ^sha}, _}
    end

    test "not_found is 404 not-found" do
      conn = request(:get, "/v1/leases/L/blobs/abc", "", [])
      assert {conn.status, problem_type(conn)} == {404, "not-found"}
    end
  end

  describe "limits per credential (Q9)" do
    setup do
      name = :"limits-#{System.unique_integer([:positive])}"
      start_supervised!({Limits, name: name, now: fn -> 0 end})
      %{limits: name}
    end

    test "past 10 requests a second, the answer is delayed, never refused", %{limits: limits} do
      test = self()
      router = stub() ++ [limits: limits, sleep: &send(test, {:slept, &1})]

      for _ <- 1..12 do
        assert request(:post, "/v1/poll", poll_body(), plug: plug(router)).status == 200
      end

      assert_received {:slept, 100}
      assert_received {:slept, 200}
      refute_received {:slept, _}

      # Another credential has its own rate.
      assert request(:post, "/v1/poll", poll_body(), token: "tok-laptop", plug: plug(router)).status ==
               200

      refute_received {:slept, _}
    end

    test "at most 4 blob streams at once per Runtime; a fifth waits for one to end",
         %{limits: limits} do
      test = self()

      held = fn _input ->
        content =
          Stream.resource(
            fn -> send(test, {:streaming, self()}) end,
            fn
              :done ->
                {:halt, :done}

              _ ->
                receive do
                  :go -> {["x"], :done}
                end
            end,
            fn _ -> :ok end
          )

        {:blob, %{sha256: "s", size: 1, content: content}}
      end

      router = stub(get_blob: held) ++ [limits: limits]

      get = fn token ->
        Task.async(fn ->
          request(:get, "/v1/leases/L/blobs/s", "", token: token, plug: plug(router)).status
        end)
      end

      first = for _ <- 1..4, do: get.("tok-mini")
      holders = for _ <- 1..4, do: assert_receive({:streaming, pid}) && pid
      fifth = get.("tok-mini")

      assert_eventually(limits, fn -> Limits.status(limits)["mini"] == %{held: 4, waiting: 1} end)
      refute_received {:streaming, _}

      # Another Runtime is not held up.
      other = get.("tok-laptop")
      assert_receive {:streaming, laptop}
      send(laptop, :go)
      assert Task.await(other) == 200

      # One ends: the fifth gets its slot.
      send(hd(holders), :go)
      assert_receive {:streaming, fifth_pid}
      send(fifth_pid, :go)
      assert Task.await(fifth) == 200

      for pid <- tl(holders), do: send(pid, :go)
      assert Enum.map(first, &Task.await/1) == [200, 200, 200, 200]

      assert_eventually(limits, fn ->
        Limits.status(limits)["mini"] in [nil, %{held: 0, waiting: 0}]
      end)
    end

    test "a stream whose holder dies frees its slot", %{limits: limits} do
      test = self()

      holders =
        for _ <- 1..4 do
          spawn(fn ->
            Limits.stream(limits, "mini", fn ->
              send(test, :holding)
              Process.sleep(:infinity)
            end)
          end)
        end

      for _ <- 1..4, do: assert_receive(:holding)
      waiter = Task.async(fn -> Limits.stream(limits, "mini", fn -> :ran end) end)
      assert_eventually(limits, fn -> Limits.status(limits)["mini"] == %{held: 4, waiting: 1} end)
      Process.exit(hd(holders), :kill)
      assert Task.await(waiter) == :ran
      for pid <- tl(holders), do: Process.exit(pid, :kill)
    end
  end

  describe "the long-poll, on Dispatch" do
    setup do
      dir = Path.join(System.tmp_dir!(), "router-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      ctx = L.start(dir, poll_wait: 25_000)
      for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
      ctx
    end

    defp http_poll(token \\ "tok-mini") do
      runtime_id = if token == "tok-laptop", do: "laptop", else: "mini"

      Task.async(fn ->
        conn = request(:post, "/v1/poll", poll_body(runtime_id), token: token, plug: plug([]))
        {conn.status, JSON.decode!(conn.resp_body)}
      end)
    end

    test "a held poll is answered early by a grant", ctx do
      poll = http_poll()
      assert Task.yield(poll, 100) == nil

      %{task: task} = L.supervised_task("B-1", "ada")
      AtlasFlow.Dispatch.ready(task)

      assert {200, %{"leases" => [%{"lease_id" => lease, "work" => %{"work_key" => ^task}}]}} =
               Task.await(poll)

      assert is_binary(lease)
      _ = ctx
    end

    test "at poll_max a held poll is answered, empty", ctx do
      poll = http_poll()
      assert Task.yield(poll, 100) == nil
      L.advance(ctx, 25)
      assert {200, %{"leases" => [], "cancel" => [], "lease_lost" => []}} = Task.await(poll)
    end

    test "a second poll of the same Runtime answers the first at once, empty", ctx do
      first = http_poll()
      assert Task.yield(first, 100) == nil
      second = http_poll()
      assert {200, %{"leases" => []}} = Task.await(first)
      assert Task.yield(second, 100) == nil

      # Another Runtime's poll does not answer it.
      other = http_poll("tok-laptop")
      assert Task.yield(second, 100) == nil

      L.advance(ctx, 25)
      assert {200, _} = Task.await(second)
      assert {200, _} = Task.await(other)
    end
  end

  describe "the listener" do
    test "it binds 127.0.0.1 and nothing else" do
      for ip <- [
            {0, 0, 0, 0},
            {10, 0, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            "0.0.0.0",
            "::",
            "localhost"
          ] do
        assert {:error, :not_loopback} =
                 Listener.start_link(port: 0, ip: ip, credentials: @credentials, name: :refused)
      end

      name = :"listener-#{System.unique_integer([:positive])}"
      start_supervised!({Listener, port: 0, credentials: @credentials, name: name})
      assert {:ok, {{127, 0, 0, 1}, port}} = Listener.address(name)
      assert port > 0

      # A request over the socket: the credential before anything else.
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

      :ok =
        :gen_tcp.send(
          socket,
          "POST /v1/poll HTTP/1.1\r\nhost: flow\r\ncontent-length: 2\r\n\r\n{}"
        )

      {:ok, answer} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.close(socket)
      assert answer =~ ~r/\AHTTP\/1\.1 401 /
    end

    test "it does not start without valid credentials, or without a port" do
      assert {:error, :credentials} = Listener.start_link(port: 0, name: :no_credentials)
      assert {:error, :port} = Listener.start_link(credentials: @credentials, name: :no_port)
    end

    test "the application starts a listener only with a port" do
      assert AtlasFlow.Application.listener(lease_ttl: 900) == []

      assert [{Listener, opts}] = AtlasFlow.Application.listener(port: 4801)
      assert opts[:port] == 4801
      refute Keyword.has_key?(opts, :ip)
    end
  end

  describe "chunked bodies over the socket (review B1)" do
    # Through the real Listener on 127.0.0.1, raw HTTP/1.1 with `Transfer-Encoding: chunked`:
    # Bandit reads such a body whole whatever `length:` says, so the caps hold only because
    # the router counts the bytes itself (AtlasBodyLimit). An oversized body is answered 413
    # with `connection: close`; the server closes with bytes unread, so the client may see a
    # reset instead of the answer; what reached the source is asserted either way.
    setup do
      test = self()
      name = :"chunked-#{System.unique_integer([:positive])}"

      read = fn input ->
        bytes = input["content"] |> Enum.to_list() |> IO.iodata_to_binary()
        send(test, {:blob_read, byte_size(bytes)})
        if bytes == "abc", do: :stored, else: {:rejected, :digest_mismatch}
      end

      router = [source: Source, source_opts: [test: test, put_blob: read]]

      start_supervised!(
        {Listener, port: 0, credentials: @credentials, name: name, router: router}
      )

      {:ok, {_ip, port}} = Listener.address(name)
      %{port: port}
    end

    defp chunked(method, path, headers, body, opts \\ []) do
      piece = Keyword.get(opts, :piece, 64 * 1024)
      token = Keyword.get(opts, :token, "tok-mini")

      head =
        ["#{method} #{path} HTTP/1.1\r\nhost: flow\r\ntransfer-encoding: chunked\r\n"] ++
          Enum.map([{"authorization", "Bearer #{token}"} | headers], fn {k, v} ->
            "#{k}: #{v}\r\n"
          end) ++ ["\r\n"]

      chunks =
        Stream.map(body, fn data ->
          [Integer.to_string(byte_size(data), 16), "\r\n", data, "\r\n"]
        end)

      {IO.iodata_to_binary(head), Stream.concat(chunks, ["0\r\n\r\n"]), piece}
    end

    # `size` bytes of `byte`, in pieces of 64 KiB.
    defp bytes(size, byte \\ ?x) do
      piece = 64 * 1024
      full = :binary.copy(<<byte>>, piece)

      Stream.concat(Stream.duplicate(full, div(size, piece)), [
        :binary.copy(<<byte>>, rem(size, piece))
      ])
      |> Stream.reject(&(&1 == ""))
    end

    defp split(binary, piece \\ 1000),
      do:
        for(<<c::binary-size(piece) <- binary>>, do: c) ++
          [
            binary_part(
              binary,
              div(byte_size(binary), piece) * piece,
              rem(byte_size(binary), piece)
            )
          ]

    # Sends from another process (it tells how many bytes went out before the server
    # stopped taking them) and reads one answer: {status, headers, body} or :reset.
    defp exchange(port, {head, body, _piece}) do
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
      test = self()

      spawn(fn ->
        sent =
          Enum.reduce_while(Stream.concat([head], body), 0, fn part, sent ->
            case :gen_tcp.send(socket, part) do
              :ok -> {:cont, sent + IO.iodata_length(part)}
              _closed -> {:halt, sent}
            end
          end)

        send(test, {:sent, sent})
      end)

      answer = answer(socket, "")
      assert_receive {:sent, sent}, 30_000
      send(self(), {:sent_in_all, sent})
      :gen_tcp.close(socket)
      answer
    end

    defp answer(socket, buffer) do
      with [head, rest] <- :binary.split(buffer, "\r\n\r\n"),
           [status_line | lines] = String.split(head, "\r\n"),
           headers =
             Map.new(lines, fn line ->
               [k, v] = String.split(line, ":", parts: 2)
               {String.downcase(k), String.trim(v)}
             end),
           length = String.to_integer(Map.get(headers, "content-length", "0")),
           true <- byte_size(rest) >= length do
        [_, status | _] = String.split(status_line, " ")
        {String.to_integer(status), headers, binary_part(rest, 0, length)}
      else
        _incomplete ->
          receive do
            {:tcp, ^socket, data} -> answer(socket, buffer <> data)
            {:tcp_closed, ^socket} -> :reset
            {:tcp_error, ^socket, _reason} -> :reset
          after
            10_000 -> flunk("no answer; got #{inspect(buffer)}")
          end
      end
    end

    defp too_large(:reset), do: :ok

    defp too_large({status, headers, body}) do
      assert {status, JSON.decode!(body)["type"]} == {413, "too-large"}
      assert headers["content-type"] =~ "application/problem+json"
      assert headers["connection"] == "close"
    end

    test "a poll body past 1 MiB is too-large; the source is not called", %{port: port} do
      big = JSON.encode!(%{runtime_id: String.duplicate("x", 3 * @mib)})
      too_large(exchange(port, chunked("POST", "/v1/poll", [], split(big, 64 * 1024))))
      assert_received {:sent_in_all, _}
      # 30 MiB sent: Bandit alone would take every byte; the cap stops the server early.
      too_large(exchange(port, chunked("POST", "/v1/poll", [], bytes(30 * @mib, ?\s))))
      assert_received {:sent_in_all, sent}
      assert sent < 30 * @mib
      refute_received {:poll, _, _, _}
    end

    test "a report body past 8 MiB is too-large; the source is not called", %{port: port} do
      too_large(exchange(port, chunked("POST", "/v1/leases/L/reports", [], bytes(30 * @mib))))
      assert_received {:sent_in_all, sent}
      assert sent < 30 * @mib
      refute_received {:report, _, _, _}
    end

    test "a put_blob body past Blob-Size + 1 is too-large; the stream stopped there",
         %{port: port} do
      octets = [{"content-type", "application/octet-stream"}]
      path = "/v1/leases/L/blobs/#{L.sha256("abc")}"

      too_large(
        exchange(port, chunked("PUT", path, octets ++ [{"blob-size", "3"}], bytes(30 * @mib)))
      )

      assert_received {:blob_read, 4}
      assert_received {:sent_in_all, sent}
      assert sent < 30 * @mib

      sized = octets ++ [{"blob-size", "2000000"}]
      too_large(exchange(port, chunked("PUT", path, sized, bytes(3 * @mib))))
      assert_received {:blob_read, 2_000_001}
    end

    test "chunked bodies within their caps are served", %{port: port} do
      assert {200, _, _} = exchange(port, chunked("POST", "/v1/poll", [], split(poll_body())))
      assert_received {:poll, {"mini", "ada"}, %{"runtime_id" => "mini"}, _}

      report =
        JSON.encode!(%{
          revision: 1,
          report: %{state: "refused", reason: "invalid", detail: String.duplicate("x", 2 * @mib)}
        })

      assert {200, _, _} =
               exchange(
                 port,
                 chunked("POST", "/v1/leases/L/reports", [], split(report, 64 * 1024))
               )

      assert_received {:report, _, _, _}

      put = [{"content-type", "application/octet-stream"}, {"blob-size", "3"}]

      assert {200, headers, _} =
               exchange(
                 port,
                 chunked("PUT", "/v1/leases/L/blobs/#{L.sha256("abc")}", put, ["a", "bc"])
               )

      assert_received {:blob_read, 3}
      refute headers["connection"] == "close"
    end

    test "without a credential: 401, and the unread body is not drained", %{port: port} do
      request = chunked("POST", "/v1/poll", [], bytes(30 * @mib), token: "wrong")

      case exchange(port, request) do
        :reset -> :ok
        {status, headers, _} -> assert {status, headers["connection"]} == {401, "close"}
      end

      assert_received {:sent_in_all, sent}
      assert sent < 30 * @mib
    end
  end

  # `check` once it holds, re-checked after each message the Limits server has handled.
  defp assert_eventually(limits, check), do: assert(Await.until(check, wake: {:trace, limits}))
end
