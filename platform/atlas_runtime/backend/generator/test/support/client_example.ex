defmodule AtlasRuntimeBackend.Generator.Example.PlugTransport do
  @moduledoc """
  The example clients' transport: it serves each request with a generated router (or a
  listener plug in front of one) through `Plug.Test`, in the calling process, so client and
  server come from one contract. It tells the caller about every request
  (`{:transport, request}`).

  Options (`transport:` of a call):
  - `plug:` the Plug that answers (default the example router);
  - `client:` the `{id, rights}` the listener would put in the assigns (default a member
    with every right), or `:none` for a listener plug that sets it itself;
  - `token:` sent as `Authorization: Bearer <token>`; `origin:` sent as `Origin`;
  - `chunk:` a stream's body in pieces of this many bytes; `fail_after:` a stream that
    fails after its body;
  - `fail:` no answer, `{:error, reason}`; `respond: {status, body}` (or `{status, body,
    headers}`) a canned answer.
  """
  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  import Plug.Conn

  @member {"ann", [:lend, :browse]}

  @impl true
  def request(request, opts) do
    send(self(), {:transport, request})

    with {:ok, conn} <- serve(request, opts),
         do: {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body || ""}}
  end

  @impl true
  def stream(request, opts) do
    send(self(), {:transport, request})

    with {:ok, conn} <- serve(request, opts) do
      size = Keyword.get(opts, :chunk, 1_048_576)
      chunks = pieces(conn.resp_body || "", size)
      tail = if opts[:fail_after], do: [{:error, :closed}], else: []
      {:ok, %{status: conn.status, headers: conn.resp_headers, body: Stream.concat(chunks, tail)}}
    end
  end

  defp serve(request, opts) do
    cond do
      reason = opts[:fail] ->
        {:error, reason}

      canned = opts[:respond] ->
        {status, body, headers} =
          case canned do
            {status, body} -> {status, body, []}
            {_status, _body, _headers} = canned -> canned
          end

        {:ok, %Plug.Conn{status: status, resp_headers: headers, resp_body: body}}

      true ->
        target =
          if request.query == "", do: request.path, else: request.path <> "?" <> request.query

        # A streamed body (an upload) goes to Plug.Test whole: it reads no socket.
        body =
          case request.body do
            nil -> ""
            body when is_binary(body) -> body
            chunks -> chunks |> Enum.to_list() |> IO.iodata_to_binary()
          end

        conn = Plug.Test.conn(request.method, target, body)

        conn =
          Enum.reduce(request.headers, conn, fn {k, v}, conn -> put_req_header(conn, k, v) end)

        conn =
          if t = opts[:token],
            do: put_req_header(conn, "authorization", "Bearer " <> t),
            else: conn

        conn = if o = opts[:origin], do: put_req_header(conn, "origin", o), else: conn

        conn =
          case Keyword.get(opts, :client, @member) do
            :none -> conn
            client -> assign(conn, :client, client)
          end

        plug = Keyword.get(opts, :plug, AtlasRuntimeBackend.Generator.Example.Rest)
        {:ok, plug.call(conn, plug.init([]))}
    end
  end

  defp pieces(<<>>, _size), do: []
  defp pieces(binary, size) when byte_size(binary) <= size, do: [binary]

  defp pieces(binary, size) do
    <<piece::binary-size(size), rest::binary>> = binary
    [piece | pieces(rest, size)]
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.Client do
  @moduledoc "The client the example contract generates, on the Plug.Test transport."
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.Generator.Example.Api,
    transport: AtlasRuntimeBackend.Generator.Example.PlugTransport
end

## A capability with a 410 outcome next to a 404 one, and a `body:` outcome whose model has
## another required field (the example has neither): a second small contract in the DSL,
## with its own facade and generated router.

defmodule AtlasRuntimeBackend.Generator.Example.GoneBoundary do
  @moduledoc """
  The example boundary with two more outcomes of `find_book`: `withdrawn`, a book that
  existed and is gone, unlike `missing`, one never seen; and `reserved`, whose model holds
  the book and `until` (both required), while its status sends only the book (`body:`).
  """
  @base AtlasRuntimeBackend.Generator.Example.Boundary

  def __schema__ do
    schema = @base.__schema__()

    withdrawn = %{
      name: :withdrawn,
      fields: [
        %{name: :book_id, type: :string, required: true},
        %{name: :kind, type: {:enum, [:lost, :sold]}, required: true}
      ]
    }

    reserved = %{
      name: :reserved,
      fields: [
        %{name: :until, type: :datetime, required: true},
        %{name: :book, type: :book, required: true}
      ]
    }

    added = [%{name: :withdrawn, model: :withdrawn}, %{name: :reserved, model: :reserved}]

    capabilities =
      for c <- schema.capabilities do
        if c.name == :find_book, do: %{c | outcomes: c.outcomes ++ added}, else: c
      end

    %{schema | models: schema.models ++ [withdrawn, reserved], capabilities: capabilities}
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.GoneApi do
  @moduledoc "A backend contract over `GoneBoundary` that exposes only `find_book`."
  use AtlasRuntimeBackend.Generator.Schema

  version "1.0.0"
  boundary AtlasRuntimeBackend.Generator.Example.GoneBoundary

  expose [:find_book]
  not_exposed [:lend, :search, :list_books, :give_back, :count, :watch, :scan, :deposit, :audit]

  rights :socket, [:browse]

  target :rest do
    resource :get, "/v1/books/:book_id", capability: :find_book

    status :found, 200, body: :book
    status :withdrawn, 410, type: "withdrawn"
    status :missing, 404, type: "not-found"
    status :reserved, 202, body: :book

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.GoneFacade do
  @moduledoc """
  The facade for `GoneApi`: book `withdrawn` is gone, book `missing` was never seen, book
  `reserved` is reserved until a time the 202 does not send.
  """
  alias AtlasRuntimeBackend.Generator.Example.Struct, as: S
  alias AtlasRuntimeBackend.Generator.Example.Types, as: T
  alias AtlasRuntimeBackend.Generator.Example.Facade.Book

  defmodule FindBookInput, do: use(S, book_id: {:string, true})

  defmodule Outcome do
    @moduledoc false
    defmodule Found, do: use(S, book: {T.book(), true})
    defmodule Missing, do: use(S, [])

    defmodule Withdrawn,
      do: use(S, book_id: {:string, true}, kind: {{:enum, [:lost, :sold]}, true})

    defmodule Reserved, do: use(S, until: {:datetime, true}, book: {T.book(), true})
  end

  def find_book({_id, rights}, input) do
    cond do
      :browse not in rights ->
        :denied

      input.book_id == "missing" ->
        %Outcome.Missing{}

      input.book_id == "withdrawn" ->
        %Outcome.Withdrawn{book_id: "withdrawn", kind: :lost}

      input.book_id == "reserved" ->
        reserved()

      true ->
        %Outcome.Found{
          book: %Book{book_id: input.book_id, title: "Dune", condition: :new, edition: 1}
        }
    end
  end

  defp reserved do
    %Outcome.Reserved{
      until: ~U[2026-11-20 12:00:00Z],
      book: %Book{book_id: "reserved", title: "Dune", condition: :new, edition: 1}
    }
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.GoneRest do
  @moduledoc "The router `GoneApi` generates."
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contract: AtlasRuntimeBackend.Generator.Example.GoneApi,
    facade: AtlasRuntimeBackend.Generator.Example.GoneFacade
end

defmodule AtlasRuntimeBackend.Generator.Example.GoneClient do
  @moduledoc "The client `GoneApi` generates."
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.Generator.Example.GoneApi,
    transport: AtlasRuntimeBackend.Generator.Example.PlugTransport
end

defmodule AtlasRuntimeBackend.Generator.Example.TokenListener do
  @moduledoc """
  A listener plug in front of the example's generated router, in the order of the
  Runtime's TCP listener: `Origin` → the router's `__problem__(:origin_refused, conn)`; a
  Bearer token `member-token` or `guest-token` → that client in the assigns, anything
  else → `WWW-Authenticate: Bearer` and `__problem__(:unauthenticated, conn)`. The
  problem bodies, the `ETag` and the 304 all come from the generated router.
  """
  @behaviour Plug
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.Rest

  @tokens %{
    "member-token" => {"token:ann", [:lend, :browse]},
    "guest-token" => {"token:guest", [:browse]}
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    cond do
      get_req_header(conn, "origin") != [] ->
        Rest.__problem__(:origin_refused, conn)

      client = client(conn) ->
        conn |> assign(:client, client) |> Rest.call(Rest.init([]))

      true ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> then(&Rest.__problem__(:unauthenticated, &1))
    end
  end

  defp client(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> Map.get(@tokens, token)
      _ -> nil
    end
  end
end
