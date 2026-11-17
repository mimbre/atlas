defmodule AtlasRuntime.WorkSource.HttpPutBlobTest.StreamedBody do
  @moduledoc """
  A `Plug.Conn` adapter for these tests only: `Plug.Adapters.Test.Conn`, except that the
  request body is pulled from the client's enumerable one element per read, only when the
  server reads it. So what the server never reads is never made, as over a socket.
  """
  @behaviour Plug.Conn.Adapter
  @inner Plug.Adapters.Test.Conn

  def conn(method, path, body) do
    conn = Plug.Test.conn(method, path, "")
    {@inner, state} = conn.adapter
    pull = &Enumerable.reduce(body, &1, fn chunk, _ -> {:suspend, chunk} end)
    %{conn | adapter: {__MODULE__, Map.put(state, :pull, pull)}}
  end

  @doc "Ends the body's enumeration where the server left it, so its clean-up runs."
  def finish(%Plug.Conn{adapter: {__MODULE__, %{pull: pull}}}) when is_function(pull, 1) do
    pull.({:halt, nil})
    :ok
  end

  def finish(_conn), do: :ok

  @impl true
  def read_req_body(%{pull: :done} = state, _opts), do: {:ok, "", state}

  def read_req_body(%{pull: pull} = state, _opts) do
    case pull.({:cont, nil}) do
      {:suspended, chunk, next} -> {:more, IO.iodata_to_binary(chunk), %{state | pull: next}}
      {_done_or_halted, _} -> {:ok, "", %{state | pull: :done}}
    end
  end

  @impl true
  def send_resp(state, status, headers, body), do: @inner.send_resp(state, status, headers, body)
  @impl true
  def send_chunked(state, status, headers), do: @inner.send_chunked(state, status, headers)
  @impl true
  def chunk(state, body), do: @inner.chunk(state, body)
  @impl true
  def send_file(state, status, headers, path, offset, length),
    do: @inner.send_file(state, status, headers, path, offset, length)

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

defmodule AtlasRuntime.WorkSource.HttpPutBlobTest.Transport do
  @moduledoc """
  The client transport of these tests: each request goes in this process to the test-only
  stand-in source (`AtlasRuntime.Test.WorkSourceRest` on `AtlasRuntime.Test.FakeWorkSource`),
  with a streamed body pulled as the server reads it. It tells the test process what the
  client handed it: `{:sent, request}`, the body as `{:binary, size}` or `:enumerable`.
  No listener: nothing here opens a socket.
  """
  @behaviour AtlasRuntimeBackend.Generator.Targets.Client.Transport

  alias AtlasRuntime.Test.{FakeWorkSource, WorkSourceRest}
  alias AtlasRuntime.WorkSource.HttpPutBlobTest.StreamedBody

  @impl true
  def request(request, opts) do
    send(self(), {:sent, %{request | body: kind(request.body)}})
    path = if request.query == "", do: request.path, else: request.path <> "?" <> request.query

    conn =
      case request.body do
        body when is_binary(body) or is_nil(body) ->
          Plug.Test.conn(request.method, path, body || "")

        body ->
          StreamedBody.conn(request.method, path, body)
      end

    conn =
      Enum.reduce(request.headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    conn =
      case FakeWorkSource.credential(opts[:credential]) do
        {:ok, runtime_id} ->
          conn
          |> Plug.Conn.assign(:client, {runtime_id, [:lease]})
          |> WorkSourceRest.call(WorkSourceRest.init([]))

        :error ->
          WorkSourceRest.__problem__(:unauthenticated, conn)
      end

    StreamedBody.finish(conn)
    {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
  end

  @impl true
  def stream(request, opts) do
    {:ok, answer} = request(request, opts)
    {:ok, %{answer | body: [answer.body]}}
  end

  defp kind(nil), do: nil
  defp kind(body) when is_binary(body), do: {:binary, byte_size(body)}
  defp kind(_body), do: :enumerable
end

defmodule AtlasRuntime.WorkSource.HttpPutBlobTest.Client do
  @moduledoc "The work source contract's generated HTTP client, on this test's transport."
  use AtlasRuntimeBackend.Generator.Targets.Client,
    contract: AtlasRuntimeBackend.WorkSource,
    transport: AtlasRuntime.WorkSource.HttpPutBlobTest.Transport
end

defmodule AtlasRuntime.WorkSource.HttpPutBlobTest do
  # M3 plan §9 Q2: put_blob over HTTP, `PUT /v1/leases/:lease_id/blobs/:sha256`, served by
  # the source. The Runtime is only the client: its generated client streams the blob as
  # the request body, with Blob-Size, to a test-only stand-in source in this process.
  use ExUnit.Case, async: true

  alias AtlasRuntime.Test.FakeWorkSource, as: Source
  alias AtlasRuntime.WorkSource.HttpPutBlobTest.Client

  @as [transport: [credential: "cred-mini"]]
  @mib 1_048_576

  # A lazy blob: `count` chunks of `size` bytes, each made only when read; every chunk
  # made tells the test process {:made, ref, index}, the clean-up {:closed, ref}.
  defp blob(count, size) do
    owner = self()
    ref = make_ref()

    stream =
      Stream.resource(
        fn -> 0 end,
        fn
          i when i >= count ->
            {:halt, i}

          i ->
            send(owner, {:made, ref, i})
            {[:binary.copy(<<rem(i, 251)>>, size)], i + 1}
        end,
        fn _ -> send(owner, {:closed, ref}) end
      )

    bytes = for i <- 0..(count - 1)//1, into: "", do: :binary.copy(<<rem(i, 251)>>, size)

    %{
      ref: ref,
      stream: stream,
      bytes: bytes,
      sha256: Source.sha256(bytes),
      size: byte_size(bytes)
    }
  end

  defp made(%{ref: ref}), do: made(ref, 0)

  defp made(ref, n) do
    receive do
      {:made, ^ref, _} -> made(ref, n + 1)
    after
      0 -> n
    end
  end

  defp start(opts \\ []) do
    source = Source.start(Keyword.put_new(opts, :name, "flow-test"))
    Source.use(source)

    manifest = ~s({"entries":[]})

    Source.add_work(
      source,
      %{
        work_key: "task-1",
        title: "Author package 1",
        instructions: "Write it.",
        profile: "deep_coding",
        cost_class: :standard,
        input: %{
          base: %{base_id: "base-1", manifest: Source.sha256(manifest)},
          permissions: :"workspace-write"
        }
      },
      %{Source.sha256(manifest) => manifest}
    )

    source
  end

  # A lease whose recorded ended references `blobs` ([{path, %{sha256:, size:}}]).
  defp ended_lease(blobs) do
    {:polled, %{leases: [%{lease_id: lease}]}} =
      Client.poll(
        %{
          runtime_id: "mini",
          incarnation: "inc-1",
          build: "test",
          policy_version: 1,
          offer: %{"deep_coding" => 1},
          holdings: []
        },
        @as
      )

    {:recorded, _} =
      Client.report(%{lease_id: lease, revision: 1, report: %{state: :accepted}}, @as)

    entries =
      for {path, b} <- blobs,
          do: %{
            path: path,
            op: :write,
            kind: :file,
            mode: :"100644",
            size: b.size,
            sha256: b.sha256
          }

    {:recorded, %{missing: missing}} =
      Client.report(
        %{
          lease_id: lease,
          revision: 2,
          report: %{
            state: :ended,
            result: %{kind: :completed, retryable: false, never_started: false},
            provenance: [],
            change_set: %{roots: [%{root: "repo", fingerprint: "csf_test", entries: entries}]}
          }
        },
        @as
      )

    assert Enum.sort(missing) == Enum.sort(for {_, b} <- blobs, do: b.sha256)
    flush_sent()
    lease
  end

  defp flush_sent do
    receive do
      {:sent, _} -> flush_sent()
    after
      0 -> :ok
    end
  end

  defp put(lease, b, overrides \\ %{}) do
    Client.put_blob(
      Map.merge(%{lease_id: lease, sha256: b.sha256, size: b.size, content: b.stream}, overrides),
      @as
    )
  end

  test "the client has put_blob among its calls" do
    assert :put_blob in Client.__capabilities__()
  end

  test "the blob goes as a streamed PUT body: lease and sha256 in the path, Blob-Size, octet-stream" do
    source = start()
    b = blob(4, 1000)
    lease = ended_lease([{"a.bin", b}])

    assert put(lease, b) == :stored

    assert_received {:sent, request}
    assert request.method == "PUT"

    assert request.path ==
             "/v1/leases/#{URI.encode(lease, &URI.char_unreserved?/1)}/blobs/#{b.sha256}"

    assert {"blob-size", Integer.to_string(b.size)} in request.headers
    assert {"content-type", "application/octet-stream"} in request.headers

    # Handed on unread: the transport got the enumerable, not the bytes.
    assert request.body == :enumerable

    # Every chunk was made once, by the server's reads, and the stream was closed.
    assert made(b) == 4
    assert_received {:closed, _}
    assert Source.blobs(source)[b.sha256] == b.bytes

    # Stored again is stored.
    assert put(lease, blob(4, 1000)) == :stored
  end

  test "bytes that do not have the path's sha256, or the declared size, are a digest mismatch" do
    source = start()
    b = blob(2, 10)
    lease = ended_lease([{"a.bin", b}])

    # As many bytes, other ones.
    zeros = [:binary.copy(<<0>>, b.size)]
    assert {:rejected, %{reason: :digest_mismatch}} = put(lease, b, %{content: zeros})

    # Blob-Size carries the declared size; the source checks the bytes against it.
    assert {:rejected, %{reason: :digest_mismatch}} = put(lease, b, %{size: b.size - 1})
    assert_received {:sent, %{headers: headers}}
    assert {"blob-size", Integer.to_string(b.size)} in headers
    assert_received {:sent, %{headers: headers}}
    assert {"blob-size", Integer.to_string(b.size - 1)} in headers

    refute Map.has_key?(Source.blobs(source), b.sha256)
  end

  test "too_large by the declared size: no byte of the body is made" do
    start(result_cap: 100)
    b = blob(50, 4)
    lease = ended_lease([{"big.bin", b}])

    assert put(lease, b) == :too_large
    assert made(b) == 0
  end

  test "too_large while it streams: the client stops being read at the cap, never whole" do
    start(result_cap: 100)
    big = blob(50, 4)
    lease = ended_lease([{"big.bin", big}])

    # The declared size fits; the bytes do not. The source stops reading past its room.
    assert put(lease, big, %{size: 40}) == :too_large
    assert made(big) < 50
    assert_received {:closed, _}
  end

  test "too_large past the server's body limit is the same outcome, read only to the limit" do
    start()
    big = blob(8, div(@mib, 4))
    lease = ended_lease([{"big.bin", big}])

    assert put(lease, big) == :too_large
    assert made(big) < 8
  end

  test "lease_lost: a stale lease's put_blob is fenced before a byte is made" do
    source = start()
    b = blob(3, 10)
    lease = ended_lease([{"a.bin", b}])

    Source.advance(source, 900)
    assert put(lease, b) == :lease_lost
    assert made(b) == 0
    refute Map.has_key?(Source.blobs(source), b.sha256)
  end

  test "not_referenced: a blob the lease's ended does not reference is refused unread" do
    start()
    b = blob(1, 10)
    lease = ended_lease([{"a.bin", b}])
    stray = blob(2, 7)

    assert put(lease, stray) == :not_referenced
    assert made(stray) == 0
  end

  test "content that is no enumerable of binaries is refused by the client, without a request" do
    start()
    b = blob(1, 10)
    lease = ended_lease([{"a.bin", b}])

    assert {:error, {:invalid, [_ | _]}} = put(lease, b, %{content: b.bytes})
    refute_received {:sent, _}
  end

  test "without a valid credential the put is answered 401, before the source reads" do
    start()
    b = blob(1, 10)
    lease = ended_lease([{"a.bin", b}])

    assert Client.put_blob(
             %{lease_id: lease, sha256: b.sha256, size: b.size, content: b.stream},
             transport: [credential: "nope"]
           ) == {:error, :unauthenticated}

    assert made(b) == 0
  end
end
