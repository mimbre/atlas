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

  # The default shared part without its rights.
  defp shared_without_rights,
    do: """
      expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch]
      not_exposed :audit
      event :book, :book_changed, id: :sequence
      event :restart, :restart, id: :current_sequence
    """

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

    test "a right that is no value of the boundary's client rights" do
      fails(
        [shared: shared_without_rights() <> "  rights :socket, [:lend, :shelve]\n"],
        "rights :socket: :shelve is no client right of AtlasRuntimeBackend.Generator.Example.Boundary (:lend, :browse, :audit)"
      )

      # Every listener's rights are checked, a ceiling as much as a socket's.
      fails(
        [
          shared:
            shared_without_rights() <>
              "  rights :socket, [:lend]\n  rights :token, [:browse, :operate]\n"
        ],
        "rights :token: :operate is no client right"
      )

      # Every right the boundary declares may be named, also one no capability needs.
      assert [{_module, _binary}] =
               compile(
                 shared: shared_without_rights() <> "  rights :socket, [:lend, :browse, :audit]\n"
               )
    end

    test "rights over a boundary that declares no client rights" do
      defmodule NoClient do
        def __schema__ do
          schema = AtlasRuntimeBackend.Generator.Example.Boundary.__schema__()
          %{schema | models: Enum.reject(schema.models, &(&1.name == :client))}
        end
      end

      fails(
        [boundary: inspect(NoClient)],
        "rights :socket: #{inspect(NoClient)} declares no client rights"
      )

      # Without a rights entry there is nothing to check.
      assert [{_module, _binary}] =
               compile(boundary: inspect(NoClient), shared: shared_without_rights())
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

    test "etag:" do
      # The valid resources, with `resource` in place of find_book's.
      with_etag = fn resource ->
        """
            resource :post, "/v1/books", capability: :lend, body: :input
            #{resource}
            resource :get, "/v1/books", capability: :search, query: [title: :title]
            resource :get, "/v1/books", capability: :list_books, query: [limit: :limit]
            resource :post, "/v1/books/:book_id/return", capability: :give_back, body: [:note]
            resource :get, "/v1/count", capability: :count
        """
      end

      found_book =
        ~s(    status :lent, 201\n    status :busy, 503, type: "busy"\n    status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}, not_permitted: {403, "not-permitted"}]\n    status :found, 200, body: :book\n    status :missing, 404, type: "not-found"\n    status :listed, 200\n    status :returned, 200\n    status :counted, 200\n)

      # Valid: the body: entity's integer field, and an outcome's own integer field.
      assert [{_, _}] =
               compile(
                 resources:
                   with_etag.(
                     ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: :edition)
                   ),
                 statuses: found_book
               )

      assert [{module, _}] =
               compile(
                 resources:
                   String.replace(
                     with_etag.(~s(resource :get, "/v1/books/:book_id", capability: :find_book)),
                     ~s(capability: :count),
                     ~s(capability: :count, etag: :total)
                   )
               )

      assert [%{capability: :count, etag: :total}] =
               for(r <- hd(module.__schema__().targets).resources, r.etag, do: r)

      # No integer: a text field.
      fails(
        [
          resources:
            with_etag.(
              ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: :title)
            ),
          statuses: found_book
        ],
        "etag: :title is no required integer field of :book, which outcome :found sends"
      )

      # Not what the success outcome sends: without body:, found sends {book}.
      fails(
        [
          resources:
            with_etag.(
              ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: :edition)
            )
        ],
        "etag: :edition is no required integer field of :found, which outcome :found sends"
      )

      # A field of another outcome than the success one.
      defmodule MissingWithCounts do
        def __schema__ do
          schema = AtlasRuntimeBackend.Generator.Example.Boundary.__schema__()

          capabilities =
            for c <- schema.capabilities do
              if c.name == :find_book,
                do: %{
                  c
                  | outcomes: [%{name: :found, model: :found}, %{name: :busy, model: :busy}]
                },
                else: c
            end

          %{schema | capabilities: capabilities}
        end
      end

      fails(
        [
          boundary: inspect(MissingWithCounts),
          resources:
            with_etag.(
              ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: :retry_after)
            ),
          statuses: found_book
        ],
        "etag: :retry_after is no required integer field of :book, which outcome :found sends"
      )

      # The success outcome is not one: two outcomes below 400.
      fails(
        [
          resources:
            with_etag.(
              ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: :edition)
            ),
          statuses:
            String.replace(
              found_book,
              ~s(status :missing, 404, type: "not-found"),
              "status :missing, 200"
            )
        ],
        "capability :find_book needs exactly one outcome with a single status below 400"
      )

      fails(
        [
          resources:
            String.replace(
              with_etag.(~s(resource :get, "/v1/books/:book_id", capability: :find_book)),
              ~s(capability: :lend, body: :input),
              ~s(capability: :lend, body: :input, etag: :edition)
            ),
          statuses: found_book
        ],
        "resource post /v1/books: etag: goes with a GET"
      )

      fails(
        [
          resources:
            with_etag.(
              ~s(resource :get, "/v1/books/:book_id", capability: :find_book, etag: "edition")
            ),
          statuses: found_book
        ],
        ~s(etag: is a field name, got "edition")
      )
    end

    test "a header with a fixed text" do
      assert [{module, _}] =
               compile(
                 statuses:
                   ~s(    status :lent, 201, header: ["Replayed": "true"]\n    status :busy, 503, type: "busy"\n    status :refused, by: :reason, cases: [invalid: {400, "invalid"}, taken: {409, "taken"}, not_permitted: {403, "not-permitted"}]\n    status :found, 200\n    status :missing, 404, type: "not-found"\n    status :listed, 200\n    status :returned, 200\n    status :counted, 200\n)
               )

      assert %{headers: [{"replayed", "true"}]} =
               Enum.find(hd(module.__schema__().targets).statuses, &(&1.outcome == :lent))
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

    test "a listener's errors: optional, each once, unauthenticated always 401" do
      required =
        ~s(    error :invalid, 400, type: "invalid"\n    error :not_permitted, 403, type: "not-permitted"\n    error :no_route, 404, type: "no-route"\n)

      assert [{_module, _binary}] =
               compile(
                 errors:
                   required <>
                     ~s(    error :unauthenticated, 401, type: "unauthenticated"\n    error :origin_refused, 403, type: "origin-refused"\n)
               )

      fails(
        [errors: required <> ~s(    error :unauthenticated, 403, type: "unauthenticated"\n)],
        "error :unauthenticated: the status is 401"
      )

      fails(
        [
          errors:
            required <> ~s(    error :origin_refused, 403, type: "origin-refused", detail: "x"\n)
        ],
        "error :origin_refused: the only option is type:"
      )

      fails(
        [
          errors:
            required <>
              ~s(    error :origin_refused, 403, type: "a"\n    error :origin_refused, 400, type: "b"\n)
        ],
        "error :origin_refused is declared twice"
      )

      fails(
        [errors: required <> ~s(    error :expired, 401, type: "expired"\n)],
        "error :expired: the kinds are :invalid, :not_permitted, :no_route, :unauthenticated, :origin_refused"
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

      assert rest.errors == [
               %{kind: :invalid, status: 400, type: "invalid"},
               %{kind: :not_permitted, status: 403, type: "not-permitted"},
               %{kind: :no_route, status: 404, type: "no-route"},
               %{kind: :unauthenticated, status: 401, type: "unauthenticated"},
               %{kind: :origin_refused, status: 403, type: "origin-refused"}
             ]
    end
  end
end
