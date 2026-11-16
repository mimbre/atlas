defmodule AtlasRuntime.Remote.Config do
  @moduledoc """
  Where `AtlasRuntime.Remote` reaches a Runtime backend, and with which token (design
  2026-11-16-runtime-backend §9; S3 plan B10, P6). The core runs this only when
  `ATLAS_RUNTIME_REMOTE=1`. With the flag unset or `0`, `child_specs/1` starts nothing and
  reads no other variable. Any other value is a startup error.

  When it starts, it reads:
  - `ATLAS_RUNTIME_BACKEND_URL`: `https://<host>:<port>`, the mini's `tailscale serve`
    address. It must have an explicit port and no path, query, fragment or user;
  - `ATLAS_RUNTIME_BACKEND_TOKEN`: the bearer token. It is read once and then removed from
    the OS environment (`System.delete_env/1`), even when the configuration turns out to be
    invalid. After that this process holds it, only inside a closure (an inspected closure
    shows no captured values), and `format_status/1` redacts even that. So the token is in
    none of this process's `:sys.get_status/1`, `:sys.get_state/1` or crash reports.

  While it runs, the process also keeps a logger primary filter (`log_filter/2`) at the head
  of the filter list, ahead of Elixir's translator. It replaces the token, wherever it appears
  in any log event of any process (a binary or a charlist, at any depth of a report, a
  format's arguments or the metadata), with `[redacted]`. That covers the one place the token
  must go as plain text: the request headers inside `:httpc`'s own processes, whose crash
  reports (state, last message, mailbox) would otherwise print them. If the redaction itself
  fails, the event is dropped and replaced by a one-line notice.

  Every request goes through the core's own `tailscaled` outbound HTTP proxy at
  `localhost:1055`, as HTTP CONNECT, with TLS inside the tunnel. The client verifies the
  peer and its host name against the OS CA store (`:public_key.cacerts_get/0`, else
  `SSL_CERT_FILE`). The `:httpc` profile `#{inspect(:atlas_runtime_remote)}` is this
  process's. It is started fresh, so no older connection or TLS session carries over, and
  it is stopped with this process. `AtlasRuntime.Remote.Transport` says how a request is
  sent (once, and never to another host).

  An invalid configuration stops the start with a reason that names the variable and never
  quotes the token.

  It is a `:temporary` child: the token is gone from the environment once read, so a
  restart could only fail, and the failed restarts would take the application's
  supervisor, and with it the core, down. After a crash the remote client is simply not
  configured (`{:error, :not_configured}`) until the core is restarted.
  """

  use GenServer, restart: :temporary

  @flag "ATLAS_RUNTIME_REMOTE"
  @url "ATLAS_RUNTIME_BACKEND_URL"
  @token "ATLAS_RUNTIME_BACKEND_TOKEN"
  @proxy {"localhost", 1055}
  @profile :atlas_runtime_remote
  @redacted "[redacted]"
  @filter :atlas_runtime_remote_token

  @doc """
  The application's children for the flag: none when `ATLAS_RUNTIME_REMOTE` is unset or
  `0`, this process when it is `1`. Only the flag is read here.
  """
  def child_specs(env \\ &System.get_env/1) do
    case env.(@flag) do
      off when off in [nil, "", "0"] -> []
      "1" -> [__MODULE__]
      _other -> raise ArgumentError, "#{@flag} must be 0 or 1"
    end
  end

  @doc """
  Starts the configuration process. `opts` are for tests: `proxy:` (`{host, port}`, default
  `localhost:1055`), `cacerts:` (DER certificates, default the OS store) and `env:` (how a
  variable is read, default `System.get_env/1`). The token is always removed from the OS
  environment.
  """
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Whether the remote client is configured (this process runs)."
  def configured?, do: GenServer.whereis(__MODULE__) != nil

  @doc """
  What a request needs: `%{base: url, authorization: secret, ssl: options, profile: httpc
  profile}`, or `{:error, :not_configured}`. `secret` is a closure that answers the
  `Authorization` header value; call it only where the header is built, never store or log
  its result.
  """
  def context do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :not_configured}
      pid -> GenServer.call(pid, :context)
    end
  catch
    :exit, _ -> {:error, :not_configured}
  end

  @doc """
  The backend URL's parts: `{:ok, %{host:, port:, base:}}` for `https://<host>:<port>`, else
  `{:error, why}`.
  """
  def parse_url(text) when is_binary(text) do
    uri = URI.parse(text)

    cond do
      uri.scheme != "https" ->
        {:error, "#{@url} must be an https:// URL"}

      not Regex.match?(
        ~r/\A[a-z]+:\/\/[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?:[0-9]{1,5}\z/,
        text
      ) ->
        {:error, "#{@url} must be https://<host>:<port>, with no path, query, fragment or user"}

      uri.port not in 1..65_535 ->
        {:error, "#{@url} has a port outside 1-65535"}

      true ->
        {:ok, %{host: uri.host, port: uri.port, base: "https://#{uri.host}:#{uri.port}"}}
    end
  end

  def parse_url(_text), do: {:error, "#{@url} is not set"}

  ## Server

  @impl true
  def init(opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    # Read once, then gone from the OS environment, whatever comes next.
    token = env.(@token)
    System.delete_env(@token)

    with {:ok, url} <- parse_url(env.(@url)),
         :ok <- check_token(token),
         {:ok, cacerts} <- cacerts(Keyword.get(opts, :cacerts, :system), env),
         :ok <- start_profile(Keyword.get(opts, :proxy, @proxy)) do
      Process.flag(:trap_exit, true)
      secret = fn -> token end
      :ok = add_log_filter(secret)

      {:ok,
       %{
         base: url.base,
         host: url.host,
         port: url.port,
         secret: secret,
         ssl: ssl(url.host, cacerts),
         profile: @profile
       }}
    else
      {:error, why} -> {:stop, {:invalid_config, why}}
    end
  end

  @impl true
  def handle_call(:context, _from, state) do
    {:reply,
     {:ok,
      %{
        base: state.base,
        authorization: authorization(state.secret),
        ssl: state.ssl,
        profile: state.profile
      }}, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :inets.stop(:httpc, @profile)
    :logger.remove_primary_filter(@filter)
  end

  @impl true
  def format_status(status), do: Map.update(status, :state, nil, &redact_state/1)

  defp redact_state(%{secret: _} = state), do: %{state | secret: @redacted}
  defp redact_state(state), do: state

  defp authorization(secret) do
    token = secret.()
    fn -> "Bearer " <> token end
  end

  ## The token in logs

  # At the head of the primary filters, so it sees each event before Elixir's translator
  # formats it (with inspect limits that could cut the token into a part no match finds).
  defp add_log_filter(secret) do
    others = List.keydelete(:logger.get_primary_config().filters, @filter, 0)
    :logger.set_primary_config(:filters, [{@filter, {&__MODULE__.log_filter/2, secret}} | others])
  end

  @doc false
  # The logger primary filter: the event with the token replaced by `[redacted]`. It never
  # raises (logger would drop a raising filter, and with it the redaction): when the
  # redaction fails, the event is replaced by a notice.
  def log_filter(%{msg: msg, meta: meta} = event, secret) do
    token = secret.()
    %{event | msg: redact(msg, token), meta: redact(meta, token)}
  catch
    _kind, _reason ->
      %{
        event
        | msg: {:string, "AtlasRuntime.Remote: a log event was dropped (token redaction failed)"},
          meta: Map.take(event.meta, [:time, :pid, :gl, :domain])
      }
  end

  def log_filter(event, _secret), do: event

  @doc """
  `term` with every occurrence of `token` (in a binary or a charlist, at any depth) replaced
  by `[redacted]`.
  """
  def redact(term, token) when is_binary(token) and token != "", do: scrub(term, token)

  defp scrub(bin, token) when is_binary(bin) do
    if :binary.match(bin, token) == :nomatch,
      do: bin,
      else: :binary.replace(bin, token, @redacted, [:global])
  end

  defp scrub(list, token) when is_list(list) do
    if chars?(list) do
      case :unicode.characters_to_binary(list) do
        bin when is_binary(bin) ->
          if :binary.match(bin, token) == :nomatch,
            do: list,
            else: String.to_charlist(:binary.replace(bin, token, @redacted, [:global]))

        _not_unicode ->
          list
      end
    else
      scrub_items(list, token)
    end
  end

  defp scrub(tuple, token) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> scrub_items(token) |> List.to_tuple()

  defp scrub(map, token) when is_map(map),
    do: :maps.fold(fn k, v, acc -> Map.put(acc, scrub(k, token), scrub(v, token)) end, %{}, map)

  defp scrub(other, _token), do: other

  defp chars?([c | rest]) when is_integer(c) and c in 0..0x10FFFF, do: chars?(rest)
  defp chars?([]), do: true
  defp chars?(_), do: false

  # Also an improper list's tail.
  defp scrub_items([item | rest], token), do: [scrub(item, token) | scrub_items(rest, token)]
  defp scrub_items([], _token), do: []
  defp scrub_items(tail, token), do: scrub(tail, token)

  # A token68 (RFC 7235), so it cannot break the header it is sent in.
  defp check_token(token) when is_binary(token) do
    if byte_size(token) <= 4096 and Regex.match?(~r/\A[A-Za-z0-9._~+\/-]+=*\z/, token),
      do: :ok,
      else: {:error, "#{@token} is not a bearer token"}
  end

  defp check_token(_token), do: {:error, "#{@token} is not set"}

  defp cacerts(cacerts, _env) when is_list(cacerts) and cacerts != [], do: {:ok, cacerts}

  defp cacerts(:system, env) do
    {:ok, :public_key.cacerts_get()}
  rescue
    _ ->
      with file when is_binary(file) and file != "" <- env.("SSL_CERT_FILE"),
           :ok <- :public_key.cacerts_load(String.to_charlist(file)) do
        {:ok, :public_key.cacerts_get()}
      else
        _ -> {:error, "no CA certificates: none in the OS store, and SSL_CERT_FILE gives none"}
      end
  end

  defp start_profile({host, port}) do
    # A fresh profile: no connection or TLS session of an earlier start carries over.
    _ = :inets.stop(:httpc, @profile)

    with {:ok, _pid} <- :inets.start(:httpc, profile: @profile),
         :ok <-
           :httpc.set_options(
             [https_proxy: {{String.to_charlist(host), port}, []}],
             @profile
           ) do
      :ok
    else
      {:error, why} -> {:error, "the HTTP client did not start: #{inspect(why)}"}
    end
  end

  defp ssl(host, cacerts),
    do: [
      verify: :verify_peer,
      cacerts: cacerts,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
      versions: [:"tlsv1.3", :"tlsv1.2"],
      depth: 4
    ]
end
