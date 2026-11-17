defmodule AtlasRuntimeBackend.Generator.Targets.RestStreamTest do
  # Not async: the memory test reads the VM's binary memory, which other tests would move.
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias AtlasRuntimeBackend.Generator.Example.{Bytes, Rest, SinkAdapter}

  @member {"ann", [:lend, :browse]}
  @mib 1_048_576

  setup do
    on_exit(fn -> Process.delete(:example_scan) end)
  end

  defp scan(path, client \\ @member) do
    conn("GET", path) |> assign(:client, client) |> Rest.call(Rest.init([]))
  end

  # Through the SinkAdapter: `sink` sees each part of the answer; nothing is kept.
  defp scan_into(path, sink, client \\ @member) do
    SinkAdapter.conn("GET", path, sink) |> assign(:client, client) |> Rest.call(Rest.init([]))
  end

  describe "an outcome sent as bytes (stream:)" do
    test "200, chunked, the declared content type and headers, the stream's bytes and no JSON" do
      Process.put(:example_scan, ["%PDF-1.7\n", <<0, 1, 2, 255>>, "", "end"])
      conn = scan("/v1/books/b1/scan")

      assert conn.status == 200
      assert conn.state == :chunked
      assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
      assert conn.resp_body == "%PDF-1.7\n" <> <<0, 1, 2, 255>> <> "end"
      assert get_resp_header(conn, "scan-pages") == ["2"]
      assert get_resp_header(conn, "scan-of") == ["/v1/books/b1"]
      # An optional field without a value has no header.
      assert get_resp_header(conn, "scanned-at") == []

      assert %{"scanned-at" => ["2026-03-01T10:00:00Z"]} =
               scan("/v1/books/dated/scan").resp_headers
               |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    end

    test "one chunk per element, in order, sent as each element is read" do
      bytes = Bytes.new(10, 3)
      Process.put(:example_scan, bytes.stream)
      parent = self()

      sink = fn
        {:chunk, body} ->
          send(parent, {:chunk, body, Bytes.made(bytes)})
          :ok

        other ->
          send(parent, other)
          :ok
      end

      scan_into("/v1/books/b1/scan", sink)

      assert_received {:head, 200, _headers}
      # Each chunk went out before the next element was made.
      for {n, size} <- [{1, 3}, {2, 3}, {3, 3}, {4, 1}] do
        assert_received {:chunk, body, ^n}
        assert byte_size(body) == size
      end

      refute_received {:chunk, _, _}
      assert_received {:bytes_closed, _}
    end

    test "5 MiB from a lazy stream arrive byte-identical, never held whole (m1)" do
      size = 5 * @mib
      chunk = 64 * 1024
      bytes = Bytes.new(size, chunk)
      Process.put(:example_scan, bytes.stream)
      :erlang.garbage_collect()
      before = :erlang.memory(:binary)
      parent = self()

      sink = fn
        {:chunk, body} ->
          # Chunks made but not yet sent: at most this one.
          in_flight = Bytes.made(bytes) - Process.get(:sent, 0)
          Process.put(:sent, Process.get(:sent, 0) + 1)
          Process.put(:in_flight, max(Process.get(:in_flight, 0), in_flight))
          Process.put(:hash, :crypto.hash_update(Process.get(:hash), body))
          Process.put(:bytes, Process.get(:bytes) + byte_size(body))
          peak = :erlang.memory(:binary) - before
          Process.put(:peak, max(Process.get(:peak, 0), peak))
          :ok

        {:head, 200, _headers} ->
          :ok

        other ->
          send(parent, other)
          :ok
      end

      Process.put(:hash, :crypto.hash_init(:sha256))
      Process.put(:bytes, 0)
      conn = scan_into("/v1/books/b1/scan", sink)

      refute_received {:whole, _, _, _}
      assert conn.state == :chunked
      assert Process.get(:bytes) == size
      assert :crypto.hash_final(Process.get(:hash)) == Bytes.sha256(size, chunk)
      assert Process.get(:sent) == div(size, chunk)
      assert Process.get(:in_flight) == 1
      assert Process.get(:peak) < 2 * @mib, "binary memory grew by #{Process.get(:peak)} bytes"
    end

    test "a client gone mid-stream: the enumeration halts, and the stream's after runs (m2)" do
      bytes = Bytes.new(100, 10)
      Process.put(:example_scan, bytes.stream)

      sink = fn
        {:chunk, _body} ->
          sent = Process.get(:sent, 0) + 1
          Process.put(:sent, sent)
          if sent >= 3, do: :closed, else: :ok

        _other ->
          :ok
      end

      conn = scan_into("/v1/books/b1/scan", sink)

      assert conn.state == :chunked
      assert_received {:bytes_closed, _}
      assert Bytes.closed(bytes) == 1
      # Nothing was read after the chunk that could not be sent.
      assert Bytes.made(bytes) == 3
      assert Process.get(:sent) == 3
    end

    test "an element that raises is not caught: the answer never ends as complete" do
      Process.put(
        :example_scan,
        Stream.resource(
          fn -> 0 end,
          fn
            0 -> {["first"], 1}
            1 -> raise "the file is gone"
          end,
          fn _ -> send(self(), :after_ran) end
        )
      )

      assert_raise RuntimeError, "the file is gone", fn -> scan("/v1/books/b1/scan") end
      assert_received :after_ran
    end

    test "a refusal before the stream is problem+json, and the stream is never read" do
      bytes = Bytes.new(10, 5)
      Process.put(:example_scan, bytes.stream)

      conn = scan("/v1/books/missing/scan")
      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["application/problem+json"]
      assert %{"type" => "not-found", "status" => 404} = JSON.decode!(conn.resp_body)

      conn = scan("/v1/books/b1/scan", {"guest", []})
      assert conn.status == 403

      assert %{"type" => "not-permitted", "detail" => "this needs the right browse"} =
               JSON.decode!(conn.resp_body)

      assert Bytes.made(bytes) == 0
      refute_received {:bytes_closed, _}
    end

    test "__routes__/0 carries the stream field and the content type" do
      route = Enum.find(Rest.__routes__(), &(&1.capability == :scan))

      assert %{method: :get, path: "/v1/books/:book_id/scan", stream: false} = route

      assert %{status: 200, stream: :content, content_type: "application/octet-stream"} =
               Enum.find(route.outcomes, &(&1.outcome == :scanned))
    end
  end
end
