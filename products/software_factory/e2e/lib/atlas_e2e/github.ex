defmodule AtlasE2E.GitHub do
  @moduledoc """
  A stand-in for GitHub's API, so the end-to-end test never reaches the real one. The
  private instance's GitHub connector reads it (`connectors.github.api` in its settings),
  with the token `e2e-stand-in`.

  It answers `GET /repos/<owner>/<repo>/pulls/<n>` from what a scenario put there with
  `put/2`, 404 for anything else, and keeps every request it got, so a scenario can check
  the connector only reads and sends its token. `put(url, {:status, 503})` makes a read
  fail.
  """

  @token "e2e-stand-in"

  def token, do: @token

  def start do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, packet: :http_bin, active: false])

    {:ok, port} = :inet.port(listen)
    {:ok, _} = Agent.start(fn -> %{pulls: %{}, requests: []} end, name: __MODULE__)
    pid = spawn(fn -> accept(listen) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    "http://127.0.0.1:#{port}"
  end

  @doc "What GitHub says about the pull at `url` from now on: its fields, or `{:status, n}`."
  def put(url, pull), do: Agent.update(__MODULE__, &put_in(&1, [:pulls, path(url)], pull))

  @doc "The requests so far: `%{method, path, authorization}`, oldest first."
  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def path(url) do
    [_, owner, repo, n] = Regex.run(~r{^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)$}, url)
    "/repos/#{owner}/#{repo}/pulls/#{n}"
  end

  defp accept(listen) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn(fn -> serve(socket) end) |> then(&:gen_tcp.controlling_process(socket, &1))
    accept(listen)
  end

  defp serve(socket) do
    with {:ok, {:http_request, method, {:abs_path, path}, _}} <- :gen_tcp.recv(socket, 0, 5_000) do
      headers = headers(socket, %{})
      request = %{method: to_string(method), path: path, authorization: headers["authorization"]}
      Agent.update(__MODULE__, &%{&1 | requests: [request | &1.requests]})
      {status, body} = answer(request)

      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n" <>
          "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
      )
    end

    :gen_tcp.close(socket)
  end

  defp answer(%{method: "GET", authorization: "Bearer " <> @token, path: path}) do
    case Agent.get(__MODULE__, & &1.pulls[path]) do
      nil -> {404, ~s|{"message":"Not Found"}|}
      {:status, status} -> {status, ~s|{"message":"stand-in failure"}|}
      pull -> {200, JSON.encode!(pull)}
    end
  end

  defp answer(%{method: "GET"}), do: {401, ~s|{"message":"Bad credentials"}|}
  defp answer(_request), do: {405, ~s|{"message":"read-only stand-in"}|}

  defp headers(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers(socket, Map.put(acc, String.downcase(to_string(name)), value))

      _ ->
        acc
    end
  end
end
