defmodule AtlasRuntimeBackend.Generator.Targets.RestTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.Facade
  alias AtlasRuntimeBackend.Generator.Example.Rest

  @member {"ann", [:lend, :browse]}

  defp request(method, path, body \\ "", headers \\ [], client \\ @member) do
    conn = conn(method, path, body) |> assign(:client, client)
    conn = Enum.reduce(headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)
    Rest.call(conn, Rest.init([]))
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)
  defp content_type(conn), do: get_resp_header(conn, "content-type")

  defp called do
    assert_received {:example_called, capability, client, input}
    {capability, client, input}
  end

  test "generated routers do not name removed helpers in compiler attributes" do
    {:ok, {_, [abstract_code: {:raw_abstract_v1, forms}]}} =
      :beam_lib.chunks(:code.which(Rest), [:abstract_code])

    refute Enum.any?(forms, fn
             {:attribute, _, :compile, options} ->
               Enum.any?(List.wrap(options), &match?({:nowarn_unused_function, _}, &1))

             _ ->
               false
           end)
  end

  describe "routes and decoding" do
    test "POST with a JSON body and a header builds the input through new/1" do
      conn =
        request(
          "POST",
          "/v1/books",
          ~s({"title":"Dune","place":{"kind":"shelf","row":2},"until":"2026-03-01T10:00:00Z"}),
          [
            {"request-key", "k1"}
          ]
        )

      assert conn.status == 201
      assert get_resp_header(conn, "location") == ["/v1/books/k1"]
      assert content_type(conn) == ["application/json"]

      # body: :book, the outcome's entity with no envelope.
      assert json(conn) == %{
               "book_id" => "k1",
               "title" => "Dune",
               "edition" => 1,
               "condition" => "new",
               "place" => %{"kind" => "shelf", "row" => 2},
               "due_at" => "2026-03-01T10:00:00Z"
             }

      assert {:lend, @member,
              %Facade.LendInput{
                request_key: "k1",
                title: "Dune",
                place: %Facade.Shelf{row: 2},
                until: ~U[2026-03-01 10:00:00Z]
              }} =
               called()
    end

    test "path parameters are percent-decoded" do
      conn = request("GET", "/v1/books/W%201")
      assert conn.status == 200
      assert {:find_book, _, %Facade.FindBookInput{book_id: "W 1"}} = called()
    end

    test "query values take the field's type; resources on one path are told apart by query" do
      assert request("GET", "/v1/books?limit=2&condition=worn&lent=true").status == 200

      assert {:list_books, _, %Facade.ListBooksInput{limit: 2, condition: :worn, lent: true}} =
               called()

      assert request("GET", "/v1/books").status == 200
      assert {:list_books, _, %Facade.ListBooksInput{limit: nil}} = called()

      assert request("GET", "/v1/books?title=Emma").status == 200
      assert {:search, _, %Facade.SearchInput{title: "Emma"}} = called()
    end

    test "a body limited to its fields" do
      conn = request("POST", "/v1/books/b1/return", ~s({"note":"late","hurry":true}))
      assert conn.status == 200

      assert {:give_back, _, %Facade.GiveBackInput{book_id: "b1", note: "late", hurry: true}} =
               called()

      # The path binds book_id; the body may not.
      conn = request("POST", "/v1/books/b1/return", ~s({"book_id":"b2"}))
      assert conn.status == 400
      assert json(conn)["detail"] == "the body has an unknown field"

      # An empty body is {}.
      assert request("POST", "/v1/books/b1/return").status == 200
    end

    test "a capability without input" do
      conn = request("GET", "/v1/count")
      assert conn.status == 200
      assert json(conn) == %{"total" => 2, "wait" => 5}
      # A header from a field of the outcome.
      assert get_resp_header(conn, "retry-after") == ["5"]
    end
  end

  describe "strict decoding: every failure is 400 invalid, as problem+json" do
    for {name, method, path, body, detail} <- [
          {"an unknown body field", "POST", "/v1/books", ~s({"title":"x","extra":1}),
           "the body has an unknown field"},
          {"a body that is no JSON", "POST", "/v1/books", ~s({"title":), "no JSON"},
          {"a body that is no object", "POST", "/v1/books", ~s(["title"]), "no JSON object"},
          {"a missing required field", "POST", "/v1/books", ~s({}), "title is required"},
          {"a wrong type", "POST", "/v1/books", ~s({"title":1}), "title is invalid"},
          {"an unknown enum value in the query", "GET", "/v1/books?condition=torn", "",
           "condition is invalid"},
          {"no integer in the query", "GET", "/v1/books?limit=two", "", "limit is invalid"},
          {"an unknown query parameter", "GET", "/v1/books?colour=red", "",
           "the query has an unknown parameter"},
          {"a query parameter twice", "GET", "/v1/books?limit=1&limit=2", "",
           ~s(query parameter "limit" is given twice)},
          {"parameters of two resources", "GET", "/v1/books?title=a&limit=1", "",
           "limit, title do not fit one resource"},
          {"a body on a resource without one", "GET", "/v1/count", "{}", "takes no body"},
          {"a body larger than 1 MiB", "POST", "/v1/books", String.duplicate(" ", 1_048_577),
           "larger than"}
        ] do
      test name do
        conn = request(unquote(method), unquote(path), unquote(body))
        assert conn.status == 400
        assert content_type(conn) == ["application/problem+json"]

        assert %{
                 "type" => "invalid",
                 "title" => "Bad Request",
                 "status" => 400,
                 "detail" => detail
               } =
                 json(conn)

        assert detail =~ unquote(detail)
        refute_received {:example_called, _, _, _}
      end
    end

    test "a bad Last-Event-ID" do
      conn = request("GET", "/v1/events", "", [{"last-event-id", "seven"}])
      assert conn.status == 400
      assert json(conn)["type"] == "invalid"
    end
  end

  describe "status per outcome" do
    test "headers from a field, problem type and the outcome's fields in the problem" do
      conn = request("POST", "/v1/books", ~s({"title":"busy"}))
      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["30"]
      assert content_type(conn) == ["application/problem+json"]

      assert json(conn) == %{
               "type" => "busy",
               "title" => "Service Unavailable",
               "status" => 503,
               "retry_after" => 30,
               "counts" => %{"total" => 3}
             }
    end

    test "a status by an enum field of the outcome" do
      for {title, status, type} <- [
            {"taken", 409, "taken"},
            {"odd", 400, "invalid"},
            {"not yours", 403, "not-permitted"}
          ] do
        conn = request("POST", "/v1/books", JSON.encode!(%{title: title}))
        assert conn.status == status
        assert %{"type" => ^type, "status" => ^status} = json(conn)
      end
    end

    test "an outcome without fields" do
      conn = request("GET", "/v1/books/missing")
      assert conn.status == 404
      assert json(conn) == %{"type" => "not-found", "title" => "Not Found", "status" => 404}
    end

    test "a header left out when its field has no value" do
      conn = request("POST", "/v1/books", ~s({"title":"Dune"}))
      assert get_resp_header(conn, "location") == ["/v1/books/b1"]
      assert get_resp_header(conn, "retry-after") == []
    end
  end

  describe "a conditional GET (etag:)" do
    test "the success outcome carries ETag: \"<field>\"; the body is unchanged" do
      conn = request("GET", "/v1/books/b1")
      assert conn.status == 200
      assert get_resp_header(conn, "etag") == [~s("1")]
      assert %{"book_id" => "b1", "edition" => 1} = json(conn)
    end

    test "If-None-Match with the tag → 304, the same ETag and no body" do
      for given <- [~s("1"), ~s("0", "1"), ~s(W/"1"), "*"] do
        conn = request("GET", "/v1/books/b1", "", [{"if-none-match", given}])
        assert conn.status == 304, "If-None-Match: #{given}"
        assert get_resp_header(conn, "etag") == [~s("1")]
        assert conn.resp_body == ""
        assert content_type(conn) == []
        # The facade still answers: the tag is the outcome's.
        assert {:find_book, _, %Facade.FindBookInput{book_id: "b1"}} = called()
      end
    end

    test "a tag that does not match → 200 with the body and the current tag" do
      for given <- [~s("2"), ~s("1-"), "1", ~s("11"), ""] do
        conn = request("GET", "/v1/books/b1", "", [{"if-none-match", given}])
        assert conn.status == 200, "If-None-Match: #{given}"
        assert get_resp_header(conn, "etag") == [~s("1")]
        assert %{"edition" => 1} = json(conn)
      end
    end

    test "a change gives a new tag, and the old one no longer matches" do
      conn = request("GET", "/v1/books/reprinted", "", [{"if-none-match", ~s("1")}])
      assert conn.status == 200
      assert get_resp_header(conn, "etag") == [~s("2")]
      assert %{"edition" => 2} = json(conn)

      conn = request("GET", "/v1/books/reprinted", "", [{"if-none-match", ~s("2")}])
      assert conn.status == 304
    end

    test "never 304 and no ETag for another outcome of the resource" do
      for given <- [~s("1"), "*"] do
        conn = request("GET", "/v1/books/missing", "", [{"if-none-match", given}])
        assert conn.status == 404
        assert get_resp_header(conn, "etag") == []
        assert %{"type" => "not-found"} = json(conn)
      end
    end

    test "no ETag on a resource without etag:, even for the same outcome" do
      # search answers found, as find_book does.
      conn = request("GET", "/v1/books?title=Emma", "", [{"if-none-match", "*"}])
      assert conn.status == 200
      assert get_resp_header(conn, "etag") == []
      assert %{"title" => "Emma"} = json(conn)
    end

    test "refused rights are refused, whatever the If-None-Match" do
      conn = request("GET", "/v1/books/b1", "", [{"if-none-match", "*"}], {"nobody", []})
      assert conn.status == 403
      assert get_resp_header(conn, "etag") == []
    end

    test "Runtime.not_modified?/2 and etag/1" do
      alias AtlasRuntimeBackend.Generator.Targets.Rest.Runtime
      assert Runtime.etag(42) == ~s("42")
      assert Runtime.not_modified?([~s("42")], ~s("42"))
      assert Runtime.not_modified?([~s("1"), ~s(W/"42")], ~s("42"))
      assert Runtime.not_modified?([~s( "1" ,"42" )], ~s("42"))
      assert Runtime.not_modified?(["*"], ~s("42"))
      refute Runtime.not_modified?([], ~s("42"))
      refute Runtime.not_modified?([~s("4"), ~s("420")], ~s("42"))
      refute Runtime.not_modified?(["42"], ~s("42"))
    end
  end

  # D44 (designer, 2026-11-17): the router's own texts name the field, never request data,
  # which can hold a path. One case per text that once repeated it.
  describe "D44: no router text repeats request data" do
    @home "/Users/someone/"
    @encoded URI.encode_www_form(@home)

    defmodule ReadFails do
      @moduledoc false
      # Plug's test adapter, but reading the body fails with a reason that holds a path.
      defdelegate send_resp(state, status, headers, body), to: Plug.Adapters.Test.Conn
      def read_req_body(_state, _opts), do: {:error, "/Users/someone/socket"}
    end

    for {name, method, path, body, status, detail} <- [
          {"an unknown body field", "POST", "/v1/books", ~s({"title":"x","/Users/someone/k":1}),
           400, "the body has an unknown field"},
          {"an unknown query parameter", "GET", "/v1/books?#{@encoded}k=1", "", 400,
           "the query has an unknown parameter"},
          {"an unknown query parameter twice", "GET", "/v1/books?#{@encoded}k=1&#{@encoded}k=2",
           "", 400, "a query parameter is given twice"},
          {"no route", "GET", "/v1/#{@encoded}p", "", 404,
           "no resource for this method and path"},
          {"no route on a path that is a home path", "GET", "/Users/someone/p", "", 404,
           "no resource for this method and path"}
        ] do
      test name do
        conn = request(unquote(method), unquote(path), unquote(body))
        assert conn.status == unquote(status)
        assert json(conn)["detail"] == unquote(detail)
        refute conn.resp_body =~ "someone"
      end
    end

    test "a body that cannot be read" do
      conn = conn("POST", "/v1/books", "") |> assign(:client, @member)
      {Plug.Adapters.Test.Conn, state} = conn.adapter
      conn = Rest.call(%{conn | adapter: {ReadFails, state}}, Rest.init([]))
      assert conn.status == 400
      assert json(conn)["detail"] == "the body could not be read"
      refute conn.resp_body =~ "someone"
    end
  end

  describe "the target's own errors" do
    test "no route" do
      for {method, path} <- [
            {"GET", "/v1/shelves"},
            {"DELETE", "/v1/books/b1"},
            {"GET", "/v1/books/b1/return"},
            {"GET", "/"}
          ] do
        conn = request(method, path)
        assert conn.status == 404
        assert %{"type" => "no-route"} = json(conn)
      end
    end

    test "not permitted: the facade refused the client's rights" do
      conn = request("POST", "/v1/books", ~s({"title":"Dune"}), [], {"guest", [:browse]})
      assert conn.status == 403
      assert %{"type" => "not-permitted", "detail" => "this needs the right lend"} = json(conn)
    end

    test "a value the facade should never return raises" do
      assert_raise ArgumentError, ~r/no declared outcome/, fn ->
        request("POST", "/v1/books", ~s({"title":"undeclared"}))
      end
    end

    test "no client in the assigns raises" do
      assert_raise ArgumentError, ~r/no client/, fn ->
        Rest.call(conn("GET", "/v1/count"), [])
      end
    end
  end

  describe "streams" do
    test "the opening, then the loop's frames with id: from the event's id field" do
      conn = request("GET", "/v1/events", "", [{"last-event-id", "6"}])
      assert conn.status == 200
      assert conn.state == :chunked
      assert content_type(conn) == ["text/event-stream"]
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert {:watch, _, %Facade.WatchInput{from: 6}} = called()

      assert conn.resp_body ==
               "event: book\nid: 7\ndata: {\"book_id\":\"b1\",\"sequence\":7}\n\n" <>
                 "event: tick\ndata: {\"at\":\"2026-03-01T10:00:00Z\"}\n\n"
    end

    test "an outcome that opens with an event" do
      conn = request("GET", "/v1/events", "", [{"last-event-id", "2"}])
      assert conn.status == 200
      assert conn.resp_body == "event: restart\nid: 9\ndata: {\"current_sequence\":9}\n\n"
    end

    test "without a resume header" do
      request("GET", "/v1/events")
      assert {:watch, _, %Facade.WatchInput{from: nil}} = called()
    end

    test "refused rights" do
      conn = request("GET", "/v1/events", "", [], {"nobody", []})
      assert conn.status == 403
    end

    test "__event__/1 frames event models only" do
      assert {:ok, frame} = Rest.__event__(%Facade.BookChanged{sequence: 3, book_id: "b9"})

      assert IO.iodata_to_binary(frame) ==
               "event: book\nid: 3\ndata: {\"book_id\":\"b9\",\"sequence\":3}\n\n"

      assert Rest.__event__(%Facade.Outcome.Watching{}) == :error
      assert Rest.__event__(:other) == :error
    end
  end

  describe "__problem__/2: a listener's refusals, before the router runs" do
    defp refuse(kind, conn \\ conn("GET", "/v1/count")), do: Rest.__problem__(kind, conn)

    test "unauthenticated: 401 problem+json with its type, halted, nothing called" do
      conn = refuse(:unauthenticated)
      assert conn.status == 401
      assert conn.halted
      assert content_type(conn) == ["application/problem+json"]

      assert json(conn) == %{
               "type" => "unauthenticated",
               "title" => "Unauthorized",
               "status" => 401
             }

      refute_received {:example_called, _, _, _}
    end

    test "origin_refused: 403 with its type" do
      conn = refuse(:origin_refused)
      assert conn.status == 403
      assert conn.halted
      assert content_type(conn) == ["application/problem+json"]

      assert json(conn) == %{
               "type" => "origin-refused",
               "title" => "Forbidden",
               "status" => 403
             }
    end

    test "the body never depends on the request" do
      one = refuse(:unauthenticated, conn("POST", "/v1/books", ~s({"title":"Dune"})))

      other =
        refuse(
          :unauthenticated,
          conn("GET", "/v1/shelves?x=1") |> put_req_header("authorization", "Bearer secret")
        )

      assert one.resp_body == other.resp_body
      refute other.resp_body =~ "secret"
    end

    test "every declared error kind, from the contract" do
      assert refuse(:no_route).status == 404
      assert json(refuse(:invalid))["type"] == "invalid"
    end

    test "a kind the contract does not declare raises" do
      assert_raise ArgumentError, ~r/declares no error :expired/, fn -> refuse(:expired) end
    end
  end

  test "__rights__/1 and __routes__/0" do
    assert Rest.__rights__(:socket) == [:lend, :browse]
    assert Rest.__rights__(:guest) == [:browse]

    routes = Rest.__routes__()
    lend = Enum.find(routes, &(&1.capability == :lend))
    assert %{method: :post, path: "/v1/books", stream: false, etag: nil} = lend

    assert for(r <- routes, r.etag, do: {r.capability, r.etag}) == [find_book: :edition]

    assert [
             %{outcome: :lent, status: 201, headers: [{"location", _}]},
             %{outcome: :busy, status: 503, type: "busy"},
             %{outcome: :refused, by: :reason}
           ] = lend.outcomes

    assert %{
             stream: true,
             outcomes: [
               %{outcome: :watching, opens_with: nil},
               %{outcome: :restart, opens_with: :restart}
             ]
           } =
             Enum.find(routes, &(&1.capability == :watch))
  end

  describe "the use options" do
    test "a facade that lacks a mapped capability is a CompileError" do
      defmodule Partial do
        def lend(_client, _input), do: nil
      end

      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule AtlasRuntimeBackend.Generator.Targets.RestTest.R1 do
            use AtlasRuntimeBackend.Generator.Targets.Rest,
              contract: AtlasRuntimeBackend.Generator.Example.Api,
              facade: #{inspect(Partial)},
              stream: AtlasRuntimeBackend.Generator.Example.Loop
          end
          """)
        end

      assert Exception.message(error) =~ "has no input lend_input"
    end

    test "a missing facade, and a stream without a loop" do
      assert_raise CompileError, ~r/facade: Nowhere is not available/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.RestTest.R2 do
          use AtlasRuntimeBackend.Generator.Targets.Rest,
            contract: AtlasRuntimeBackend.Generator.Example.Api, facade: Nowhere
        end
        """)
      end

      assert_raise CompileError, ~r/has a stream; name its loop with stream:/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.RestTest.R3 do
          use AtlasRuntimeBackend.Generator.Targets.Rest,
            contract: AtlasRuntimeBackend.Generator.Example.Api,
            facade: AtlasRuntimeBackend.Generator.Example.Facade
        end
        """)
      end
    end
  end
end
