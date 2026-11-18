defmodule AtlasCode.Git do
  @moduledoc """
  Code's Git endpoint for Runtimes: Git's smart HTTP protocol (`git http-backend`), read
  only, on 127.0.0.1 behind the core's tailnet ingress (TLS ends there).

  A base is a repository URL of its own, `/bases/<base_id>`, which advertises the ref
  `refs/atlas/bases/<base_id>` on the base's commit (`AtlasCode.Service.base_repository/2`):
  a Runtime fetches that ref and never names a commit.

  Every request needs `Authorization: Bearer <token>` with a Runtime's work source token: the
  credentials secret Flow's work source reads (`{runtime_id: {holder, token_sha256}}`, in the
  environment variable `credentials_env` names), read once when the endpoint starts.

  `config :atlas_code, git: %{"port" => port, "credentials_env" => name}` starts it
  (`AtlasCode.Application`); it serves the registered Code (`AtlasCode.settings/0`).
  """
  @behaviour Plug
  import Plug.Conn

  alias AtlasCode.Service

  def child_spec(%{"port" => port, "credentials_env" => env}) do
    digests =
      for {_runtime, %{"token_sha256" => sha}} <- JSON.decode!(System.fetch_env!(env)),
          do: Base.decode16!(sha, case: :lower)

    Bandit.child_spec(
      plug: {__MODULE__, digests},
      ip: {127, 0, 0, 1},
      port: port,
      startup_log: false
    )
  end

  @impl true
  def init(digests), do: digests

  @impl true
  def call(conn, digests) do
    if authorized?(conn, digests),
      do: serve(conn),
      else: send_resp(conn, 401, "")
  end

  defp authorized?(conn, digests) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        hash = :crypto.hash(:sha256, token)
        Enum.any?(digests, &:crypto.hash_equals(&1, hash))

      _ ->
        false
    end
  end

  defp serve(%{path_info: ["bases", base_id | rest]} = conn) do
    {:ok, dir} = Service.base_repository(AtlasCode.settings(), base_id)
    {body, conn} = body(conn, [])
    input = Path.join(System.tmp_dir!(), "atlas-git-#{System.unique_integer([:positive])}")
    File.write!(input, body)

    env = [
      {"GIT_PROJECT_ROOT", Path.dirname(dir)},
      {"GIT_HTTP_EXPORT_ALL", "1"},
      {"PATH_INFO", Enum.join(["", Path.basename(dir) | rest], "/")},
      {"REQUEST_METHOD", conn.method},
      {"QUERY_STRING", conn.query_string},
      {"CONTENT_LENGTH", Integer.to_string(byte_size(body))},
      {"CONTENT_TYPE", header(conn, "content-type")},
      {"HTTP_CONTENT_ENCODING", header(conn, "content-encoding")},
      {"GIT_PROTOCOL", header(conn, "git-protocol")}
    ]

    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        env: for({key, value} <- env, do: {~c"#{key}", ~c"#{value}"}),
        args: ["-c", ~s(exec git http-backend < "$1"), "sh", input]
      ])

    try do
      respond(conn, port, "")
    after
      File.rm(input)
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first("")

  defp body(conn, acc) do
    case read_body(conn) do
      {:ok, data, conn} -> {IO.iodata_to_binary([acc, data]), conn}
      {:more, data, conn} -> body(conn, [acc, data])
    end
  end

  # The CGI answer: its headers up to the blank line, then the body as it comes.
  defp respond(conn, port, buffer) do
    receive do
      {^port, {:data, data}} ->
        case :binary.split(buffer <> data, "\r\n\r\n") do
          [head, rest] -> stream(cgi_headers(conn, head), port, rest)
          [buffer] -> respond(conn, port, buffer)
        end
    end
  end

  defp cgi_headers(conn, head) do
    {status, conn} =
      head
      |> String.split("\r\n")
      |> Enum.reduce({200, conn}, fn line, {status, conn} ->
        [name, value] = String.split(line, ": ", parts: 2)

        case String.downcase(name) do
          "status" -> {value |> String.split(" ") |> hd() |> String.to_integer(), conn}
          name -> {status, put_resp_header(conn, name, value)}
        end
      end)

    send_chunked(conn, status)
  end

  defp stream(conn, port, data) do
    {:ok, conn} = if data == "", do: {:ok, conn}, else: chunk(conn, data)

    receive do
      {^port, {:data, data}} -> stream(conn, port, data)
      {^port, {:exit_status, _}} -> conn
    end
  end
end
