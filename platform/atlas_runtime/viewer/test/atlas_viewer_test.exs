defmodule AtlasViewerTest do
  use ExUnit.Case, async: false

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "avw-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

    on_exit(fn ->
      File.rm_rf!(dir)
      refute File.exists?(dir)
    end)

    home = Path.join(dir, "home")
    static = Path.join(dir, "static")
    File.mkdir_p!(home)
    File.mkdir_p!(Path.join(static, "prism/fonts"))
    # Test-only stand-ins for the built files; the shipped CSS comes from assets/build.js.
    for file <- ["index.html", "app.js", "app.css"],
        do: File.write!(Path.join(static, file), "test #{file}")

    File.write!(Path.join(static, "prism/fonts/a.woff2"), "font")
    File.write!(Path.join(dir, "secret.woff2"), "outside")

    {:ok, pid, port, token} = AtlasViewer.start(home: home, static: static, read_ms: 300)

    on_exit(fn ->
      monitor = Process.monitor(pid)
      :ok = AtlasViewer.stop(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}
      refute Process.alive?(pid)
    end)

    %{home: home, port: port, token: token, dir: dir}
  end

  # A listener at `path` that reports each request line and answers with `reply.(line)`;
  # `:silent` never answers.
  defp listen(path, reply) do
    test = self()

    id = make_ref()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, listener} =
             :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: :line, active: false])

           try do
             send(test, {:listening, self()})
             serve(listener, test, path, reply)
           after
             :gen_tcp.close(listener)
           end
         end},
        id: id
      )

    # ExUnit stops supervised children before on_exit, closing their owned sockets too.
    on_exit(fn -> refute Process.alive?(pid) end)
    assert_receive {:listening, ^pid}
    {id, pid, path}
  end

  defp stop_listener({id, pid, path}) do
    stop_supervised!(id)
    refute Process.alive?(pid)
    File.rm!(path)
  end

  defp serve(listener, test, path, reply) do
    {:ok, socket} = :gen_tcp.accept(listener)

    try do
      {:ok, line} = :gen_tcp.recv(socket, 0, 1000)
      send(test, {:received, Path.basename(path), JSON.decode!(line)})
      if reply != :silent, do: :gen_tcp.send(socket, reply.(line) <> "\n")
      if reply == :silent, do: Process.sleep(1000)
    after
      :gen_tcp.close(socket)
    end

    serve(listener, test, path, reply)
  end

  # An HTTP stand-in for backend.sock: reports each request as {:http, method, target} and
  # answers `reply.(method, target)`: {status, body}, {:chunked, status, body} or :silent.
  defp listen_http(path, reply) do
    test = self()
    id = make_ref()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, listener} =
             :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: :raw, active: false])

           try do
             send(test, {:listening, self()})
             serve_http(listener, test, reply)
           after
             :gen_tcp.close(listener)
           end
         end},
        id: id
      )

    on_exit(fn -> refute Process.alive?(pid) end)
    assert_receive {:listening, ^pid}
    {id, pid, path}
  end

  defp serve_http(listener, test, reply) do
    {:ok, socket} = :gen_tcp.accept(listener)

    try do
      head = receive_head(socket, "")
      [request_line | _] = String.split(head, "\r\n")
      [method, target, "HTTP/1.1"] = String.split(request_line, " ")
      send(test, {:http, method, target})

      case reply.(method, target) do
        :silent ->
          Process.sleep(1000)

        {:chunked, status, body} ->
          {first, rest} = String.split_at(body, 5)

          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
              chunk(first) <> chunk(rest) <> "0\r\n\r\n"
          )

        {status, body} ->
          type = if status < 300, do: "application/json", else: "application/problem+json"

          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} X\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"
          )
      end
    after
      :gen_tcp.close(socket)
    end

    serve_http(listener, test, reply)
  end

  defp chunk(data), do: Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n"

  defp receive_head(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      {:ok, data} = :gen_tcp.recv(socket, 0, 1000)
      receive_head(socket, acc <> data)
    end
  end

  # Raw HTTP, so Host and Origin are exactly what the test says.
  defp http(port, method, path, headers, body \\ "") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    try do
      http_response(socket, method, path, headers, body)
    after
      :gen_tcp.close(socket)
    end
  end

  defp http_response(socket, method, path, headers, body) do
    lines = Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end)

    :ok =
      :gen_tcp.send(
        socket,
        "#{method} #{path} HTTP/1.1\r\n#{lines}Content-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
      )

    response = receive_all(socket, "")
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    [status | header_lines] = String.split(head, "\r\n")
    [_, code | _] = String.split(status, " ")

    headers =
      Map.new(header_lines, fn line ->
        [k, v] = String.split(line, ":", parts: 2)
        {String.downcase(k), String.trim(v)}
      end)

    {String.to_integer(code), headers, body}
  end

  defp receive_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, data} -> receive_all(socket, acc <> data)
      {:error, :closed} -> acc
    end
  end

  defp api(%{port: port, token: token}, body, overrides \\ []) do
    headers =
      Keyword.merge(
        [
          Host: "127.0.0.1:#{port}",
          Origin: "http://127.0.0.1:#{port}",
          Authorization: "Bearer #{token}",
          "Content-Type": "application/json"
        ],
        overrides
      )
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    {status, headers, reply} = http(port, "POST", "/api/read", headers, JSON.encode!(body))
    {status, headers, JSON.decode!(reply)}
  end

  @runtime_info ~s({"runtime_build":"b1","incarnation":"i1","mode":"open","policy_version":3,"slots":[{"name":"dev1","busy":true}]})

  test "reads runtime info, history and output on backend.sock with GET, and passes the reply through",
       context do
    listen_http(Path.join(context.home, "backend.sock"), fn "GET", target ->
      {200, if(target == "/v1/runtime", do: @runtime_info, else: ~s({"target":"#{target}"}))}
    end)

    # Nothing may reach the sockets the viewer does not read.
    listen(Path.join(context.home, "read.sock"), fn _ -> "{}" end)

    assert {200, _, %{"slots" => [%{"name" => "dev1", "busy" => true}], "mode" => "open"}} =
             api(context, %{"op" => "runtime"})

    assert_receive {:http, "GET", "/v1/runtime"}

    for {body, target} <- [
          {%{"op" => "turns"}, "/v1/turns"},
          {%{"op" => "turns", "cursor" => "h:2", "limit" => 100},
           "/v1/turns?cursor=h%3A2&limit=100"},
          {%{"op" => "turn", "turn_id" => "t1"}, "/v1/turns/t1"},
          # A turn ID stays one path segment.
          {%{"op" => "turn", "turn_id" => "../work?x=1"}, "/v1/turns/..%2Fwork%3Fx%3D1"},
          {%{"op" => "output", "turn_id" => "t1"}, "/v1/turns/t1/output"},
          {%{"op" => "output", "turn_id" => "t1", "cursor" => "o:2"},
           "/v1/turns/t1/output?cursor=o%3A2"}
        ] do
      assert {200, _, %{"target" => ^target}} = api(context, body)
      assert_receive {:http, "GET", ^target}
    end

    refute_receive {:received, _, _}, 200
  end

  test "reads the journal on runtime.sock with one runtime.read/1 line, setting api itself",
       context do
    listen(Path.join(context.home, "runtime.sock"), fn _ ->
      ~s({"api":"runtime.read/1","op":"events","events":[],"cursor":"e:1:0","more":false})
    end)

    listen(Path.join(context.home, "read.sock"), fn _ -> "{}" end)

    assert {200, _, %{"events" => [], "cursor" => "e:1:0", "more" => false}} =
             api(context, %{"op" => "events", "cursor" => "e:1:0", "limit" => 100})

    assert_receive {:received, "runtime.sock",
                    %{
                      "api" => "runtime.read/1",
                      "op" => "events",
                      "cursor" => "e:1:0",
                      "limit" => 100
                    }}

    refute_receive {:received, "read.sock", _}, 200
  end

  test "refuses anything but the five reads before connecting", context do
    listen_http(Path.join(context.home, "backend.sock"), fn _, _ -> {200, "{}"} end)
    listen(Path.join(context.home, "runtime.sock"), fn _ -> "{}" end)

    for body <- [
          %{"op" => "workers"},
          %{"op" => "start", "worker_id" => "w"},
          %{"op" => "stop"},
          %{"command" => "start"},
          %{"op" => "runtime", "api" => "runtime/2"},
          %{"op" => "turn", "turn_id" => "t1", "cwd" => "/"},
          %{"op" => "turn"},
          %{"op" => "turn", "turn_id" => ""},
          %{"op" => "output", "turn_id" => 7},
          %{"op" => "events", "limit" => "5"},
          %{"op" => "follow"}
        ] do
      assert {400, _, %{"viewer_error" => %{"code" => code}}} = api(context, body)
      assert code in ["not_a_read", "invalid_request"]
    end

    refute_receive {:http, _, _}, 200
    refute_receive {:received, _, _}
  end

  test "a backend refusal keeps its problem type and status; a chunked reply is read whole",
       context do
    listen_http(Path.join(context.home, "backend.sock"), fn
      "GET", "/v1/turns/gone" ->
        {404, ~s({"type":"not-found","title":"Not Found","status":404})}

      "GET", "/v1/turns" <> _ ->
        {400,
         ~s({"type":"invalid","title":"Bad Request","status":400,"detail":"limit must be 1..100"})}

      "GET", "/v1/runtime" ->
        {:chunked, 200, @runtime_info}
    end)

    assert {200, _,
            %{"error" => %{"code" => "not-found", "status" => 404, "message" => "Not Found"}}} =
             api(context, %{"op" => "turn", "turn_id" => "gone"})

    assert {200, _,
            %{
              "error" => %{
                "code" => "invalid",
                "status" => 400,
                "message" => "limit must be 1..100"
              }
            }} =
             api(context, %{"op" => "turns", "limit" => 0})

    assert {200, _, %{"incarnation" => "i1"}} = api(context, %{"op" => "runtime"})
  end

  test "requires this launch's token, its own Host and Origin, and JSON", context do
    listen_http(Path.join(context.home, "backend.sock"), fn _, _ -> {200, @runtime_info} end)

    port = context.port
    read = %{"op" => "runtime"}

    assert {401, _, %{"viewer_error" => %{"code" => "unauthorized"}}} =
             api(context, read, Authorization: nil)

    assert {401, _, _} = api(context, read, Authorization: "Bearer wrong")
    assert {401, _, _} = api(context, read, Authorization: context.token)

    assert {403, _, %{"viewer_error" => %{"code" => "forbidden_origin"}}} =
             api(context, read, Origin: nil)

    assert {403, _, _} = api(context, read, Origin: "http://evil.example")
    assert {403, _, _} = api(context, read, Origin: "http://localhost:#{port}")

    assert {403, _, %{"viewer_error" => %{"code" => "forbidden_host"}}} =
             api(context, read, Host: "evil.example:#{port}")

    assert {415, _, _} = api(context, read, "Content-Type": "text/plain")
    refute_receive {:http, _, _}, 200

    assert {200, _, _} =
             api(context, read, Host: "localhost:#{port}", Origin: "http://localhost:#{port}")
  end

  test "reports an unreachable Runtime per socket, reconnects when it returns, and bounds slow reads",
       context do
    backend = Path.join(context.home, "backend.sock")

    assert {503, _, %{"viewer_error" => %{"code" => "runtime_unreachable", "message" => message}}} =
             api(context, %{"op" => "runtime"})

    assert message =~ "backend.sock"

    assert {503, _, %{"viewer_error" => %{"code" => "runtime_unreachable", "message" => message}}} =
             api(context, %{"op" => "events"})

    assert message =~ "runtime.sock"

    listener = listen_http(backend, fn _, _ -> {200, @runtime_info} end)
    assert {200, _, %{"slots" => [_]}} = api(context, %{"op" => "runtime"})

    stop_listener(listener)
    listener = listen_http(backend, fn _, _ -> :silent end)

    assert {504, _, %{"viewer_error" => %{"code" => "read_timeout"}}} =
             api(context, %{"op" => "runtime"})

    stop_listener(listener)
    listener = listen_http(backend, fn _, _ -> {200, "not json"} end)

    assert {502, _, %{"viewer_error" => %{"code" => "bad_reply"}}} =
             api(context, %{"op" => "runtime"})

    stop_listener(listener)
    listen(Path.join(context.home, "runtime.sock"), fn _ -> "not json" end)

    assert {502, _, %{"viewer_error" => %{"code" => "bad_reply"}}} =
             api(context, %{"op" => "events"})
  end

  test "serves only its static files, with a strict policy and no CORS", %{port: port} do
    host = [Host: "127.0.0.1:#{port}"]
    assert {200, headers, "test index.html"} = http(port, "GET", "/", host)
    assert headers["content-security-policy"] =~ "default-src 'none'"
    assert headers["content-security-policy"] =~ "frame-ancestors 'none'"
    assert headers["x-content-type-options"] == "nosniff"
    assert headers["cache-control"] == "no-store"

    assert {200, %{"content-type" => "font/woff2"}, "font"} =
             http(port, "GET", "/assets/prism/fonts/a.woff2", host)

    for path <- [
          "/assets/prism/../../secret.woff2",
          "/assets/prism/%2e%2e/%2e%2e/secret.woff2",
          "/index.html.bak",
          "/assets/prism/fonts/missing.woff2"
        ],
        do: assert({404, _, _} = http(port, "GET", path, host))

    assert {403, _, _} = http(port, "GET", "/", Host: "evil.example")
    assert {405, _, _} = http(port, "GET", "/api/read", host)

    {status, headers, _} =
      http(port, "OPTIONS", "/api/read", host ++ [Origin: "http://evil.example"])

    assert status >= 400
    refute Map.has_key?(headers, "access-control-allow-origin")
  end

  test "refuses to start without built assets", %{dir: dir} do
    assert_raise RuntimeError, ~r/assets missing/, fn ->
      AtlasViewer.start(home: dir, static: Path.join(dir, "none"))
    end
  end
end
