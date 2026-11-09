defmodule AtlasRuntimeBackend.Generator.SchemaTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Example.Api

  # A contract over the example boundary; `parts` replaces pieces of the valid one.
  defp source(parts) do
    shared =
      Keyword.get(parts, :shared, """
        expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch]
        not_exposed :audit
        rights :socket, [:lend, :browse]
        event :book, :book_changed, id: :sequence
        event :restart, :restart, id: :current_sequence
      """)

    resources =
      Keyword.get(parts, :resources, """
          resource :post, "/v1/books", capability: :lend, body: :input
          resource :get, "/v1/books/:book_id", capability: :find_book
          resource :get, "/v1/books", capability: :search, query: [title: :title]
          resource :get, "/v1/books", capability: :list_books, query: [limit: :limit]
          resource :post, "/v1/books/:book_id/return", capability: :give_back, body: [:note]
          resource :get, "/v1/count", capability: :count
      """)

    stream =
      Keyword.get(parts, :stream, """
          stream "/v1/events", capability: :watch, events: [:book, :restart],
            resume_header: "Last-Event-ID", into: :from, open: [watching: nil, restart: :restart]
      """)

    statuses =
      Keyword.get(parts, :statuses, """
          status :lent, 201
          status :busy, 503, type: "busy"
          status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}, not_permitted: {403, "not-permitted"}]
          status :found, 200
          status :missing, 404, type: "not-found"
          status :listed, 200
          status :returned, 200
          status :counted, 200
      """)

    errors =
      Keyword.get(parts, :errors, """
          error :invalid, 400, type: "invalid"
          error :not_permitted, 403, type: "not-permitted"
          error :no_route, 404, type: "no-route"
      """)

    target_opts = Keyword.get(parts, :target_opts, "")

    """
    defmodule AtlasRuntimeBackend.Generator.SchemaTest.C#{System.unique_integer([:positive])} do
      use AtlasRuntimeBackend.Generator.Schema
      version "1.0.0"
      boundary #{Keyword.get(parts, :boundary, "AtlasRuntimeBackend.Generator.Example.Boundary")}
    #{shared}
      target :rest#{target_opts} do
    #{resources}
    #{stream}
    #{statuses}
    #{errors}
      end
    end
    """
  end

  defp compile(parts), do: Code.compile_string(source(parts))

  defp fails(parts, message) do
    error = assert_raise CompileError, fn -> compile(parts) end
    assert Exception.message(error) =~ message
    error
  end

  test "the valid contract compiles" do
    assert [{_module, _binary}] = compile([])
  end

  describe "acceptance: CompileErrors" do
    test "a resource naming an unknown capability" do
      fails(
        [resources: ~s(    resource :get, "/v1/shelves", capability: :shelve\n)],
        ":shelve is no capability of the boundary"
      )
    end

    test "a mapped capability whose outcome has no status" do
      fails(
        [statuses: ~s(    status :lent, 201\n    status :found, 200\n)],
        "outcome :busy of capability :lend has no status in target :rest"
      )
    end

    test "a capability that is neither mapped nor not_exposed" do
      # Neither exposed nor not_exposed.
      fails(
        [
          shared:
            "  expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch]\n"
        ],
        "capability :audit of AtlasRuntimeBackend.Generator.Example.Boundary is neither exposed nor not_exposed"
      )

      # Exposed, but the target does not map it.
      fails(
        [resources: ~s(    resource :post, "/v1/books", capability: :lend, body: :input\n)],
        "target :rest does not map the exposed capability :find_book"
      )
    end

    test "an exposed name that is no capability, and a resource for a capability not exposed" do
      fails(
        [shared: "  expose [:lend, :shelve]\n  not_exposed :audit\n"],
        "expose :shelve: no capability of the boundary"
      )

      fails(
        [
          shared:
            "  expose [:lend]\n  not_exposed [:audit, :find_book, :search, :list_books, :give_back, :count, :watch]\n",
          resources:
            ~s(    resource :post, "/v1/books", capability: :lend, body: :input\n    resource :get, "/v1/count", capability: :count\n),
          stream: "",
          statuses:
            ~s(    status :lent, 201\n    status :busy, 503, type: "busy"\n    status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}, not_permitted: {403, "x"}]\n    status :counted, 200\n)
        ],
        "capability :count is not exposed"
      )
    end

    test "a boundary target carried by no backend target" do
      fails([target_opts: ", carries: :blocks"], "carries :blocks, which is no target of")

      defmodule TwoTargets do
        def __schema__,
          do:
            Map.put(AtlasRuntimeBackend.Generator.Example.Boundary.__schema__(), :targets, [
              :entities,
              :blocks
            ])
      end

      fails(
        [boundary: inspect(TwoTargets)],
        "boundary target :blocks of #{inspect(TwoTargets)} is carried by no backend target"
      )
    end
  end

  describe "more CompileErrors, at their line" do
    test "resources" do
      fails(
        [resources: ~s(    resource :get, "/v1/books/:id", capability: :find_book\n)],
        "path parameter :id is no field of :find_book_input"
      )

      fails(
        [resources: ~s(    resource :get, "/v1/books", capability: :find_book\n)],
        "required input field :book_id is bound to nothing"
      )

      fails(
        [
          resources:
            ~s(    resource :get, "/v1/books/:book_id", capability: :find_book, query: [id: :book_id]\n)
        ],
        "input field :book_id is bound twice"
      )

      fails(
        [
          resources: ~s(    resource :get, "/v1/books", capability: :list_books, body: [:limit]\n)
        ],
        "a GET takes no body"
      )

      fails(
        [resources: ~s(    resource :get, "/v1/count", capability: :count, body: :input\n)],
        ":count takes no input, so no body"
      )

      fails(
        [resources: ~s(    resource :fetch, "/v1/count", capability: :count\n)],
        "the method is one of"
      )

      fails(
        [resources: ~s(    resource :get, "v1/count", capability: :count\n)],
        "does not start with /"
      )
    end

    test "two resources with the same method and path that nothing tells apart" do
      fails(
        [
          resources: """
              resource :post, "/v1/books", capability: :lend, body: :input
              resource :get, "/v1/books/:book_id", capability: :find_book
              resource :get, "/v1/books", capability: :search, query: [title: :title]
              resource :get, "/v1/books", capability: :list_books, query: [limit: :limit]
              resource :post, "/v1/books/:book_id/return", capability: :give_back, body: [:note]
              resource :get, "/v1/books", capability: :count
          """
        ],
        "another resource has the same method and path, and neither needs a query parameter"
      )
    end

    test "a capability mapped twice" do
      fails(
        [
          resources: """
              resource :post, "/v1/books", capability: :lend, body: :input
              resource :put, "/v1/books", capability: :lend, body: :input
          """
        ],
        "target :rest maps capability :lend twice"
      )
    end

    test "statuses" do
      fails(
        [statuses: ~s(    status :lent, 201\n    status :busy, 503\n)],
        "a status of 400 or more needs a problem type"
      )

      fails(
        [statuses: ~s(    status :lent, 201, type: "lent"\n)],
        "a status below 400 has no problem type"
      )

      fails(
        [
          statuses:
            ~s(    status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}]\n)
        ],
        "reason :not_permitted has no case"
      )

      fails(
        [statuses: ~s(    status :refused, by: :detail, cases: [x: 400]\n)],
        "by: :detail is no required enum field"
      )

      fails(
        [statuses: ~s(    status :lent, 201, header: [location: "/v1/books/{book.shelf}"]\n)],
        "{book.shelf} is no required scalar field of its model"
      )

      fails(
        [statuses: ~s(    status :lent, 201, header: [location: :book]\n)],
        "header field :book is no scalar field of its model"
      )

      fails(
        [statuses: ~s(    status :shelved, 200\n)],
        "status :shelved: no outcome of the boundary"
      )

      fails(
        [statuses: ~s(    status :lent, 201, body: :title\n)],
        "body: :title is no required model field of its model"
      )

      fails(
        [
          statuses:
            ~s(    status :lent, 201\n    status :busy, 503, type: "busy", body: :counts\n)
        ],
        "a problem body is the outcome's fields; no body:"
      )
    end

    test "errors" do
      fails(
        [
          errors:
            ~s(    error :invalid, 400, type: "invalid"\n    error :no_route, 404, type: "no-route"\n)
        ],
        "the target needs `error :not_permitted"
      )

      fails(
        [errors: ~s(    error :invalid, 200, type: "invalid"\n)],
        "error :invalid: the status is 400 or more"
      )
    end

    test "events and streams" do
      fails(
        [
          shared:
            "  expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch]\n  not_exposed :audit\n  event :book, :novel\n"
        ],
        "event :book: :novel is no boundary model"
      )

      fails(
        [
          shared:
            "  expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch]\n  not_exposed :audit\n  event :book, :book_changed, id: :book_id\n"
        ],
        "id :book_id is no required integer field of :book_changed"
      )

      fails(
        [
          stream:
            ~s(    stream "/v1/events", capability: :watch, events: [:book], resume_header: "Last-Event-ID", into: :from, open: [watching: nil]\n)
        ],
        "outcome :restart of :watch has no open: entry"
      )

      fails(
        [
          stream:
            ~s(    stream "/v1/events", capability: :watch, events: [:book, :restart], resume_header: "Last-Event-ID", into: :from, open: [watching: nil, restart: :book]\n)
        ],
        "outcome :restart carries :restart, event :book carries :book_changed"
      )

      fails(
        [
          stream:
            ~s(    stream "/v1/events", capability: :watch, events: [:tick], resume_header: "Last-Event-ID", into: :from, open: [watching: nil, restart: nil]\n)
        ],
        ":tick is no declared event"
      )
    end

    test "the line of the mistake" do
      error =
        fails(
          [resources: ~s(    resource :get, "/v1/shelves", capability: :shelve\n)],
          ":shelve is no capability"
        )

      assert error.line > 1
    end
  end

  describe "__schema__/0" do
    test "the contract as plain data" do
      schema = Api.__schema__()

      assert schema.boundary == AtlasRuntimeBackend.Generator.Example.Boundary

      assert schema.exposed == [
               :lend,
               :find_book,
               :search,
               :list_books,
               :give_back,
               :count,
               :watch
             ]

      assert schema.not_exposed == [:audit]

      assert schema.rights == [
               %{listener: :socket, rights: [:lend, :browse]},
               %{listener: :guest, rights: [:browse]}
             ]

      assert [%{name: :book, model: :book_changed, id: :sequence}, %{name: :tick, id: nil} | _] =
               schema.events

      assert [%{name: :rest, carries: :entities} = rest] = schema.targets

      assert %{
               method: :post,
               path: "/v1/books",
               capability: :lend,
               headers: [{"request-key", :request_key}],
               body: [:title, :place, :until]
             } = hd(rest.resources)

      assert %{resume_header: "last-event-id", into: :from} = hd(rest.streams)

      assert %{outcome: :refused, by: :reason, cases: [%{value: :invalid, status: 400} | _]} =
               Enum.find(rest.statuses, &(&1.outcome == :refused))
    end
  end
end
