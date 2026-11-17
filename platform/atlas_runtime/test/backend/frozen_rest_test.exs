Code.require_file("support.exs", __DIR__)

defmodule AtlasRuntime.Backend.FrozenRestTest do
  @moduledoc """
  S5a P11 (design §3.9, §8.2, §8.3; s5a-plan B1, B15): the frozen-result reads over REST,
  through the test facade (`AtlasRuntime.Test.WorkFacade` on `AtlasRuntime.Test.FakeWork`).

      GET /v1/work/{id}/attempts/{n}/frozen?fingerprint=   get_frozen
      GET /v1/work/{id}/attempts/{n}/frozen/blobs/{sha256} get_frozen_blob

  Every outcome × status, the blob as `application/octet-stream` bytes (never JSON, never
  held whole) through Plug, Bandit on `backend.sock` and on the TCP listener, and a real
  `:httpc` download through the remote client (`AtlasRuntime.Remote`). What a reader may
  see is the core's decision (s5a-plan P8); here only that the router hands the facade the
  listener's client, a token with its own rights.
  """
  # FakeWork's answers, the OS environment and the :httpc profile are global.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias AtlasRuntime.Backend.{Clients, Listener, TcpListener, TestSocket}
  alias AtlasRuntime.Remote
  alias AtlasRuntime.Remote.Config
  alias AtlasRuntime.RemoteFixtures, as: RF
  alias AtlasRuntime.RemoteFixtures.Proxy
  alias AtlasRuntime.Test.{FakeWork, WorkRest}
  alias AtlasRuntime.Test.WorkFacade, as: F

  @socket {"local:test", [:submit, :cancel, :read, :read_all, :choose_slot, :choose_path]}
  @csf_a "csf_" <> String.duplicate("a", 64)
  @csf_b "csf_" <> String.duplicate("b", 64)
  @sha String.duplicate("5", 64)

  setup do
    FakeWork.reset_all()
    FakeWork.owner(self())
    on_exit(&FakeWork.reset_all/0)
  end

  ## Values

  defp frozen(work_id \\ "w-1", attempt \\ 1) do
    %F.Outcome.Frozen{
      work_id: work_id,
      attempt: attempt,
      base: "sha256:" <> String.duplicate("0", 64),
      roots: [
        %F.FrozenRoot{
          root: "atlas",
          fingerprint: @csf_a,
          entries: [
            %F.ChangeEntry{
              path: "docs/a b.md",
              op: :write,
              kind: :file,
              mode: :"100644",
              size: 3,
              sha256: @sha
            },
            %F.ChangeEntry{
              path: "bin/link",
              op: :write,
              kind: :symlink,
              mode: :"120000",
              size: 6,
              sha256: @sha,
              target: "../run"
            },
            %F.ChangeEntry{path: "gone", op: :delete}
          ]
        },
        %F.FrozenRoot{root: "other", fingerprint: @csf_b, entries: []}
      ]
    }
  end

  # get_frozen as a core answers it (P8): a fingerprint must match one root's.
  defp answer_frozen(answer \\ &frozen/0) do
    FakeWork.answer(:get_frozen, fn _client, input ->
      frozen = answer.()

      cond do
        is_nil(input.fingerprint) -> frozen
        Enum.any?(frozen.roots, &(&1.fingerprint == input.fingerprint)) -> frozen
        true -> %F.Outcome.FingerprintMismatch{}
      end
    end)
  end

  # A blob of `size` bytes in `chunk`-byte pieces, each made only as it is read.
  defp bytes(size, chunk) do
    Stream.unfold(0, fn
      offset when offset >= size ->
        nil

      offset ->
        {:binary.copy(<<rem(div(offset, 7), 251)>>, min(chunk, size - offset)), offset + chunk}
    end)
  end

  defp sha256(enumerable),
    do:
      enumerable
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

  defp answer_blob(size, chunk \\ 65_536) do
    content = bytes(size, chunk)
    sha = sha256(content)

    FakeWork.answer(:get_frozen_blob, fn _client, _input ->
      %F.Outcome.Blob{sha256: sha, size: size, content: content}
    end)

    sha
  end

  defp request(method, path, client \\ @socket) do
    conn(method, path, "") |> assign(:client, client) |> WorkRest.call(WorkRest.init([]))
  end

  defp problem(conn, status, type) do
    assert conn.status == status, "#{conn.status}: #{conn.resp_body}"
    assert get_resp_header(conn, "content-type") == ["application/problem+json"]
    body = JSON.decode!(conn.resp_body)
    assert %{"type" => ^type, "status" => ^status, "title" => _} = body
    body
  end

  defp called(capability) do
    assert_received {:fake_work, ^capability, client, input}
    {client, input}
  end

  describe "GET /v1/work/{id}/attempts/{n}/frozen: get_frozen" do
    test "frozen → 200, the change set per root with each fingerprint, as JSON" do
      answer_frozen()
      conn = request("GET", "/v1/work/w-1/attempts/2/frozen")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json"]

      assert JSON.decode!(conn.resp_body) ==
               F.Frozen.dump(struct(F.Frozen, Map.from_struct(frozen())))

      assert %{
               "roots" => [
                 %{"root" => "atlas", "fingerprint" => @csf_a, "entries" => [_, _, delete]},
                 _
               ]
             } =
               JSON.decode!(conn.resp_body)

      # A delete carries its path only.
      assert delete == %{"path" => "gone", "op" => "delete"}

      assert {@socket, %F.GetFrozenInput{work_id: "w-1", attempt: 2, fingerprint: nil}} =
               called(:get_frozen)
    end

    test "?fingerprint= reaches the facade; one that matches a root → 200" do
      answer_frozen()
      conn = request("GET", "/v1/work/w-1/attempts/1/frozen?fingerprint=" <> @csf_b)

      assert conn.status == 200
      assert {_, %F.GetFrozenInput{fingerprint: @csf_b}} = called(:get_frozen)
    end

    test "fingerprint_mismatch → 409 fingerprint-mismatch (m1, m3)" do
      answer_frozen()

      body =
        problem(
          request("GET", "/v1/work/w-1/attempts/1/frozen?fingerprint=csf_nope"),
          409,
          "fingerprint-mismatch"
        )

      assert Map.keys(body) |> Enum.sort() == ["status", "title", "type"]
      assert {_, %F.GetFrozenInput{fingerprint: "csf_nope"}} = called(:get_frozen)
    end

    test "pruned → 410 pruned, not_found → 404 not-found" do
      FakeWork.answer(:get_frozen, fn _, _ ->
        %F.Outcome.Pruned{work_id: "w-1", kind: :completed}
      end)

      body = problem(request("GET", "/v1/work/w-1/attempts/1/frozen"), 410, "pruned")
      assert %{"work_id" => "w-1", "kind" => "completed"} = body

      FakeWork.answer(:get_frozen, fn _, _ -> %F.Outcome.NotFound{} end)
      body = problem(request("GET", "/v1/work/w-9/attempts/1/frozen"), 404, "not-found")
      assert Map.keys(body) |> Enum.sort() == ["status", "title", "type"]
    end
  end

  describe "GET /v1/work/{id}/attempts/{n}/frozen/blobs/{sha256}: get_frozen_blob" do
    test "blob → 200 application/octet-stream, chunked, byte-identical, sha256 and size in headers (m2)" do
      sha = answer_blob(1_000_003)
      conn = request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert get_resp_header(conn, "blob-sha256") == [sha]
      assert get_resp_header(conn, "blob-size") == ["1000003"]
      assert get_resp_header(conn, "content-length") == []
      assert conn.state == :chunked
      assert byte_size(conn.resp_body) == 1_000_003
      assert sha256([conn.resp_body]) == sha
      # Bytes, never a JSON value.
      assert {:error, _} = JSON.decode(conn.resp_body)

      assert {@socket, %F.GetFrozenBlobInput{work_id: "w-1", attempt: 1, sha256: @sha}} =
               called(:get_frozen_blob)
    end

    test "an empty blob is a 200 with no bytes" do
      sha = answer_blob(0)
      conn = request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha)
      assert conn.status == 200
      assert conn.resp_body == ""
      assert get_resp_header(conn, "blob-sha256") == [sha]
      assert get_resp_header(conn, "blob-size") == ["0"]
    end

    test "pruned → 410, not_found → 404: problem+json, never bytes" do
      FakeWork.answer(:get_frozen_blob, fn _, _ ->
        %F.Outcome.Pruned{work_id: "w-1", kind: :completed}
      end)

      problem(request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha), 410, "pruned")

      FakeWork.answer(:get_frozen_blob, fn _, _ -> %F.Outcome.NotFound{} end)
      problem(request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha), 404, "not-found")
    end
  end

  describe "the request" do
    test "an attempt that is not an integer → 400 invalid; the facade is not called" do
      for path <- [
            "/v1/work/w-1/attempts/one/frozen",
            "/v1/work/w-1/attempts/1.5/frozen",
            "/v1/work/w-1/attempts/one/frozen/blobs/" <> @sha
          ] do
        problem(request("GET", path), 400, "invalid")
      end

      refute_received {:fake_work, _, _, _}
    end

    test "an undeclared query parameter → 400 invalid; the facade is not called" do
      problem(request("GET", "/v1/work/w-1/attempts/1/frozen?root=atlas"), 400, "invalid")

      problem(
        request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/#{@sha}?fingerprint=x"),
        400,
        "invalid"
      )

      refute_received {:fake_work, _, _, _}
    end

    test "a client without read → 403 not-permitted before the facade's implementation" do
      problem(
        request("GET", "/v1/work/w-1/attempts/1/frozen", {"nobody", []}),
        403,
        "not-permitted"
      )

      problem(
        request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha, {"nobody", [:submit]}),
        403,
        "not-permitted"
      )

      refute_received {:fake_work, _, _, _}
    end

    test "submit → pruned is 410 pruned (from_work on a pruned result, B2)" do
      FakeWork.answer(:submit, fn _, _ -> %F.Outcome.Pruned{work_id: "w-0", kind: :completed} end)

      body =
        conn(
          "POST",
          "/v1/work",
          JSON.encode!(%{
            "title" => "t",
            "instructions" => "i",
            "profile" => "p",
            "cost_class" => "standard",
            "workspace" => %{
              "kind" => "from_work",
              "work_id" => "w-0",
              "permissions" => "read-only"
            }
          })
        )
        |> assign(:client, @socket)
        |> WorkRest.call(WorkRest.init([]))
        |> problem(410, "pruned")

      assert %{"work_id" => "w-0", "kind" => "completed"} = body
    end

    test "the frozen routes overlap no other route (I-R2); each request reaches its own capability" do
      routes = WorkRest.__routes__()
      paths = for r <- routes, do: {r.method, r.path}

      for {method, path} = route <- paths,
          String.contains?(path, "/frozen"),
          {other_method, other} = other_route <- paths,
          other_route != route,
          other_method == method do
        refute overlap?(path, other), "#{method} #{path} overlaps #{other}"
      end

      answer_frozen()
      answer_blob(3)
      FakeWork.answer(:retry, fn _, _ -> %F.Outcome.NotFound{} end)

      assert request("GET", "/v1/work/w-1/attempts/1/frozen").status == 200
      assert {_, %F.GetFrozenInput{}} = called(:get_frozen)
      assert request("GET", "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha).status == 200
      assert {_, %F.GetFrozenBlobInput{}} = called(:get_frozen_blob)
      assert request("POST", "/v1/work/w-1/attempts").status == 404
      assert {_, %F.RetryInput{work_id: "w-1"}} = called(:retry)
      assert request("GET", "/v1/work/w-1/attempts/1").status == 404
      refute_received {:fake_work, _, _, _}
    end
  end

  # Two paths overlap when they have as many segments and at each position the segments
  # are the same literal or one is a parameter.
  defp overlap?(a, b) do
    sa = String.split(a, "/", trim: true)
    sb = String.split(b, "/", trim: true)

    length(sa) == length(sb) and
      Enum.all?(Enum.zip(sa, sb), fn {x, y} ->
        x == y or String.starts_with?(x, [":", "{"]) or String.starts_with?(y, [":", "{"])
      end)
  end

  ## Over the listeners: Bandit sends the blob chunked, and a token is its own client.

  @reader "cmVhZGVyLXRva2VuLWZvci10ZXN0cy0xMjM"

  defp sha(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp tcp!(rights) do
    home = TestSocket.home()
    on_exit(fn -> File.rm_rf!(home) end)
    port = free_port()
    path = Clients.path(home)

    File.write!(
      path,
      JSON.encode!(%{
        "version" => 1,
        "listen" => %{"port" => port},
        "clients" => [%{"name" => "reader", "token_sha256" => sha(@reader), "rights" => rights}]
      })
    )

    File.chmod!(path, 0o600)
    start_supervised!({TcpListener, home: home, router: WorkRest})
    port
  end

  # A raw HTTP/1.1 GET on `connect` ({:local, path} or a loopback port), read to the close;
  # a chunked body is decoded and its chunk count kept.
  defp raw_get(connect, path, headers) do
    {address, port} =
      case connect do
        {:local, _} = local -> {local, 0}
        port when is_integer(port) -> {{127, 0, 0, 1}, port}
      end

    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false], 2_000)
    lines = for {k, v} <- headers, do: [k, ": ", v, "\r\n"]

    :ok =
      :gen_tcp.send(socket, [
        "GET ",
        path,
        " HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\n",
        lines,
        "\r\n"
      ])

    raw = recv_all(socket, [])
    :gen_tcp.close(socket)
    [head, body] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", code | _] = String.split(status_line, " ")

    headers =
      for line <- header_lines do
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end

    {body, chunks} =
      if {"transfer-encoding", "chunked"} in headers, do: dechunk(body, [], 0), else: {body, 0}

    %{status: String.to_integer(code), headers: headers, body: body, chunks: chunks}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> recv_all(socket, [acc, data])
      {:error, _closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp dechunk(data, acc, count) do
    [size, rest] = :binary.split(data, "\r\n")
    size = String.to_integer(size |> String.split(";") |> hd(), 16)

    if size == 0 do
      {IO.iodata_to_binary(acc), count}
    else
      <<piece::binary-size(size), "\r\n", rest::binary>> = rest
      dechunk(rest, [acc, piece], count + 1)
    end
  end

  describe "over the listeners" do
    test "TCP: a token with only read is its own client, with its own rights, for both reads" do
      port = tcp!(["read"])

      # As the core decides it (P8): only the caller's own work, without read_all.
      FakeWork.answer(:get_frozen, fn {_id, rights}, input ->
        if input.work_id == "mine" or :read_all in rights,
          do: frozen(input.work_id, input.attempt),
          else: %F.Outcome.NotFound{}
      end)

      auth = [{"authorization", "Bearer " <> @reader}]

      assert %{status: 200, body: body} = raw_get(port, "/v1/work/mine/attempts/1/frozen", auth)
      assert %{"work_id" => "mine", "attempt" => 1} = JSON.decode!(body)
      assert_received {:fake_work, :get_frozen, {"token:reader", [:read]}, _}

      assert %{status: 404} = raw_get(port, "/v1/work/theirs/attempts/1/frozen", auth)
      assert_received {:fake_work, :get_frozen, {"token:reader", [:read]}, _}

      answer_blob(10)

      assert %{status: 200} =
               raw_get(port, "/v1/work/mine/attempts/1/frozen/blobs/" <> @sha, auth)

      assert_received {:fake_work, :get_frozen_blob, {"token:reader", [:read]}, _}

      # Without a token, nothing is read.
      assert %{status: 401} = raw_get(port, "/v1/work/mine/attempts/1/frozen", [])
      refute_received {:fake_work, _, _, _}
    end

    test "TCP and backend.sock: Bandit sends a 5 MiB blob chunked, one chunk per element, byte-identical" do
      size = 5 * 1_048_576
      sha = answer_blob(size)
      port = tcp!(["read"])
      home = TestSocket.home()
      on_exit(fn -> File.rm_rf!(home) end)
      start_supervised!({Listener, home: home, router: WorkRest})

      for {connect, headers} <- [
            {port, [{"authorization", "Bearer " <> @reader}]},
            {{:local, Listener.path(home)}, []}
          ] do
        reply = raw_get(connect, "/v1/work/w-1/attempts/1/frozen/blobs/" <> @sha, headers)

        assert reply.status == 200
        assert {"content-type", "application/octet-stream"} in reply.headers
        assert {"transfer-encoding", "chunked"} in reply.headers
        assert {"blob-sha256", sha} in reply.headers
        assert {"blob-size", Integer.to_string(size)} in reply.headers
        refute List.keymember?(reply.headers, "content-length", 0)
        assert byte_size(reply.body) == size
        assert sha256([reply.body]) == sha
        assert reply.chunks == 80
      end
    end
  end

  describe "a real :httpc download (AtlasRuntime.Remote)" do
    @url "ATLAS_RUNTIME_BACKEND_URL"
    @token "ATLAS_RUNTIME_BACKEND_TOKEN"

    setup do
      on_exit(fn ->
        System.delete_env(@url)
        System.delete_env(@token)
      end)

      :ok
    end

    # The HTTPS stand-in serving the test router as the token's client, reached through the
    # CONNECT proxy, as AtlasRuntime.RemoteTest does.
    defp remote!(client) do
      pki = RF.pki()
      token = "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower)

      serve =
        start_supervised!(
          RF.serve_spec(
            fn conn -> conn |> assign(:client, client) |> WorkRest.call(WorkRest.init([])) end,
            pki
          )
        )

      proxy = start_supervised!({Proxy, mode: :tunnel})
      System.put_env(@url, "https://#{RF.host()}:#{RF.serve_port(serve)}")
      System.put_env(@token, token)
      start_supervised!({Config, proxy: {"localhost", Proxy.port(proxy)}, cacerts: pki.cacerts})
      :ok
    end

    test "the client gets the blob as a stream with its sha256 and size, byte-identical" do
      remote!({"token:reader", [:read]})
      size = 3 * 1_048_576 + 17
      sha = answer_blob(size)

      assert {:blob, %{sha256: ^sha, size: ^size, content: content}} =
               Remote.get_frozen_blob(%{work_id: "w-1", attempt: 1, sha256: @sha})

      assert sha256(content) == sha
      assert_received {:fake_work, :get_frozen_blob, {"token:reader", [:read]}, _}
    end

    test "the client gets frozen, fingerprint_mismatch, pruned and not_found apart" do
      remote!({"token:reader", [:read]})
      answer_frozen()

      assert {:frozen, %{work_id: "w-1", roots: [%{fingerprint: @csf_a}, _]}} =
               Remote.get_frozen(%{work_id: "w-1", attempt: 1})

      assert {:fingerprint_mismatch, %{}} =
               Remote.get_frozen(%{work_id: "w-1", attempt: 1, fingerprint: "csf_nope"})

      FakeWork.answer(:get_frozen_blob, fn _, _ ->
        %F.Outcome.Pruned{work_id: "w-1", kind: :completed}
      end)

      assert {:pruned, %{work_id: "w-1"}} =
               Remote.get_frozen_blob(%{work_id: "w-1", attempt: 1, sha256: @sha})

      FakeWork.answer(:get_frozen_blob, fn _, _ -> %F.Outcome.NotFound{} end)

      assert {:not_found, %{}} =
               Remote.get_frozen_blob(%{work_id: "w-1", attempt: 1, sha256: @sha})
    end
  end
end
