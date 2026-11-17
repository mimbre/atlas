defmodule AtlasBodyLimitTest do
  # The cap holds whatever the transfer encoding: over a real Bandit socket (127.0.0.1, port
  # 0) with raw requests, a chunked body past the cap is refused after at most the cap plus
  # one socket read (the bytes the server took off the socket, `recv_oct`), a chunked body
  # within it is read whole and byte-identical, the connection stays usable after one, and a
  # response that leaves a body unread says `connection: close` (Bandit does not drain it).
  use ExUnit.Case, async: true

  @mib 1_048_576
  # One socket read past the cap, and the request's head: what the server may take beyond it.
  @slack @mib + 64 * 1024

  defmodule Probe do
    @moduledoc "Reads the body as told and tells the test what it read and took off the socket."
    @behaviour Plug
    import Plug.Conn

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, %{test: test, limit: limit, mode: mode}) do
      conn = AtlasBodyLimit.guard(conn)

      {result, conn} =
        case mode do
          :read ->
            case AtlasBodyLimit.read(conn, limit) do
              {:ok, body, conn} -> {{:ok, byte_size(body), :crypto.hash(:sha256, body)}, conn}
              {:too_large, conn} -> {:too_large, conn}
              {:error, reason, conn} -> {{:error, reason}, conn}
            end

          :stream ->
            {ref, body} = AtlasBodyLimit.stream(conn, limit)
            size = Enum.reduce(body, 0, &(byte_size(&1) + &2))
            {conn, state} = AtlasBodyLimit.streamed(ref)
            {{:stream, size, state}, conn}

          :unread ->
            {:unread, conn}
        end

      send(test, {:served, result, AtlasBodyLimit.ended?(conn), taken(conn)})

      status =
        case result do
          {:ok, _, _} -> 200
          {:stream, _, :ended} -> 200
          {:error, _} -> 400
          :unread -> 401
          _too_large -> 413
        end

      send_resp(conn, status, "")
    end

    defp taken(%{adapter: {_, %{transport: %{socket: %{socket: port}}}}}) do
      {:ok, [recv_oct: n]} = :inet.getstat(port, [:recv_oct])
      n
    end
  end

  defp serve(mode, limit) do
    pid =
      start_supervised!(
        {Bandit,
         plug: {Probe, %{test: self(), limit: limit, mode: mode}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp head(extra),
    do:
      ["PUT /x HTTP/1.1\r\nhost: t\r\n" | Enum.map(extra, fn {k, v} -> "#{k}: #{v}\r\n" end)] ++
        ["\r\n"]

  defp chunked_head, do: head([{"transfer-encoding", "chunked"}])

  # `size` bytes of `byte` as chunks of `piece` bytes, then the last chunk.
  defp chunks(size, piece, byte \\ ?x) do
    full = div(size, piece)
    rest = rem(size, piece)
    data = :binary.copy(<<byte>>, piece)
    one = [Integer.to_string(piece, 16), "\r\n", data, "\r\n"]

    Stream.concat([
      Stream.duplicate(one, full),
      if(rest > 0,
        do: [[Integer.to_string(rest, 16), "\r\n", :binary.copy(<<byte>>, rest), "\r\n"]],
        else: []
      ),
      ["0\r\n\r\n"]
    ])
  end

  # Sends `parts` from another process (a server that stops reading blocks the sender, and
  # closing ends it), and reads one response: {status, headers, rest}. The socket is active,
  # so the answer is taken in as it arrives, before a reset of the closed connection.
  defp exchange(port, parts) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
    send_all(socket, parts)
    answer = response(socket)
    # The sender ends when the server stops reading (its close) or when all is sent.
    assert_receive {:sent, sent}, 30_000
    send(self(), {:sent_in_all, sent})
    :gen_tcp.close(socket)
    answer
  end

  # Tells the test how many bytes went out before the server stopped taking them.
  defp send_all(socket, parts) do
    test = self()

    spawn(fn ->
      sent =
        Enum.reduce_while(enumerable(parts), 0, fn part, sent ->
          case :gen_tcp.send(socket, part) do
            :ok -> {:cont, sent + IO.iodata_length(part)}
            _closed -> {:halt, sent}
          end
        end)

      send(test, {:sent, sent})
    end)
  end

  # `[head | stream]`: the head, then the stream's parts.
  defp enumerable([head | rest]) when not is_list(rest), do: Stream.concat([head], rest)
  defp enumerable(parts), do: parts

  defp response(socket, buffer \\ "") do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_, status | _] = String.split(status_line, " ")

        headers =
          Map.new(lines, fn line ->
            [k, v] = String.split(line, ":", parts: 2)
            {String.downcase(k), String.trim(v)}
          end)

        {String.to_integer(status), headers, rest}

      [_] ->
        receive do
          {:tcp, ^socket, data} -> response(socket, buffer <> data)
          {:tcp_closed, ^socket} -> :reset
          {:tcp_error, ^socket, _reason} -> :reset
        after
          10_000 -> flunk("no answer; got #{inspect(buffer)}")
        end
    end
  end

  # The server closes a connection whose body it did not read; with bytes still unread in its
  # socket the close is a reset, which may beat the answer to the client. What the server
  # read is asserted from the server's side either way.
  defp refused(:reset, _status), do: :ok
  defp refused({status, headers, _}, status), do: assert(headers["connection"] == "close")
  defp refused(other, status), do: flunk("expected #{status} or a reset, got #{inspect(other)}")

  describe "a chunked body" do
    test "within the cap is read whole and byte-identical, extensions and trailers dropped" do
      port = serve(:read, @mib)
      body = :crypto.strong_rand_bytes(300_000)

      parts = [
        chunked_head(),
        "1000;name=value\r\n",
        binary_part(body, 0, 4096),
        "\r\n",
        Integer.to_string(byte_size(body) - 4096, 16),
        "\r\n",
        binary_part(body, 4096, byte_size(body) - 4096),
        "\r\n0\r\nx-trailer: yes\r\n\r\n"
      ]

      assert {200, _headers, _} = exchange(port, parts)
      assert_receive {:served, {:ok, 300_000, sha}, true, _}
      assert sha == :crypto.hash(:sha256, body)
    end

    test "of exactly the cap is accepted; one byte more is too large" do
      port = serve(:read, 1000)
      assert {200, _, _} = exchange(port, [chunked_head() | Enum.to_list(chunks(1000, 300))])
      assert_receive {:served, {:ok, 1000, _}, true, _}

      assert {413, %{"connection" => "close"}, _} =
               exchange(port, [chunked_head() | Enum.to_list(chunks(1001, 300))])

      assert_receive {:served, :too_large, false, _}
    end

    test "past the cap is refused after at most the cap plus one socket read (30 MiB sent)" do
      port = serve(:read, @mib)
      refused(exchange(port, [chunked_head() | chunks(30 * @mib, 64 * 1024)]), 413)
      assert_receive {:served, :too_large, false, taken}
      assert taken <= @mib + 1 + @slack, "the server took #{taken} bytes off the socket"
    end

    test "one chunk declared 30 MiB: a stream capped at 3 reads 4 bytes and stops" do
      port = serve(:stream, 3)
      first = IO.iodata_to_binary([chunked_head(), Integer.to_string(30 * @mib, 16), "\r\n"])
      parts = [first | Stream.duplicate(:binary.copy("x", 64 * 1024), 480)]
      refused(exchange(port, parts), 413)
      assert_receive {:served, {:stream, 4, :too_large}, false, taken}
      assert taken <= 4 + @slack, "the server took #{taken} bytes off the socket"
    end

    test "a stream within the cap ends, and gives every byte" do
      port = serve(:stream, 2 * @mib)

      assert {200, headers, _} =
               exchange(port, [chunked_head() | Enum.to_list(chunks(@mib + 17, 10_000))])

      refute Map.has_key?(headers, "connection") and headers["connection"] == "close"
      assert_receive {:served, {:stream, 1_048_593, :ended}, true, _}
    end

    test "the connection serves the next request after one, pipelined in the same send" do
      port = serve(:read, @mib)
      one = IO.iodata_to_binary([chunked_head() | Enum.to_list(chunks(5000, 777))])
      {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: true])
      :ok = :gen_tcp.send(socket, one <> one)
      assert {200, _, rest} = response(socket)
      assert {200, _, _} = response(socket, rest)
      :gen_tcp.close(socket)
      assert_receive {:served, {:ok, 5000, _}, true, _}
      assert_receive {:served, {:ok, 5000, _}, true, _}
    end

    test "with bad framing is invalid" do
      port = serve(:read, @mib)

      for bad <- [
            "zz\r\nab\r\n0\r\n\r\n",
            "2\r\nabXX0\r\n\r\n",
            "1234567890ABCDEF0\r\n",
            String.duplicate("1", 5000)
          ] do
        assert {400, %{"connection" => "close"}, _} = exchange(port, [chunked_head(), bad])
        assert_receive {:served, {:error, :invalid}, false, _}
      end
    end

    test "left unread, the answer says connection: close and Bandit does not drain it" do
      port = serve(:unread, 0)
      small = IO.iodata_to_binary([chunked_head() | Enum.to_list(chunks(100, 10))])
      assert {401, %{"connection" => "close"}, _} = exchange(port, [small])
      assert_receive {:served, :unread, false, _}

      refused(exchange(port, [chunked_head() | chunks(30 * @mib, 64 * 1024)]), 401)
      assert_receive {:served, :unread, false, taken}
      assert taken <= @slack
      # Bandit's keep-alive drain would have taken all 30 MiB before it closed.
      assert_received {:sent_in_all, sent}
      assert sent < 30 * @mib
    end
  end

  describe "a Content-Length body" do
    test "past the cap is too large after at most the cap plus one" do
      port = serve(:read, @mib)
      length = 30 * @mib

      parts = [
        head([{"content-length", length}]) | Stream.duplicate(:binary.copy("x", 64 * 1024), 480)
      ]

      refused(exchange(port, parts), 413)
      assert_receive {:served, :too_large, false, taken}
      assert taken <= @mib + 1 + @slack
    end

    test "within the cap is read whole" do
      port = serve(:read, @mib)
      assert {200, _, _} = exchange(port, [head([{"content-length", 3}]), "abc"])
      assert_receive {:served, {:ok, 3, _}, true, _}
    end
  end

  describe "other adapters (Plug.Test)" do
    test "the count is ours; a transfer encoding cannot be bounded and is refused" do
      body = String.duplicate("y", 2000)
      assert {:ok, ^body, _} = AtlasBodyLimit.read(Plug.Test.conn(:put, "/", body), 2000)
      assert {:too_large, _} = AtlasBodyLimit.read(Plug.Test.conn(:put, "/", body), 1999)

      chunked =
        Plug.Test.conn(:put, "/", body)
        |> Plug.Conn.put_req_header("transfer-encoding", "chunked")

      assert {:error, :unsupported_encoding, _} = AtlasBodyLimit.read(chunked, 5000)

      {ref, stream} = AtlasBodyLimit.stream(Plug.Test.conn(:put, "/", body), 10)
      assert stream |> Enum.to_list() |> IO.iodata_to_binary() |> byte_size() == 11
      assert {_conn, :too_large} = AtlasBodyLimit.streamed(ref)
    end
  end
end
