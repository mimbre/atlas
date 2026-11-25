defmodule AtlasRuntimeBackend.Generator.Targets.OpenapiTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.{Api, Bare, Extended, Rest}
  alias AtlasRuntimeBackend.Generator.Targets.{Openapi, Routes}

  @opts [name: "api", security: [guest: :bearer]]

  defp doc(schema, opts \\ @opts),
    do: schema |> Openapi.files(opts) |> then(fn [{_, b}] -> JSON.decode!(b) end)

  defp op(doc, method, path), do: doc["paths"][path][method]

  test "the extended example's file: keys sorted, indented by two; every path, operation and schema" do
    assert [{"api/openapi.json", body}] = Openapi.files(Extended.__schema__(), @opts)
    assert body == layout(JSON.decode!(body))

    doc = JSON.decode!(body)
    assert Map.keys(doc) |> Enum.sort() == ["components", "info", "openapi", "paths", "security"]

    assert Map.new(doc["paths"], fn {path, ops} -> {path, ops |> Map.keys() |> Enum.sort()} end) ==
             %{
               "/v1/books" => ["get", "post"],
               "/v1/books/{book_id}" => ["get"],
               "/v1/books/{book_id}/pages" => ["put"],
               "/v1/books/{book_id}/return" => ["post"],
               "/v1/books/{book_id}/scan" => ["get"],
               "/v1/count" => ["get"],
               "/v1/events" => ["get"]
             }

    assert doc["components"]["schemas"] |> Map.keys() |> Enum.sort() ==
             ~w(book book_changed books branch busy counts deposit found lent refused restart shelf tick)
  end

  test "OpenAPI 3.1, no servers: the host is configuration" do
    for schema <- [Api.__schema__(), Extended.__schema__()], opts <- [@opts, []] do
      doc = doc(schema, opts)
      assert doc["openapi"] == "3.1.0"
      assert doc["info"]["version"] == "1.0.0"
      refute Map.has_key?(doc, "servers")
      refute Enum.any?(Map.values(doc["paths"]), &Map.has_key?(&1, "servers"))
    end
  end

  test "a bearer security scheme on each listener named in security:, the others need none" do
    doc = doc(Api.__schema__())

    assert doc["components"]["securitySchemes"] == %{
             "guest" => %{
               "type" => "http",
               "scheme" => "bearer",
               "description" =>
                 "Listener `guest`: `Authorization: Bearer <token>`; a token's rights are at most browse."
             }
           }

    # The socket listener's clients need no credentials, the guest's a bearer token.
    assert doc["security"] == [%{}, %{"guest" => []}]
    assert doc["info"]["description"] =~ "`guest` (bearer token; rights: browse)"

    assert doc["info"]["description"] =~
             "`socket` (the listener's own identity; rights: lend, browse)"
  end

  test "no security: gives no scheme" do
    doc = doc(Api.__schema__(), [])
    refute Map.has_key?(doc, "security")
    refute Map.has_key?(doc["components"], "securitySchemes")
  end

  test "a security: listener the contract declares no rights for is refused, never skipped" do
    for security <- [[remote: :bearer], [guest: :bearer, gust: :bearer]] do
      assert_raise ArgumentError,
                   ~r/security: names :(remote|gust), a listener the contract/,
                   fn ->
                     Openapi.files(Api.__schema__(), security: security)
                   end
    end
  end

  test "every outcome of every resource is a response of its operation, with its status" do
    schema = Extended.__schema__()
    doc = doc(schema)
    [rest] = schema.targets
    boundary = schema.boundary.__schema__()
    statuses = Map.new(rest.statuses, &{&1.outcome, &1})

    for r <- rest.resources,
        o <- Enum.find(boundary.capabilities, &(&1.name == r.capability)).outcomes,
        code <- codes(statuses[o.name]) do
      responses = op(doc, Atom.to_string(r.method), Routes.template(r.path))["responses"]
      assert responses[Integer.to_string(code)]["description"] =~ "`#{o.name}`"
    end
  end

  test "401 and 403 origin-refused from the contract's errors, on every operation" do
    doc = doc(Extended.__schema__())

    for {_path, methods} <- doc["paths"], {_method, op} <- methods do
      assert %{"401" => unauthenticated, "403" => forbidden} = op["responses"]
      assert types(unauthenticated) == ["unauthenticated"]
      assert "origin-refused" in types(forbidden)
      assert "not-permitted" in types(forbidden)
      if op["operationId"] != "find_book", do: refute(Map.has_key?(op["responses"], "304"))
    end

    bare = doc(Bare.__schema__())

    for {_path, methods} <- bare["paths"], {_m, op} <- methods do
      refute op["responses"]["401"]
      refute "origin-refused" in types(op["responses"]["403"])
    end
  end

  test "a resource with etag: If-None-Match, ETag on success, 304 without a body" do
    doc = doc(Extended.__schema__())
    find = op(doc, "get", "/v1/books/{book_id}")

    assert %{"in" => "header", "name" => "if-none-match", "required" => false} =
             Enum.find(find["parameters"], &(&1["name"] == "if-none-match"))

    assert %{"description" => _, "headers" => %{"etag" => %{"required" => true}}} =
             not_modified = find["responses"]["304"]

    refute Map.has_key?(not_modified, "content")
    assert %{"etag" => %{"required" => true}} = find["responses"]["200"]["headers"]
    refute Map.has_key?(find["responses"]["404"], "headers")

    # Not on the other resources, though search answers the same outcome.
    search = op(doc, "get", "/v1/books")
    refute Map.has_key?(search["responses"], "304")
    refute Map.has_key?(search["responses"]["200"], "headers")
    refute Enum.any?(search["parameters"], &(&1["name"] == "if-none-match"))

    bare = op(doc(Bare.__schema__()), "get", "/v1/books/{book_id}")
    refute Map.has_key?(bare["responses"], "304")
    refute Enum.any?(bare["parameters"], &(&1["name"] == "if-none-match"))
  end

  test "declared headers: a field, a template and a constant" do
    doc = doc(Extended.__schema__())

    lent = op(doc, "post", "/v1/books")["responses"]
    assert lent["201"]["headers"]["location"]["schema"] == %{"type" => "string"}
    assert lent["201"]["headers"]["location"]["description"] =~ "/v1/books/{book.book_id}"
    assert lent["503"]["headers"]["retry-after"]["schema"] == %{"type" => "integer"}

    assert %{"schema" => %{"type" => "string", "const" => "true"}, "required" => true} =
             op(doc, "post", "/v1/books/{book_id}/return")["responses"]["200"]["headers"][
               "replayed"
             ]
  end

  test "bodies: the entity, problem+json per case, a closed request body" do
    doc = doc(Api.__schema__())
    lend = op(doc, "post", "/v1/books")

    assert lend["responses"]["201"]["content"]["application/json"]["schema"] ==
             %{"$ref" => "#/components/schemas/book"}

    assert %{
             "properties" => %{"type" => %{"const" => "taken"}, "reason" => %{"const" => "taken"}}
           } =
             lend["responses"]["409"]["content"]["application/problem+json"]["schema"]

    assert %{"additionalProperties" => false, "required" => ["title"]} =
             lend["requestBody"]["content"]["application/json"]["schema"]

    assert %{"in" => "header", "name" => "request-key", "required" => false} =
             Enum.find(lend["parameters"], &(&1["name"] == "request-key"))

    assert %{"oneOf" => [_, _], "discriminator" => %{"propertyName" => "kind"}} =
             doc["components"]["schemas"]["book"]["properties"]["place"]

    refute Map.has_key?(doc["components"]["schemas"], "audit_input")
  end

  test "resources told apart by query share one operation" do
    op = op(doc(Api.__schema__()), "get", "/v1/books")
    assert op["operationId"] == "search_or_list_books"

    assert Enum.map(op["x-capabilities"], &{&1["capability"], &1["required_query"]}) ==
             [{"search", ["title"]}, {"list_books", []}]

    # Required in one of them only: not required for the operation.
    assert %{"required" => false} = Enum.find(op["parameters"], &(&1["name"] == "title"))
  end

  test "the stream: text/event-stream with its events and the resume header" do
    op = op(doc(Api.__schema__()), "get", "/v1/events")
    media = op["responses"]["200"]["content"]["text/event-stream"]

    assert Enum.map(media["x-events"], &{&1["name"], &1["id"]}) ==
             [{"book", "sequence"}, {"tick", nil}, {"restart", "current_sequence"}]

    assert hd(media["x-events"])["data"] == %{"$ref" => "#/components/schemas/book_changed"}
    assert media["x-opens-with"] == %{"watching" => nil, "restart" => "restart"}

    assert %{"in" => "header", "schema" => %{"type" => "integer"}} =
             Enum.find(op["parameters"], &(&1["name"] == "last-event-id"))
  end

  test "an outcome sent as bytes: its content type, a binary string, and its headers" do
    doc = doc(Api.__schema__())
    op = op(doc, "get", "/v1/books/{book_id}/scan")
    ok = op["responses"]["200"]

    assert ok["content"] == %{
             "application/octet-stream" => %{
               "schema" => %{"type" => "string", "format" => "binary"}
             }
           }

    assert %{
             "scan-pages" => %{"required" => true, "schema" => %{"type" => "integer"}},
             "scanned-at" => %{"schema" => %{"type" => "string", "format" => "date-time"}},
             "scan-of" => %{"required" => true}
           } = ok["headers"]

    refute Map.has_key?(ok["headers"]["scanned-at"], "required")
    assert %{"application/problem+json" => _} = op["responses"]["404"]["content"]
    # The stream's model is never a JSON body, so it is no schema.
    refute Map.has_key?(doc["components"]["schemas"], "scan")
  end

  test "no_route answers no operation's path: under components only" do
    doc = doc(Api.__schema__())
    assert types(doc["components"]["responses"]["no_route"]) == ["no-route"]

    for {_path, methods} <- doc["paths"],
        {_m, op} <- methods,
        r <- Map.values(op["responses"]),
        do: refute(r["description"] =~ "no_route")
  end

  test "a problem response has one oneOf branch per problem type" do
    for schema <- [Api.__schema__(), Extended.__schema__(), Bare.__schema__()] do
      doc = doc(schema)

      responses =
        for {_path, methods} <- doc["paths"],
            {_m, op} <- methods,
            r <- Map.values(op["responses"]),
            do: r

      for r <- responses ++ Map.values(doc["components"]["responses"]),
          %{"schema" => s} <- [r["content"]["application/problem+json"]],
          branches = Map.get(s, "oneOf", [s]) do
        types = for b <- branches, do: b["properties"]["type"]["const"]
        assert types == Enum.uniq(types), "#{r["description"]}: #{inspect(types)}"
      end
    end

    # A refused case and an error of the same type: one branch for both.
    lend = op(doc(Api.__schema__()), "post", "/v1/books")
    assert types(lend["responses"]["403"]) == ["not-permitted", "origin-refused"]
    assert types(lend["responses"]["400"]) == ["invalid"]
  end

  test "each 4xx body the router sends matches exactly one branch of its response" do
    doc = doc(Api.__schema__())
    member = {"ann", [:lend, :browse]}

    sent = [
      # refused, reason invalid: 400 invalid with reason
      lend(~s({"title":"odd"}), member),
      # error invalid: 400 invalid without reason
      lend(~s({"title":5}), member),
      # refused, reason not_permitted: 403 not-permitted with reason
      lend(~s({"title":"not yours"}), member),
      # error not_permitted: the facade refused the client's rights
      lend(~s({"title":"Dune"}), {"guest", [:browse]}),
      # refused, reason taken: 409
      lend(~s({"title":"taken"}), member),
      Rest.__problem__(:origin_refused, conn("POST", "/v1/books")),
      Rest.__problem__(:unauthenticated, conn("POST", "/v1/books"))
    ]

    statuses = Enum.map(sent, & &1.status)
    assert statuses == [400, 400, 403, 403, 409, 403, 401]
    assert Enum.count(sent, &(JSON.decode!(&1.resp_body)["reason"] != nil)) == 3

    for conn <- sent do
      body = JSON.decode!(conn.resp_body)
      response = op(doc, "post", "/v1/books")["responses"][Integer.to_string(conn.status)]
      schema = response["content"]["application/problem+json"]["schema"]
      branches = Map.get(schema, "oneOf", [schema])
      matching = Enum.count(branches, &valid?(&1, body, doc))
      assert matching == 1, "#{conn.status} #{inspect(body)} matches #{matching} branches"
      assert valid?(schema, body, doc)
    end
  end

  defp lend(body, client) do
    conn("POST", "/v1/books", body)
    |> put_req_header("content-type", "application/json")
    |> assign(:client, client)
    |> Rest.call(Rest.init([]))
  end

  # The JSON Schema subset the document uses, with oneOf exactly one, as strict validators do.
  defp valid?(%{"$ref" => "#/components/schemas/" <> name}, value, doc),
    do: valid?(doc["components"]["schemas"][name], value, doc)

  defp valid?(schema, value, doc) do
    Enum.all?(schema, fn
      {"const", c} ->
        value == c

      {"enum", e} ->
        value in e

      {"type", t} ->
        type?(t, value)

      {"oneOf", s} ->
        Enum.count(s, &valid?(&1, value, doc)) == 1

      {"anyOf", s} ->
        Enum.any?(s, &valid?(&1, value, doc))

      {"required", r} ->
        not is_map(value) or Enum.all?(r, &Map.has_key?(value, &1))

      {"properties", p} ->
        not is_map(value) or
          Enum.all?(p, fn {k, s} -> not Map.has_key?(value, k) or valid?(s, value[k], doc) end)

      {"additionalProperties", false} ->
        not is_map(value) or
          Enum.all?(Map.keys(value), &Map.has_key?(schema["properties"] || %{}, &1))

      {"items", s} ->
        not is_list(value) or Enum.all?(value, &valid?(s, &1, doc))

      {_ignored, _} ->
        true
    end)
  end

  defp type?("object", v), do: is_map(v)
  defp type?("string", v), do: is_binary(v)
  defp type?("integer", v), do: is_integer(v)
  defp type?("boolean", v), do: is_boolean(v)
  defp type?("array", v), do: is_list(v)
  defp type?("null", v), do: is_nil(v)
  defp type?(list, v) when is_list(list), do: Enum.any?(list, &type?(&1, v))

  test "unknown options are refused" do
    assert_raise ArgumentError, ~r/unknown option :servers/, fn ->
      Openapi.files(Api.__schema__(), servers: ["https://x"])
    end

    assert_raise ArgumentError, ~r/security: is \[listener: :bearer\]/, fn ->
      Openapi.files(Api.__schema__(), security: [guest: :basic])
    end
  end

  defp codes(%{by: nil, status: code}), do: [code]
  defp codes(%{cases: cases}), do: Enum.map(cases, & &1.status)

  defp types(response) do
    schema =
      response["content"]["application/problem+json"]["schema"]

    for s <- Map.get(schema, "oneOf", [schema]), do: s["properties"]["type"]["const"]
  end

  # The layout the file target promises: keys sorted, two spaces per level, a newline at the end.
  defp layout(value), do: IO.iodata_to_binary(layout(value, "")) <> "\n"

  defp layout(map, at) when is_map(map) and map_size(map) > 0 do
    inner =
      for {k, v} <- Enum.sort(map), do: [at, "  ", JSON.encode!(k), ": ", layout(v, at <> "  ")]

    ["{\n", Enum.intersperse(inner, ",\n"), "\n", at, "}"]
  end

  defp layout(list, at) when is_list(list) and list != [] do
    inner = for v <- list, do: [at, "  ", layout(v, at <> "  ")]
    ["[\n", Enum.intersperse(inner, ",\n"), "\n", at, "]"]
  end

  defp layout(value, _at), do: JSON.encode!(value)
end
