defmodule AtlasRuntime.Sources.HttpTargetPutBlobTest do
  @moduledoc """
  D2 (pull-e2e plan P3, with re-review C2 and C3): `HttpTarget.put_blob/2` over the real
  transport against an in-test TLS 1.3 server that reads each request raw.

  - Each answer the `work_source` 0.2.0 route names maps to Upload's seam: 200 `stored`,
    410 `lease_lost`, 413 `too_large`, 409 `not_referenced`; `rejected` (400 `invalid`,
    422 `digest-mismatch`) stops as for a lost lease (as `InBeamTarget.put_blob/2` does), so
    the puller never repeats it; a connection closed before an answer is `{:error, _}`.
  - The body is the frozen store's own blob stream (a raw `File.stream!`), sent chunked,
    without a Content-Length, byte for byte.
  """
  # The :httpc profile and the logger's primary filters are global.
  use ExUnit.Case, async: false

  alias AtlasRuntime.Sources.{Credential, HttpTarget}
  alias AtlasRuntime.TLSFixtures, as: F
  alias AtlasRuntime.Work.FrozenStore

  @moduletag capture_log: true

  @name "flow-test"
  @lease "lease-0001"

  defmodule RawServer do
    @moduledoc false
    # A TLS 1.3 server on a listening socket that reads each request raw: its head, then its
    # body as the head frames it (chunked, de-chunked here, or by Content-Length). It sends
    # `{:raw, request}` to the test and answers as `answer.(request)` says: `{:send, bytes}`
    # after the body; `{:early, bytes}` right after the head, the body unread, then closes;
    # `:close` after the body, with no answer. One connection after another.
    def serve(listen, test, answer) do
      {:ok, socket} = :ssl.transport_accept(listen)
      {:ok, socket} = :ssl.handshake(socket, 30_000)
      {head, rest} = head(socket, "")
      [request_line | lines] = String.split(head, "\r\n")
      [method, path, _version] = String.split(request_line, " ")

      headers =
        for line <- lines,
            [name, value] = String.split(line, ":", parts: 2),
            do: {String.downcase(name), String.trim(value)}

      request = %{method: method, path: path, headers: headers}

      case answer.(request) do
        {:early, bytes} ->
          send(test, {:raw, Map.merge(request, %{chunked?: chunked?(headers), body: nil})})
          _ = :ssl.send(socket, bytes)

        then ->
          body =
            if chunked?(headers),
              do: chunks(socket, rest, []),
              else: exactly(socket, rest, content_length(headers))

          send(test, {:raw, Map.merge(request, %{chunked?: chunked?(headers), body: body})})
          with {:send, bytes} <- then, do: :ssl.send(socket, bytes)
      end

      :ssl.close(socket)
      serve(listen, test, answer)
    end

    def response(status, json \\ nil) do
      body = if json, do: JSON.encode!(json), else: ""

      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
    end

    defp chunked?(headers), do: {"transfer-encoding", "chunked"} in headers

    defp content_length(headers) do
      case List.keyfind(headers, "content-length", 0) do
        {_, n} -> String.to_integer(n)
        nil -> 0
      end
    end

    defp recv!(socket) do
      {:ok, data} = :ssl.recv(socket, 0, 30_000)
      data
    end

    defp head(socket, buffer) do
      case :binary.split(buffer, "\r\n\r\n") do
        [head, rest] -> {head, rest}
        [_] -> head(socket, buffer <> recv!(socket))
      end
    end

    defp exactly(_socket, buffer, n) when byte_size(buffer) >= n, do: binary_part(buffer, 0, n)
    defp exactly(socket, buffer, n), do: exactly(socket, buffer <> recv!(socket), n)

    # The chunked framing: `<hex size>\r\n<bytes>\r\n` ... `0\r\n\r\n`.
    defp chunks(socket, buffer, acc) do
      case :binary.split(buffer, "\r\n") do
        [size_line, rest] ->
          {size, _} = Integer.parse(size_line, 16)

          if size == 0 do
            IO.iodata_to_binary(Enum.reverse(acc))
          else
            rest = fill(socket, rest, size + 2)
            <<chunk::binary-size(size), "\r\n", rest::binary>> = rest
            chunks(socket, rest, [chunk | acc])
          end

        [_] ->
          chunks(socket, buffer <> recv!(socket), acc)
      end
    end

    defp fill(_socket, buffer, n) when byte_size(buffer) >= n, do: buffer
    defp fill(socket, buffer, n), do: fill(socket, buffer <> recv!(socket), n)
  end

  setup do
    home = Path.join(System.tmp_dir!(), "d2-put-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, "sources", @name]))
    path = Credential.path(home, @name)
    File.write!(path, "t0k." <> Base.encode16(:crypto.strong_rand_bytes(24), case: :lower))
    File.chmod!(path, 0o600)
    on_exit(fn -> File.rm_rf!(home) end)

    pki = F.pki("localhost")
    %{home: home, pki: pki, cacertfile: F.cacertfile(pki, home)}
  end

  # A raw TLS 1.3 server answering with `answer`, and the HTTP target's ref to it.
  defp target(ctx, answer) do
    {:ok, listen} =
      :ssl.listen(
        0,
        [:binary, active: false, ip: {127, 0, 0, 1}, versions: [:"tlsv1.3"]] ++ ctx.pki.server
      )

    on_exit(fn -> :ssl.close(listen) end)
    {:ok, {_ip, port}} = :ssl.sockname(listen)
    test = self()

    start_supervised!(
      Supervisor.child_spec({Task, fn -> RawServer.serve(listen, test, answer) end},
        id: make_ref()
      )
    )

    assert {:ok, ref} =
             HttpTarget.open(@name, "https://localhost:#{port}", ctx.home,
               cacertfile: ctx.cacertfile
             )

    on_exit(fn -> HttpTarget.close(ref) end)
    ref
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp blob(bytes, content \\ nil),
    do: %{
      lease_id: @lease,
      sha256: sha(bytes),
      size: byte_size(bytes),
      content: content || [bytes]
    }

  defp answering(status, json \\ nil),
    do: fn _request -> {:send, RawServer.response(status, json)} end

  test "each answer of the route maps to Upload's seam", ctx do
    bytes = "abcdef"

    for {status, json, expected} <- [
          {200, nil, :stored},
          {410, %{type: "lease-lost"}, :lease_lost},
          {413, %{type: "too-large"}, :too_large},
          {409, %{type: "not-referenced"}, :not_referenced}
        ] do
      ref = target(ctx, answering(status, json))
      assert HttpTarget.put_blob(ref, blob(bytes)) == expected

      path = "/v1/leases/#{@lease}/blobs/#{sha(bytes)}"

      assert_received {:raw,
                       %{method: "PUT", path: ^path, chunked?: true, body: ^bytes} = request}

      assert {"blob-size", "6"} in request.headers
    end
  end

  # C2: a rejected put_blob is final at the source; repeating it would loop for ever.
  test "rejected (400 invalid, 422 digest-mismatch) stops as for a lost lease", ctx do
    for {status, type, reason} <- [
          {400, "invalid", "invalid"},
          {422, "digest-mismatch", "digest_mismatch"}
        ] do
      ref = target(ctx, answering(status, %{type: type, reason: reason, detail: "x"}))
      assert HttpTarget.put_blob(ref, blob("abc")) == :lease_lost
      assert_received {:raw, %{chunked?: true}}
    end
  end

  test "a connection closed before an answer is an error, not an outcome", ctx do
    ref = target(ctx, fn _request -> :close end)
    assert {:error, _} = HttpTarget.put_blob(ref, blob("abc"))
    assert_received {:raw, %{chunked?: true, body: "abc"}}
  end

  # C3: the frozen store's blob is a raw File.stream!, readable only by the process that
  # opened it. It is sent whole, chunked, without a Content-Length.
  test "a frozen-store blob stream is sent chunked and byte-exact", ctx do
    bytes = :crypto.strong_rand_bytes(200_000)
    store = Path.join(ctx.home, "rt")
    File.mkdir_p!(store)
    :ok = FrozenStore.ensure!(store)
    File.write!(FrozenStore.blob_path(store, sha(bytes)), bytes)
    content = FrozenStore.blob(store, sha(bytes))
    assert %File.Stream{} = content

    ref = target(ctx, answering(200))
    assert HttpTarget.put_blob(ref, blob(bytes, content)) == :stored

    assert_received {:raw, %{chunked?: true, headers: headers, body: body}}
    refute List.keymember?(headers, "content-length", 0)
    assert sha(body) == sha(bytes)
  end
end
