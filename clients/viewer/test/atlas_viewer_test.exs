defmodule AtlasViewerTest do
  use ExUnit.Case, async: false

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "avw-#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"
      )

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
      AtlasViewer.stop(pid)
      File.rm_rf!(dir)
    end)

    %{home: home, port: port, token: token, dir: dir}
  end

  # A listener at `path` that reports each request line and answers with `reply.(line)`;
  # `:silent` never answers.
  defp listen(path, reply) do
    test = self()

    spawn_link(fn ->
      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: :line, active: false])

      send(test, :listening)
      serve(listener, test, path, reply)
    end)

    assert_receive :listening
  end

  defp serve(listener, test, path, reply) do
    {:ok, socket} = :gen_tcp.accept(listener)
    {:ok, line} = :gen_tcp.recv(socket, 0, 1000)
    send(test, {:received, Path.basename(path), JSON.decode!(line)})
    if reply != :silent, do: :gen_tcp.send(socket, reply.(line) <> "\n")
    if reply == :silent, do: Process.sleep(1000)
    :gen_tcp.close(socket)
    serve(listener, test, path, reply)
  end

  # Raw HTTP, so Host and Origin are exactly what the test says.
  defp http(port, method, path, headers, body \\ "") do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
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

  test "forwards only reads to read.sock, sets api itself and passes Runtime's reply through",
       context do
    listen(Path.join(context.home, "read.sock"), fn _ ->
      ~s({"api":"runtime.read/1","op":"turn","turn":{"turn_id":"t1"}})
    end)

    listen(Path.join(context.home, "runtime.sock"), fn _ -> "{}" end)

    assert {200, _, %{"turn" => %{"turn_id" => "t1"}}} =
             api(context, %{"op" => "turn", "turn_id" => "t1"})

    assert_receive {:received, "read.sock",
                    %{"api" => "runtime.read/1", "op" => "turn", "turn_id" => "t1"}}

    for body <- [
          %{"op" => "start", "worker_id" => "w"},
          %{"op" => "stop"},
          %{"command" => "start"},
          %{"op" => "workers", "api" => "runtime/2"},
          %{"op" => "turn", "turn_id" => "t1", "cwd" => "/"}
        ] do
      assert {400, _, %{"viewer_error" => %{"code" => code}}} = api(context, body)
      assert code in ["not_a_read", "invalid_request"]
    end

    refute_receive {:received, _, _}, 200
  end

  test "requires this launch's token, its own Host and Origin, and JSON", context do
    listen(Path.join(context.home, "read.sock"), fn _ ->
      ~s({"api":"runtime.read/1","op":"workers"})
    end)

    port = context.port
    read = %{"op" => "workers"}

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
    refute_receive {:received, _, _}, 200

    assert {200, _, _} =
             api(context, read, Host: "localhost:#{port}", Origin: "http://localhost:#{port}")
  end

  test "reports an unreachable Runtime, reconnects when it returns, and bounds slow reads",
       context do
    path = Path.join(context.home, "read.sock")

    assert {503, _, %{"viewer_error" => %{"code" => "runtime_unreachable"}}} =
             api(context, %{"op" => "workers"})

    listen(path, fn _ -> ~s({"api":"runtime.read/1","op":"workers","workers":[]}) end)
    assert {200, _, %{"workers" => []}} = api(context, %{"op" => "workers"})

    File.rm!(path)
    listen(path, :silent)

    assert {504, _, %{"viewer_error" => %{"code" => "read_timeout"}}} =
             api(context, %{"op" => "workers"})

    File.rm!(path)
    listen(path, fn _ -> "not json" end)

    assert {502, _, %{"viewer_error" => %{"code" => "bad_reply"}}} =
             api(context, %{"op" => "workers"})
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
