defmodule AtlasFlow.Backend.Router do
  @moduledoc """
  The HTTP carriage of Flow's work source (plan m3 §3.6; ADR 0006; decision 2026-11-17
  §6.2): exactly the routes, outcomes, statuses and problem types of the Runtime's
  `work_source` backend contract (its route description, `routes.json`, version 0.2.0),
  and nothing else. `__routes__/0` and `__errors__/0` are that table as data; the router
  answers from it.

  | Route                                    | Capability | Body                              |
  |------------------------------------------|------------|-----------------------------------|
  | `POST /v1/poll`                          | `poll`     | JSON, at most 1 MiB               |
  | `POST /v1/leases/{lease_id}/reports`     | `report`   | JSON, at most 8 MiB               |
  | `GET /v1/leases/{lease_id}/blobs/{sha256}` | `get_blob` | none; the answer is chunked     |
  | `PUT /v1/leases/{lease_id}/blobs/{sha256}` | `put_blob` | the blob's bytes, streamed      |

  The client is `conn.assigns.client`, `{runtime_id, holder}`, set by
  `AtlasFlow.Backend.Listener` from the request's credential before the router runs; the
  router raises without one. It calls the work source (`AtlasFlow.WorkSource`) and nothing
  else.

  **Bodies.** A JSON body holds only its route's body fields (`AtlasFlow.Backend.Codec`);
  anything else is the `invalid` error, and a body past its limit the `too_large` error.
  A `put_blob` body must be `application/octet-stream` (else `unsupported_media_type`),
  with `Blob-Size` its size; it is handed to the work source as a lazy stream of the
  body's chunks, read only as the result store takes them, at most `Blob-Size` + 1
  bytes and never past `blob_max_bytes` (20 MB, the per-result cap) + 1. A body that runs
  past `Blob-Size` is the `too_large` error, whatever the source answered to its bytes
  (it saw one byte too many and keeps nothing). Every body is read by `AtlasBodyLimit`,
  which counts the bytes itself whatever the transfer encoding: Bandit keeps `length:`
  only for a `Content-Length` body and reads a chunked one whole. Answered before the
  body was read to its end, the response says `connection: close` (`AtlasBodyLimit.guard/1`),
  so Bandit does not drain it either. The blob of `get_blob` goes out chunked as it is
  read, with `Blob-Sha256` and `Blob-Size`.

  **Limits** (protection 5; Q9), kept by the listener's `AtlasFlow.Backend.Listener.Limits`:
  at most `rate` requests a second per credential (10), past which the answer is delayed,
  never refused (`routes.json` declares no 429); at most `streams` blob streams at once
  per Runtime (4), past which a blob request waits for one to end. One open poll per
  Runtime is Dispatch's: a second poll answers the first at once.

  **Unavailable.** A report or `put_blob` that Facts could not answer (the source's
  `:unavailable`, `AtlasFlow.Delivery`) is 503 `unavailable`. The contract names no such
  answer, so the Runtime's client takes it as unreachable and the puller sends the same
  request again; never `lease-lost`, which makes a Runtime drop the work.

  Options (`init/1`): `source` (the work source module, `AtlasFlow.WorkSource`),
  `source_opts` (its servers), `limits` (the limits server; none: no limits),
  `poll_max_bytes`, `report_max_bytes`, `blob_max_bytes`, and `sleep` (how a delayed
  request waits, `Process.sleep/1`).
  """
  @behaviour Plug

  import Plug.Conn

  alias AtlasFlow.Backend.{Codec, Listener}

  @rejected [
    %{value: :invalid, status: 400, type: "invalid"},
    %{value: :conflict, status: 409, type: "revision-conflict"},
    %{value: :digest_mismatch, status: 422, type: "digest-mismatch"}
  ]

  @routes [
    %{
      capability: :poll,
      method: "POST",
      path: "/v1/poll",
      headers: %{},
      upload: nil,
      outcomes: [%{outcome: :polled, status: 200}, %{outcome: :rejected, cases: @rejected}]
    },
    %{
      capability: :report,
      method: "POST",
      path: "/v1/leases/{lease_id}/reports",
      headers: %{},
      upload: nil,
      outcomes: [
        %{outcome: :recorded, status: 200},
        %{outcome: :lease_lost, status: 410, type: "lease-lost"},
        %{outcome: :rejected, cases: @rejected}
      ]
    },
    %{
      capability: :get_blob,
      method: "GET",
      path: "/v1/leases/{lease_id}/blobs/{sha256}",
      headers: %{},
      upload: nil,
      outcomes: [
        %{
          outcome: :blob,
          status: 200,
          stream: :content,
          content_type: "application/octet-stream",
          headers: %{"blob-sha256" => :sha256, "blob-size" => :size}
        },
        %{outcome: :not_found, status: 404, type: "not-found"},
        %{outcome: :rejected, cases: @rejected}
      ]
    },
    %{
      capability: :put_blob,
      method: "PUT",
      path: "/v1/leases/{lease_id}/blobs/{sha256}",
      headers: %{"blob-size" => :size},
      upload: %{field: :content, content_type: "application/octet-stream"},
      outcomes: [
        %{outcome: :stored, status: 200},
        %{outcome: :lease_lost, status: 410, type: "lease-lost"},
        %{outcome: :too_large, status: 413, type: "too-large"},
        %{outcome: :not_referenced, status: 409, type: "not-referenced"},
        %{outcome: :rejected, cases: @rejected}
      ]
    }
  ]

  @errors [
    %{kind: :invalid, status: 400, type: "invalid"},
    %{kind: :not_permitted, status: 403, type: "not-permitted"},
    %{kind: :no_route, status: 404, type: "no-route"},
    %{kind: :unauthenticated, status: 401, type: "unauthenticated"},
    %{kind: :too_large, status: 413, type: "too-large"},
    %{kind: :unsupported_media_type, status: 415, type: "unsupported-media-type"}
  ]

  @mib 1_048_576
  @defaults [
    source: AtlasFlow.WorkSource,
    source_opts: [],
    limits: nil,
    poll_max_bytes: @mib,
    report_max_bytes: 8 * @mib,
    blob_max_bytes: 20_000_000,
    sleep: &Process.sleep/1
  ]
  @read [read_timeout: 60_000]

  # The version of the Runtime's backend contract whose routes these are.
  @version "0.2.0"

  @doc "The version of the Runtime's `work_source` backend contract this router carries."
  def __version__, do: @version

  @doc "The routes this router serves, with their outcomes' statuses and problem types."
  def __routes__, do: @routes

  @doc "The router's and the listener's own errors: kind, status and problem type."
  def __errors__, do: @errors

  @impl true
  def init(opts), do: Map.new(Keyword.merge(@defaults, opts))

  @impl true
  def call(%{assigns: %{client: {runtime_id, _holder} = client}} = conn, opts)
      when is_binary(runtime_id) do
    conn = AtlasBodyLimit.guard(conn)
    admit(opts, runtime_id)

    case match(conn.method, conn.path_info) do
      {route, params} -> serve(route.capability, conn, params, client, opts)
      nil -> error(conn, :no_route)
    end
  end

  def call(_conn, _opts),
    do: raise(ArgumentError, "the router runs behind the listener, which sets the client")

  @doc "Sends the error `kind` as its status and problem body, and halts `conn`."
  def error(conn, kind) do
    %{status: status, type: type} = Enum.find(@errors, &(&1.kind == kind))

    conn
    |> json(status, Codec.problem(status, type))
    |> halt()
  end

  ## Routes

  defp match(method, segments) do
    Enum.find_value(@routes, fn route ->
      with ^method <- route.method,
           {:ok, params} <- params(String.split(route.path, "/", trim: true), segments, %{}) do
        {route, params}
      else
        _ -> nil
      end
    end)
  end

  defp params([], [], acc), do: {:ok, acc}

  defp params(["{" <> name | template], [segment | segments], acc) when segment != "",
    do: params(template, segments, Map.put(acc, String.trim_trailing(name, "}"), segment))

  defp params([same | template], [same | segments], acc), do: params(template, segments, acc)
  defp params(_template, _segments, _acc), do: :error

  defp serve(:poll, conn, params, client, opts),
    do: json_route(:poll, conn, params, opts.poll_max_bytes, client, opts)

  defp serve(:report, conn, params, client, opts),
    do: json_route(:report, conn, params, opts.report_max_bytes, client, opts)

  defp serve(:get_blob, conn, params, client, opts) do
    {runtime_id, _} = client

    stream(opts, runtime_id, fn ->
      answer = opts.source.get_blob(client, params, opts.source_opts)

      case Codec.outcome(:get_blob, answer) do
        {:blob, %{sha256: sha, size: size, content: content}} ->
          download(conn, sha, size, content)

        outcome ->
          answer(conn, :get_blob, outcome)
      end
    end)
  end

  defp serve(:put_blob, conn, params, client, opts) do
    {runtime_id, _} = client

    # The Runtime's generated router's order: 415, then 413 by Content-Length, then 400.
    with :ok <- media_type(conn),
         :ok <- length_fits(conn, opts.blob_max_bytes),
         {:ok, size} <- blob_size(conn) do
      stream(opts, runtime_id, fn ->
        {ref, body} = AtlasBodyLimit.stream(conn, min(size, opts.blob_max_bytes), @read)

        input = Map.merge(params, %{"size" => size, "content" => body})
        answer = opts.source.put_blob(client, input, opts.source_opts)

        case AtlasBodyLimit.streamed(ref) do
          {conn, :ended} ->
            answer(conn, :put_blob, Codec.outcome(:put_blob, answer))

          {conn, :too_large} ->
            conn |> put_resp_header("connection", "close") |> error(:too_large)

          {conn, _open_or_failed} ->
            conn
            |> put_resp_header("connection", "close")
            |> answer(:put_blob, Codec.outcome(:put_blob, answer))
        end
      end)
    else
      {:error, kind} -> conn |> put_resp_header("connection", "close") |> error(kind)
    end
  end

  defp json_route(capability, conn, params, limit, client, opts) do
    with :ok <- length_fits(conn, limit),
         {:ok, body, conn} <- read_json(conn, limit),
         {:ok, input} <- input(capability, body, params) do
      answer = apply(opts.source, capability, [client, input, opts.source_opts])
      answer(conn, capability, Codec.outcome(capability, answer))
    else
      {:error, kind} -> conn |> put_resp_header("connection", "close") |> error(kind)
      {:error, kind, conn} -> error(conn, kind)
    end
  end

  defp input(capability, body, params) do
    case Codec.input(capability, body, params) do
      {:ok, input} -> {:ok, input}
      :error -> {:error, :invalid}
    end
  end

  # At most `limit` + 1 bytes are read, counted here whatever the transfer encoding.
  defp read_json(conn, limit) do
    case AtlasBodyLimit.read(conn, limit, @read) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:too_large, conn} ->
        {:error, :too_large, put_resp_header(conn, "connection", "close")}

      {:error, _reason, conn} ->
        {:error, :invalid, put_resp_header(conn, "connection", "close")}
    end
  end

  ## Answers

  # An outcome as its declared status: below 400 its fields as JSON, from 400 up a
  # problem body. Something that is no outcome of the capability is a fault: it raises.
  defp answer(conn, capability, {name, fields}) do
    route = Enum.find(@routes, &(&1.capability == capability))

    case Enum.find(route.outcomes, &(&1.outcome == name)) do
      %{cases: cases} ->
        reason = String.to_existing_atom(fields["reason"])
        %{status: status, type: type} = Enum.find(cases, &(&1.value == reason))
        json(conn, status, Codec.problem(status, type, fields))

      %{status: status, type: type} ->
        json(conn, status, Codec.problem(status, type, fields))

      %{status: status} ->
        json(conn, status, fields || %{})
    end
  end

  defp answer(conn, _capability, :unavailable),
    do: json(conn, 503, Codec.problem(503, "unavailable"))

  defp answer(_conn, capability, :error),
    do: raise(ArgumentError, "the work source answered no outcome of #{capability}")

  defp json(conn, status, body) do
    type = if status >= 400, do: "application/problem+json", else: "application/json"

    conn
    |> put_resp_header("content-type", type)
    |> send_resp(status, Codec.encode(body))
  end

  # Chunked, one chunk per element as it is read; a chunk that cannot be sent (the client
  # went away) halts the enumeration, so the stream's own clean-up runs.
  defp download(conn, sha, size, content) do
    conn =
      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header("blob-sha256", sha)
      |> put_resp_header("blob-size", Integer.to_string(size))
      |> send_chunked(200)

    Enum.reduce_while(content, conn, fn bytes, conn ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, conn}
        {:error, _closed} -> {:halt, conn}
      end
    end)
  end

  ## A streamed request body

  defp media_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if value |> String.split(";") |> hd() |> String.trim() |> String.downcase() ==
             "application/octet-stream",
           do: :ok,
           else: {:error, :unsupported_media_type}

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  defp blob_size(conn) do
    with [text] <- get_req_header(conn, "blob-size"),
         {size, ""} when size >= 0 <- Integer.parse(String.trim(text)) do
      {:ok, size}
    else
      _ -> {:error, :invalid}
    end
  end

  defp length_fits(conn, limit) do
    with [text] <- get_req_header(conn, "content-length"),
         {length, ""} <- Integer.parse(String.trim(text)),
         true <- length > limit do
      {:error, :too_large}
    else
      _ -> :ok
    end
  end

  ## Limits

  defp admit(%{limits: nil}, _runtime_id), do: :ok

  defp admit(%{limits: limits, sleep: sleep}, runtime_id) do
    case Listener.Limits.admit(limits, runtime_id) do
      0 -> :ok
      wait -> sleep.(wait)
    end
  end

  defp stream(%{limits: nil}, _runtime_id, fun), do: fun.()

  defp stream(%{limits: limits}, runtime_id, fun),
    do: Listener.Limits.stream(limits, runtime_id, fun)
end
