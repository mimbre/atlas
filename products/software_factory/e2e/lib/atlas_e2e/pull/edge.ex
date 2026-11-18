defmodule AtlasE2E.Pull.Edge do
  @moduledoc """
  The TLS edge (the stand-in for `tailscale serve`; plan rev 2 §6): TLS 1.3 on 127.0.0.1 in
  front of Flow's plain-HTTP work-source listener, the wire tap, and the faults.

  - **One request per connection.** The edge reads the head, relays the body as it arrives
    (`Content-Length` or chunked) while a separate reader process relays the upstream's
    answer, then closes both. Upstream is asked `connection: close`.
  - **The tap.** One `:wire` event per exchange (`AtlasE2E.Pull.Hub`), on every end, failed
    ones included: `route` (`:poll | :report | :get_blob | :put_blob | :other | :unknown`),
    `lease_id`, `sha256`, `req` (the decoded JSON body), `chunked?`, `bytes_in` (body
    payload bytes), `status` (nil when no answer was read), `type` (a problem's), `resp`
    (the decoded JSON answer), `bytes_out`, `upstream` (`:ok | :refused | :held |
    :released | :closed | :edge_refused | :handshake_failed`), `began`/`ended` (monotonic
    ms). The `authorization` header is never recorded.
  - **Faults** (`mode/2`, for new connections): `:pass`; `:refuse` (closed after accept,
    before TLS); `{:hold, match, others}`: a request `match.(summary)` accepts is read whole
    and kept until `release/2`, every other one is `others` (`:refuse` or `:pass`). Flow
    down: an upstream connect refused is answered 502 (`upstream: :refused`).
  """
  use GenServer
  require Logger

  alias AtlasE2E.Pull.Hub
  alias AtlasE2E.Pull.Edge.Chunked

  @json_cap 1_048_576
  @handshake_ms 30_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  def port(edge), do: GenServer.call(edge, :port)
  def mode(edge, mode), do: GenServer.call(edge, {:mode, mode})

  @doc "Release held requests: every one, or those `match` accepts. Returns how many."
  def release(edge, match \\ fn _ -> true end), do: GenServer.call(edge, {:release, match})

  @doc "The summaries of the requests held now."
  def held(edge), do: GenServer.call(edge, :held)

  def stop(edge), do: GenServer.stop(edge)

  @impl true
  def init(opts) do
    tls = opts[:tls] || AtlasE2E.Pull.Fixture.tls()

    # Plain TCP, upgraded per connection: a refused connection is then closed before any TLS.
    {:ok, listen} =
      :gen_tcp.listen(opts[:port] || 0, [
        :binary,
        active: false,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, port} = :inet.port(listen)

    ssl = [
      versions: [:"tlsv1.3"],
      certs_keys: [%{cert: tls.cert, key: tls.key}],
      cacerts: tls.cacerts
    ]

    edge = self()
    acceptor = spawn_link(fn -> accept(edge, listen, ssl) end)

    {:ok,
     %{
       listen: listen,
       port: port,
       acceptor: acceptor,
       upstream: opts[:upstream],
       hub: opts[:hub] || Hub,
       mode: :pass,
       held: %{},
       log: opts[:log]
     }}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}
  def handle_call({:mode, mode}, _from, state), do: {:reply, :ok, %{state | mode: mode}}

  def handle_call(:connection, _from, state),
    do: {:reply, {state.mode, state.upstream, state.hub}, state}

  def handle_call({:hold, ref, pid, summary}, _from, state),
    do: {:reply, :ok, %{state | held: Map.put(state.held, ref, {pid, summary})}}

  def handle_call(:held, _from, state),
    do: {:reply, Enum.map(state.held, fn {_, {_, s}} -> s end), state}

  def handle_call({:release, match}, _from, state) do
    {go, keep} = Enum.split_with(state.held, fn {_, {_, summary}} -> match.(summary) end)
    for {ref, {pid, _}} <- go, do: send(pid, {:release, ref})
    {:reply, length(go), %{state | held: Map.new(keep)}}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listen)
    :ok
  end

  # ---- connections --------------------------------------------------------------------

  defp accept(edge, listen, ssl) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {mode, upstream, hub} = GenServer.call(edge, :connection)

        if mode == :refuse do
          # Before TLS: the Runtime sees a closed connection, as when the edge is down.
          :gen_tcp.close(socket)

          publish(hub, %{
            route: :unknown,
            upstream: :edge_refused,
            status: nil,
            began: Hub.now(),
            ended: Hub.now()
          })
        else
          handler = spawn(fn -> handle(edge, mode, upstream, hub, ssl) end)
          :ok = :gen_tcp.controlling_process(socket, handler)
          send(handler, {:socket, socket})
        end

        accept(edge, listen, ssl)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        accept(edge, listen, ssl)
    end
  end

  defp handle(edge, mode, upstream, hub, ssl) do
    socket =
      receive do
        {:socket, socket} -> socket
      end

    began = Hub.now()

    with {:ok, tls} <- :ssl.handshake(socket, ssl, @handshake_ms),
         {:ok, head, rest} <- read_head(tls, "") do
      request = parse_request(head)
      summary = summary(request)
      record = Map.merge(summary, %{began: began, chunked?: request.chunked?})

      case decide(mode, summary) do
        :refuse ->
          :ssl.close(tls)

          publish(
            hub,
            Map.merge(record, %{upstream: :edge_refused, status: nil, ended: Hub.now()})
          )

        :hold ->
          {body, ended?} = read_body(tls, request, rest)
          ref = make_ref()
          :ok = GenServer.call(edge, {:hold, ref, self(), summary})
          held = Map.merge(record, request_facts(request, body, ended?))
          publish(hub, Map.merge(held, %{upstream: :held, status: nil, ended: Hub.now()}))

          receive do
            {:release, ^ref} -> :ok
          end

          # Upstream as it is now (Flow may have restarted on its port meanwhile).
          relay(tls, request, body, :done, held, current_upstream(edge), hub, :released)

        :pass ->
          relay(tls, request, rest, :streaming, record, upstream, hub, :ok)
      end
    else
      _ ->
        :gen_tcp.close(socket)

        publish(hub, %{
          route: :unknown,
          upstream: :handshake_failed,
          status: nil,
          began: began,
          ended: Hub.now()
        })
    end
  end

  defp current_upstream(edge) do
    {_mode, upstream, _hub} = GenServer.call(edge, :connection)
    upstream
  end

  defp decide(:pass, _summary), do: :pass

  defp decide({:hold, match, others}, summary) do
    if safe(match, summary), do: :hold, else: others
  end

  defp safe(match, summary) do
    match.(summary)
  rescue
    _ -> false
  end

  # Relay one exchange: the head, then the body (as it arrives, or already read when held),
  # while the reader relays the answer. `upstream_tag` is the record's `upstream` on success.
  defp relay(tls, request, body_or_rest, body_state, record, {host, port}, hub, upstream_tag) do
    case :gen_tcp.connect(host, port, [:binary, active: false], 5_000) do
      {:ok, up} ->
        :ok = :gen_tcp.send(up, upstream_head(request))
        handler = self()
        reader = spawn(fn -> send(handler, {:answer, answer(up, tls)}) end)
        :gen_tcp.controlling_process(up, reader)

        {sent, ended?} =
          case body_state do
            :streaming -> stream_body(tls, up, request, body_or_rest)
            :done -> {send_all(up, body_or_rest), true}
          end

        answer =
          receive do
            {:answer, answer} -> answer
          end

        :ssl.close(tls)
        :gen_tcp.close(up)

        facts =
          case body_state do
            :streaming -> request_facts(request, sent, ended?)
            :done -> %{}
          end

        tag = if answer.status == nil, do: :closed, else: upstream_tag

        publish(
          hub,
          record
          |> Map.merge(facts)
          |> Map.merge(%{
            status: answer.status,
            type: answer.type,
            resp: answer.json,
            bytes_out: answer.bytes,
            upstream: tag,
            ended: Hub.now()
          })
        )

      {:error, _} ->
        {body, ended?} =
          case body_state do
            :streaming -> read_body(tls, request, body_or_rest)
            :done -> {body_or_rest, true}
          end

        problem = ~s({"type":"bad-gateway","title":"Flow is not reachable"})

        :ssl.send(
          tls,
          "HTTP/1.1 502 Bad Gateway\r\ncontent-type: application/problem+json\r\n" <>
            "content-length: #{byte_size(problem)}\r\nconnection: close\r\n\r\n" <> problem
        )

        :ssl.close(tls)

        publish(
          hub,
          record
          |> Map.merge(
            if(body_state == :streaming, do: request_facts(request, body, ended?), else: %{})
          )
          |> Map.merge(%{status: 502, type: "bad-gateway", upstream: :refused, ended: Hub.now()})
        )
    end
  end

  defp send_all(up, body) do
    _ = :gen_tcp.send(up, body)
    body
  end

  # ---- request ------------------------------------------------------------------------

  defp read_head(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        {:ok, head, rest}

      [_] ->
        if byte_size(acc) > 65_536 do
          {:error, :head_too_large}
        else
          case :ssl.recv(socket, 0, 60_000) do
            {:ok, data} -> read_head(socket, acc <> data)
            error -> error
          end
        end
    end
  end

  @doc false
  def parse_request(head) do
    [line | header_lines] = String.split(head, "\r\n")
    [method, target | _] = String.split(line, " ")

    headers =
      for h <- header_lines,
          [k, v] = String.split(h, ":", parts: 2),
          do: {String.downcase(String.trim(k)), String.trim(v)}

    chunked? =
      Enum.any?(headers, fn {k, v} ->
        k == "transfer-encoding" and String.contains?(String.downcase(v), "chunked")
      end)

    length =
      case List.keyfind(headers, "content-length", 0) do
        {_, v} -> String.to_integer(v)
        nil -> nil
      end

    %{method: method, target: target, headers: headers, chunked?: chunked?, length: length}
  end

  @doc false
  def summary(%{method: method, target: target}) do
    path = target |> String.split("?") |> hd()

    case {method, String.split(path, "/", trim: true)} do
      {"POST", ["v1", "poll"]} ->
        %{route: :poll, lease_id: nil, sha256: nil}

      {"POST", ["v1", "leases", id, "reports"]} ->
        %{route: :report, lease_id: URI.decode(id), sha256: nil}

      {"GET", ["v1", "leases", id, "blobs", sha]} ->
        %{route: :get_blob, lease_id: URI.decode(id), sha256: sha}

      {"PUT", ["v1", "leases", id, "blobs", sha]} ->
        %{route: :put_blob, lease_id: URI.decode(id), sha256: sha}

      _ ->
        %{route: :other, lease_id: nil, sha256: nil}
    end
  end

  defp upstream_head(%{method: method, target: target, headers: headers}) do
    kept = Enum.reject(headers, fn {k, _} -> k in ["connection", "keep-alive"] end)

    [
      method,
      " ",
      target,
      " HTTP/1.1\r\n",
      Enum.map(kept, fn {k, v} -> [k, ": ", v, "\r\n"] end),
      "connection: close\r\n\r\n"
    ]
  end

  # The whole body (a held request): `{bytes as sent, ended?}`.
  defp read_body(tls, request, rest), do: read_body(tls, framing(request), rest, [])

  defp read_body(tls, frame, data, acc) do
    {frame, _payload, done?} = advance(frame, data)
    acc = [acc, data]

    cond do
      done? ->
        {IO.iodata_to_binary(acc), true}

      true ->
        case :ssl.recv(tls, 0, 60_000) do
          {:ok, more} -> read_body(tls, frame, more, acc)
          _ -> {IO.iodata_to_binary(acc), false}
        end
    end
  end

  # Relay the body as it arrives; `{bytes sent, ended?}` (bytes kept up to the JSON cap).
  defp stream_body(tls, up, request, rest),
    do: stream_body(tls, up, framing(request), rest, {[], 0}, true)

  defp stream_body(tls, up, frame, data, {acc, size}, open?) do
    {frame, _payload, done?} = advance(frame, data)
    open? = open? and (data == "" or :gen_tcp.send(up, data) == :ok)
    acc = if size < @json_cap, do: [acc, data], else: acc
    size = size + byte_size(data)

    cond do
      done? ->
        {{:counted, IO.iodata_to_binary(acc), frame}, true}

      true ->
        case :ssl.recv(tls, 0, 60_000) do
          {:ok, more} -> stream_body(tls, up, frame, more, {acc, size}, open?)
          _ -> {{:counted, IO.iodata_to_binary(acc), frame}, false}
        end
    end
  end

  defp framing(%{chunked?: true}), do: {:chunked, Chunked.new()}
  defp framing(%{length: n}) when is_integer(n), do: {:length, n, 0}
  defp framing(_), do: {:length, 0, 0}

  # `{frame, payload bytes in data, done?}`
  defp advance({:chunked, decoder}, data) do
    {decoder, payload} = Chunked.feed(decoder, data)
    {{:chunked, decoder}, payload, Chunked.done?(decoder)}
  end

  defp advance({:length, n, seen}, data) do
    seen = seen + byte_size(data)
    {{:length, n, seen}, byte_size(data), seen >= n}
  end

  defp request_facts(request, {:counted, kept, frame}, ended?) do
    bytes =
      case frame do
        {:chunked, d} -> Chunked.payload_bytes(d)
        {:length, _n, seen} -> seen
      end

    Map.merge(%{bytes_in: bytes, body_ended?: ended?}, json_req(request, kept, frame))
  end

  defp request_facts(request, body, ended?) when is_binary(body) do
    {frame, _, _} = advance(framing(request), body)
    request_facts(request, {:counted, body, frame}, ended?)
  end

  defp json_req(request, kept, frame) do
    json? =
      Enum.any?(request.headers, fn {k, v} ->
        k == "content-type" and String.contains?(v, "json")
      end)

    cond do
      not json? -> %{req: nil}
      match?({:chunked, _}, frame) -> %{req: decode(Chunked.decode_all(kept))}
      true -> %{req: decode(kept)}
    end
  end

  # ---- answer -------------------------------------------------------------------------

  # Relays the upstream's answer to the client until the upstream closes; the tap's view.
  defp answer(up, tls) do
    answer(up, tls, %{head: "", parsed: nil, frame: nil, kept: [], kept_size: 0, bytes: 0})
  end

  defp answer(up, tls, acc) do
    case :gen_tcp.recv(up, 0, 600_000) do
      {:ok, data} ->
        _ = :ssl.send(tls, data)
        answer(up, tls, take(acc, data))

      {:error, _} ->
        finish(acc)
    end
  end

  defp take(%{parsed: nil} = acc, data) do
    buffer = acc.head <> data

    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        parsed = parse_response(head)

        frame =
          if parsed.chunked?, do: {:chunked, Chunked.new()}, else: {:length, parsed.length, 0}

        take(%{acc | head: head, parsed: parsed, frame: frame}, rest)

      [_] ->
        %{acc | head: buffer}
    end
  end

  defp take(acc, data) do
    {frame, payload, _done?} = advance(acc.frame, data)
    bytes = if match?({:chunked, _}, frame), do: 0, else: payload
    kept = if acc.kept_size < @json_cap, do: [acc.kept, data], else: acc.kept

    %{
      acc
      | frame: frame,
        bytes: acc.bytes + bytes,
        kept: kept,
        kept_size: acc.kept_size + byte_size(data)
    }
  end

  defp finish(%{parsed: nil}), do: %{status: nil, type: nil, json: nil, bytes: 0}

  defp finish(%{parsed: parsed} = acc) do
    kept = IO.iodata_to_binary(acc.kept)

    {bytes, body} =
      case acc.frame do
        {:chunked, d} -> {Chunked.payload_bytes(d), Chunked.decode_all(kept)}
        _ -> {acc.bytes, kept}
      end

    json = if parsed.json?, do: decode(body)
    type = if is_map(json) and parsed.status >= 400, do: json["type"]
    %{status: parsed.status, type: type, json: json, bytes: bytes}
  end

  @doc false
  def parse_response(head) do
    [line | header_lines] = String.split(head, "\r\n")
    [_, status | _] = String.split(line, " ")

    headers =
      for h <- header_lines,
          [k, v] = String.split(h, ":", parts: 2),
          do: {String.downcase(String.trim(k)), String.trim(v)}

    %{
      status: String.to_integer(status),
      chunked?:
        Enum.any?(headers, fn {k, v} ->
          k == "transfer-encoding" and String.contains?(v, "chunked")
        end),
      length:
        case List.keyfind(headers, "content-length", 0) do
          {_, v} -> String.to_integer(v)
          nil -> :infinity
        end,
      json?:
        Enum.any?(headers, fn {k, v} -> k == "content-type" and String.contains?(v, "json") end)
    }
  end

  defp decode(""), do: nil

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp publish(hub, record) do
    record =
      Map.merge(
        %{
          route: :unknown,
          lease_id: nil,
          sha256: nil,
          req: nil,
          chunked?: false,
          bytes_in: 0,
          status: nil,
          type: nil,
          resp: nil,
          bytes_out: 0,
          upstream: nil
        },
        record
      )

    Hub.publish(:wire, record, hub)
  end
end

defmodule AtlasE2E.Pull.Edge.Chunked do
  @moduledoc """
  An incremental HTTP/1.1 chunked-encoding reader: `feed/2` takes bytes as they arrive and
  counts the payload; `done?/1` once the last chunk and the trailers were read. It never
  holds the payload (`decode_all/1` decodes a body kept whole, for a JSON tap).
  """
  defstruct state: :size, line: "", left: 0, bytes: 0, done: false

  def new, do: %__MODULE__{}
  def done?(%__MODULE__{done: done}), do: done
  def payload_bytes(%__MODULE__{bytes: bytes}), do: bytes

  @doc "`{decoder, payload bytes in data}`"
  def feed(%__MODULE__{} = d, data), do: feed(d, data, 0)

  defp feed(d, "", n), do: {d, n}
  defp feed(%{done: true} = d, _data, n), do: {d, n}

  defp feed(%{state: :size} = d, data, n) do
    case :binary.split(d.line <> data, "\r\n") do
      [line, rest] ->
        size = line |> String.split(";") |> hd() |> String.trim() |> String.to_integer(16)

        if size == 0,
          do: feed(%{d | state: :trailer, line: ""}, rest, n),
          else: feed(%{d | state: :data, line: "", left: size}, rest, n)

      [part] ->
        {%{d | line: part}, n}
    end
  end

  defp feed(%{state: :data, left: left} = d, data, n) do
    take = min(left, byte_size(data))
    rest = binary_part(data, take, byte_size(data) - take)
    d = %{d | left: left - take, bytes: d.bytes + take}
    if d.left == 0, do: feed(%{d | state: :crlf, line: ""}, rest, n + take), else: {d, n + take}
  end

  defp feed(%{state: :crlf} = d, data, n) do
    buffer = d.line <> data

    if byte_size(buffer) >= 2,
      do: feed(%{d | state: :size, line: ""}, binary_part(buffer, 2, byte_size(buffer) - 2), n),
      else: {%{d | line: buffer}, n}
  end

  defp feed(%{state: :trailer} = d, data, n) do
    case :binary.split(d.line <> data, "\r\n") do
      ["", _rest] -> {%{d | done: true, line: ""}, n}
      [_trailer, rest] -> feed(%{d | line: ""}, rest, n)
      [part] -> {%{d | line: part}, n}
    end
  end

  @doc "The payload of a whole chunked body (for a small JSON body only)."
  def decode_all(body), do: decode_all(body, [])

  defp decode_all(body, acc) do
    case :binary.split(body, "\r\n") do
      [size_line, rest] ->
        case Integer.parse(size_line |> String.split(";") |> hd() |> String.trim(), 16) do
          {0, _} ->
            IO.iodata_to_binary(Enum.reverse(acc))

          {size, _} when byte_size(rest) >= size + 2 ->
            decode_all(binary_part(rest, size + 2, byte_size(rest) - size - 2), [
              binary_part(rest, 0, size) | acc
            ])

          _ ->
            IO.iodata_to_binary(Enum.reverse(acc))
        end

      _ ->
        IO.iodata_to_binary(Enum.reverse(acc))
    end
  end
end
