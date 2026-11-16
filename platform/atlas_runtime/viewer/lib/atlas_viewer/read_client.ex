defmodule AtlasViewer.ReadClient do
  @moduledoc """
  The viewer's only connection to Runtime: two sockets in `<home>`, one request per
  connection. No other path under the home is built, and nothing but these reads is sent.

    * `backend.sock`: HTTP `GET` only. `runtime` is `GET /v1/runtime` (runtime info with
      its slots), `turns` is one page of `GET /v1/turns` (the history contract), `turn` is
      `GET /v1/turns/{turn_id}` and `output` is `GET /v1/turns/{turn_id}/output` (the work
      contract's turn output).
    * `runtime.sock`: `events`, one runtime.read/1 line of the execution-event journal.

  Only these five operations and their fields pass; `api` is always set here. A success
  body or journal reply is passed through unchanged. A refusal from the backend
  (`application/problem+json`) is passed as `{"error": {"code", "status", "message"}}`,
  with its problem type as the code, which is the shape journal refusals already have.
  """
  @api "runtime.read/1"
  @fields %{
    "runtime" => [],
    "turns" => ["cursor", "limit"],
    "turn" => ["turn_id"],
    "output" => ["turn_id", "cursor"],
    "events" => ["cursor", "limit"]
  }
  @required %{"turn" => ["turn_id"], "output" => ["turn_id"]}
  @connect_ms 2_000
  # Runtime's largest reply is a 1 MiB answer, JSON-escaped.
  @reply_bytes 8 * 1_048_576

  @doc "The two sockets the viewer reads, in the Runtime home."
  def sockets(home),
    do: %{backend: Path.join(home, "backend.sock"), journal: Path.join(home, "runtime.sock")}

  @doc """
  The read to make for a browser body, `{:backend, path}` or `{:journal, request}`, or the
  code it is refused with.
  """
  def request(%{"op" => op} = body) when is_map_key(@fields, op) do
    args = Map.delete(body, "op")

    if Map.keys(args) -- @fields[op] == [] and
         Enum.all?(Map.get(@required, op, []), &Map.has_key?(args, &1)) and
         Enum.all?(args, &valid?/1),
       do: {:ok, route(op, args)},
       else: {:error, "invalid_request"}
  end

  def request(_), do: {:error, "not_a_read"}

  defp valid?({"limit", limit}), do: is_integer(limit)
  defp valid?({_field, value}), do: is_binary(value) and value != ""

  defp route("runtime", _args), do: {:backend, "/v1/runtime"}
  defp route("turns", args), do: {:backend, "/v1/turns" <> query(args)}
  defp route("turn", %{"turn_id" => id}), do: {:backend, "/v1/turns/" <> segment(id)}

  defp route("output", %{"turn_id" => id} = args),
    do: {:backend, "/v1/turns/" <> segment(id) <> "/output" <> query(Map.delete(args, "turn_id"))}

  defp route("events", args), do: {:journal, Map.merge(args, %{"api" => @api, "op" => "events"})}

  # A turn ID is one path segment, whatever it holds.
  defp segment(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp query(args) when map_size(args) == 0, do: ""
  defp query(args), do: "?" <> URI.encode_query(Enum.sort(args))

  @doc "The socket a read goes to."
  def socket(sockets, {:backend, _path}), do: sockets.backend
  def socket(sockets, {:journal, _request}), do: sockets.journal

  @doc """
  Make `read` on its socket and return the reply as JSON text, within `timeout`
  milliseconds overall. Errors: `:unreachable`, `:timeout`, `:no_reply`, `:bad_reply`,
  `:too_large`.
  """
  def read(sockets, read, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case :gen_tcp.connect(
           {:local, socket(sockets, read)},
           0,
           [:binary, active: false, packet: :raw],
           min(@connect_ms, timeout)
         ) do
      {:ok, socket} ->
        try do
          case :gen_tcp.send(socket, wire(read)) do
            :ok -> reply(read, socket, deadline)
            {:error, _} -> {:error, :unreachable}
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :unreachable}
    end
  end

  defp wire({:journal, request}), do: JSON.encode!(request) <> "\n"

  # Connection: close, so the reply ends where the connection does.
  defp wire({:backend, path}),
    do:
      "GET #{path} HTTP/1.1\r\nhost: localhost\r\naccept: application/json\r\n" <>
        "connection: close\r\n\r\n"

  defp reply({:journal, _}, socket, deadline) do
    with {:ok, received} <- receive_until(socket, deadline, "", &line_end/1),
         [line | _] = :binary.split(received, "\n"),
         {:ok, reply} when is_map(reply) <- JSON.decode(line) do
      {:ok, line}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :bad_reply}
    end
  end

  defp reply({:backend, _}, socket, deadline) do
    with {:ok, received} <- receive_until(socket, deadline, "", fn _ -> false end) do
      response(received)
    end
  end

  defp line_end(received), do: :binary.match(received, "\n") != :nomatch

  # Receives until done?(received) or the peer closes; a closed connection with nothing
  # received is no reply.
  defp receive_until(socket, deadline, received, done?) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      byte_size(received) > @reply_bytes ->
        {:error, :too_large}

      remaining <= 0 ->
        {:error, :timeout}

      true ->
        case :gen_tcp.recv(socket, 0, remaining) do
          {:ok, data} ->
            received = received <> data

            if done?.(received),
              do: {:ok, received},
              else: receive_until(socket, deadline, received, done?)

          {:error, :closed} when received != "" ->
            {:ok, received}

          {:error, :timeout} ->
            {:error, :timeout}

          {:error, _} ->
            {:error, :no_reply}
        end
    end
  end

  defp response(received) do
    with [head, rest] <- :binary.split(received, "\r\n\r\n"),
         ["HTTP/1." <> <<_, " ", code::binary-size(3), _::binary>> | lines] <-
           String.split(head, "\r\n"),
         {status, ""} <- Integer.parse(code),
         headers = Map.new(lines, &header/1),
         {:ok, body} <- body(headers, rest),
         {:ok, %{} = reply} <- JSON.decode(body) do
      if status in 200..299, do: {:ok, body}, else: refusal(status, reply)
    else
      _ -> {:error, :bad_reply}
    end
  end

  defp header(line) do
    case :binary.split(line, ":") do
      [name, value] -> {String.downcase(name), String.trim(value)}
      [name] -> {String.downcase(name), ""}
    end
  end

  defp body(%{"transfer-encoding" => "chunked"}, rest), do: dechunk(rest, "")

  defp body(%{"content-length" => length}, rest) do
    case Integer.parse(length) do
      {n, ""} when byte_size(rest) >= n -> {:ok, binary_part(rest, 0, n)}
      _ -> :error
    end
  end

  defp body(_headers, rest), do: {:ok, rest}

  defp dechunk(data, body) do
    with [size, rest] <- :binary.split(data, "\r\n"),
         {n, _extension} <- Integer.parse(size |> String.split(";") |> hd(), 16) do
      cond do
        n == 0 ->
          {:ok, body}

        byte_size(rest) >= n + 2 ->
          dechunk(
            binary_part(rest, n + 2, byte_size(rest) - n - 2),
            body <> binary_part(rest, 0, n)
          )

        true ->
          :error
      end
    else
      _ -> :error
    end
  end

  defp refusal(status, %{"type" => type} = problem) when is_binary(type) do
    message = problem["detail"] || problem["reason"] || problem["title"] || "HTTP #{status}"

    {:ok,
     JSON.encode!(%{
       "error" => %{"code" => type, "status" => status, "message" => to_string(message)}
     })}
  end

  defp refusal(_status, _reply), do: {:error, :bad_reply}
end
