## What the stream-outcome tests (B15) need around the example: bytes that are made only as
## they are read, a Plug adapter that hands every chunk on instead of keeping it, and a
## client transport that streams from a router in another process.

defmodule AtlasRuntimeBackend.Generator.Example.Bytes do
  @moduledoc """
  A lazy byte stream for the stream-outcome tests: `size` bytes in chunks of `chunk`
  bytes, each made only when it is read (a `Stream.resource`). It counts the chunks it has
  made (`made/1`), and its `after` tells `owner` `{:bytes_closed, ref}` and counts itself
  (`closed/1`), whether the stream ended or was halted. `sha256/2` is the hash of the same
  bytes, made the same way, for comparing.
  """

  defstruct [:ref, :counters, :stream]

  @made 1
  @closed 2

  def new(size, chunk, owner \\ self()) do
    ref = make_ref()
    counters = :counters.new(2, [:atomics])

    stream =
      Stream.resource(
        fn -> 0 end,
        fn
          offset when offset >= size ->
            {:halt, offset}

          offset ->
            :counters.add(counters, @made, 1)
            {[piece(offset, min(chunk, size - offset))], offset + chunk}
        end,
        fn _offset ->
          :counters.add(counters, @closed, 1)
          send(owner, {:bytes_closed, ref})
        end
      )

    %__MODULE__{ref: ref, counters: counters, stream: stream}
  end

  def made(%__MODULE__{counters: c}), do: :counters.get(c, @made)
  def closed(%__MODULE__{counters: c}), do: :counters.get(c, @closed)

  def sha256(size, chunk) do
    Stream.unfold(0, fn
      offset when offset >= size -> nil
      offset -> {piece(offset, min(chunk, size - offset)), offset + chunk}
    end)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
  end

  # A fresh binary for each chunk, its bytes depending on where it is.
  defp piece(offset, length), do: :binary.copy(<<rem(div(offset, 7), 251)>>, length)
end

defmodule AtlasRuntimeBackend.Generator.Example.SinkAdapter do
  @moduledoc """
  A `Plug.Conn` adapter for the stream-outcome tests: `Plug.Adapters.Test.Conn`, except that
  a response goes to `sink`, a function, and is not kept. `sink` gets `{:head, status,
  headers}` (chunked), `{:chunk, binary}` per chunk (answering `:ok`, or `:closed` for a
  client that is gone, which `chunk/2` reports as `{:error, :closed}`), or `{:whole, status,
  headers, body}`.
  """
  @behaviour Plug.Conn.Adapter
  @inner Plug.Adapters.Test.Conn

  def conn(method, path, sink) do
    conn = Plug.Test.conn(method, path)
    {@inner, state} = conn.adapter
    %{conn | adapter: {__MODULE__, Map.put(state, :sink, sink)}}
  end

  @impl true
  def send_chunked(state, status, headers) do
    :ok = state.sink.({:head, status, headers})
    {:ok, nil, state}
  end

  @impl true
  def chunk(state, body) do
    case state.sink.({:chunk, IO.iodata_to_binary(body)}) do
      :ok -> {:ok, nil, state}
      :closed -> {:error, :closed}
    end
  end

  @impl true
  def send_resp(state, status, headers, body) do
    :ok = state.sink.({:whole, status, headers, IO.iodata_to_binary(body)})
    {:ok, nil, state}
  end

  @impl true
  def send_file(state, status, headers, path, offset, length),
    do: @inner.send_file(state, status, headers, path, offset, length)

  @impl true
  def read_req_body(state, opts), do: @inner.read_req_body(state, opts)
  @impl true
  def inform(state, status, headers), do: @inner.inform(state, status, headers)
  @impl true
  def upgrade(state, protocol, opts), do: @inner.upgrade(state, protocol, opts)
  @impl true
  def push(state, path, headers), do: @inner.push(state, path, headers)
  @impl true
  def get_peer_data(state), do: @inner.get_peer_data(state)
  @impl true
  def get_sock_data(state), do: @inner.get_sock_data(state)
  @impl true
  def get_ssl_data(state), do: @inner.get_ssl_data(state)
  @impl true
  def get_http_protocol(state), do: @inner.get_http_protocol(state)
end

defmodule AtlasRuntimeBackend.Generator.Example.StreamTransport do
  @moduledoc """
  A client transport for the stream-outcome tests that streams as a network transport
  does: the example router answers in a process of its own, on the `SinkAdapter`, and
  each chunk is sent to the caller and waits until the caller has read it (one chunk in
  flight). The body is a `Stream.resource` read in the caller. Halting it tells the
  router's process that the client is gone, so its next `chunk/2` fails. Options
  (`transport:`): `scan:` the stream the example facade's `scan` answers with; `client:`
  the `{id, rights}`; `cut_after:` the router's process dies after that many chunks, and
  the body ends with `{:error, :closed}`.
  """
  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  alias AtlasRuntimeBackend.Generator.Example.{Rest, SinkAdapter}

  @impl true
  def request(_request, _opts), do: {:error, :not_used}

  @impl true
  def stream(request, opts) do
    caller = self()
    ref = make_ref()
    cut_after = opts[:cut_after]

    server =
      spawn(fn ->
        if scan = opts[:scan], do: Process.put(:example_scan, scan)
        sent = :counters.new(1, [])

        sink = fn
          {:chunk, body} ->
            :counters.add(sent, 1, 1)
            if cut_after && :counters.get(sent, 1) > cut_after, do: exit(:cut)
            send(caller, {ref, :chunk, body})

            receive do
              {^ref, :more} -> :ok
              {^ref, :gone} -> :closed
            end

          message ->
            send(caller, {ref, message})
            :ok
        end

        conn =
          SinkAdapter.conn(request.method, request.path, sink)
          |> Plug.Conn.assign(:client, Keyword.get(opts, :client, {"ann", [:lend, :browse]}))

        Rest.call(conn, Rest.init([]))
        send(caller, {ref, :done})
      end)

    monitor = Process.monitor(server)

    receive do
      {^ref, {:head, status, headers}} ->
        {:ok, %{status: status, headers: headers, body: body(ref, server, monitor)}}

      {^ref, {:whole, status, headers, body}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, %{status: status, headers: headers, body: [body]}}
    after
      5_000 -> {:error, :timeout}
    end
  end

  defp body(ref, server, monitor) do
    Stream.resource(
      fn -> :first end,
      fn
        :done ->
          {:halt, :done}

        state ->
          if state == :next, do: send(server, {ref, :more})

          receive do
            {^ref, :chunk, body} -> {[body], :next}
            {^ref, :done} -> {:halt, :done}
            {:DOWN, ^monitor, :process, _, :normal} -> {:halt, :done}
            {:DOWN, ^monitor, :process, _, _reason} -> {[{:error, :closed}], :done}
          after
            5_000 -> {[{:error, :timeout}], :done}
          end
      end,
      fn
        :done ->
          Process.demonitor(monitor, [:flush])

        _reading ->
          # The client is gone: the router's next chunk/2 fails.
          send(server, {ref, :gone})

          receive do
            {:DOWN, ^monitor, :process, _, _} -> :ok
          after
            5_000 -> :ok
          end
      end
    )
  end
end

defmodule AtlasRuntimeBackend.Generator.Example.StreamClient do
  @moduledoc "The example contract's client on the streaming transport."
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.Generator.Example.Api,
    transport: AtlasRuntimeBackend.Generator.Example.StreamTransport
end
