defmodule AtlasRuntimeBackend.Generator.Example.Api do
  @moduledoc "A neutral example backend contract over `AtlasRuntimeBackend.Generator.Example.Boundary`."
  use AtlasRuntimeBackend.Generator.Schema

  version "1.0.0"
  boundary AtlasRuntimeBackend.Generator.Example.Boundary

  expose [:lend, :find_book, :search, :list_books, :give_back, :count, :watch, :scan]
  not_exposed :audit

  rights :socket, [:lend, :browse]
  rights :guest, [:browse]

  event :book, :book_changed, id: :sequence
  event :tick, :tick
  event :restart, :restart, id: :current_sequence

  target :rest do
    resource :post, "/v1/books",
      capability: :lend,
      body: :input,
      header: ["Request-Key": :request_key]

    # A conditional GET: ETag from the book's edition, If-None-Match → 304.
    resource :get, "/v1/books/:book_id", capability: :find_book, etag: :edition
    resource :get, "/v1/books", capability: :search, query: [title: :title]

    resource :get, "/v1/books",
      capability: :list_books,
      query: [condition: :condition, limit: :limit, lent: :lent]

    resource :post, "/v1/books/:book_id/return", capability: :give_back, body: [:note, :hurry]
    resource :get, "/v1/count", capability: :count
    # A download: the outcome's :stream field is the body, its other fields are headers.
    resource :get, "/v1/books/:book_id/scan", capability: :scan

    stream "/v1/events",
      capability: :watch,
      events: [:book, :tick, :restart],
      resume_header: "Last-Event-ID",
      into: :from,
      open: [watching: nil, restart: :restart]

    status :lent, 201, body: :book, header: [location: "/v1/books/{book.book_id}"]
    status :busy, 503, type: "busy", header: ["Retry-After": :retry_after]

    status :refused,
      by: :reason,
      cases: [
        invalid: {400, "invalid"},
        taken: {409, "taken"},
        not_permitted: {403, "not-permitted"}
      ]

    status :found, 200, body: :book
    status :missing, 404, type: "not-found"
    status :listed, 200
    status :returned, 200
    status :counted, 200, header: ["Retry-After": :wait]

    status :scanned, 200,
      stream: :content,
      content_type: "application/octet-stream",
      header: ["Scan-Pages": :pages, "Scanned-At": :scanned_at, "Scan-Of": "/v1/books/{book_id}"]

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
    # A listener's refusals, sent with the router's __problem__/2.
    error :unauthenticated, 401, type: "unauthenticated"
    error :origin_refused, 403, type: "origin-refused"
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.Loop do
  @moduledoc """
  The example's stream loop: it writes the notifications already in the mailbox and ends,
  so a `Plug.Test` request returns. A real loop waits for more.
  """
  def stream(conn, router) do
    receive do
      {:notification, value} ->
        case router.__event__(value) do
          {:ok, frame} ->
            {:ok, conn} = Plug.Conn.chunk(conn, frame)
            stream(conn, router)

          :error ->
            stream(conn, router)
        end
    after
      0 -> conn
    end
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.Rest do
  @moduledoc "The router the example contract generates, on the example facade."
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contract: AtlasRuntimeBackend.Generator.Example.Api,
    facade: AtlasRuntimeBackend.Generator.Example.Facade,
    stream: AtlasRuntimeBackend.Generator.Example.Loop
end
