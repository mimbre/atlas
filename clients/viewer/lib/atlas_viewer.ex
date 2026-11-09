defmodule AtlasViewer do
  @moduledoc """
  Local, read-only browser viewer for a standalone Runtime, over OTP `:inets` httpd bound
  to 127.0.0.1. It holds no domain state: every `POST /api/read` is one runtime.read/1
  request to `<home>/read.sock` (`AtlasViewer.ReadClient`). Starting or stopping the viewer
  never connects to Runtime, and nothing it serves can start, stop, answer or change work.

  - `GET /`, `/assets/app.js`, `/assets/app.css` and `/assets/prism/…` (the built Prism
    fonts) are the static files in `priv/static`.
  - `POST /api/read` takes `{"op", …fields}` with `Authorization: Bearer <token>`. The
    reply is Runtime's own JSON, or `{"viewer_error": {"code", "message"}}`.

  The token is random per launch and kept only in this process; the launcher prints it in
  the URL fragment, which browsers never send. Every request must name this server as
  `Host` (127.0.0.1 or localhost), and `/api/read` also needs the same `Origin`, so other
  sites and rebound DNS names cannot read. There is no CORS and no request logging.
  """
  require Record
  Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

  alias AtlasViewer.ReadClient

  @body_bytes 4096
  @read_ms 10_000
  @static %{
    "/" => {"index.html", ~c"text/html; charset=utf-8"},
    "/assets/app.js" => {"app.js", ~c"text/javascript; charset=utf-8"},
    "/assets/app.css" => {"app.css", ~c"text/css; charset=utf-8"}
  }
  # The asset types assets/build.js may copy from Prism; keep both lists equal.
  @asset_types %{
    ".woff2" => ~c"font/woff2",
    ".woff" => ~c"font/woff",
    ".ttf" => ~c"font/ttf",
    ".otf" => ~c"font/otf",
    ".eot" => ~c"application/vnd.ms-fontobject",
    ".svg" => ~c"image/svg+xml",
    ".png" => ~c"image/png",
    ".jpg" => ~c"image/jpeg",
    ".jpeg" => ~c"image/jpeg",
    ".gif" => ~c"image/gif",
    ".webp" => ~c"image/webp"
  }
  @headers [
    cache_control: ~c"no-store",
    "content-security-policy":
      ~c"default-src 'none'; script-src 'self'; style-src 'self'; font-src 'self' data:; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "x-content-type-options": ~c"nosniff",
    "x-frame-options": ~c"DENY",
    "referrer-policy": ~c"no-referrer",
    "cross-origin-opener-policy": ~c"same-origin",
    "cross-origin-resource-policy": ~c"same-origin"
  ]

  @doc """
  Serve the viewer for the Runtime at `:home` (absolute). Options: `:port` (0 picks one),
  `:static` (default `priv/static`), `:read_ms`. Returns `{:ok, pid, port, token}`.
  """
  def start(opts) do
    home = Keyword.fetch!(opts, :home)
    if Path.type(home) != :absolute, do: raise(ArgumentError, "home must be an absolute path")

    static =
      Keyword.get_lazy(opts, :static, fn -> Application.app_dir(:atlas_viewer, "priv/static") end)

    case Enum.reject(["index.html", "app.js", "app.css"], &File.regular?(Path.join(static, &1))) do
      [] ->
        :ok

      missing ->
        raise "Viewer assets missing in #{static}: #{Enum.join(missing, ", ")} (build with assets/build.js)"
    end

    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, pid} =
      :inets.start(:httpd,
        port: Keyword.get(opts, :port, 0),
        bind_address: {127, 0, 0, 1},
        server_name: ~c"atlas-viewer",
        server_root: String.to_charlist(static),
        document_root: String.to_charlist(static),
        modules: [__MODULE__],
        max_body_size: @body_bytes,
        atlas_viewer: %{
          socket: ReadClient.socket(home),
          static: static,
          digest: :crypto.hash(:sha256, token),
          read_ms: Keyword.get(opts, :read_ms, @read_ms)
        }
      )

    {:ok, pid, :httpd.info(pid)[:port], token}
  end

  def stop(pid), do: :inets.stop(:httpd, pid)

  @doc false
  # httpd callback: every request is answered here; no other module serves files.
  def unquote(:do)(request) do
    settings = :httpd_util.lookup(mod(request, :config_db), :atlas_viewer)
    headers = mod(request, :parsed_header)
    # The bound port; the configuration holds 0 when one was picked.
    {:ok, {_, port}} = :inet.sockname(mod(request, :socket))
    path = request |> mod(:request_uri) |> to_string() |> String.split("?") |> hd()
    host = header(headers, ~c"host")

    {status, type, body} =
      if host in ["127.0.0.1:#{port}", "localhost:#{port}"] or
           (port == 80 and host in ["127.0.0.1", "localhost"]),
        do: route(mod(request, :method), path, request, "http://" <> host, settings),
        else:
          viewer_error(
            403,
            "forbidden_host",
            "This viewer answers only on 127.0.0.1 or localhost"
          )

    headers =
      [code: status, content_type: type, content_length: Integer.to_charlist(byte_size(body))] ++
        @headers

    {:proceed, [response: {:response, headers, [body]}]}
  end

  defp route(~c"GET", path, _request, _origin, settings) when is_map_key(@static, path) do
    {file, type} = @static[path]
    {200, type, File.read!(Path.join(settings.static, file))}
  end

  defp route(~c"GET", "/assets/prism/" <> rest, _request, _origin, settings) do
    segments = rest |> URI.decode() |> String.split("/")
    type = @asset_types[String.downcase(Path.extname(rest))]
    file = Path.join([settings.static, "prism" | segments])

    if type &&
         Enum.all?(
           segments,
           &(&1 not in ["", ".", ".."] and not String.contains?(&1, ["\\", <<0>>]))
         ) &&
         File.regular?(file),
       do: {200, type, File.read!(file)},
       else: viewer_error(404, "not_found", "No such file")
  end

  defp route(~c"POST", "/api/read", request, origin, settings) do
    headers = mod(request, :parsed_header)

    cond do
      header(headers, ~c"origin") != origin ->
        viewer_error(403, "forbidden_origin", "Reads must come from this viewer's own page")

      not authorized?(header(headers, ~c"authorization"), settings.digest) ->
        viewer_error(
          401,
          "unauthorized",
          "Missing or wrong access token; open the URL this viewer printed"
        )

      not String.starts_with?(header(headers, ~c"content-type") || "", "application/json") ->
        viewer_error(415, "unsupported_media_type", "Send application/json")

      true ->
        forward(request |> mod(:entity_body) |> IO.iodata_to_binary(), settings)
    end
  end

  defp route(method, path, _request, _origin, _settings)
       when method == ~c"GET" and path != "/api/read",
       do: viewer_error(404, "not_found", "No such file")

  defp route(_method, _path, _request, _origin, _settings),
    do: viewer_error(405, "method_not_allowed", "This viewer only reads")

  defp forward(body, settings) do
    with {:ok, %{} = decoded} <- JSON.decode(body),
         {:ok, request} <- ReadClient.request(decoded) do
      case ReadClient.read(settings.socket, request, settings.read_ms) do
        {:ok, reply} ->
          {200, ~c"application/json", reply}

        {:error, :unreachable} ->
          viewer_error(
            503,
            "runtime_unreachable",
            "Runtime's read.sock is not accepting connections"
          )

        {:error, :timeout} ->
          viewer_error(
            504,
            "read_timeout",
            "Runtime did not answer within #{settings.read_ms} ms"
          )

        {:error, :no_reply} ->
          viewer_error(502, "no_reply", "Runtime closed the connection without a reply")

        {:error, :bad_reply} ->
          viewer_error(502, "bad_reply", "Runtime's reply was not a JSON object")

        {:error, :too_large} ->
          viewer_error(502, "reply_too_large", "Runtime's reply exceeded the viewer's limit")
      end
    else
      {:error, "not_a_read"} ->
        viewer_error(400, "not_a_read", "Only runtime.read/1 operations are available")

      _ ->
        viewer_error(
          400,
          "invalid_request",
          "Body must be {\"op\": read operation, ...its fields}"
        )
    end
  end

  defp authorized?("Bearer " <> token, digest),
    do: :crypto.hash_equals(:crypto.hash(:sha256, token), digest)

  defp authorized?(_, _digest), do: false

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> to_string(value)
      nil -> nil
    end
  end

  defp viewer_error(status, code, message),
    do:
      {status, ~c"application/json",
       JSON.encode!(%{"viewer_error" => %{"code" => code, "message" => message}})}
end
