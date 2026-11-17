defmodule AtlasRuntime.RemoteFixtures do
  @moduledoc """
  In-test stand-ins for the path from the core to a Runtime backend (S3 plan P6, reused by
  P8 through `Code.require_file/1`). Everything is on loopback:

  - `pki/1`: a test CA and a server certificate for a host name, from
    `:public_key.pkix_test_data/1`;
  - `start_serve/2`: a Bandit HTTPS server on `127.0.0.1`, the stand-in for the mini's
    `tailscale serve`, answering with a handler function;
  - `AtlasRuntime.RemoteFixtures.Proxy`: an HTTP CONNECT proxy on `127.0.0.1` (`:gen_tcp`),
    the stand-in for the core's `tailscaled` outbound proxy. It logs every request it gets
    and opens tunnels only to `127.0.0.1`, whatever host is asked for, as MagicDNS would
    resolve the mini's name.
  """

  alias AtlasRuntimeBackend.Generator.Targets.Rest.Runtime, as: Wire

  @host "mini.tailnet.test"

  @doc "The host name the server's certificate is issued for."
  def host, do: @host

  @doc """
  A fresh test PKI: `%{server: ssl options for the server, cacerts: [DER] a client trusts}`.
  The server's certificate names `host` (a DNS subjectAltName).
  """
  def pki(host \\ @host) do
    san = {:Extension, {2, 5, 29, 17}, false, [{:dNSName, String.to_charlist(host)}]}
    rsa = {:rsa, 2048, 65_537}

    data =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: rsa], peer: [key: rsa, extensions: [san]]},
        client_chain: %{root: [key: rsa], peer: [key: rsa]}
      })

    server = Keyword.take(data[:server_config], [:cert, :key, :cacerts])
    %{server: server, cacerts: data[:client_config][:cacerts]}
  end

  @doc """
  Starts the HTTPS stand-in on `127.0.0.1:0` with `handler` (a `Plug.Conn` -> `Plug.Conn`
  function). Answers `{pid, port}`; link it to the test (`start_supervised/1` takes
  `serve_spec/2`).
  """
  def start_serve(handler, pki) do
    {:ok, pid} = Bandit.start_link(serve_options(handler, pki))
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {pid, port}
  end

  @doc "The child spec of the HTTPS stand-in, for `start_supervised/1`."
  def serve_spec(handler, pki),
    do: %{
      id: {__MODULE__, :serve, make_ref()},
      start: {Bandit, :start_link, [serve_options(handler, pki)]}
    }

  @doc "The port of a started HTTPS stand-in."
  def serve_port(pid) do
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp serve_options(handler, pki),
    do: [
      plug: {__MODULE__.Serve, handler},
      scheme: :https,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false,
      thousand_island_options: [transport_options: pki.server]
    ]

  @doc "A port on `127.0.0.1` that nothing listens on."
  def closed_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  ## Answers, in the backend's own wire forms

  @doc "A capacity entity as the backend serializes it."
  def capacity_json(fields \\ %{}),
    do:
      Map.merge(
        %{
          "slots" => %{"total" => 2, "busy" => 1, "free" => 1},
          "buffer" => %{"size" => 4, "used" => 0, "free" => 4},
          "profiles" => [%{"profile" => "deep_coding", "available" => true}],
          "accepting" => true,
          "policy_version" => 3,
          "runtime_build" => "test-build",
          "incarnation" => "inc-1"
        },
        fields
      )

  @doc "A JSON answer."
  def json(conn, status, body, type \\ "application/json") do
    conn
    |> Plug.Conn.put_resp_content_type(type, nil)
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  @doc "A problem+json answer, as the backend's generated router writes it."
  def problem(conn, status, type, fields \\ %{}),
    do: json(conn, status, Wire.problem(status, type, type, fields), "application/problem+json")

  @doc "One Server-Sent Events frame, as the backend writes it."
  def frame(event, id, data), do: IO.iodata_to_binary(Wire.frame(event, id, data))

  defmodule Serve do
    @moduledoc false
    @behaviour Plug

    @impl true
    def init(handler), do: handler

    @impl true
    def call(conn, handler), do: handler.(conn)
  end

  defmodule Proxy do
    @moduledoc """
    An HTTP CONNECT proxy on `127.0.0.1` (`port:`, default 0, any free port; P8 runs it on
    the core's `localhost:1055`). `mode: :tunnel` answers a CONNECT with 200 and pipes bytes
    to `127.0.0.1:<port>`. `mode: :refuse` answers 403. A request that is not a CONNECT gets
    405. `requests/1` lists what came, in order: `{:connect, "host:port"}` or
    `{:other, request_line}`. Stopping it closes its listening socket, so the port is free
    (and refuses connections) at once. `upstream:` makes it a man in the middle: a port
    sends every tunnel to `127.0.0.1:<port>`, a map `%{asked => port}` only those it names,
    whatever was asked for (the CONNECT is still logged as asked).
    """

    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def port(proxy), do: GenServer.call(proxy, :port)
    def requests(proxy), do: GenServer.call(proxy, :requests)

    def connects(proxy),
      do: for({:connect, target} <- requests(proxy), do: target)

    @impl true
    def init(opts) do
      mode = Keyword.get(opts, :mode, :tunnel)

      {:ok, listen} =
        :gen_tcp.listen(Keyword.get(opts, :port, 0), [
          :binary,
          ip: {127, 0, 0, 1},
          active: false,
          reuseaddr: true
        ])

      {:ok, port} = :inet.port(listen)
      proxy = self()
      mode = if up = opts[:upstream], do: {mode, up}, else: mode
      acceptor = spawn_link(fn -> accept(listen, proxy, mode) end)
      :ok = :gen_tcp.controlling_process(listen, acceptor)
      {:ok, %{port: port, requests: [], listen: listen}}
    end

    @impl true
    def handle_call(:port, _from, state), do: {:reply, state.port, state}
    def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}

    @impl true
    def handle_cast({:request, request}, state),
      do: {:noreply, %{state | requests: [request | state.requests]}}

    @impl true
    def terminate(_reason, state), do: :gen_tcp.close(state.listen)

    defp accept(listen, proxy, mode) do
      case :gen_tcp.accept(listen) do
        {:ok, client} ->
          handler = spawn(fn -> handle(proxy, mode) end)
          :ok = :gen_tcp.controlling_process(client, handler)
          send(handler, {:socket, client})
          accept(listen, proxy, mode)

        {:error, _closed} ->
          :ok
      end
    end

    defp handle(proxy, mode) do
      receive do
        {:socket, client} ->
          with {:ok, head} <- head(client, "") do
            [line | _] = String.split(head, "\r\n")
            request(proxy, mode, client, String.split(line, " "), line)
          end
      after
        5_000 -> :ok
      end
    end

    defp head(socket, acc) do
      if String.contains?(acc, "\r\n\r\n") do
        {:ok, acc}
      else
        case :gen_tcp.recv(socket, 0, 5_000) do
          {:ok, data} -> head(socket, acc <> data)
          error -> error
        end
      end
    end

    defp request(proxy, {:tunnel, upstream}, client, ["CONNECT", target, _version], _line) do
      GenServer.cast(proxy, {:request, {:connect, target}})
      [_host, port] = String.split(target, ":")
      port = String.to_integer(port)
      tunnel(client, if(is_map(upstream), do: Map.get(upstream, port, port), else: upstream))
    end

    defp request(proxy, :tunnel, client, ["CONNECT", target, _version], _line) do
      GenServer.cast(proxy, {:request, {:connect, target}})
      [_host, port] = String.split(target, ":")
      tunnel(client, String.to_integer(port))
    end

    defp request(proxy, :refuse, client, ["CONNECT", target, _version], _line) do
      GenServer.cast(proxy, {:request, {:connect, target}})
      :gen_tcp.send(client, "HTTP/1.1 403 Forbidden\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(client)
    end

    defp request(proxy, _mode, client, _parts, line) do
      GenServer.cast(proxy, {:request, {:other, line}})
      :gen_tcp.send(client, "HTTP/1.1 405 Method Not Allowed\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(client)
    end

    defp tunnel(client, port) do
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true]) do
        {:ok, upstream} ->
          :ok = :gen_tcp.send(client, "HTTP/1.1 200 Connection established\r\n\r\n")
          :ok = :inet.setopts(client, active: true)
          pipe(client, upstream)

        {:error, _} ->
          :gen_tcp.send(client, "HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n")
          :gen_tcp.close(client)
      end
    end

    defp pipe(client, upstream) do
      receive do
        {:tcp, ^client, data} ->
          :gen_tcp.send(upstream, data)
          pipe(client, upstream)

        {:tcp, ^upstream, data} ->
          :gen_tcp.send(client, data)
          pipe(client, upstream)

        {:tcp_closed, _either} ->
          :gen_tcp.close(client)
          :gen_tcp.close(upstream)
      end
    end
  end
end
