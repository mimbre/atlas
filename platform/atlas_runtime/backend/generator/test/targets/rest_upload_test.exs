defmodule AtlasRuntimeBackend.Generator.Targets.RestUploadTest.CountingAdapter do
  @moduledoc """
  A `Plug.Conn` adapter for the upload tests: `Plug.Adapters.Test.Conn`, except that every
  body read tells the test process how many bytes it handed out (`{:adapter_read, bytes}`),
  so a test sees what the router read and when. `fail_after:` reads after that many
  bytes fail with `{:error, :timeout}`.
  """
  @behaviour Plug.Conn.Adapter
  @inner Plug.Adapters.Test.Conn

  def conn(method, path, body, opts \\ []) do
    conn = Plug.Test.conn(method, path, body)
    {@inner, state} = conn.adapter
    state = Map.merge(state, %{counted: self(), read: 0, fail_after: opts[:fail_after]})
    %{conn | adapter: {__MODULE__, state}}
  end

  @impl true
  def read_req_body(%{fail_after: limit, read: read}, _opts)
      when is_integer(limit) and read >= limit,
      do: {:error, :timeout}

  def read_req_body(state, opts) do
    {tag, data, state} = @inner.read_req_body(state, opts)
    send(state.counted, {:adapter_read, byte_size(data)})
    {tag, data, %{state | read: state.read + byte_size(data)}}
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

defmodule AtlasRuntimeBackend.Generator.Targets.RestUploadTest do
  # Not async: the limit and the reads are per process, but the 3 MiB bodies are large.
  use ExUnit.Case, async: false
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.{Client, Rest}
  alias AtlasRuntimeBackend.Generator.Targets.Openapi
  alias AtlasRuntimeBackend.Generator.Targets.Rest.Runtime
  alias __MODULE__.CountingAdapter

  @member {"ann", [:lend, :browse]}
  @mib 1_048_576
  @octet "application/octet-stream"

  setup do
    on_exit(fn -> Process.delete(:example_deposit_limit) end)
  end

  # A PUT of `body` to /v1/books/<id>/pages through the counting adapter.
  defp deposit(id, body, opts \\ []) do
    conn =
      CountingAdapter.conn("PUT", "/v1/books/#{id}/pages", body, opts)
      |> assign(:client, Keyword.get(opts, :client, @member))

    conn =
      case Keyword.get(opts, :content_type, @octet) do
        nil -> conn
        type -> put_req_header(conn, "content-type", type)
      end

    conn =
      if length = opts[:content_length],
        do: put_req_header(conn, "content-length", Integer.to_string(length)),
        else: conn

    Rest.call(conn, Rest.init([]))
  end

  defp json(conn), do: JSON.decode!(conn.resp_body)

  # The messages the adapter and the facade sent, in the order they were sent.
  defp trace(acc \\ []) do
    receive do
      {:adapter_read, n} -> trace([{:read, n} | acc])
      {:deposit_chunk, n} -> trace([{:chunk, n} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp bytes(size),
    do: :binary.copy(<<7, 1, 255, 0>>, div(size, 4)) <> :binary.copy("x", rem(size, 4))

  defp sha256(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

  defp read_total(trace),
    do: trace |> Enum.filter(&match?({:read, _}, &1)) |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  describe "a streamed request body" do
    test "1 MiB arrives as it is read, only when the facade asks (m1)" do
      body = bytes(@mib)
      conn = deposit("b1", body)

      assert conn.status == 201
      assert get_resp_header(conn, "connection") == []

      assert json(conn) == %{
               "book_id" => "b1",
               "bytes" => @mib,
               "sha256" => sha256(body)
             }

      # The held-chunk probe: the chunk is read just before the facade gets it, never ahead.
      assert trace() == [{:read, @mib}, {:chunk, @mib}]

      assert_received {:example_called, :deposit, @member, %{book_id: "b1"}}
      assert_received {:deposit_after, "b1"}
    end

    test "a streamed body has the 1 MiB cap too, whatever max_bytes allows (8 MiB here)" do
      conn = deposit("b1", bytes(@mib + 1))

      assert conn.status == 413
      assert get_resp_header(conn, "connection") == ["close"]

      assert %{
               "type" => "too-large",
               "status" => 413,
               "detail" => "the body is larger than 1048576 bytes"
             } = json(conn)

      assert_received {:deposit_after, "b1"}
      # Never more than one byte past the cap is read.
      assert read_total(trace()) == @mib + 1

      conn = deposit("b2", bytes(3 * @mib), content_length: 3 * @mib)
      assert conn.status == 413
      assert json(conn)["detail"] == "the body is larger than 1048576 bytes"
      refute_received {:example_called, :deposit, _, %{book_id: "b2"}}
      assert trace() == []
    end

    test "the facade's input holds the body unread, as an enumerable" do
      conn = deposit("ignored", bytes(10))

      assert conn.status == 201
      assert_received {:example_called, :deposit, _client, input}
      refute is_binary(input.pages)
      assert Enumerable.impl_for(input.pages)
      assert trace() == []
    end

    test "an empty body is an empty stream" do
      conn = deposit("b1", "")
      assert conn.status == 201
      assert json(conn)["bytes"] == 0
      assert json(conn)["sha256"] == sha256("")
    end

    test "max_bytes + 1 is 413 too-large, the facade's clean-up runs, and the connection closes (m3)" do
      Process.put(:example_deposit_limit, 1000)

      conn = deposit("b1", bytes(1000))
      assert conn.status == 201
      assert json(conn)["bytes"] == 1000
      _ = trace()

      conn = deposit("b2", bytes(1001))
      assert conn.status == 413
      assert get_resp_header(conn, "content-type") == ["application/problem+json"]
      assert get_resp_header(conn, "connection") == ["close"]

      assert %{
               "type" => "too-large",
               "status" => 413,
               "detail" => "the body is larger than 1000 bytes"
             } = json(conn)

      assert_received {:deposit_after, "b2"}
      # Never more than one byte past the limit is read.
      assert read_total(trace()) == 1001
    end

    test "a Content-Length above max_bytes is 413 before the facade is called (m3)" do
      Process.put(:example_deposit_limit, 1000)
      conn = deposit("b1", bytes(1001), content_length: 1001)

      assert conn.status == 413
      assert %{"type" => "too-large"} = json(conn)
      assert get_resp_header(conn, "connection") == ["close"]
      refute_received {:example_called, :deposit, _, _}
      assert trace() == []
    end

    test "max_bytes is asked for each request" do
      Process.put(:example_deposit_limit, 4)
      assert deposit("b1", "12345").status == 413
      Process.put(:example_deposit_limit, 5)
      assert deposit("b1", "12345").status == 201
    end

    test "another Content-Type, or none, is 415; the facade is not called and nothing is read (m4)" do
      for type <- ["application/json", "text/plain", nil, "application/octet-streamx"] do
        conn = deposit("b1", bytes(100), content_type: type)

        assert conn.status == 415, "content type #{inspect(type)}"
        assert get_resp_header(conn, "connection") == ["close"]

        assert %{"type" => "unsupported-media-type", "status" => 415} = json(conn)
        refute_received {:example_called, :deposit, _, _}
        assert trace() == []
      end
    end

    test "the content type is compared without case and without its parameters" do
      for type <- ["Application/Octet-Stream", "application/octet-stream; charset=binary"] do
        assert deposit("b1", "abc", content_type: type).status == 201
      end
    end

    test "an early outcome: its status, connection: close, and the rest is never read" do
      conn = deposit("early", bytes(3 * @mib))

      assert conn.status == 400
      assert %{"type" => "invalid", "reason" => "invalid"} = json(conn)
      assert get_resp_header(conn, "connection") == ["close"]
      # One chunk of three was read; the router read nothing more after the facade answered.
      assert trace() == [{:read, @mib}, {:chunk, @mib}]
      assert_received {:deposit_after, "early"}
    end

    test "an outcome without reading, and a refusal before it: nothing read, connection: close" do
      conn = deposit("ignored", bytes(@mib))
      assert conn.status == 201
      assert get_resp_header(conn, "connection") == ["close"]

      conn = deposit("missing", bytes(@mib))
      assert conn.status == 404
      assert get_resp_header(conn, "connection") == ["close"]

      conn = deposit("b1", bytes(@mib), client: {"guest", [:browse]})
      assert conn.status == 403
      assert %{"type" => "not-permitted", "detail" => "this needs the right lend"} = json(conn)
      assert get_resp_header(conn, "connection") == ["close"]

      assert trace() == []
    end

    test "a read that fails is 400 invalid, and the connection closes" do
      conn = deposit("b1", bytes(3 * @mib), fail_after: @mib)

      assert conn.status == 400
      assert get_resp_header(conn, "connection") == ["close"]

      assert %{"type" => "invalid", "detail" => "the body could not be read to its end"} =
               json(conn)

      assert_received {:deposit_after, "b1"}
    end

    test "JSON resources still refuse a body over 1 MiB (m2)" do
      body = JSON.encode!(%{"title" => String.duplicate("a", @mib)})

      conn =
        Plug.Test.conn("POST", "/v1/books", body)
        |> put_req_header("content-type", "application/json")
        |> assign(:client, @member)
        |> Rest.call(Rest.init([]))

      assert conn.status == 400
      assert json(conn)["detail"] =~ "larger than 1048576 bytes"
      refute_received {:example_called, :lend, _, _}
    end

    test "no answer repeats the request's path or content type (D44)" do
      secret = "/Users/someone/private/tree"

      conn = deposit("b1", "x", content_type: "application/x-#{secret}")
      assert conn.status == 415
      refute conn.resp_body =~ "someone"

      conn =
        Plug.Test.conn("PUT", "/v1/books/b1/pages#{secret}", "x")
        |> put_req_header("content-type", @octet)
        |> assign(:client, @member)
        |> Rest.call(Rest.init([]))

      assert conn.status == 404
      assert %{"type" => "no-route", "detail" => detail} = json(conn)
      refute detail =~ "someone"
      refute detail =~ "/v1"
    end

    test "__routes__/0 carries the upload and its errors" do
      route = Enum.find(Rest.__routes__(), &(&1.capability == :deposit))

      assert %{
               method: :put,
               path: "/v1/books/:book_id/pages",
               upload: %{
                 field: :pages,
                 content_type: @octet,
                 errors: [
                   %{kind: :too_large, status: 413, type: "too-large"},
                   %{kind: :unsupported_media_type, status: 415, type: "unsupported-media-type"}
                 ]
               }
             } = route

      refute Map.has_key?(Enum.find(Rest.__routes__(), &(&1.capability == :lend)), :upload)
    end
  end

  describe "the body stream (Runtime.upload/3)" do
    # A body reader over `chunks`, as Plug.Conn.read_body/2 answers: each call tells the
    # test process the length it asked for.
    defp reader(chunks) do
      key = {:chunks, make_ref()}
      Process.put(key, chunks)

      fn conn, opts ->
        send(self(), {:asked, opts[:length]})

        case Process.get(key) do
          [last] ->
            Process.put(key, [])
            {:ok, last, conn}

          [one | rest] ->
            Process.put(key, rest)
            {:more, one, conn}
        end
      end
    end

    test "is read only in the process that took the request" do
      {ref, stream} = Runtime.upload(:conn, 10, reader(["ab"]))
      task = Task.async(fn -> catch_error(Enum.to_list(stream)) end)

      assert %ArgumentError{message: message} = Task.await(task)
      assert message =~ "in the process that took the request"
      assert Enum.to_list(stream) == ["ab"]
      assert Runtime.uploaded(ref) == {:conn, true}
      Runtime.discard(ref)
    end

    test "is not read after its request was answered" do
      {ref, stream} = Runtime.upload(:conn, 10, reader(["ab"]))
      Runtime.discard(ref)

      assert_raise ArgumentError, ~r/after its request was answered/, fn ->
        Enum.to_list(stream)
      end
    end

    test "asks for at most 1 MiB, and never more than one byte past the limit" do
      {ref, stream} = Runtime.upload(:conn, 3 * @mib, reader(["a", "b"]))
      assert Enum.to_list(stream) == ["a", "b"]
      assert_received {:asked, @mib}
      Runtime.discard(ref)

      {ref, stream} = Runtime.upload(:conn, 5, reader(["abc", "de"]))
      assert Enum.to_list(stream) == ["abc", "de"]
      assert_received {:asked, 6}
      assert_received {:asked, 3}
      Runtime.discard(ref)
    end

    test "after its end, or once it failed, is empty" do
      {ref, stream} = Runtime.upload(:conn, 10, reader(["ab"]))
      assert Enum.to_list(stream) == ["ab"]
      assert Enum.to_list(stream) == []
      Runtime.discard(ref)
    end

    test "a limit that is no positive integer is an ArgumentError" do
      assert_raise ArgumentError, ~r/M.f\(\) gave 0, no positive number of bytes/, fn ->
        Runtime.limit!(0, M, :f)
      end
    end
  end

  describe "the other targets" do
    test "the client sends the stream as the body, with the declared content type" do
      assert {:deposited, %{book_id: "b1", bytes: 4, sha256: sha}} =
               Client.deposit(%{book_id: "b1", pages: Stream.map(["ab", "cd"], & &1)})

      assert sha == sha256("abcd")
      assert_received {:transport, request}
      assert request.method == "PUT"
      assert request.path == "/v1/books/b1/pages"
      assert {"content-type", @octet} in request.headers
      refute is_binary(request.body)

      assert {:error, {:invalid, ["pages is invalid: no enumerable of binaries"]}} =
               Client.deposit(%{book_id: "b1", pages: "abcd"})

      assert {:error, :too_large} =
               Client.deposit(%{book_id: "b1", pages: ["abcd"]},
                 transport: [respond: {413, ~s({"type":"too-large","title":"x","status":413})}]
               )
    end

    test "openapi: an octet-stream request body, and 413/415 only where a body is streamed" do
      [{_, body}] = Openapi.files(AtlasRuntimeBackend.Generator.Example.Api.__schema__(), [])
      doc = JSON.decode!(body)
      put = doc["paths"]["/v1/books/{book_id}/pages"]["put"]

      assert put["requestBody"] == %{
               "required" => true,
               "content" => %{
                 @octet => %{
                   "schema" => %{
                     "type" => "string",
                     "format" => "binary",
                     "description" => "the input's `pages`, as a byte stream"
                   }
                 }
               }
             }

      assert Map.has_key?(put["responses"], "413")
      assert Map.has_key?(put["responses"], "415")

      for {path, ops} <- doc["paths"],
          {method, op} <- ops,
          {path, method} != {"/v1/books/{book_id}/pages", "put"} do
        refute Map.has_key?(op["responses"], "413"), "#{method} #{path}"
        refute Map.has_key?(op["responses"], "415"), "#{method} #{path}"
      end
    end
  end
end
