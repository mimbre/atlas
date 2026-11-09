defmodule AtlasViewer.ReadClient do
  @moduledoc """
  The viewer's only connection to Runtime: one runtime.read/1 request per connection to
  `<home>/read.sock` (docs/contracts/runtime-read.md). No other path under the home is
  built, so `runtime.sock` and Runtime's files are never opened.

  Only the five read operations and their fields pass; `api` is always set here. Field
  values, cursors and replies keep Runtime's meaning and are passed through unchanged.
  """
  @api "runtime.read/1"
  @fields %{
    "workers" => [],
    "turns" => [],
    "turn" => ["turn_id"],
    "events" => ["cursor", "limit"],
    "output" => ["turn_id", "cursor"]
  }
  @connect_ms 2_000
  # Runtime's largest reply is a 1 MiB answer, JSON-escaped.
  @reply_bytes 8 * 1_048_576

  def socket(home), do: Path.join(home, "read.sock")

  @doc "The request to send for a browser body, or the code it is refused with."
  def request(%{"op" => op} = body) when is_map_key(@fields, op) do
    args = Map.delete(body, "op")

    if Map.keys(args) -- @fields[op] == [],
      do: {:ok, Map.merge(args, %{"api" => @api, "op" => op})},
      else: {:error, "invalid_request"}
  end

  def request(_), do: {:error, "not_a_read"}

  @doc """
  Send `request` to the socket at `path` and return Runtime's reply line, within `timeout`
  milliseconds overall. Errors: `:unreachable`, `:timeout`, `:no_reply`, `:bad_reply`,
  `:too_large`.
  """
  def read(path, request, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    case :gen_tcp.connect(
           {:local, path},
           0,
           [:binary, active: false, packet: :raw],
           min(@connect_ms, timeout)
         ) do
      {:ok, socket} ->
        try do
          case :gen_tcp.send(socket, JSON.encode!(request) <> "\n") do
            :ok -> socket |> receive_reply(deadline, "") |> decoded()
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

  defp receive_reply(socket, deadline, received) do
    remaining = deadline - System.monotonic_time(:millisecond)

    with true <- remaining > 0 || {:error, :timeout},
         {:ok, data} <- :gen_tcp.recv(socket, 0, remaining) do
      received = received <> data

      case :binary.match(received, "\n") do
        {at, _} -> {:ok, binary_part(received, 0, at)}
        :nomatch when byte_size(received) > @reply_bytes -> {:error, :too_large}
        :nomatch -> receive_reply(socket, deadline, received)
      end
    else
      {:error, :timeout} -> {:error, :timeout}
      {:error, _} -> {:error, :no_reply}
    end
  end

  defp decoded({:ok, line}) do
    case JSON.decode(line) do
      {:ok, reply} when is_map(reply) -> {:ok, line}
      _ -> {:error, :bad_reply}
    end
  end

  defp decoded(error), do: error
end
