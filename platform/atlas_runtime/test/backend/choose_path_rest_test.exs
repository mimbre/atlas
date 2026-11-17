Code.require_file("support.exs", __DIR__)

defmodule AtlasRuntime.Backend.ChoosePathRestTest do
  @moduledoc """
  D44 over REST (design §3.1, §3.2, §3.5, §8.1; s5a-plan P11, B26, B31, B32): the real
  router (`AtlasRuntime.Backend.Rest`) on the real work core (`AtlasRuntime.WorkHarness`),
  served by Bandit on the loopback TCP listener (Bearer tokens, never `choose_path`) and on
  `backend.sock` (the owner, with it).

  - A token never names a folder (403 `not-permitted`), and nothing of a socket client's
    `folder` work it reads through `read_all` carries a path, its frozen-result reads
    included. Over `backend.sock` the same submit is accepted.
  - A token's problem bodies carry `type` and `reason`, never a `detail`; the socket's
    carry it (403, 409, 422).
  - `read_all` grants reading, never acting: a token's `cancel` and `retry` of the
    socket's work are 403 and change nothing; without `read_all` they are 404.
  """
  use ExUnit.Case, async: false

  import AtlasRuntime.WorkHarness, except: [request: 3, request: 2]

  alias AtlasRuntime.Backend.{Clients, Listener, TcpListener, TestSocket}

  @moduletag capture_log: true

  # Every TCP right (§8.1); `solo` has no read_all.
  @flow "Zmxvdy1lbmdpbmUtdG9rZW4tZm9yLXRlc3Rz"
  @solo "c29sby10b2tlbi1mb3ItdGVzdHMtMTIzNDU"

  # Two buffered works fit beside two busy slots (the token's and the socket's, below).
  @policy %{
    "buffer_size" => 2,
    "profiles" => %{
      "light_work" => %{
        "permissions" => ["read-only", "workspace-write", "materialized-folder"],
        "cost_classes" => ["low", "standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      },
      # A repository work a token may submit; it stays buffered while both slots are busy.
      "repo_work" => %{
        "permissions" => ["dedicated-repository"],
        "cost_classes" => ["standard"],
        "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
      }
    }
  }

  setup do
    bench = start!(@policy)
    home = TestSocket.home()
    on_exit(fn -> File.rm_rf!(home) end)
    port = free_port()
    write_clients!(home, port, entries())

    start_supervised!({TcpListener, home: home, router: AtlasRuntime.Backend.Rest})
    start_supervised!({Listener, home: home, router: AtlasRuntime.Backend.Rest})

    %{
      bench: bench,
      home: home,
      port: port,
      flow: {port, [{"authorization", "Bearer " <> @flow}]},
      solo: {port, [{"authorization", "Bearer " <> @solo}]},
      socket: {{:local, Listener.path(home)}, []}
    }
  end

  defp sha(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp entries(flow_rights \\ ["submit", "cancel", "read", "read_all"]) do
    [
      %{"name" => "flow", "token_sha256" => sha(@flow), "rights" => flow_rights},
      %{"name" => "solo", "token_sha256" => sha(@solo), "rights" => ["submit", "cancel", "read"]}
    ]
  end

  defp write_clients!(home, port, clients) do
    path = Clients.path(home)

    File.write!(
      path,
      JSON.encode!(%{"version" => 1, "listen" => %{"port" => port}, "clients" => clients})
    )

    File.chmod!(path, 0o600)
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  ## HTTP/1.1 on the listeners, raw, read to the close (a `{:raw, binary}` body is sent as is)

  defp http({connect, auth}, method, path, headers \\ [], body \\ nil) do
    {address, port} =
      case connect do
        {:local, _} = local -> {local, 0}
        port -> {{127, 0, 0, 1}, port}
      end

    body =
      case body do
        nil -> ""
        {:raw, binary} -> binary
        body -> JSON.encode!(body)
      end

    {:ok, socket} = :gen_tcp.connect(address, port, [:binary, active: false], 2_000)
    lines = for {k, v} <- auth ++ headers, do: [k, ": ", v, "\r\n"]

    :ok =
      :gen_tcp.send(socket, [
        method,
        " ",
        path,
        " HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-type: application/json\r\n",
        "content-length: ",
        Integer.to_string(byte_size(body)),
        "\r\n",
        lines,
        "\r\n",
        body
      ])

    raw = recv_all(socket, [])
    :gen_tcp.close(socket)
    [head, rest] = :binary.split(raw, "\r\n\r\n")
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", code | _] = String.split(status_line, " ")

    headers =
      for line <- header_lines do
        [k, v] = String.split(line, ": ", parts: 2)
        {String.downcase(k), v}
      end

    %{status: String.to_integer(code), headers: headers, body: rest}
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, data} -> recv_all(socket, [acc, data])
      {:error, _closed} -> IO.iodata_to_binary(acc)
    end
  end

  defp json(%{body: body}), do: JSON.decode!(body)

  defp problem(reply, status, type) do
    assert reply.status == status, "#{reply.status}: #{reply.body}"
    assert {"content-type", "application/problem+json"} in reply.headers
    body = json(reply)
    assert %{"type" => ^type, "status" => ^status} = body
    body
  end

  defp submit(listener, request, key) do
    http(listener, "POST", "/v1/work", [{"idempotency-key", key}], request)
  end

  defp folder(bench, instructions), do: AtlasRuntime.WorkHarness.request(bench, instructions)

  defp repository(title, profile \\ "repo_work") do
    %{
      "title" => title,
      "instructions" => "Fix the bug.",
      "profile" => profile,
      "cost_class" => "standard",
      "workspace" => %{
        "kind" => "repository",
        "url" => "https://example.test/r.git",
        "branch" => "fix",
        "base" => "develop"
      }
    }
  end

  # Every value under a "path" key, at any depth.
  defp paths(value) when is_map(value),
    do:
      Enum.flat_map(value, fn
        {"path", path} when is_binary(path) -> [path]
        {_key, inner} -> paths(inner)
      end)

  defp paths(value) when is_list(value), do: Enum.flat_map(value, &paths/1)
  defp paths(_value), do: []

  defp await_http(listener, work_id, check) do
    await(fn ->
      reply = http(listener, "GET", "/v1/work/" <> work_id)
      reply.status == 200 and check.(json(reply)) and json(reply)
    end)
  end

  # Both slots busy with the socket's hanging works, so the next accepted work stays buffered.
  defp fill_slots(ctx) do
    for n <- 1..2 do
      reply = submit(ctx.socket, folder(ctx.bench, "hang #{n}"), "hang-#{n}")
      assert reply.status == 201, reply.body
      work = json(reply)
      await_http(ctx.socket, work["work_id"], &(&1["state"] == "running"))
    end
  end

  describe "D44: a token never names a path, and never sees one" do
    test "a folder submit: 403 not-permitted for a token, nothing stored; 201 over backend.sock (m4)",
         ctx do
      request = folder(ctx.bench, "complete for the socket")

      body = problem(submit(ctx.flow, request, "k-folder"), 403, "not-permitted")
      assert body["reason"] == "not_permitted"
      refute Map.has_key?(body, "detail")
      assert paths(body) == []
      refute JSON.encode!(body) =~ request.workspace.path

      assert %{status: 404} = http(ctx.flow, "GET", "/v1/work?key=k-folder")
      assert %{status: 200} = reply = http(ctx.flow, "GET", "/v1/work")
      assert json(reply)["works"] == []

      reply = submit(ctx.socket, request, "k-folder")
      assert reply.status == 201, reply.body
      assert json(reply)["request"]["workspace"]["path"] == request.workspace.path

      # Not even an operator gives a token choose_path: an entry naming it is outside the
      # TCP ceiling, so the file is invalid, and the request is refused before the router.
      write_clients!(ctx.home, ctx.port, entries(["submit", "read", "read_all", "choose_path"]))
      reply = submit(ctx.flow, folder(ctx.bench, "complete for an operator"), "k-folder-2")
      problem(reply, 401, "unauthenticated")
      assert paths(json(reply)) == []
    end

    test "a socket client's folder work, read with read_all: no path anywhere, frozen reads included",
         ctx do
      request = folder(ctx.bench, "complete for me")
      reply = submit(ctx.socket, request, "k-mine")
      assert reply.status == 201
      id = json(reply)["work_id"]

      own = await_http(ctx.socket, id, &(&1["state"] == "completed"))
      own_paths = paths(own)
      # The socket client sees where it ran: its folder, and the turn's resume point.
      assert request.workspace.path in own_paths
      assert length(own_paths) >= 2

      for reply <- [
            http(ctx.flow, "GET", "/v1/work/" <> id),
            http(ctx.flow, "GET", "/v1/work"),
            http(ctx.flow, "GET", "/v1/work?state=completed")
          ] do
        assert reply.status == 200, reply.body
        assert paths(json(reply)) == []
        refute reply.body =~ ctx.bench.dir
        for path <- own_paths, do: refute(reply.body =~ path)
      end

      assert json(http(ctx.flow, "GET", "/v1/work/" <> id))["work_id"] == id

      # A plain folder is never frozen (B8): both reads are 404, with no path in them.
      for path <- [
            "/frozen",
            "/frozen?fingerprint=csf_x",
            "/frozen/blobs/" <> String.duplicate("a", 64)
          ] do
        reply = http(ctx.flow, "GET", "/v1/work/#{id}/attempts/1" <> path)
        problem(reply, 404, "not-found")
        refute reply.body =~ ctx.bench.dir
      end

      # An attempt that is no integer is the router's 400, naming no path either.
      reply = http(ctx.flow, "GET", "/v1/work/#{id}/attempts/one/frozen")
      problem(reply, 400, "invalid")
      refute reply.body =~ ctx.bench.dir
    end
  end

  describe "D44: no router text for a token repeats a home path (designer, 2026-11-17)" do
    # Every refusal the router or the input check writes itself: one request per text that
    # once repeated the value, the key or the path. Each holds the home path, and the 400
    # (404 for no route) names the field, never the value.
    test "decode errors, invalid fields, unknown fields and parameters, unknown routes", ctx do
      home = System.user_home!() <> "/"
      enc = URI.encode_www_form(home)
      base = repository("probe")
      ws = base["workspace"]

      cases = [
        {"wrong type", "POST", "/v1/work", %{base | "title" => [home <> "p2"]}, 400,
         "work_request.title must be a string, got a list"},
        {"bad enum value", "POST", "/v1/work", %{base | "cost_class" => home <> "p1"}, 400,
         "work_request.cost_class must be one of"},
        {"bad tag", "POST", "/v1/work", %{base | "workspace" => %{ws | "kind" => home <> "p4"}},
         400, "work_request.workspace.kind must be one of"},
        {"a non-object where an object belongs", "POST", "/v1/work",
         %{base | "workspace" => home <> "p5"}, 400,
         "work_request.workspace must be one of repository"},
        {"an unknown top-level field", "POST", "/v1/work", Map.put(base, home <> "p3", 1), 400,
         "the body has an unknown field"},
        {"an unknown nested field", "POST", "/v1/work",
         %{base | "workspace" => Map.put(ws, home <> "p9", 1)}, 400,
         "work_request.workspace has an unknown field"},
        {"broken JSON holding a path", "POST", "/v1/work", {:raw, ~s({"title": "#{home}p6)}, 400,
         "the body is no JSON"},
        {"the attempt is a path", "GET", "/v1/work/w/attempts/#{enc}p8/frozen", nil, 400,
         "get_frozen_input.attempt must be an integer, got a string"},
        {"an unknown query parameter name", "GET", "/v1/work/w/attempts/1/frozen?#{enc}p7=1", nil,
         400, "the query has an unknown parameter"},
        {"an unknown query parameter twice", "GET",
         "/v1/work/w/attempts/1/frozen?#{enc}p7=1&#{enc}p7=2", nil, 400,
         "a query parameter is given twice"},
        {"no route under /v1", "GET", "/v1/#{enc}p10", nil, 404,
         "no resource for this method and path"},
        {"no route at the home path", "GET", home <> "p11", nil, 404,
         "no resource for this method and path"}
      ]

      for {name, method, path, body, status, detail} <- cases do
        reply = http(ctx.flow, method, path, [], body)
        problem_body = problem(reply, status, if(status == 404, do: "no-route", else: "invalid"))
        assert problem_body["detail"] =~ detail, "#{name}: #{reply.body}"
        refute reply.body =~ home, "#{name}: #{reply.body}"
        refute reply.body =~ String.trim_trailing(home, "/"), "#{name}: #{reply.body}"
      end

      # Nothing of it was stored.
      assert json(http(ctx.flow, "GET", "/v1/work"))["works"] == []
    end
  end

  describe "refusal details (B32): a token's problem body has type and reason, no detail (m5)" do
    test "403 not-permitted, 409 idempotency-conflict and 422 policy-forbids", ctx do
      fill_slots(ctx)

      # 422: a repository on a profile that does not permit it.
      for {listener, detail?} <- [{ctx.flow, false}, {ctx.socket, true}] do
        body =
          problem(
            submit(listener, repository("no repo here", "light_work"), "k-422"),
            422,
            "policy-forbids"
          )

        assert body["reason"] == "policy_forbids"
        assert Map.has_key?(body, "detail") == detail?
        if detail?, do: assert(is_binary(body["detail"]) and body["detail"] != "")
      end

      # 409: the same client key, another request. The token's first one stays buffered.
      reply = submit(ctx.flow, repository("first"), "k-409")
      assert reply.status == 201, reply.body
      tokens_work = json(reply)["work_id"]
      body = problem(submit(ctx.flow, repository("second"), "k-409"), 409, "idempotency-conflict")
      assert body["reason"] == "conflict"
      refute Map.has_key?(body, "detail")

      assert submit(ctx.socket, folder(ctx.bench, "complete first"), "k-409").status == 201

      body =
        problem(
          submit(ctx.socket, folder(ctx.bench, "complete second"), "k-409"),
          409,
          "idempotency-conflict"
        )

      assert body["detail"] =~ "k-409"

      # 403: the token's folder submit, and, for the socket, acting on the token's work
      # (Ownership; the socket holds read_all).
      body =
        problem(submit(ctx.flow, folder(ctx.bench, "complete no"), "k-403"), 403, "not-permitted")

      assert body["reason"] == "not_permitted"
      refute Map.has_key?(body, "detail")

      body =
        problem(
          http(ctx.socket, "POST", "/v1/work/#{tokens_work}/cancel", [], %{"mode" => "graceful"}),
          403,
          "not-permitted"
        )

      assert body["reason"] == "not_permitted"
      assert is_binary(body["detail"]) and body["detail"] != ""
    end
  end

  describe "Ownership (B31): read_all reads, never acts" do
    test "a read_all token's cancel and retry of the socket's work → 403, unchanged; without read_all → 404 (m6)",
         ctx do
      reply = submit(ctx.socket, folder(ctx.bench, "hang until cancelled"), "k-own")
      assert reply.status == 201
      id = json(reply)["work_id"]
      running = await_http(ctx.socket, id, &(&1["state"] == "running"))
      before = http(ctx.socket, "GET", "/v1/work/" <> id)

      cancel = &http(&1, "POST", "/v1/work/#{id}/cancel", [], %{"mode" => "force"})
      retry = &http(&1, "POST", "/v1/work/#{id}/attempts", [], %{"resume" => false})

      for call <- [cancel, retry] do
        body = problem(call.(ctx.flow), 403, "not-permitted")
        assert body["reason"] == "not_permitted"
        refute Map.has_key?(body, "detail")
        problem(call.(ctx.solo), 404, "not-found")
      end

      after_ = http(ctx.socket, "GET", "/v1/work/" <> id)
      assert json(after_)["revision"] == running["revision"]
      assert List.keyfind(after_.headers, "etag", 0) == List.keyfind(before.headers, "etag", 0)
      assert json(after_)["state"] == "running"
      assert length(json(after_)["attempts"]) == 1
      refute Map.get(List.last(json(after_)["attempts"]), "cancel_stage")

      # The socket, its owner, still cancels it.
      assert cancel.(ctx.socket).status == 202
    end
  end
end
