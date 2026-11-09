defmodule AtlasRuntime.Backend.TestSocket do
  @moduledoc false
  # A raw HTTP/1.1 client on a Unix socket, for the event stream (Server-Sent Events).

  def home do
    dir = Path.join(System.tmp_dir!(), "abk-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  def open(path, request_path, headers \\ []) do
    {:ok, socket} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false], 2_000)
    lines = for {k, v} <- headers, do: "#{k}: #{v}\r\n"

    :ok =
      :gen_tcp.send(socket, [
        "GET ",
        request_path,
        " HTTP/1.1\r\nhost: localhost\r\n",
        lines,
        "\r\n"
      ])

    {socket, ""}
  end

  @doc "Read until `pattern` is in what was received; returns the new state and what came."
  def await({socket, seen}, pattern, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await(socket, seen, pattern, deadline)
  end

  defp await(socket, seen, pattern, deadline) do
    if String.contains?(seen, pattern) do
      {{socket, seen}, seen}
    else
      left = deadline - System.monotonic_time(:millisecond)

      if left <= 0 do
        raise ExUnit.AssertionError, message: "#{inspect(pattern)} not received; got:\n#{seen}"
      end

      case :gen_tcp.recv(socket, 0, left) do
        {:ok, data} ->
          await(socket, seen <> data, pattern, deadline)

        {:error, reason} ->
          raise ExUnit.AssertionError, message: "socket #{reason}; got:\n#{seen}"
      end
    end
  end

  @doc "What arrives within `ms` more."
  def drain({socket, seen}, ms) do
    case :gen_tcp.recv(socket, 0, ms) do
      {:ok, data} -> drain({socket, seen <> data}, ms)
      {:error, _} -> {socket, seen}
    end
  end

  def close({socket, _seen}), do: :gen_tcp.close(socket)
end
