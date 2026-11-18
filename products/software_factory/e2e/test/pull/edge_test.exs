Code.require_file("support.exs", __DIR__)

defmodule AtlasE2E.Pull.EdgeTest do
  @moduledoc """
  The pull-e2e's TLS edge (`AtlasE2E.Pull.Edge`) against a plain-HTTP stand-in for Flow's
  listener: the tap records every exchange, failed ones too, and the faults do what S3 and
  S5 rely on. Structure only: routes, statuses, byte counts, `upstream` tags.
  """
  use ExUnit.Case, async: true

  alias AtlasE2E.Pull.{Await, Edge, Fixture, Hub}
  alias AtlasE2E.Pull.Edge.Chunked
  alias AtlasE2E.PullTest.Support

  setup do
    hub = Support.hub!()
    tls = Fixture.tls()
    test = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, upstream_port} = :inet.port(listen)
    upstream = spawn_link(fn -> upstream(listen, test) end)
    {:ok, edge} = Edge.start_link(upstream: {{127, 0, 0, 1}, upstream_port}, tls: tls, hub: hub)

    %{
      hub: hub,
      tls: tls,
      edge: edge,
      port: Edge.port(edge),
      upstream: upstream,
      upstream_port: upstream_port
    }
  end

  # The stand-in: per connection, reads the request (head and body, Content-Length or
  # chunked), tells the test, and answers as the test said (`{:mode, mode}`).
  defp upstream(listen, test) do
    {:ok, socket} = :gen_tcp.accept(listen)
    send(test, {:upstream_conn, self()})

    case read_request(socket, "") do
      {:ok, head, body} ->
        send(test, {:upstream_request, head, body})

        receive do
          {:answer, :close} ->
            :gen_tcp.close(socket)

          {:answer, status, json} ->
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\n\r\n" <>
                json
            )

            :gen_tcp.close(socket)
        end

      _ ->
        :gen_tcp.close(socket)
    end

    upstream(listen, test)
  end

  defp read_request(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, rest] ->
        request = Edge.parse_request(head)

        if request.chunked?,
          do: read_chunked(socket, head, Chunked.new(), rest, rest),
          else: read_length(socket, head, request.length || 0, rest)

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0)
        read_request(socket, acc <> more)
    end
  end

  defp read_length(_socket, head, n, body) when byte_size(body) >= n, do: {:ok, head, body}

  defp read_length(socket, head, n, body) do
    {:ok, more} = :gen_tcp.recv(socket, 0)
    read_length(socket, head, n, body <> more)
  end

  defp read_chunked(socket, head, decoder, data, all) do
    {decoder, _} = Chunked.feed(decoder, data)

    if Chunked.done?(decoder) do
      {:ok, head, Chunked.decode_all(all)}
    else
      {:ok, more} = :gen_tcp.recv(socket, 0)
      read_chunked(socket, head, decoder, more, all <> more)
    end
  end

  defp connect(c) do
    :ssl.connect(
      ~c"localhost",
      c.port,
      [
        :binary,
        active: false,
        versions: [:"tlsv1.3"],
        verify: :verify_peer,
        cacerts: c.tls.cacerts,
        server_name_indication: ~c"localhost",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      10_000
    )
  end

  defp read_all(socket, acc \\ "") do
    case :ssl.recv(socket, 0) do
      {:ok, data} -> read_all(socket, acc <> data)
      {:error, _} -> acc
    end
  end

  defp wire(c, match), do: Await.event(0, &(&1.source == :wire and match.(&1.data)), hub: c.hub)

  test "a chunked body is recorded as chunked with its byte count, and reaches upstream whole",
       c do
    {:ok, s} = connect(c)
    parts = [:binary.copy("a", 1_000), :binary.copy("b", 70_000), "cdefg"]
    sha = String.duplicate("0", 64)

    :ok =
      :ssl.send(
        s,
        "PUT /v1/leases/L1/blobs/#{sha} HTTP/1.1\r\nhost: localhost\r\ntransfer-encoding: chunked\r\nblob-size: 71005\r\n\r\n"
      )

    for part <- parts,
        do: :ok = :ssl.send(s, Integer.to_string(byte_size(part), 16) <> "\r\n" <> part <> "\r\n")

    :ok = :ssl.send(s, "0\r\n\r\n")

    assert_receive {:upstream_conn, up}
    assert_receive {:upstream_request, head, body}
    refute head =~ ~r/content-length/i
    assert body == IO.iodata_to_binary(parts)
    send(up, {:answer, 200, "{}"})
    assert read_all(s) =~ "HTTP/1.1 200"

    record = wire(c, &(&1.route == :put_blob)).data

    assert %{
             lease_id: "L1",
             sha256: ^sha,
             chunked?: true,
             bytes_in: 71_005,
             status: 200,
             upstream: :ok
           } = record
  end

  test "an upstream reset still yields one record, upstream: :closed", c do
    {:ok, s} = connect(c)
    json = ~s({"runtime_id":"m"})

    :ok =
      :ssl.send(
        s,
        "POST /v1/poll HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\n\r\n" <>
          json
      )

    assert_receive {:upstream_conn, up}
    assert_receive {:upstream_request, _, ^json}
    send(up, {:answer, :close})
    assert read_all(s) == ""

    record = wire(c, &(&1.route == :poll)).data
    assert %{status: nil, upstream: :closed, req: %{"runtime_id" => "m"}} = record
    assert length(Hub.select(0, &(&1.source == :wire), c.hub)) == 1
  end

  test "refuse closes before the handshake and reaches nothing upstream", c do
    :ok = Edge.mode(c.edge, :refuse)
    assert {:error, _} = connect(c)
    wire(c, &(&1.upstream == :edge_refused))
    refute_received {:upstream_conn, _}
  end

  test "held reaches upstream only on release; others are refused while it holds", c do
    :ok = Edge.mode(c.edge, {:hold, &(&1.route == :report and &1.lease_id == "Lb"), :refuse})
    {:ok, s} = connect(c)
    json = ~s({"revision":3,"report":{"state":"ended"}})

    :ok =
      :ssl.send(
        s,
        "POST /v1/leases/Lb/reports HTTP/1.1\r\nhost: localhost\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\n\r\n" <>
          json
      )

    held = wire(c, &(&1.upstream == :held)).data

    assert %{
             route: :report,
             lease_id: "Lb",
             req: %{"report" => %{"state" => "ended"}},
             status: nil
           } = held

    refute_received {:upstream_conn, _}

    # A request the hold does not match is refused meanwhile (a fresh connection).
    {:ok, other} = connect(c)

    :ok =
      :ssl.send(other, "POST /v1/poll HTTP/1.1\r\nhost: localhost\r\ncontent-length: 2\r\n\r\n{}")

    wire(c, &(&1.upstream == :edge_refused and &1.route == :poll))

    assert Edge.release(c.edge) == 1
    assert_receive {:upstream_conn, up}
    assert_receive {:upstream_request, _, ^json}
    send(up, {:answer, 410, ~s({"type":"lease-lost"})})
    assert read_all(s) =~ "HTTP/1.1 410"
    released = wire(c, &(&1.upstream == :released)).data
    assert %{status: 410, type: "lease-lost", lease_id: "Lb"} = released
  end

  test "Flow down: an upstream connect refused is answered 502", c do
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(closed)
    :gen_tcp.close(closed)
    {:ok, edge} = Edge.start_link(upstream: {{127, 0, 0, 1}, port}, tls: c.tls, hub: c.hub)
    {:ok, s} = connect(%{c | port: Edge.port(edge)})
    :ok = :ssl.send(s, "POST /v1/poll HTTP/1.1\r\nhost: localhost\r\ncontent-length: 2\r\n\r\n{}")
    assert read_all(s) =~ "HTTP/1.1 502"
    assert %{status: 502, upstream: :refused, route: :poll} = wire(c, &(&1.route == :poll)).data
  end

  test "the chunked reader counts the payload however the bytes are split" do
    body = "4\r\nabcd\r\n10\r\n" <> :binary.copy("x", 16) <> "\r\n0\r\n\r\n"

    for split <- 1..byte_size(body) do
      <<first::binary-size(split), rest::binary>> = body
      {d, _} = Chunked.feed(Chunked.new(), first)
      {d, _} = Chunked.feed(d, rest)
      assert Chunked.done?(d) and Chunked.payload_bytes(d) == 20, "split at #{split}"
    end

    assert Chunked.decode_all(body) == "abcd" <> :binary.copy("x", 16)
  end
end
