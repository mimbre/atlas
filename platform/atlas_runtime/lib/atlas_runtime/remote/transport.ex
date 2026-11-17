defmodule AtlasRuntime.Remote.Transport do
  @moduledoc """
  How `AtlasRuntime.Remote` reaches the Runtime backend (S3 plan B10): OTP `:httpc` in the
  profile of `AtlasRuntime.Remote.Config`, through the core's HTTP CONNECT proxy, with
  verified TLS inside the tunnel and `Authorization: Bearer <token>` on every request. It
  carries requests and answers and decides nothing. The generated client decodes every
  status, a 401 included.

  It sends each request once (B11). `:httpc` would re-send on its own in three cases, and
  each is turned off:
  - a 503 with `Retry-After`: `autoretry: 0`;
  - a request whose kept-alive connection closed before the answer came: each request
    goes on its own connection (`connection: close`), and a first request is never
    re-sent. It also means one CONNECT per request;
  - a redirect: `autoredirect: false`, so the token never goes to another host.

  A redirect is never followed, by `:httpc` or here: any 3xx answer except 304 (which is
  not a redirect, but `If-None-Match`'s answer) is `{:error, {:redirect, status}}`, and
  nothing connects to its `Location`. The backend never redirects, so a 3xx means
  something between the core and the backend is not what it should be.

  A failure is `{:error, reason}`, which the client answers as `{:error, :unreachable}`.
  Such failures are a connection or proxy error, a CONNECT answer other than 200, a TLS
  failure, a timeout, a redirect, `:httpc` itself failing (`{:client_failed, kind}`; an
  exit from it would carry the request, headers included), or the remote client not being
  configured. Each is logged as one warning line with a short reason. The warning never
  includes the request's headers, and a reason is returned and logged with the token
  replaced by `[redacted]`.

  The token: `Config` hands over a closure, and the `Authorization` header is built from it
  only in the argument list of `:httpc.request/5`. From there it lives in `:httpc`'s own
  processes for as long as the request runs (`connection: close` ends the handler with the
  answer). Their log events are redacted by `Config`'s logger filter.

  `opts` (the client's `transport:` option): `timeout:` (ms for a whole answer, default
  15 000), `connect_timeout:` (default 5 000) and, for a stream, `idle_timeout:` (ms without
  a byte before the stream ends with `{:error, :idle_timeout}`, default 45 000, three
  heartbeats).

  A stream's body is read in the process that opened it, because `:httpc` sends it there.
  Halting the enumeration cancels the request.
  """

  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  require Logger

  alias AtlasRuntime.Remote.Config

  @timeout 15_000
  @connect_timeout 5_000
  @idle_timeout 45_000

  # 304 answers If-None-Match; every other 3xx is a redirect, and never followed.
  defguardp redirect?(status) when status in 300..399 and status != 304

  @impl true
  def request(request, opts) do
    with {:ok, context} <- context(request) do
      case httpc(
             context,
             request,
             http_options(context, opts, Keyword.get(opts, :timeout, @timeout)),
             body_format: :binary
           ) do
        {:ok, {{_version, status, _phrase}, _headers, _body}} when redirect?(status) ->
          failed(request, {:redirect, status}, context)

        {:ok, {{_version, status, _phrase}, headers, body}} ->
          {:ok, %{status: status, headers: headers(headers), body: body}}

        {:error, reason} ->
          failed(request, reason, context)
      end
    end
  end

  @impl true
  def stream(request, opts) do
    with {:ok, context} <- context(request) do
      case httpc(
             context,
             request,
             http_options(context, opts, :infinity),
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
        {:ok, ref} -> opened(request, ref, context, opts)
        {:error, reason} -> failed(request, reason, context)
      end
    end
  end

  # The only call with the Authorization header. Whatever :httpc raises or exits with can
  # carry the request record (an exit from its gen_server call does), so none of it
  # leaves here: only its kind does.
  defp httpc(context, request, http_options, options) do
    :httpc.request(
      method(request.method),
      http_request(context, request),
      http_options,
      options,
      context.profile
    )
  catch
    kind, _reason -> {:error, {:client_failed, kind}}
  end

  defp context(request) do
    case Config.context() do
      {:ok, context} -> {:ok, context}
      {:error, reason} -> failed(request, reason, nil)
    end
  end

  # Until the status line and headers: a 200 streams; any other status comes whole.
  defp opened(request, ref, context, opts) do
    receive do
      {:http, {^ref, :stream_start, headers, handler}} ->
        idle = Keyword.get(opts, :idle_timeout, @idle_timeout)
        {:ok, %{status: 200, headers: headers(headers), body: body(ref, handler, context, idle)}}

      {:http, {^ref, {{_version, status, _phrase}, _headers, _body}}} when redirect?(status) ->
        failed(request, {:redirect, status}, context)

      {:http, {^ref, {{_version, status, _phrase}, headers, body}}} ->
        {:ok, %{status: status, headers: headers(headers), body: [body]}}

      {:http, {^ref, {:error, reason}}} ->
        failed(request, reason, context)
    after
      Keyword.get(opts, :timeout, @timeout) ->
        cancel(ref, context.profile)
        failed(request, :timeout, context)
    end
  end

  defp body(ref, handler, context, idle) do
    profile = context.profile

    Stream.resource(
      fn -> :open end,
      fn
        :open ->
          :ok = :httpc.stream_next(handler)

          receive do
            {:http, {^ref, :stream, chunk}} -> {[chunk], :open}
            {:http, {^ref, :stream_end, _headers}} -> {:halt, :ended}
            {:http, {^ref, {:error, reason}}} -> {[{:error, short(reason, context)}], :failed}
          after
            idle -> {[{:error, :idle_timeout}], :failed}
          end

        done ->
          {:halt, done}
      end,
      fn
        :ended -> :ok
        _open_or_failed -> cancel(ref, profile)
      end
    )
  end

  defp cancel(ref, profile) do
    :httpc.cancel_request(ref, profile)
    flush(ref)
  end

  defp flush(ref) do
    receive do
      {:http, {^ref, _}} -> flush(ref)
      {:http, {^ref, _, _}} -> flush(ref)
      {:http, {^ref, _, _, _}} -> flush(ref)
    after
      0 -> :ok
    end
  end

  defp failed(request, reason, context) do
    reason = short(reason, context)

    Logger.warning(
      "AtlasRuntime.Remote: #{request.method} #{request.path} is unreachable: #{inspect(reason)}"
    )

    {:error, reason}
  end

  # The cause, without the TLS options :httpc puts next to it (its CA list, for one), and
  # with the token redacted.
  defp short(reason, %{authorization: authorization}) do
    "Bearer " <> token = authorization.()
    Config.redact(short(reason), token)
  end

  defp short(reason, nil), do: short(reason)

  defp short({:failed_connect, parts}) when is_list(parts) do
    case for {kind, _options, why} <- parts, kind in [:inet, :tls], do: {kind, why} do
      [cause | _] -> {:failed_connect, cause}
      [] -> :failed_connect
    end
  end

  defp short(reason), do: reason

  defp http_request(context, request) do
    url = String.to_charlist(context.base <> request.path <> query(request.query))

    {content_type, headers} =
      Enum.split_with(request.headers, fn {name, _} -> String.downcase(name) == "content-type" end)

    headers =
      [
        {~c"authorization", String.to_charlist(context.authorization.())},
        {~c"connection", ~c"close"}
      ] ++
        for {name, value} <- headers, do: {String.to_charlist(name), String.to_charlist(value)}

    if request.method in ["GET", "HEAD", "DELETE"] and request.body in [nil, ""] do
      {url, headers}
    else
      type =
        case content_type do
          [{_, value} | _] -> value
          [] -> "application/json"
        end

      {url, headers, String.to_charlist(type), request.body || ""}
    end
  end

  defp query(""), do: ""
  defp query(query), do: "?" <> query

  defp http_options(context, opts, timeout),
    do: [
      ssl: context.ssl,
      autoredirect: false,
      autoretry: 0,
      timeout: timeout,
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout)
    ]

  defp method(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp headers(headers),
    do: for({name, value} <- headers, do: {String.downcase(to_string(name)), to_string(value)})
end
