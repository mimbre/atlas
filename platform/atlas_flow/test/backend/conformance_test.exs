defmodule AtlasFlow.Backend.ConformanceTest do
  # Plan m3 A3: Flow's router serves exactly the Runtime's work source routes. The two
  # contract files are read at test time (the route description routes.json and the
  # boundary's work_source.json, both the Runtime's, never edited here):
  #
  # - the router's table equals routes.json: routes, parameters, request headers, the
  #   streamed body, every outcome's status and problem type (per reason for rejected),
  #   the blob's headers and content type, the errors, and the version;
  # - every outcome of every route, driven through the listener on the real work source
  #   (and a stand-in for the outcomes it cannot be made to give here), answers the status
  #   and type routes.json declares, and its body validates against work_source.json;
  #   so do the request bodies sent.
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias AtlasFlow.{Dispatch, FakeFacts}
  alias AtlasFlow.Backend.{Listener, Router}
  alias AtlasFlow.FakeFacts.Leasing, as: L
  alias AtlasFlow.WorkSource.Credentials

  @runtime Path.expand("../../../atlas_runtime", __DIR__)
  @routes_json Path.join(@runtime, "backend/targets/rest/work_source_api/routes.json")
  @schema_json Path.join(@runtime, "boundary/targets/json/work_source.json")
  @problem ~w(type title status)

  defp routes, do: @routes_json |> File.read!() |> JSON.decode!()
  defp schema, do: @schema_json |> File.read!() |> JSON.decode!()

  ## The table

  defp described(route) do
    %{
      key: {route["method"], route["path"], route["capability"]},
      params: route["params"],
      headers: Map.new(route["headers"], fn {name, %{"field" => f}} -> {name, f} end),
      upload: route["upload"] && {route["upload"]["content_type"], route["upload"]["field"]},
      outcomes: route["outcomes"] |> Enum.flat_map(&described_outcome/1) |> MapSet.new()
    }
  end

  defp described_outcome(%{"by" => "reason", "cases" => cases, "outcome" => name}),
    do: for(c <- cases, do: {name, c["value"], c["status"], c["type"]})

  defp described_outcome(o) do
    [
      {o["outcome"], nil, o["status"], o["type"], o["headers"], o["content_type"], o["stream"]}
    ]
  end

  defp served(route) do
    %{
      key: {route.method, route.path, Atom.to_string(route.capability)},
      params: Regex.scan(~r/\{([a-z0-9_]+)\}/, route.path) |> Enum.map(&List.last/1),
      headers: Map.new(route.headers, fn {name, f} -> {name, Atom.to_string(f)} end),
      upload: route.upload && {route.upload.content_type, Atom.to_string(route.upload.field)},
      outcomes: route.outcomes |> Enum.flat_map(&served_outcome/1) |> MapSet.new()
    }
  end

  defp served_outcome(%{cases: cases, outcome: name}),
    do: for(c <- cases, do: {Atom.to_string(name), Atom.to_string(c.value), c.status, c.type})

  defp served_outcome(o) do
    headers = Map.new(Map.get(o, :headers, %{}), fn {n, f} -> {n, Atom.to_string(f)} end)
    stream = o[:stream] && Atom.to_string(o.stream)
    [{Atom.to_string(o.outcome), nil, o.status, o[:type], headers, o[:content_type], stream}]
  end

  test "the router serves exactly the routes routes.json describes" do
    described = Map.new(routes()["routes"], &{described(&1).key, described(&1)})
    served = Map.new(Router.__routes__(), &{served(&1).key, served(&1)})

    assert Map.keys(served) |> MapSet.new() == Map.keys(described) |> MapSet.new()
    for {key, route} <- described, do: assert(served[key] == route, inspect(key))
  end

  test "the errors and the version are routes.json's" do
    described =
      for e <- routes()["errors"], into: MapSet.new(), do: {e["kind"], e["status"], e["type"]}

    served =
      for e <- Router.__errors__(),
          into: MapSet.new(),
          do: {Atom.to_string(e.kind), e.status, e.type}

    assert served == described
    assert Router.__version__() == routes()["version"]
    assert routes()["listeners"] == [%{"name" => "runtime", "rights" => ["lease"]}]
  end

  test "every capability routes.json carries is one of work_source.json's, with its outcomes" do
    capabilities = Map.new(schema()["capabilities"], &{&1["name"], &1})

    for route <- routes()["routes"] do
      declared =
        capabilities[route["capability"]]["outcomes"] |> Enum.map(& &1["name"]) |> MapSet.new()

      carried = route["outcomes"] |> Enum.map(& &1["outcome"]) |> MapSet.new()
      assert carried == declared, route["capability"]
    end
  end

  ## Every outcome, on the wire

  defmodule Stand do
    @moduledoc "A work source that gives the outcome the test names, for any capability."
    def poll(_c, _i, opts), do: opts[:answer]
    def report(_c, _i, opts), do: opts[:answer]
    def get_blob(_c, _i, opts), do: opts[:answer]

    def put_blob(_c, input, opts) do
      Stream.run(input["content"])
      opts[:answer]
    end
  end

  @credentials %{
    "mini" => %{holder: "ada", token_sha256: Credentials.token_sha256("tok-mini")}
  }

  setup do
    dir = Path.join(System.tmp_dir!(), "conformance-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    ctx = L.start(dir)
    for clerk <- ~w(ada bea), do: FakeFacts.put("clerk", %{"key" => clerk})
    ctx
  end

  defp call(method, path, body, opts \\ []) do
    conn =
      Enum.reduce(
        Keyword.get(opts, :headers, []),
        Plug.Test.conn(method, path, body),
        fn {k, v}, conn -> Plug.Conn.put_req_header(conn, k, v) end
      )

    conn =
      if Keyword.get(opts, :auth, true),
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer tok-mini"),
        else: conn

    router = Keyword.get(opts, :router, [])
    Listener.call(conn, %{credentials: @credentials, router: Router.init(router)})
  end

  defp stand(answer), do: [router: [source: Stand, source_opts: [answer: answer]]]

  defp poll_body(holdings \\ []) do
    %{
      "runtime_id" => "mini",
      "incarnation" => "inc-1",
      "build" => "test",
      "policy_version" => 1,
      "offer" => %{"deep_coding" => 1},
      "holdings" => for(h <- holdings, do: %{"lease_id" => h, "state" => "running"})
    }
  end

  # The outcome's status and type as routes.json declares it, and the body as
  # work_source.json types it. `nil` reason for an outcome without cases.
  defp conforms!(conn, capability, outcome, reason \\ nil) do
    route = Enum.find(routes()["routes"], &(&1["capability"] == capability))
    declared = Enum.find(route["outcomes"], &(&1["outcome"] == outcome))

    {status, type} =
      case declared do
        %{"cases" => cases} ->
          c = Enum.find(cases, &(&1["value"] == reason))
          {c["status"], c["type"]}

        %{"status" => status} = o ->
          {status, o["type"]}
      end

    assert conn.status == status, "#{capability} #{outcome}"
    model = model_of(capability, outcome)

    cond do
      declared["stream"] ->
        assert Plug.Conn.get_resp_header(conn, "content-type") == [declared["content_type"]]

        for {header, field} <- declared["headers"] do
          [text] = Plug.Conn.get_resp_header(conn, header)
          assert ok?(field_type(model, field), header_value(field_type(model, field), text))
        end

      status >= 400 ->
        assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/problem+json"]
        body = JSON.decode!(conn.resp_body)
        assert %{"type" => ^type, "status" => ^status, "title" => title} = body
        assert is_binary(title)
        fields = Map.drop(body, @problem)
        if model, do: assert(check(model, fields) == []), else: assert(fields == %{})
        if reason, do: assert(fields["reason"] == reason)

      true ->
        assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
        body = JSON.decode!(conn.resp_body)

        if model,
          do: assert(check(model, body) == [], inspect(check(model, body))),
          else: assert(body == %{})
    end

    conn
  end

  defp error!(conn, kind) do
    e = Enum.find(routes()["errors"], &(&1["kind"] == kind))
    assert conn.status == e["status"]
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/problem+json"]
    body = JSON.decode!(conn.resp_body)
    assert Map.keys(body) |> Enum.sort() == Enum.sort(@problem)
    assert body["type"] == e["type"]
  end

  defp model_of(capability, outcome) do
    cap = Enum.find(schema()["capabilities"], &(&1["name"] == capability))
    Enum.find(cap["outcomes"], &(&1["name"] == outcome))["model"]
  end

  defp request!(capability, body) do
    cap = Enum.find(schema()["capabilities"], &(&1["name"] == capability))
    assert check(cap["input"], body) == [], "#{capability} request"
    body
  end

  test "poll: polled with a lease, and rejected(invalid)" do
    %{task: _} = L.supervised_task("B-1", "ada")
    Dispatch.resync()

    conn = call(:post, "/v1/poll", JSON.encode!(request!("poll", poll_body())))
    conforms!(conn, "poll", "polled")
    assert [%{"lease_id" => _}] = JSON.decode!(conn.resp_body)["leases"]

    other = poll_body() |> Map.put("runtime_id", "laptop") |> then(&request!("poll", &1))
    conforms!(call(:post, "/v1/poll", JSON.encode!(other)), "poll", "rejected", "invalid")
  end

  test "report: recorded, lease_lost and rejected(conflict, invalid); ended's missing", ctx do
    %{task: _} = L.supervised_task("B-1", "ada")
    Dispatch.resync()

    [%{"lease_id" => lease}] =
      JSON.decode!(call(:post, "/v1/poll", JSON.encode!(poll_body())).resp_body)["leases"]

    report = fn revision, report, path_lease ->
      full =
        request!("report", %{"lease_id" => path_lease, "revision" => revision, "report" => report})

      body = JSON.encode!(Map.delete(full, "lease_id"))
      call(:post, "/v1/leases/#{URI.encode(path_lease, &URI.char_unreserved?/1)}/reports", body)
    end

    conforms!(report.(1, %{"state" => "accepted"}, lease), "report", "recorded")
    conforms!(report.(3, %{"state" => "started"}, lease), "report", "rejected", "conflict")
    conforms!(report.(2, %{"state" => "started"}, lease), "report", "recorded")

    a = L.sha256("a\n")

    entries = [
      %{
        "path" => "a.txt",
        "op" => "write",
        "kind" => "file",
        "mode" => "100644",
        "size" => 2,
        "sha256" => a
      }
    ]

    fp = AtlasChangeset.fingerprint(L.base().base_id, "repo", entries)

    ended = %{
      "state" => "ended",
      "result" => %{"kind" => "completed", "retryable" => false, "never_started" => false},
      "provenance" => [],
      "change_set" => %{
        "roots" => [%{"root" => "repo", "fingerprint" => fp, "entries" => entries}]
      }
    }

    conn = conforms!(report.(3, ended, lease), "report", "recorded")
    assert JSON.decode!(conn.resp_body)["missing"] == [a]

    # A report of a state the contract does not know.
    bad =
      call(
        :post,
        "/v1/leases/#{lease}/reports",
        JSON.encode!(%{"revision" => 4, "report" => %{"state" => "maybe"}})
      )

    conforms!(bad, "report", "rejected", "invalid")

    L.advance(ctx, 900)
    Dispatch.sweep()
    conforms!(report.(4, %{"state" => "started"}, lease), "report", "lease_lost")
  end

  test "get_blob: blob and not_found" do
    sha = L.sha256("abc")
    blob = {:blob, %{sha256: sha, size: 3, content: ["abc"]}}
    conforms!(call(:get, "/v1/leases/L/blobs/#{sha}", "", stand(blob)), "get_blob", "blob")
    conforms!(call(:get, "/v1/leases/L/blobs/#{sha}", ""), "get_blob", "not_found")

    conforms!(
      call(:get, "/v1/leases/L/blobs/#{sha}", "", stand({:rejected, :invalid})),
      "get_blob",
      "rejected",
      "invalid"
    )
  end

  test "put_blob: every outcome" do
    headers = [{"content-type", "application/octet-stream"}, {"blob-size", "3"}]
    path = "/v1/leases/L/blobs/#{L.sha256("abc")}"

    for {answer, outcome, reason} <- [
          {:stored, "stored", nil},
          {:lease_lost, "lease_lost", nil},
          {:too_large, "too_large", nil},
          {:not_referenced, "not_referenced", nil},
          {{:rejected, :digest_mismatch}, "rejected", "digest_mismatch"},
          {{:rejected, :invalid}, "rejected", "invalid"}
        ] do
      conforms!(
        call(:put, path, "abc", [headers: headers] ++ stand(answer)),
        "put_blob",
        outcome,
        reason
      )
    end

    # The real source: no ended recorded for this lease.
    conforms!(call(:put, path, "abc", headers: headers), "put_blob", "lease_lost")
  end

  test "the errors: unauthenticated, no_route, invalid, too_large, unsupported_media_type" do
    error!(call(:post, "/v1/poll", "{}", auth: false), "unauthenticated")
    error!(call(:get, "/v2/poll", ""), "no_route")
    error!(call(:post, "/v1/poll", "[]"), "invalid")
    error!(call(:post, "/v1/poll", String.duplicate(" ", 1_048_577)), "too_large")

    error!(
      call(:put, "/v1/leases/L/blobs/abc", "abc",
        headers: [{"content-type", "text/plain"}, {"blob-size", "3"}]
      ),
      "unsupported_media_type"
    )
  end

  ## work_source.json, as a checker of JSON values

  defp check(model, value) do
    case Enum.find(schema()["models"], &(&1["name"] == model)) do
      nil -> ["no model #{model}"]
      %{"fields" => fields} -> fields(fields, value, model)
    end
  end

  defp fields(fields, value, at) when is_map(value) do
    names = Enum.map(fields, & &1["name"])
    unknown = for k <- Map.keys(value), k not in names, do: "#{at}.#{k} is not declared"

    unknown ++
      Enum.flat_map(fields, fn f ->
        case Map.fetch(value, f["name"]) do
          {:ok, v} when v != nil -> typed(f, v, "#{at}.#{f["name"]}")
          _ -> if f["required"], do: ["#{at}.#{f["name"]} is missing"], else: []
        end
      end)
  end

  defp fields(_fields, _value, at), do: ["#{at} is not an object"]

  defp typed(%{"type" => "one_of", "tag" => tag, "models" => models}, v, at) do
    case Enum.find(models, &(&1 == v[tag])) do
      nil -> ["#{at}: #{tag} names no member"]
      m -> check(m, Map.delete(v, tag))
    end
  end

  defp typed(%{"type" => "list of " <> inner} = f, v, at) when is_list(v),
    do:
      v
      |> Enum.with_index()
      |> Enum.flat_map(fn {x, i} -> typed(%{f | "type" => inner}, x, "#{at}[#{i}]") end)

  defp typed(%{"type" => "map of " <> inner} = f, v, at) when is_map(v),
    do: Enum.flat_map(v, fn {k, x} -> typed(%{f | "type" => inner}, x, "#{at}.#{k}") end)

  defp typed(%{"type" => type} = f, v, at) do
    case ok?(type, v) do
      true -> range(f, v, at) ++ enum(f, v, at)
      false -> if model?(type), do: check(type, v), else: ["#{at} is no #{type}"]
    end
  end

  defp ok?("string", v), do: is_binary(v)
  defp ok?("integer", v), do: is_integer(v)
  defp ok?("boolean", v), do: is_boolean(v)
  defp ok?("enum", v), do: is_binary(v)
  defp ok?("datetime", v), do: is_binary(v) and match?({:ok, _, _}, DateTime.from_iso8601(v))
  defp ok?(_type, _v), do: false

  defp model?(type), do: Enum.any?(schema()["models"], &(&1["name"] == type))

  defp range(%{"range" => %{"min" => min, "max" => max}}, v, at) when v < min or v > max,
    do: ["#{at} is out of range"]

  defp range(_f, _v, _at), do: []

  defp enum(%{"values" => values}, v, at),
    do: if(v in values, do: [], else: ["#{at} is no value"])

  defp enum(_f, _v, _at), do: []

  defp field_type(model, field) do
    Enum.find(
      Enum.find(schema()["models"], &(&1["name"] == model))["fields"],
      &(&1["name"] == field)
    )["type"]
  end

  defp header_value("integer", text), do: String.to_integer(text)
  defp header_value(_type, text), do: text
end
