defmodule AtlasFacts.StubHttp do
  @moduledoc """
  A tiny HTTP server on a free local port, for tests of a connector's source: `answer`
  gets `%{method, path, headers}` and returns `{status, body}`. Every request is kept,
  so a test can check what was asked (only GETs, the token).
  """

  def start(answer) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, packet: :http_bin, active: false])

    {:ok, port} = :inet.port(listen)
    {:ok, log} = Agent.start_link(fn -> [] end)
    pid = spawn_link(fn -> accept(listen, answer, log) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    %{url: "http://127.0.0.1:#{port}", log: log}
  end

  def requests(%{log: log}), do: Agent.get(log, &Enum.reverse/1)

  defp accept(listen, answer, log) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    request = %{method: to_string(method), path: path, headers: headers(socket, %{})}
    Agent.update(log, &[request | &1])
    {status, body} = answer.(request)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n" <>
        "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
    )

    :gen_tcp.close(socket)
    accept(listen, answer, log)
  end

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(acc, String.downcase(to_string(name)), value))

      {:ok, :http_eoh} ->
        acc
    end
  end
end
