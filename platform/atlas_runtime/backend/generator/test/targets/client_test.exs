defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Example.{Api, Client, Facade, GoneClient, GoneRest}
  alias AtlasRuntimeBackend.Generator.Example.TokenListener

  # The round trip: each call goes through the example's generated router (Plug.Test), in
  # this process, so the facade's {:example_called, ...} messages arrive here too.

  defp called do
    assert_received {:example_called, capability, _client, input}
    {capability, input}
  end

  defp sent do
    assert_received {:transport, request}
    request
  end

  # The latest request, dropping the ones before it.
  defp last_sent(last \\ nil) do
    receive do
      {:transport, request} -> last_sent(request)
    after
      0 -> last || flunk("no request was sent")
    end
  end

  defp canned(status, body), do: [transport: [respond: {status, body}]]

  describe "every outcome decodes to its typed value" do
    test "lend: a JSON body, a header from an input field, and the entity as the outcome's field" do
      assert {:lent, %{book: book}} =
               Client.lend(%{
                 request_key: "k1",
                 title: "Dune",
                 place: %{kind: :shelf, row: 2},
                 until: ~U[2026-03-01 10:00:00Z]
               })

      assert book == %{
               book_id: "k1",
               title: "Dune",
               condition: :new,
               place: %{kind: :shelf, row: 2},
               due_at: ~U[2026-03-01 10:00:00Z],
               edition: 1
             }

      request = sent()
      assert %{method: "POST", path: "/v1/books", query: ""} = request
      assert {"request-key", "k1"} in request.headers
      assert {"content-type", "application/json"} in request.headers

      assert JSON.decode!(request.body) == %{
               "title" => "Dune",
               "place" => %{"kind" => "shelf", "row" => 2},
               "until" => "2026-03-01T10:00:00Z"
             }

      assert {:lend, %Facade.LendInput{request_key: "k1", place: %Facade.Shelf{row: 2}}} =
               called()
    end

    test "lend: a problem with a header and nested fields, and a status by a field" do
      assert Client.lend(%{title: "busy"}) ==
               {:busy, %{retry_after: 30, counts: %{total: 3, wait: nil}}}

      assert Client.lend(%{title: "taken"}) ==
               {:refused, %{reason: :taken, detail: "already lent"}}

      assert Client.lend(%{title: "odd"}) == {:refused, %{reason: :invalid, detail: nil}}

      assert Client.lend(%{title: "not yours"}) ==
               {:refused, %{reason: :not_permitted, detail: nil}}
    end

    test "find_book and search: found and missing, path values percent-encoded" do
      assert {:found, %{book: %{book_id: "W 1", place: %{kind: :shelf, row: 3}}}} =
               Client.find_book(%{book_id: "W 1"})

      assert sent().path == "/v1/books/W%201"
      assert Client.find_book(%{book_id: "missing"}) == :missing

      assert {:found, %{book: %{title: "Emma", place: %{kind: :branch, city: "Delft"}}}} =
               Client.search(%{title: "Emma"})

      assert last_sent().query == "title=Emma"
      assert Client.search(%{title: "missing"}) == :missing
    end

    test "list_books: query values from their types; give_back: a body limited to its fields" do
      assert {:listed, %{books: [%{title: "Emma"}, %{title: "Emma"}]}} =
               Client.list_books(%{limit: 2, condition: :worn, lent: true})

      assert {:list_books, %Facade.ListBooksInput{limit: 2, condition: :worn, lent: true}} =
               called()

      assert {:listed, %{books: [_]}} = Client.list_books()

      assert {:returned, %{book: %{book_id: "b1"}}} =
               Client.give_back(%{book_id: "b1", note: "late", hurry: true})

      assert %{path: "/v1/books/b1/return", body: body} = last_sent()
      assert JSON.decode!(body) == %{"note" => "late", "hurry" => true}
      assert Client.give_back(%{book_id: "missing"}) == :missing
    end

    test "count: a capability without input" do
      assert Client.count() == {:counted, %{total: 2, wait: 5}}
      assert %{method: "GET", path: "/v1/count", body: nil} = sent()
    end

    test "a 410 outcome is its own value, never folded into the 404 one" do
      assert GoneClient.find_book(%{book_id: "withdrawn"}, transport: [plug: GoneRest]) ==
               {:withdrawn, %{book_id: "withdrawn", kind: :lost}}

      assert GoneClient.find_book(%{book_id: "missing"}, transport: [plug: GoneRest]) == :missing

      assert {:found, %{book: %{book_id: "b1"}}} =
               GoneClient.find_book(%{book_id: "b1"}, transport: [plug: GoneRest])
    end

    test "a body: outcome is its entity only, though its model has another required field" do
      # The router sends the book only (body: :book); the model's `until` is not on the wire.
      assert GoneClient.find_book(%{book_id: "reserved"}, transport: [plug: GoneRest]) ==
               {:reserved,
                %{
                  book: %{
                    book_id: "reserved",
                    title: "Dune",
                    condition: :new,
                    place: nil,
                    due_at: nil,
                    edition: 1
                  }
                }}

      # An `until` in the body is still no field of the value: the body is the book.
      book =
        ~s({"book_id":"r2","title":"Dune","condition":"new","edition":1,"until":"2026-11-20T12:00:00Z"})

      assert {:reserved, fields} =
               GoneClient.find_book(%{book_id: "r2"}, transport: [respond: {202, book}])

      assert Map.keys(fields) == [:book]

      assert {:error, {:invalid_response, [reason]}} =
               GoneClient.find_book(%{book_id: "r2"},
                 transport: [respond: {202, ~s({"until":"2026-11-20T12:00:00Z"})}]
               )

      assert reason =~ "book_id is required"
    end
  end

  describe "the request key is the caller's" do
    test "without one, no header is sent, and the client makes none up" do
      assert {:lent, %{book: %{book_id: "b1"}}} = Client.lend(%{title: "Dune"})
      request = sent()
      refute Enum.any?(request.headers, fn {name, _} -> name == "request-key" end)
      assert {:lend, %Facade.LendInput{request_key: nil}} = called()

      assert {:lent, _} = Client.lend(%{title: "Dune", request_key: nil})
      refute Enum.any?(sent().headers, fn {name, _} -> name == "request-key" end)
    end

    test "the same key twice is sent as it is, each time once" do
      for _ <- 1..2, do: assert({:lent, _} = Client.lend(%{title: "Dune", request_key: "k7"}))
      assert {"request-key", "k7"} in sent().headers
      assert {"request-key", "k7"} in sent().headers
      refute_received {:transport, _}
    end
  end

  describe "errors" do
    test "a transport failure is unreachable, and the client does not try again" do
      assert Client.lend(%{title: "Dune"}, transport: [fail: :econnrefused]) ==
               {:error, :unreachable}

      assert_received {:transport, _}
      refute_received {:transport, _}
      refute_received {:example_called, _, _, _}

      assert Client.count(transport: [fail: :timeout]) == {:error, :unreachable}
      assert_received {:transport, _}
      refute_received {:transport, _}
    end

    test "502, 503 and 504 without a declared type are unreachable, each sent once" do
      for status <- [502, 503, 504],
          body <- ["", "<html>Bad Gateway</html>", ~s({"title":"x"}), ~s({"type":"other"})] do
        assert Client.lend(%{title: "Dune"}, canned(status, body)) == {:error, :unreachable},
               "#{status} #{body}"

        # B11: exactly one request, never a second try.
        assert_received {:transport, _}
        refute_received {:transport, _}, "#{status} #{body} was sent again"

        assert Client.count(canned(status, body)) == {:error, :unreachable}
        assert_received {:transport, _}
        refute_received {:transport, _}, "#{status} #{body} was sent again"
      end

      # A 503 with the declared type is the typed outcome, where the capability has it.
      busy =
        ~s({"type":"busy","title":"Service Unavailable","status":503,"retry_after":9,"counts":{"total":1}})

      assert {:busy, %{retry_after: 9}} = Client.lend(%{title: "x"}, canned(503, busy))
      assert_received {:transport, _}
      refute_received {:transport, _}

      assert Client.count(canned(503, busy)) == {:error, :unreachable}
      assert_received {:transport, _}
      refute_received {:transport, _}
    end

    test "undeclared statuses and types are unreachable" do
      assert Client.count(canned(418, "")) == {:error, :unreachable}
      assert Client.count(canned(500, ~s({"type":"invalid"}))) == {:error, :unreachable}

      assert Client.find_book(%{book_id: "b1"}, canned(404, ~s({"type":"gone"}))) ==
               {:error, :unreachable}

      # 304 means nothing on a resource without an entity tag.
      assert Client.count(canned(304, "")) == {:error, :unreachable}
      assert GoneClient.find_book(%{book_id: "b1"}, canned(304, "")) == {:error, :unreachable}
    end

    test "the target's own errors" do
      assert Client.lend(%{title: "Dune"}, transport: [client: {"guest", [:browse]}]) ==
               {:error, :not_permitted}

      invalid = ~s({"type":"invalid","title":"Bad Request","status":400,"detail":"no"})
      assert Client.lend(%{title: "x"}, canned(400, invalid)) == {:error, {:invalid, "no"}}
      assert Client.count(canned(404, ~s({"type":"no-route"}))) == {:error, :no_route}
    end

    test "401 is unauthenticated, whatever its body" do
      assert Client.count(canned(401, "")) == {:error, :unauthenticated}
      assert Client.count(canned(401, ~s({"type":"x"}))) == {:error, :unauthenticated}
    end

    test "input that does not fit its model is refused before any request" do
      assert {:error, {:invalid, reasons}} = Client.lend(%{title: 1, colour: :red})
      assert "no field :colour" in reasons
      assert Enum.any?(reasons, &(&1 =~ "title is invalid"))
      assert Client.lend(%{}) == {:error, {:invalid, ["title is required"]}}

      assert {:error, {:invalid, [reason]}} = Client.lend(%{title: "x", place: %{kind: :attic}})
      assert reason =~ "place is invalid"

      assert Client.list_books(%{condition: :torn}) ==
               {:error, {:invalid, ["condition is invalid: :torn"]}}

      assert Client.give_back(%{book_id: "b1", note: 3}) ==
               {:error, {:invalid, ["note is invalid: 3"]}}

      assert Client.lend("Dune") == {:error, {:invalid, [~s(the input is no map: "Dune")]}}
      refute_received {:transport, _}
    end

    test "a recognised outcome whose body does not decode" do
      assert {:error, {:invalid_response, [reason]}} =
               Client.find_book(%{book_id: "b1"}, canned(200, ~s({"title":"Dune"})))

      assert reason =~ "book_id is required"

      assert {:error, {:invalid_response, _}} =
               Client.find_book(%{book_id: "b1"}, canned(200, "not json"))
    end

    test "unknown options raise" do
      assert_raise ArgumentError, ~r/the options are transport:/, fn ->
        Client.count(retries: 3)
      end

      # If-None-Match only where the resource has an entity tag.
      assert_raise ArgumentError, fn -> Client.count(if_none_match: 1) end

      assert_raise ArgumentError, fn ->
        GoneClient.find_book(%{book_id: "b1"}, if_none_match: 1)
      end
    end
  end

  describe "a stream" do
    test "the typed events, in order, whatever the chunks" do
      for chunk <- [1, 5, 1_000] do
        assert {:ok, events} = Client.watch(%{from: 6}, transport: [chunk: chunk])

        assert Enum.to_list(events) == [
                 {:book, %{sequence: 7, book_id: "b1"}},
                 {:tick, %{at: ~U[2026-03-01 10:00:00Z]}}
               ]

        assert {"last-event-id", "6"} in sent().headers
        assert {:watch, %Facade.WatchInput{from: 6}} = called()
      end
    end

    test "an outcome that opens with an event (outside the window: restart)" do
      assert {:ok, events} = Client.watch(%{from: 2})
      assert Enum.to_list(events) == [{:restart, %{current_sequence: 9}}]
    end

    test "without a resume value, no resume header" do
      assert {:ok, _} = Client.watch()
      refute Enum.any?(sent().headers, fn {name, _} -> name == "last-event-id" end)
    end

    test "refusals before the stream opens, and failures while it runs" do
      assert Client.watch(%{}, transport: [client: {"nobody", []}]) == {:error, :not_permitted}
      assert Client.watch(%{}, transport: [fail: :closed]) == {:error, :unreachable}
      assert Client.watch(%{}, canned(502, "")) == {:error, :unreachable}
      assert Client.watch(%{}, canned(401, "")) == {:error, :unauthenticated}

      assert {:ok, events} = Client.watch(%{from: 6}, transport: [fail_after: true])
      assert [{:book, _}, {:tick, _}, {:error, :unreachable}] = Enum.to_list(events)
    end

    test "unknown events are skipped; an event that does not decode ends the stream" do
      body =
        ": a comment\n\nevent: other\ndata: {}\n\nevent: book\nid: 3\ndata: {\"sequence\":3,\"book_id\":\"b\"}\n\n" <>
          "event: tick\ndata: {\"at\":\"soon\"}\n\nevent: book\ndata: {\"sequence\":4,\"book_id\":\"c\"}\n\n"

      assert {:ok, events} = Client.watch(%{}, canned(200, body))

      assert [{:book, %{sequence: 3}}, {:error, {:invalid_response, [reason]}}] =
               Enum.to_list(events)

      assert reason =~ "event tick: at is no datetime"
    end

    test "only the resume field is carried" do
      assert {:error, {:invalid, ["from is invalid: \"x\""]}} = Client.watch(%{from: "x"})
    end
  end

  describe "S3: the listener's auth errors (P1) and entity tags (P3), on the generated router" do
    @member [client: :none, token: "member-token", plug: TokenListener]

    test "401 without a valid token; 403 origin-refused; the token's rights" do
      assert Client.count(transport: [client: :none, plug: TokenListener]) ==
               {:error, :unauthenticated}

      assert Client.count(transport: [client: :none, token: "wrong", plug: TokenListener]) ==
               {:error, :unauthenticated}

      assert Client.count(transport: Keyword.put(@member, :origin, "http://x")) ==
               {:error, :origin_refused}

      assert Client.count(transport: @member) == {:counted, %{total: 2, wait: 5}}

      assert Client.lend(%{title: "Dune"},
               transport: [client: :none, token: "guest-token", plug: TokenListener]
             ) == {:error, :not_permitted}
    end

    test "If-None-Match: 304 is :not_modified; another tag, or a missing book, is not" do
      assert {:found, %{book: %{book_id: "b1"}}} =
               Client.find_book(%{book_id: "b1"}, transport: @member)

      refute Enum.any?(sent().headers, fn {name, _} -> name == "if-none-match" end)

      assert Client.find_book(%{book_id: "b1"}, if_none_match: 1, transport: @member) ==
               :not_modified

      assert {"if-none-match", ~s("1")} in sent().headers

      assert Client.find_book(%{book_id: "b1"}, if_none_match: ~s("1"), transport: @member) ==
               :not_modified

      assert {:found, _} =
               Client.find_book(%{book_id: "b1"}, if_none_match: 2, transport: @member)

      assert Client.find_book(%{book_id: "missing"}, if_none_match: 1, transport: @member) ==
               :missing
    end
  end

  describe "the generated module" do
    test "one call per exposed capability, none for the others" do
      assert Client.__capabilities__() == Api.__schema__().exposed

      for name <- Api.__schema__().exposed,
          do: assert(function_exported?(Client, name, 1) or function_exported?(Client, name, 0))

      for name <- Api.__schema__().not_exposed do
        for arity <- 0..2, do: refute(function_exported?(Client, name, arity))
      end
    end

    test "an exposed capability the target does not map is a CompileError" do
      error =
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest.C1 do
            use AtlasRuntimeBackend.Generator.Targets.Client,
              contract: #{inspect(__MODULE__.Unmapped)},
              transport: AtlasRuntimeBackend.Generator.Example.PlugTransport
          end
          """)
        end

      assert Exception.message(error) =~
               "maps no resource or stream for the exposed capability :count, so the client would miss it"
    end

    test "outcomes the client cannot tell apart are a CompileError" do
      assert_raise CompileError,
                   ~r/outcomes :found and :missing of :find_book both answer 200/,
                   fn ->
                     Code.compile_string("""
                     defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest.C2 do
                       use AtlasRuntimeBackend.Generator.Targets.Client,
                         contract: #{inspect(__MODULE__.Ambiguous)},
                         transport: AtlasRuntimeBackend.Generator.Example.PlugTransport
                     end
                     """)
                   end
    end

    test "the use options and the transport's callbacks" do
      assert_raise CompileError, ~r/takes contract:, transport: and optionally target:/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest.C3 do
          use AtlasRuntimeBackend.Generator.Targets.Client, contract: #{inspect(Api)}
        end
        """)
      end

      assert_raise CompileError, ~r/has no stream\/2/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest.C4 do
          use AtlasRuntimeBackend.Generator.Targets.Client,
            contract: #{inspect(Api)}, transport: #{inspect(__MODULE__.RequestOnly)}
        end
        """)
      end

      assert_raise CompileError, ~r/no compiled backend contract/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.ClientTest.C5 do
          use AtlasRuntimeBackend.Generator.Targets.Client,
            contract: Nowhere, transport: #{inspect(__MODULE__.RequestOnly)}
        end
        """)
      end
    end
  end

  defmodule Unmapped do
    # The example's schema with the resource for `count` left out of the target.
    def __schema__ do
      schema = Api.__schema__()

      targets =
        for t <- schema.targets,
            do: %{t | resources: Enum.reject(t.resources, &(&1.capability == :count))}

      %{schema | targets: targets}
    end
  end

  defmodule Ambiguous do
    # The example's schema with `missing` answering 200, like `found`.
    def __schema__ do
      schema = Api.__schema__()

      targets =
        for t <- schema.targets do
          statuses =
            for s <- t.statuses,
                do: if(s.outcome == :missing, do: %{s | status: 200, type: nil}, else: s)

          %{t | statuses: statuses}
        end

      %{schema | targets: targets}
    end
  end

  defmodule RequestOnly do
    def request(_request, _opts), do: {:error, :none}
  end
end
