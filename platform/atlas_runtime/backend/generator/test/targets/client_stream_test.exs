defmodule AtlasRuntimeBackend.Generator.Targets.ClientStreamTest do
  # Not async: the memory test reads the VM's binary memory, which other tests would move.
  use ExUnit.Case, async: false

  alias AtlasRuntimeBackend.Generator.Example.{Api, Bytes, Client, StreamClient}
  alias AtlasRuntimeBackend.Generator.Targets.Client.StreamError

  @mib 1_048_576

  setup do
    on_exit(fn -> Process.delete(:example_scan) end)
  end

  defp sent do
    assert_received {:transport, request}
    request
  end

  describe "an outcome sent as bytes, through the generated router (Plug.Test)" do
    test "{name, fields}: the content as a stream, and the fields its headers carry" do
      Process.put(:example_scan, ["page 1\n", <<0, 255>>])

      assert {:scanned, %{content: content, pages: 2, scanned_at: nil} = fields} =
               Client.scan(%{book_id: "b1"})

      # Only what is on the wire: the stream and the header fields, not book_id.
      assert Map.keys(fields) |> Enum.sort() == [:content, :pages, :scanned_at]
      assert Enum.join(content) == "page 1\n" <> <<0, 255>>

      request = sent()
      assert %{method: "GET", path: "/v1/books/b1/scan", body: nil} = request
      assert {"accept", "application/octet-stream, application/json"} in request.headers

      assert {:scanned, %{scanned_at: ~U[2026-03-01 10:00:00Z]}} =
               Client.scan(%{book_id: "dated"})
    end

    test "other outcomes and errors decode as for any resource" do
      assert Client.scan(%{book_id: "missing"}) == :missing

      assert Client.scan(%{book_id: "b1"}, transport: [client: {"guest", []}]) ==
               {:error, :not_permitted}

      assert Client.scan(%{book_id: "b1"}, transport: [fail: :econnrefused]) ==
               {:error, :unreachable}

      assert Client.scan(%{}) == {:error, {:invalid, ["book_id is required"]}}
    end

    test "a transport failure before the end raises from the enumeration" do
      assert {:scanned, %{content: content}} =
               Client.scan(%{book_id: "b1"}, transport: [fail_after: true])

      error = assert_raise StreamError, fn -> Enum.to_list(content) end
      assert %StreamError{capability: :scan, reason: :unreachable} = error
      assert Exception.message(error) =~ "the download broke off before its end"
    end

    test "a content type other than the declared one, or a header that does not decode" do
      headers = [{"content-type", "application/octet-stream"}, {"scan-of", "/v1/books/b1"}]

      assert {:error, {:invalid_response, ["scanned: content-type \"text/html\" is not " <> _]}} =
               Client.scan(%{book_id: "b1"},
                 transport: [respond: {200, "<html>", [{"content-type", "text/html"}]}]
               )

      assert {:error, {:invalid_response, ["scanned: header scan-pages (pages) is missing"]}} =
               Client.scan(%{book_id: "b1"}, transport: [respond: {200, "x", headers}])

      assert {:error,
              {:invalid_response, ["scanned: header scan-pages (pages) is invalid: \"two\""]}} =
               Client.scan(%{book_id: "b1"},
                 transport: [respond: {200, "x", [{"scan-pages", "two"} | headers]}]
               )

      # Parameters of the media type do not matter.
      assert {:scanned, %{pages: 2, content: content}} =
               Client.scan(%{book_id: "b1"},
                 transport: [
                   respond:
                     {200, "bytes",
                      [{"content-type", "application/octet-stream; q=1"}, {"scan-pages", "2"}]}
                 ]
               )

      assert Enum.join(content) == "bytes"
    end
  end

  describe "a round trip that streams end to end (StreamTransport)" do
    test "5 MiB from a lazy stream arrive byte-identical, one chunk in flight, memory bounded" do
      size = 5 * @mib
      chunk = 64 * 1024
      bytes = Bytes.new(size, chunk)
      :erlang.garbage_collect()
      before = :erlang.memory(:binary)

      assert {:scanned, %{content: content, pages: 2}} =
               StreamClient.scan(%{book_id: "b1"}, transport: [scan: bytes.stream])

      # Nothing is read before the caller reads it.
      assert Bytes.made(bytes) <= 1

      {hash, count, in_flight, peak} =
        Enum.reduce(content, {:crypto.hash_init(:sha256), 0, 0, 0}, fn body,
                                                                       {hash, n, in_flight, peak} ->
          {:crypto.hash_update(hash, body), n + byte_size(body),
           max(in_flight, Bytes.made(bytes) - div(n, chunk)),
           max(peak, :erlang.memory(:binary) - before)}
        end)

      assert count == size
      assert :crypto.hash_final(hash) == Bytes.sha256(size, chunk)
      assert in_flight <= 2
      assert peak < 2 * @mib, "binary memory grew by #{peak} bytes"
      assert_receive {:bytes_closed, _}
    end

    test "a caller that stops reading ends the request, and the server's stream closes" do
      bytes = Bytes.new(10 * 64 * 1024, 64 * 1024)

      assert {:scanned, %{content: content}} =
               StreamClient.scan(%{book_id: "b1"}, transport: [scan: bytes.stream])

      assert [_, _] = Enum.take(content, 2)
      assert_receive {:bytes_closed, _}
      assert Bytes.closed(bytes) == 1
      assert Bytes.made(bytes) <= 3
    end

    test "a server that dies mid-stream: the read raises" do
      bytes = Bytes.new(10 * 1024, 1024)

      assert {:scanned, %{content: content}} =
               StreamClient.scan(%{book_id: "b1"},
                 transport: [scan: bytes.stream, cut_after: 3]
               )

      assert_raise StreamError, fn -> Enum.to_list(content) end
    end

    test "an answer that is not the stream comes whole" do
      assert StreamClient.scan(%{book_id: "missing"}) == :missing
    end
  end

  describe "at compile time" do
    test "a transport without stream/2, for a contract with an outcome sent as bytes" do
      assert_raise CompileError, ~r/has no stream\/2/, fn ->
        Code.compile_string("""
        defmodule AtlasRuntimeBackend.Generator.Targets.ClientStreamTest.C1 do
          use AtlasRuntimeBackend.Generator.Targets.Client,
            contract: #{inspect(__MODULE__.OnlyScan)},
            transport: #{inspect(__MODULE__.RequestOnly)}
        end
        """)
      end
    end
  end

  defmodule OnlyScan do
    # The example's schema without its event stream: only the download needs stream/2.
    def __schema__ do
      schema = Api.__schema__()

      %{
        schema
        | exposed: schema.exposed -- [:watch],
          targets: for(t <- schema.targets, do: %{t | streams: []})
      }
    end
  end

  defmodule RequestOnly do
    def request(_request, _opts), do: {:error, :none}
  end
end
