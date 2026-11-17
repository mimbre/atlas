defmodule AtlasBodyLimit do
  @moduledoc """
  A request body read against a byte cap, whatever its transfer encoding.

  `Plug.Conn.read_body/2`'s `length:` is the adapter's to keep, and Bandit 1.10.1 keeps it
  only for a `Content-Length` body: a `Transfer-Encoding: chunked` body is read whole into
  memory in one call, whatever `length:` says. So this module never relies on `length:` for
  the cap. It counts the bytes it read itself and stops one byte past the cap, and on Bandit's
  HTTP/1 it decodes a chunked body from the socket itself, piece by piece:

  - `read/3`: the whole body, at most `limit` bytes: `{:ok, body, conn}`, else
    `{:too_large, conn}` (at most `limit + 1` bytes were read) or
    `{:error, reason, conn}` (`:invalid` chunked framing, `:unsupported_encoding`, or the
    socket's `:timeout`, `:closed`, …).
  - `stream/3` and `streamed/1`: the body as a lazy stream of its pieces, read only as it
    is enumerated, in the calling process, at most `limit + 1` bytes in all; then the conn
    of the last read and how the body ended: `:ended`, `:open` (not read to its end),
    `:too_large` (past `limit`) or `{:error, reason}`.
  - `next/3`: one piece of at most `max` bytes, the building block of both.
  - `guard/1`: a `before_send` hook. An HTTP/1 response sent while its request body is
    still unread says `connection: close`, so Bandit does not drain the body after the
    response (its keep-alive drain would read a chunked body whole, again unbounded).
  - `ended?/1`: whether the request's body was read to its end (or there is none).

  Options: `read_length` (the most bytes taken from the socket at once, 1 MiB) and
  `read_timeout` (ms per socket read, 60 s).

  Bytes read never exceed the cap plus one: each piece asks for at most what is left of
  `limit + 1`. A chunk-size line or the trailers are read with the socket's available
  bytes (one socket read) and are refused past 4 KiB and 8 KiB. Adapters other than
  Bandit's HTTP/1 (Bandit's HTTP/2, `Plug.Test`) keep `length:` for each call: the count is
  still ours; a request on one of them that names a transfer encoding is refused
  (`:unsupported_encoding`), as no bound can be known for it.
  """

  import Plug.Conn, only: [get_req_header: 2, put_private: 3, register_before_send: 2]

  @key :atlas_body_limit
  @guard :atlas_body_limit_guard
  @read_length 1_048_576
  @read_timeout 60_000
  @max_line 4_096
  @max_trailers 8_192

  @type reason :: :invalid | :unsupported_encoding | :not_owner | term()

  @doc "The whole body, read to at most `limit` bytes (`limit + 1` read when it is longer)."
  @spec read(Plug.Conn.t(), non_neg_integer(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:too_large, Plug.Conn.t()}
          | {:error, reason(), Plug.Conn.t()}
  def read(conn, limit, opts \\ []) when is_integer(limit) and limit >= 0,
    do: read(conn, limit, opts, 0, [])

  defp read(conn, limit, opts, count, acc) do
    case next(conn, limit + 1 - count, opts) do
      {status, data, conn} when status in [:ok, :more] ->
        count = count + byte_size(data)

        cond do
          count > limit -> {:too_large, conn}
          status == :ok -> {:ok, IO.iodata_to_binary(Enum.reverse([data | acc])), conn}
          true -> read(conn, limit, opts, count, [data | acc])
        end

      {:error, reason, conn} ->
        {:error, reason, conn}
    end
  end

  @doc """
  The body as a lazy stream of its pieces, at most `limit + 1` bytes in all, read only as it
  is enumerated and only in this process. `streamed/1` gives back the conn and the ending.
  """
  @spec stream(Plug.Conn.t(), non_neg_integer(), keyword()) :: {reference(), Enumerable.t()}
  def stream(conn, limit, opts \\ []) when is_integer(limit) and limit >= 0 do
    ref = make_ref()
    owner = self()

    Process.put(
      {__MODULE__, ref},
      %{conn: conn, read: 0, limit: limit, state: :open, opts: opts}
    )

    {ref, Stream.resource(fn -> ref end, &piece(&1, owner), fn ref -> ref end)}
  end

  @doc "The conn of `stream/3`'s last read, and how its body ended."
  @spec streamed(reference()) ::
          {Plug.Conn.t(), :ended | :open | :too_large | {:error, reason()}}
  def streamed(ref) do
    %{conn: conn, state: state} = Process.delete({__MODULE__, ref})
    {conn, state}
  end

  defp piece(ref, owner) when owner == self() do
    case Process.get({__MODULE__, ref}) do
      %{state: :open, conn: conn, read: read, limit: limit, opts: opts} = body ->
        case next(conn, limit + 1 - read, opts) do
          {status, data, conn} when status in [:ok, :more] ->
            read = read + byte_size(data)

            state =
              cond do
                read > limit -> :too_large
                status == :ok -> :ended
                true -> :open
              end

            Process.put({__MODULE__, ref}, %{body | conn: conn, read: read, state: state})
            {if(data == "", do: [], else: [data]), ref}

          {:error, reason, conn} ->
            Process.put({__MODULE__, ref}, %{body | conn: conn, state: {:error, reason}})
            {:halt, ref}
        end

      _ended ->
        {:halt, ref}
    end
  end

  defp piece(ref, _other), do: {:halt, ref}

  @doc """
  One piece of the body, at most `max` (≥ 1) bytes: `{:ok, data, conn}` when the body
  ended with it, `{:more, data, conn}`, or `{:error, reason, conn}`.
  """
  @spec next(Plug.Conn.t(), pos_integer(), keyword()) ::
          {:ok | :more, binary(), Plug.Conn.t()} | {:error, reason(), Plug.Conn.t()}
  def next(conn, max, opts \\ [])

  def next(
        %Plug.Conn{
          adapter:
            {Bandit.Adapter,
             %Bandit.Adapter{transport: %Bandit.HTTP1.Socket{} = socket} = adapter}
        } = conn,
        max,
        opts
      )
      when is_integer(max) and max > 0 do
    cond do
      adapter.owner_pid != self() ->
        {:error, :not_owner, conn}

      socket.read_state == :read ->
        {:ok, "", conn}

      socket.body_encoding == "chunked" ->
        chunked(conn, adapter, socket, max, opts)

      socket.body_encoding != nil ->
        {:error, :unsupported_encoding, conn}

      true ->
        read_body(conn, max, opts)
    end
  end

  def next(%Plug.Conn{} = conn, max, opts) when is_integer(max) and max > 0 do
    if get_req_header(conn, "transfer-encoding") == [],
      do: read_body(conn, max, opts),
      else: {:error, :unsupported_encoding, conn}
  end

  # A Content-Length body (or another adapter): `length:` bounds one call; the count is ours.
  defp read_body(conn, max, opts) do
    case Plug.Conn.read_body(conn,
           length: max,
           read_length: min(max, read_length(opts)),
           read_timeout: read_timeout(opts)
         ) do
      {:ok, data, conn} -> {:ok, data, put_private(conn, @key, :ended)}
      {:more, data, conn} -> {:more, data, conn}
      {:error, reason} -> {:error, reason, conn}
    end
  end

  ## A chunked body on Bandit's HTTP/1, decoded here (RFC 9112 §7.1)

  defp chunked(conn, adapter, socket, max, opts) do
    phase = Map.get(conn.private, @key, :size)
    buffer = IO.iodata_to_binary(socket.buffer)
    want = min(max, read_length(opts))

    case decode(phase, buffer, socket.socket, want, read_timeout(opts)) do
      {:data, data, buffer, phase} ->
        {:more, data, put(conn, adapter, %{socket | buffer: buffer}, phase)}

      {:done, buffer} ->
        {:ok, "", put(conn, adapter, %{socket | buffer: buffer, read_state: :read}, :ended)}

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp put(conn, adapter, socket, phase),
    do:
      put_private(
        %{conn | adapter: {Bandit.Adapter, %{adapter | transport: socket}}},
        @key,
        phase
      )

  # A chunk-size line: hex digits, optional extensions after `;`.
  defp decode(:size, buffer, socket, want, timeout) do
    case :binary.split(buffer, "\r\n") do
      [line, rest] ->
        case chunk_size(line) do
          {:ok, 0} -> decode({:trailers, 0}, rest, socket, want, timeout)
          {:ok, size} -> decode({:data, size}, rest, socket, want, timeout)
          :error -> {:error, :invalid}
        end

      [_partial] when byte_size(buffer) > @max_line ->
        {:error, :invalid}

      [_partial] ->
        more(:size, buffer, socket, 0, want, timeout)
    end
  end

  # Chunk data: never more than `want`, and never more than is left of this chunk.
  defp decode({:data, left}, "", socket, want, timeout),
    do: more({:data, left}, "", socket, min(left, want), want, timeout)

  defp decode({:data, left}, buffer, _socket, want, _timeout) do
    take = Enum.min([left, want, byte_size(buffer)])
    <<data::binary-size(take), rest::binary>> = buffer
    left = left - take
    {:data, data, rest, if(left == 0, do: :crlf, else: {:data, left})}
  end

  defp decode(:crlf, "\r\n" <> rest, socket, want, timeout),
    do: decode(:size, rest, socket, want, timeout)

  defp decode(:crlf, buffer, socket, want, timeout) when byte_size(buffer) < 2 do
    if String.starts_with?("\r\n", buffer),
      do: more(:crlf, buffer, socket, 0, want, timeout),
      else: {:error, :invalid}
  end

  defp decode(:crlf, _buffer, _socket, _want, _timeout), do: {:error, :invalid}

  # Trailer fields are read and dropped, up to an empty line.
  defp decode({:trailers, seen}, buffer, socket, want, timeout) do
    case :binary.split(buffer, "\r\n") do
      ["", rest] ->
        {:done, rest}

      [line, rest] when seen + byte_size(line) + 2 <= @max_trailers ->
        decode({:trailers, seen + byte_size(line) + 2}, rest, socket, want, timeout)

      [_line, _rest] ->
        {:error, :invalid}

      [_partial] when seen + byte_size(buffer) > @max_trailers ->
        {:error, :invalid}

      [_partial] ->
        more({:trailers, seen}, buffer, socket, 0, want, timeout)
    end
  end

  defp more(phase, buffer, socket, length, want, timeout) do
    case ThousandIsland.Socket.recv(socket, length, timeout) do
      {:ok, data} -> decode(phase, buffer <> data, socket, want, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunk_size(line) do
    hex = line |> String.split(";", parts: 2) |> hd() |> String.trim_trailing()

    if hex =~ ~r/\A[0-9A-Fa-f]{1,15}\z/,
      do: {:ok, String.to_integer(hex, 16)},
      else: :error
  end

  ## Unread bodies

  @doc """
  Registers (once) a `before_send` hook that puts `connection: close` on the response when
  the request's body was not read to its end on Bandit's HTTP/1.
  """
  @spec guard(Plug.Conn.t()) :: Plug.Conn.t()
  def guard(%Plug.Conn{private: %{@guard => true}} = conn), do: conn

  def guard(conn) do
    conn
    |> put_private(@guard, true)
    |> register_before_send(fn conn ->
      if pending?(conn),
        do: Plug.Conn.put_resp_header(conn, "connection", "close"),
        else: conn
    end)
  end

  @doc "Whether the request's body was read to its end, or it has none."
  @spec ended?(Plug.Conn.t()) :: boolean()
  def ended?(%Plug.Conn{private: %{@key => :ended}}), do: true

  def ended?(
        %Plug.Conn{adapter: {Bandit.Adapter, %Bandit.Adapter{transport: %Bandit.HTTP1.Socket{}}}} =
          conn
      ),
      do: not pending?(conn)

  def ended?(%Plug.Conn{}), do: false

  # Bandit HTTP/1: a declared body that is not read to its end.
  defp pending?(%Plug.Conn{
         adapter: {Bandit.Adapter, %Bandit.Adapter{transport: %Bandit.HTTP1.Socket{} = socket}}
       }) do
    socket.read_state != :read and
      (socket.body_encoding != nil or
         (is_integer(socket.unread_content_length) and socket.unread_content_length > 0))
  end

  defp pending?(%Plug.Conn{}), do: false

  defp read_length(opts), do: Keyword.get(opts, :read_length, @read_length)
  defp read_timeout(opts), do: Keyword.get(opts, :read_timeout, @read_timeout)
end
