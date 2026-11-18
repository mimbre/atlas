defmodule AtlasRuntime.CodeStandIn do
  @moduledoc """
  A loopback Code for `atlas-runtime snapshot materialize` (s5a-plan P7a): a Bandit Plug on
  `127.0.0.1:0` that serves one snapshot's manifest and archives as Code does
  (`host/snapshot/snapshot.go`: `GET /v1/snapshots/ID/manifest` and
  `GET /v1/snapshots/ID/archive?path=ROOT`, with the bearer token from `code.json`).

  `start!/2` writes `code.json` and its token into the Runtime home. The stand-in logs every
  request (`log/1`), can hold the next archive until `release/1` (`hold/1`), answer it with an
  error status (`fail/2`), and `unreachable!/1` points `code.json` at a closed port. Tests
  materialize through the real helper; nothing here writes a baseline itself.
  """

  @token "stand-in-token-5a7"
  @repository "github.com/test/atlas"

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug

    @impl true
    def init(agent), do: agent

    @impl true
    def call(conn, agent) do
      state = Agent.get(agent, & &1)
      conn = Elixir.Plug.Conn.fetch_query_params(conn)

      entry = %{
        path: conn.request_path,
        root: conn.query_params["path"],
        at: System.monotonic_time()
      }

      Agent.update(agent, &%{&1 | log: &1.log ++ [entry]})

      cond do
        Elixir.Plug.Conn.get_req_header(conn, "authorization") != ["Bearer " <> state.token] ->
          error(conn, 401, "unauthorized")

        conn.request_path == "/v1/snapshots/#{state.id}/manifest" ->
          Elixir.Plug.Conn.send_resp(conn, 200, state.manifest)

        conn.request_path == "/v1/snapshots/#{state.id}/archive" ->
          archive(conn, agent, conn.query_params["path"])

        true ->
          error(conn, 404, "not_found")
      end
    end

    defp archive(conn, agent, root) do
      case Agent.get_and_update(agent, &{&1.next, %{&1 | next: nil}}) do
        :hold ->
          handler = self()
          Agent.update(agent, &%{&1 | held: [handler | &1.held]})

          receive do
            :release -> archive(conn, agent, root)
          after
            120_000 -> error(conn, 503, "held")
          end

        {:fail, status} ->
          error(conn, status, "not_found")

        nil ->
          case Agent.get(agent, & &1.archives[root]) do
            nil -> error(conn, 404, "not_found")
            tar -> Elixir.Plug.Conn.send_resp(conn, 200, tar)
          end
      end
    end

    defp error(conn, status, code) do
      body = ~s({"error":{"code":"#{code}","message":"stand-in #{code}","details":{}}})

      conn
      |> Elixir.Plug.Conn.put_resp_content_type("application/json")
      |> Elixir.Plug.Conn.send_resp(status, body)
    end
  end

  @doc """
  Starts the stand-in for one snapshot of the root `atlas` holding `files` (name => content,
  plain files 0644 directly in the root), writes `code.json` into `home` and returns
  `%{id, url, agent, server}`.
  """
  def start!(home, files \\ %{"README.md" => "base\n"}) do
    {id, manifest} = manifest(files)
    archives = %{"atlas" => tar(files)}

    {:ok, agent} =
      Agent.start(fn ->
        %{
          id: id,
          manifest: manifest,
          archives: archives,
          token: @token,
          log: [],
          next: nil,
          held: []
        }
      end)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, agent},
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    Process.unlink(server)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}"
    configure!(home, url)
    %{id: id, url: url, agent: agent, server: server}
  end

  @doc "Stops the stand-in, and makes the home's sealed folders and baselines removable."
  def stop(%{agent: agent, server: server}, home \\ nil) do
    if home, do: System.cmd("/bin/chmod", ["-R", "u+w", home], stderr_to_stdout: true)
    if Process.alive?(server), do: Supervisor.stop(server)
    if Process.alive?(agent), do: Agent.stop(agent)
    :ok
  end

  @doc """
  Every request so far, `%{path, root, at}` (`at`: monotonic native time); `archives/1` the
  roots of the archive fetches only.
  """
  def log(%{agent: agent}), do: Agent.get(agent, & &1.log)

  def archives(stand_in),
    do:
      for(
        %{path: path, root: root} <- log(stand_in),
        String.ends_with?(path, "/archive"),
        do: root
      )

  @doc "Holds the next archive request until `release/1`."
  def hold(%{agent: agent}), do: Agent.update(agent, &%{&1 | next: :hold})

  @doc "Whether a held archive request is waiting."
  def held?(%{agent: agent}), do: Agent.get(agent, & &1.held) != []

  def release(%{agent: agent}) do
    for pid <- Agent.get_and_update(agent, &{&1.held, %{&1 | held: []}}), do: send(pid, :release)
    :ok
  end

  @doc "Answers the next archive request with `status`."
  def fail(%{agent: agent}, status), do: Agent.update(agent, &%{&1 | next: {:fail, status}})

  @doc "Points `code.json` at a loopback port nothing listens on."
  def unreachable!(home) do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    configure!(home, "http://127.0.0.1:#{port}")
  end

  defp configure!(home, url) do
    token = Path.join([home, "code-service", "runtime.token"])
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, @token <> "\n")
    File.chmod!(token, 0o600)
    File.write!(Path.join(home, "code.json"), JSON.encode!(%{url: url, token_file: token}))
  end

  # Code's canonical version 2 manifest (`manifest.canonical`), whose sha256 is the id.
  defp manifest(files) do
    entries =
      files
      |> Enum.sort()
      |> Enum.map_join(",", fn {name, content} ->
        sha = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

        ~s({"kind":"file","mode":"100644","path":"atlas/#{name}","repository":"#{@repository}",) <>
          ~s("sha256":"#{sha}","size":#{byte_size(content)}})
      end)

    revision = "rev_" <> String.duplicate("a", 64)

    repositories =
      ~s("repositories":[{"path":"atlas","repository":"#{@repository}","revision":"#{revision}"}])

    canonical = ~s({"entries":[#{entries}],#{repositories},"version":2})
    id = "sha256:" <> (:crypto.hash(:sha256, canonical) |> Base.encode16(case: :lower))
    served = ~s({"entries":[#{entries}],#{repositories},"snapshot_id":"#{id}","version":2})
    {id, served}
  end

  # A ustar archive of plain 0644 files.
  defp tar(files) do
    members =
      for {name, content} <- Enum.sort(files) do
        header(name, byte_size(content)) <> pad(content)
      end

    IO.iodata_to_binary([members, <<0::size(1024 * 8)>>])
  end

  defp header(name, size) do
    fields = [
      field(name, 100),
      field("0000644", 8),
      field("0000000", 8),
      field("0000000", 8),
      field(String.pad_leading(Integer.to_string(size, 8), 11, "0"), 12),
      field("00000000000", 12)
    ]

    rest = [
      "0",
      field("", 100),
      "ustar\0",
      "00",
      field("", 32),
      field("", 32),
      field("", 8),
      field("", 8),
      field("", 155)
    ]

    blank = IO.iodata_to_binary([fields, "        ", rest])
    sum = blank |> :binary.bin_to_list() |> Enum.sum()
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> "\0 "
    header = IO.iodata_to_binary([fields, checksum, rest])
    header <> :binary.copy(<<0>>, 512 - byte_size(header))
  end

  defp field(text, size), do: text <> :binary.copy(<<0>>, size - byte_size(text))

  defp pad(content) do
    case rem(byte_size(content), 512) do
      0 -> content
      r -> content <> :binary.copy(<<0>>, 512 - r)
    end
  end

  ## Base work helpers for the work core's tests (P7a)

  import ExUnit.Assertions

  alias AtlasRuntime.Boundary.Work, as: F

  @doc "A `base` work request (a map, as decoded JSON would be) for the stand-in's snapshot."
  def base_request(code, instructions, permissions \\ "workspace-write", extra \\ %{}) do
    Map.merge(
      %{
        title: instructions,
        instructions: instructions,
        profile: "light_work",
        cost_class: "standard",
        workspace: %{kind: "base", base_id: code.id, permissions: permissions}
      },
      extra
    )
  end

  @doc "Submits a base work through the facade and asserts `accepted`."
  def submit_base!(code, instructions, permissions \\ "workspace-write", extra \\ %{}) do
    assert %F.Outcome.Accepted{work: work} =
             F.submit(
               AtlasRuntime.WorkHarness.client(),
               base_request(code, instructions, permissions, extra)
             )

    work
  end

  @doc """
  The folder §3.9 names, computed without `AtlasRuntime.Work.Folders`: the home through its
  symlinks (macOS's temp dir is one), `workers`, `work-` and the work_id.
  """
  def expected_folder(dir, work_id) do
    {home, 0} = System.cmd("/bin/sh", ["-c", ~s(cd -P "$0" && pwd), dir])
    Path.join([String.trim(home), "workers", "work-" <> work_id])
  end

  @doc """
  Attempt `n` of the work as the core stored it, private fields included; nil until the
  local source's lease has added the work (or that attempt) to the core.
  """
  def private_attempt(dir, work_id, n) do
    case AtlasRuntime.Work.Store.read_work(dir, work_id) do
      nil -> nil
      record -> Enum.find(record.attempts, &(&1.attempt == n))
    end
  end

  @doc "The write bits of a path's mode."
  def writable_bits(path) do
    {:ok, %{mode: mode}} = File.lstat(path)
    Bitwise.band(mode, 0o222)
  end
end
