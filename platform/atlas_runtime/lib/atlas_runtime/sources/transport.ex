defmodule AtlasRuntime.Sources.Transport do
  @moduledoc """
  How a puller reaches one remote work source (decision 2026-11-17 §3 "Who authenticates
  whom", §6.2 "TLS and the credential"; M2 plan W3). It is the transport of the
  `work_source` HTTP client (`AtlasRuntimeBackend.Generator.Targets.Client`): it carries
  requests and answers and decides nothing.

  The Runtime authenticates the source by TLS; the source authenticates the Runtime by its
  bearer token (`AtlasRuntime.Sources.Credential`):
  - `https://` only. `open/3` refuses any other URL, and a request can only add a path to
    the opened base, so nothing is ever sent in plain text and nothing falls back to it;
  - TLS 1.3 only (`versions: [:"tlsv1.3"]`), the peer verified (`verify: :verify_peer`)
    against the OS CA store, or the `cacertfile:` given, and its host name checked
    (`customize_hostname_check` with the `https` match);
  - no proxy: the `:httpc` profile is the source's own, started fresh by `open/3` (so no
    earlier connection or TLS session carries over) with `:httpc`'s defaults, which set
    none; `:httpc` reads no proxy from the environment;
  - each request is sent once: `autoretry: 0`, and each request has its own connection
    (`connection: close`), so `:httpc` never re-sends one on a closed keep-alive;
  - no redirect: `autoredirect: false`, and any 3xx answer except 304 is
    `{:error, {:redirect, status}}`; nothing connects to its `Location`, so the token never
    goes to another host;
  - a whole answer may take `timeout_ms/0` (35 s): above the source's `poll_max` (25 s, a
    long poll) plus a margin. `opts` (the client's `transport:` option) may set `timeout:`,
    `connect_timeout:` (default 5 s) and, for a stream, `idle_timeout:` (default 35 s
    without a byte);
  - a streamed request body (the client's enumerable of binaries, as for `put_blob`) is
    sent `transfer-encoding: chunked`, one chunk per element, read only as it is sent, and
    never with a `Content-Length`: for a chunked body `:httpc` itself sets
    `transfer-encoding: chunked` over any the caller gave and drops a `content-length`
    (inets `httpc.erl` `ensure_chunked_encoding/1`, `httpc_request.erl`
    `handle_transfer_encoding/1`; the transport test pins it). A JSON or binary body goes
    with its `Content-Length`, as before.
    `:httpc` reads the enumerable in its own request handler process, so the enumeration
    is started there, not in the caller: a frozen blob is a raw file stream, which only the
    process that opened it may read. `:httpc` has no idle timeout while it sends, so the
    whole `timeout:` the caller gives bounds a stalled upload; a handler still blocked in a
    TLS send after the caller's timeout ends when the connection's profile is stopped
    (`close/1`, as the puller does when it stops).

  A failure is `{:error, reason}` (the client answers it as `{:error, :unreachable}`).
  `reason` is a short term made only from the cause: `:timeout`, `{:redirect, status}`,
  `{:failed_connect, {:tls, alert}}` for a TLS failure (an untrusted or wrong-host
  certificate, a version below 1.3), `{:failed_connect, {:inet, why}}`,
  `{:client_failed, kind}` when `:httpc` raised or exited (an exit from it would carry the
  request, headers included), `:invalid_path` or `:not_open`.
  It never holds a request's headers or body, nor an answer's. Each failure is logged as
  one warning line with the source's name, the method, the path and that reason.

  The token: the connection (`t:t/0`) keeps the credential's closure, and the
  `Authorization` header is built from it only in the argument list of `:httpc.request/5`.
  The connection inspects without it, so a process holding it shows no token in
  `:sys.get_state/1` or `:sys.get_status/1`. In `:httpc`'s own processes the header lives
  as long as the request runs; their log events, and any other log event, are redacted by
  a logger primary filter that `open/3` puts at the head of the filter list (ahead of
  Elixir's translator) and `close/1` removes. If the redaction fails, the event is replaced
  by a one-line notice.

  One source name has one `:httpc` profile and one log filter, so each `open/3` supersedes
  the connection an earlier `open/3` of that name answered (credential rotation is
  re-opening): the earlier one's profile is stopped and its filter replaced. Each
  connection carries the tag of its own `open/3`, which its filter holds too. A superseded
  connection answers every request with `:not_open` (its token is no longer redacted), and
  `close/1` of it changes nothing, so closing an old connection never breaks a newer one.
  """

  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  require Logger

  alias AtlasRuntime.Sources.Credential

  @poll_max 25_000
  @timeout @poll_max + 10_000
  @connect_timeout 5_000
  @idle_timeout @timeout

  @enforce_keys [:name, :base, :profile, :ssl, :filter, :secret, :tag]
  defstruct @enforce_keys

  @typedoc "An open connection to one source: pass it as the client's `transport: [conn: t]`."
  @type t :: %__MODULE__{}

  # 304 answers If-None-Match; every other 3xx is a redirect, and never followed.
  defguardp redirect?(status) when status in 300..399 and status != 304

  @doc "How long a whole answer may take by default, in ms: above `poll_max` plus a margin."
  def timeout_ms, do: @timeout

  @doc """
  Opens source `name` at `url` (`https://<host>[:<port>][/<path>]`, no user, query or
  fragment) with its credential from the Runtime home. `opts`: `home:` (required),
  `cacertfile:` (a PEM file of the CAs to trust; default the OS store) and `uid:` (passed
  to `Credential.load/3`). Answers `{:ok, conn}` or `{:error, reason}`:
  `{:url, :not_https | :invalid}`, `{:credential, why}`, `:no_cacerts` or
  `{:client, :not_started}`. Call `close/1` when done.
  """
  @spec open(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(name, url, opts) do
    home = Keyword.fetch!(opts, :home)

    with {:ok, %{host: host, base: base}} <- parse_url(url),
         {:ok, secret} <- Credential.load(home, name, Keyword.take(opts, [:uid])),
         {:ok, trust} <- trust(Keyword.get(opts, :cacertfile)),
         {:ok, profile} <- start_profile(name) do
      filter = :"atlas_runtime_source_token_#{name}"
      tag = make_ref()
      :ok = add_log_filter(filter, secret, tag)

      {:ok,
       %__MODULE__{
         name: name,
         base: base,
         profile: profile,
         ssl: ssl(host, trust),
         filter: filter,
         secret: secret,
         tag: tag
       }}
    end
  end

  @doc """
  Closes `conn`: stops its `:httpc` profile and removes its log filter, unless a later
  `open/3` of the same source has superseded it (then those are the later connection's, and
  are left alone).
  """
  def close(%__MODULE__{} = conn) do
    if current?(conn) do
      _ = :inets.stop(:httpc, conn.profile)
      _ = :logger.remove_primary_filter(conn.filter)
    end

    :ok
  end

  # Whether conn is its source's latest open: the log filter of its name holds its tag.
  defp current?(%__MODULE__{filter: filter, tag: tag}) do
    case List.keyfind(:logger.get_primary_config().filters, filter, 0) do
      {^filter, {_fun, {_secret, ^tag}}} -> true
      _ -> false
    end
  end

  @doc """
  A source URL's parts: `{:ok, %{host:, port:, base:}}` for an `https://` URL with a host
  and no user, query or fragment (a path is a prefix, kept without its trailing `/`), else
  `{:error, {:url, :not_https | :invalid}}`.
  """
  def parse_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" ->
        {:error, {:url, :not_https}}

      uri.host in [nil, ""] or uri.userinfo != nil or uri.query != nil or uri.fragment != nil or
        uri.port not in 1..65_535 or String.contains?(url, ["\s", "\\"]) ->
        {:error, {:url, :invalid}}

      true ->
        prefix = String.trim_trailing(uri.path || "", "/")
        {:ok, %{host: uri.host, port: uri.port, base: "https://#{uri.host}:#{uri.port}#{prefix}"}}
    end
  end

  def parse_url(_url), do: {:error, {:url, :invalid}}

  @doc "The TLS options of a connection to `host`, trusting `trust` (`{:cacerts, ders}` or `{:cacertfile, path}`)."
  def ssl(host, {kind, value}) when kind in [:cacerts, :cacertfile],
    do: [
      {:verify, :verify_peer},
      {kind, value},
      {:server_name_indication, String.to_charlist(host)},
      {:customize_hostname_check,
       [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]},
      {:versions, [:"tlsv1.3"]},
      {:depth, 4}
    ]

  ## The behaviour

  @impl true
  def request(request, opts) do
    with {:ok, conn} <- conn(request, opts) do
      case httpc(
             conn,
             request,
             http_options(conn, opts, Keyword.get(opts, :timeout, @timeout)),
             body_format: :binary
           ) do
        {:ok, {{_version, status, _phrase}, _headers, _body}} when redirect?(status) ->
          failed(conn, request, {:redirect, status})

        {:ok, {{_version, status, _phrase}, headers, body}} ->
          {:ok, %{status: status, headers: headers(headers), body: body}}

        {:error, reason} ->
          failed(conn, request, reason)
      end
    end
  end

  @impl true
  def stream(request, opts) do
    with {:ok, conn} <- conn(request, opts) do
      case httpc(
             conn,
             request,
             http_options(conn, opts, :infinity),
             sync: false,
             stream: {:self, :once},
             body_format: :binary
           ) do
        {:ok, ref} -> opened(conn, request, ref, opts)
        {:error, reason} -> failed(conn, request, reason)
      end
    end
  end

  # The only call with the Authorization header. Whatever :httpc raises or exits with can
  # carry the request record (an exit from its gen_server call does), so none of it
  # leaves here: only its kind does.
  defp httpc(conn, request, http_options, options) do
    :httpc.request(
      method(request.method),
      http_request(conn, request),
      http_options,
      options,
      conn.profile
    )
  catch
    kind, _reason -> {:error, {:client_failed, kind}}
  end

  defp conn(request, opts) do
    case Keyword.get(opts, :conn) do
      %__MODULE__{} = conn ->
        cond do
          not current?(conn) ->
            failed(conn, request, :not_open)

          String.starts_with?(request.path, "/") and not String.starts_with?(request.path, "//") ->
            {:ok, conn}

          true ->
            failed(conn, request, :invalid_path)
        end

      _ ->
        Logger.warning("AtlasRuntime.Sources: #{request.method} #{request.path}: not open")
        {:error, :not_open}
    end
  end

  # Until the status line and headers: a 200 streams; any other status comes whole.
  defp opened(conn, request, ref, opts) do
    receive do
      {:http, {^ref, :stream_start, headers, handler}} ->
        idle = Keyword.get(opts, :idle_timeout, @idle_timeout)
        {:ok, %{status: 200, headers: headers(headers), body: body(conn, ref, handler, idle)}}

      {:http, {^ref, {{_version, status, _phrase}, _headers, _body}}} when redirect?(status) ->
        failed(conn, request, {:redirect, status})

      {:http, {^ref, {{_version, status, _phrase}, headers, body}}} ->
        {:ok, %{status: status, headers: headers(headers), body: [body]}}

      {:http, {^ref, {:error, reason}}} ->
        failed(conn, request, reason)
    after
      Keyword.get(opts, :timeout, @timeout) ->
        cancel(ref, conn.profile)
        failed(conn, request, :timeout)
    end
  end

  defp body(conn, ref, handler, idle) do
    profile = conn.profile

    Stream.resource(
      fn -> :open end,
      fn
        :open ->
          :ok = :httpc.stream_next(handler)

          receive do
            {:http, {^ref, :stream, chunk}} -> {[chunk], :open}
            {:http, {^ref, :stream_end, _headers}} -> {:halt, :ended}
            {:http, {^ref, {:error, reason}}} -> {[{:error, short(reason)}], :failed}
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

  defp failed(conn, request, reason) do
    reason = short(reason)

    Logger.warning(
      "AtlasRuntime.Sources: #{conn.name}: #{request.method} #{request.path} failed: #{inspect(reason)}"
    )

    {:error, reason}
  end

  # Only the cause's shape: never the TLS options :httpc puts next to it (its CA list, for
  # one), and nothing of a request or an answer.
  defp short({:failed_connect, parts}) when is_list(parts) do
    case for {kind, _options, why} <- parts, kind in [:inet, :tls], do: {kind, cause(why)} do
      [{_kind, {:tls, alert}} | _] -> {:failed_connect, {:tls, alert}}
      [cause | _] -> {:failed_connect, cause}
      [] -> :failed_connect
    end
  end

  defp short({:redirect, status}) when is_integer(status), do: {:redirect, status}
  defp short({:client_failed, kind}) when is_atom(kind), do: {:client_failed, kind}
  defp short(reason) when is_atom(reason), do: reason
  defp short({tag, _detail}) when is_atom(tag), do: tag
  defp short(_reason), do: :failed

  # A TLS alert is a TLS failure, whichever part :httpc files it under.
  defp cause({:tls_alert, {alert, _description}}) when is_atom(alert), do: {:tls, alert}
  defp cause(why) when is_atom(why), do: why
  defp cause({tag, _}) when is_atom(tag), do: tag
  defp cause(_why), do: :failed

  defp http_request(conn, request) do
    url = String.to_charlist(conn.base <> request.path <> query(request.query))

    {content_type, headers} =
      request.headers
      |> Enum.reject(fn {name, _} -> String.downcase(name) in ["authorization", "connection"] end)
      |> Enum.split_with(fn {name, _} -> String.downcase(name) == "content-type" end)

    headers =
      [
        {~c"authorization", String.to_charlist(conn.secret.())},
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

      {url, headers, String.to_charlist(type), body(request.body)}
    end
  end

  # A binary (JSON) goes with its Content-Length. A streamed body (the caller's enumerable
  # of binaries) goes chunked, one chunk per element, read only as :httpc sends it. The
  # reduce is *started* by the first `next_chunk/1` call, which :httpc makes in its own
  # request handler process, so the enumerable is opened, read and closed all in that one
  # process: a frozen blob is a raw `File.stream!`, readable only by the process that opened
  # it (a reduce begun here and resumed there answers `:not_on_controlling_process`).
  defp body(nil), do: ""
  defp body(body) when is_binary(body), do: body
  defp body(enumerable), do: {:chunkify, &__MODULE__.next_chunk/1, {:unstarted, enumerable}}

  @doc false
  # :httpc's chunk function: `{:ok, chunk, acc}` for each non-empty element, then `:eof`
  # (an empty chunk would end the body early, so it is skipped). It runs in :httpc's handler.
  def next_chunk({:unstarted, enumerable}),
    do: resumed(Enumerable.reduce(enumerable, {:cont, nil}, &suspend/2))

  def next_chunk({:suspended, continuation}), do: resumed(continuation.({:cont, nil}))

  defp suspend(element, _acc), do: {:suspend, element}

  defp resumed({:suspended, element, continuation}) do
    if IO.iodata_length(element) == 0,
      do: next_chunk({:suspended, continuation}),
      else: {:ok, element, {:suspended, continuation}}
  end

  defp resumed({done, _acc}) when done in [:done, :halted], do: :eof

  defp query(""), do: ""
  defp query(nil), do: ""
  defp query(query), do: "?" <> query

  defp http_options(conn, opts, timeout),
    do: [
      ssl: conn.ssl,
      autoredirect: false,
      autoretry: 0,
      timeout: timeout,
      connect_timeout: Keyword.get(opts, :connect_timeout, @connect_timeout)
    ]

  defp method(method), do: method |> String.downcase() |> String.to_existing_atom()

  defp headers(headers),
    do: for({name, value} <- headers, do: {String.downcase(to_string(name)), to_string(value)})

  ## Setup

  defp trust(nil) do
    {:ok, {:cacerts, :public_key.cacerts_get()}}
  rescue
    _ -> {:error, :no_cacerts}
  end

  defp trust(file) when is_binary(file) do
    if File.regular?(file),
      do: {:ok, {:cacertfile, String.to_charlist(file)}},
      else: {:error, :no_cacerts}
  end

  # The source's own profile, started fresh: no connection or TLS session of an earlier
  # open carries over, and its options are :httpc's defaults (no proxy).
  defp start_profile(name) do
    profile = :"atlas_runtime_source_#{name}"

    with {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, _} <- Application.ensure_all_started(:inets) do
      _ = :inets.stop(:httpc, profile)

      case :inets.start(:httpc, profile: profile) do
        {:ok, _pid} -> {:ok, profile}
        {:error, _} -> {:error, {:client, :not_started}}
      end
    else
      _ -> {:error, {:client, :not_started}}
    end
  end

  ## The token in logs

  # At the head of the primary filters, so it sees each event before Elixir's translator
  # formats it (with inspect limits that could cut the token into a part no match finds).
  defp add_log_filter(filter, secret, tag) do
    others = List.keydelete(:logger.get_primary_config().filters, filter, 0)

    :logger.set_primary_config(:filters, [
      {filter, {&__MODULE__.log_filter/2, {secret, tag}}} | others
    ])
  end

  @doc false
  # The logger primary filter: the event with the token replaced by `[redacted]`. It never
  # raises (logger would drop a raising filter, and with it the redaction): when the
  # redaction fails, the event is replaced by a notice.
  def log_filter(%{msg: msg, meta: meta} = event, {secret, _tag}) do
    "Bearer " <> token = secret.()
    %{event | msg: Credential.redact(msg, token), meta: Credential.redact(meta, token)}
  catch
    _kind, _reason ->
      %{
        event
        | msg:
            {:string, "AtlasRuntime.Sources: a log event was dropped (token redaction failed)"},
          meta: Map.take(event.meta, [:time, :pid, :gl, :domain])
      }
  end

  def log_filter(event, _config), do: event

  defimpl Inspect do
    def inspect(conn, _opts), do: "#AtlasRuntime.Sources.Transport<#{conn.name} #{conn.base}>"
  end
end
