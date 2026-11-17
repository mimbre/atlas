# MIX_ENV=test mix run --no-start integration/runtime_backend_tcp.exs
#
# The Runtime backend on loopback TCP, end to end without a tailnet (design
# 2026-11-16-runtime-backend §8.1–§8.4, §9, §13 S3; S3 plan P8). The real Service, work
# core and both backend listeners run as a separate OS process (`mix run
# platform/atlas_runtime/host/service.exs HOME`, in a session of its own, as
# integration/runtime_backend.exs runs it), with the host built from this tree as
# `ATLAS_RUNTIME_EXECUTABLE`, a fake `codex` and `claude` on `PATH` (`fake-native work`,
# which never launches a provider) and a `clients.json` this script writes (mode 0600).
# Nothing here is started by the bench: `host/service.exs` starts the TCP listener itself.
#
# Three kinds of case:
# - plain HTTP/1.1 on `127.0.0.1:<port>` and on `backend.sock`, written byte by byte, so
#   every header (Origin, Authorization, If-None-Match) or its absence is the case's own;
# - through a TLS stand-in for `tailscale serve --https=<P> http://127.0.0.1:<P>` (an `:ssl`
#   listener with an in-test CA, piping each connection to the TCP listener, 502 when it
#   cannot reach it), with a verified TLS client;
# - tagged `:remote`: `AtlasRuntime.Remote` (S3 P6) driving the whole path, through the
#   CONNECT proxy of `platform/atlas_runtime/test/support/remote_fixtures.ex` and the TLS
#   stand-in. They always run: without P6 in the tree (`AtlasRuntime.Remote.probe/0` and
#   the fixtures) the script stops before any case, rather than passing without them.
#
# D44: a TCP client never names a path on the Runtime's machine. Work submitted over TCP or
# through `AtlasRuntime.Remote` uses a `repository` workspace (a `https://github.com/s3-e2e/…`
# URL that the fake `codex sandbox` clones from a local source through `insteadOf`, as
# host_test.go does); only backend.sock names folders.
#
# Environment: ATLAS_E2E_SEED (ExUnit seed, default 0), ATLAS_E2E_INCLUDE (comma separated
# tags to include) and ATLAS_E2E_TRACE=1 (per-test times).

seed = String.to_integer(System.get_env("ATLAS_E2E_SEED", "0"))

include =
  System.get_env("ATLAS_E2E_INCLUDE", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.to_atom/1)

defmodule RuntimeBackendTcpE2E.RemoteSeam do
  @moduledoc """
  The one place this script touches S3 P6 (`AtlasRuntime.Remote`), written against the
  plan's P6 interface: `Remote.probe/0`, the calls `Targets.Client` generates from
  `AtlasRuntimeBackend.Work` (`submit/2`, `get_work/2`, `cancel/2`, `subscribe/2`, ...),
  configuration only from `ATLAS_RUNTIME_REMOTE=1`, `ATLAS_RUNTIME_BACKEND_URL` and
  `ATLAS_RUNTIME_BACKEND_TOKEN` read at application start, and the outbound proxy at
  `localhost:1055` (HTTP CONNECT).

  Bound to P6 (each is marked P6-SEAM below): the fixtures' CONNECT proxy
  (`AtlasRuntime.RemoteFixtures.Proxy`, here on the release's own `localhost:1055`), and
  how this VM trusts the in-test CA. `AtlasRuntime.Remote.Config` takes the OS store
  (`:public_key.cacerts_get/0`) at start, so the seam loads the test CA into that store
  (`:public_key.cacerts_load/1`) before the application starts. Nothing else is set:
  the Remote starts exactly as the release starts it.
  """

  @fixtures Path.expand(
              "../../../platform/atlas_runtime/test/support/remote_fixtures.ex",
              __DIR__
            )

  def fixtures, do: Module.concat(["AtlasRuntime", "RemoteFixtures"])

  @doc "Whether P6 is in this tree; the reason when it is not."
  def available do
    cond do
      not (Code.ensure_loaded?(AtlasRuntime.Remote) and
               function_exported?(AtlasRuntime.Remote, :probe, 0)) ->
        {:no, "AtlasRuntime.Remote.probe/0 is not in this tree (S3 P6 not landed)"}

      not Code.ensure_loaded?(fixtures()) and not File.exists?(@fixtures) ->
        {:no, "#{Path.relative_to_cwd(@fixtures)} is not in this tree (S3 P6 not landed)"}

      true ->
        unless Code.ensure_loaded?(fixtures()), do: Code.require_file(@fixtures)
        :yes
    end
  end

  # P6-SEAM: the fixtures' in-test CONNECT proxy (`:gen_tcp`) on `port`, recording each
  # CONNECT target, and its answer to CONNECT (`:ok` → 200 and a tunnel, 403 → refused).
  # Not linked to the caller: a case may replace it, and the next case finds the new one.
  # `upstream:` makes it a man in the middle (every tunnel goes to that port).
  def proxy!(port, answer \\ :ok, opts \\ []) do
    mode = if answer == :ok, do: :tunnel, else: :refuse
    proxy = Module.concat(fixtures(), Proxy)

    {:ok, pid} =
      RuntimeBackendTcpE2E.await(
        fn ->
          case proxy.start_link([port: port, mode: mode] ++ opts) do
            {:ok, pid} -> {:ok, pid}
            {:error, _} -> nil
          end
        end,
        5_000,
        fn -> "127.0.0.1:#{port} is taken: the CONNECT proxy cannot listen there" end
      )

    Process.unlink(pid)
    :persistent_term.put({__MODULE__, :proxy}, pid)
    pid
  end

  @doc "The proxy started last (a case may have replaced the one setup_all started)."
  def current_proxy, do: :persistent_term.get({__MODULE__, :proxy})

  @doc "The CONNECT targets the proxy saw, in order, as `{host, port}`."
  def connects(proxy) do
    for target <- Module.concat(fixtures(), Proxy).connects(proxy) do
      [host, port] = String.split(target, ":")
      {host, String.to_integer(port)}
    end
  end

  def stop_proxy(proxy) do
    if Process.alive?(proxy), do: GenServer.stop(proxy)
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Starts the core side as the release does: the env, then `:atlas_runtime`'s application
  (whose one optional child is the Remote). The token must be gone from the env after.
  """
  def start!(url, token, cacertfile) do
    # P6-SEAM: trusting the in-test CA (this VM's OS store becomes the test CA alone).
    :ok = :public_key.cacerts_load(String.to_charlist(cacertfile))

    System.put_env(%{
      "ATLAS_RUNTIME_REMOTE" => "1",
      "ATLAS_RUNTIME_BACKEND_URL" => url,
      "ATLAS_RUNTIME_BACKEND_TOKEN" => token
    })

    {:ok, _} = Application.ensure_all_started(:atlas_runtime)
    :ok
  end

  # Named at run time: without P6 the script stops before any case (see below).
  def remote, do: Module.concat(["AtlasRuntime", "Remote"])
  def config, do: Module.concat(["AtlasRuntime", "Remote", "Config"])

  @doc """
  Starts the Remote's configuration again under `:atlas_runtime`'s supervisor with this
  env, as a core restart would: `Supervisor.start_child/2`'s answer. It is a temporary
  child (it is never restarted by the supervisor), so it is stopped and started anew.
  """
  def restart!(env) do
    _ = Supervisor.terminate_child(AtlasRuntime.Root, config())
    System.put_env(env)
    Supervisor.start_child(AtlasRuntime.Root, config())
  end
end

remote = RuntimeBackendTcpE2E.RemoteSeam.available()

with {:no, why} <- remote, do: raise("runtime_backend_tcp: the :remote cases cannot run: #{why}")

ExUnit.start(
  seed: seed,
  include: include,
  timeout: 120_000,
  trace: System.get_env("ATLAS_E2E_TRACE") == "1"
)

defmodule RuntimeBackendTcpE2E do
  @moduledoc false
  # The bench: build, homes and clients.json, the Runtime process, raw HTTP and SSE on
  # backend.sock and on 127.0.0.1:<port>, the TLS serve stand-in.
  import ExUnit.Assertions

  @root Path.expand("../../..", __DIR__)
  @project Path.join(@root, "products/software_factory")
  @service Path.join(@root, "platform/atlas_runtime/host/service.exs")
  @terminal ~w(completed failed crashed interrupted cancelled returned)
  @wait 20_000
  # One heartbeat (15 s, §8.4) and some room: an open TCP stream re-checks its token there.
  @heartbeat_wait 25_000
  # Repository workspaces (D44): every URL under here is cloned from <run>/src/<name>.git.
  @repositories "https://github.com/s3-e2e/"

  def heartbeat_wait, do: @heartbeat_wait

  ## Build (once per run)

  def build! do
    dir = Path.join(System.tmp_dir!(), "rbt-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Path.join(dir, "atlas-runtime")
    fake = Path.join(dir, "fake-native")
    go!(["-C", "platform/atlas_runtime/host", "build", "-o", host, "."], @root)

    go!(
      ["build", "-o", fake, "main.go"],
      Path.join(@root, "platform/atlas_runtime/test/support/fake_native")
    )

    :persistent_term.put({__MODULE__, :build}, %{dir: dir, host: host, fake: fake})
    # Every folder this run makes in TMPDIR (Runtime runs, serve CAs) is under `dir`.
    ExUnit.after_suite(fn _ -> File.rm_rf(dir) end)
  end

  defp go!(args, cd) do
    case System.cmd("go", args, cd: cd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise "go #{Enum.join(args, " ")} failed:\n#{out}"
    end
  end

  def build, do: :persistent_term.get({__MODULE__, :build})

  ## Tokens and clients.json (the shape of AtlasRuntime.Backend.Clients)

  @doc "A token as the runbook makes one (`openssl rand -hex 32`)."
  def token, do: Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

  def sha256(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)

  @doc "A clients.json entry; `extra` such as `%{\"disabled\" => true}`."
  def entry(name, token, rights, extra \\ %{}) do
    Map.merge(%{"name" => name, "token_sha256" => sha256(token), "rights" => rights}, extra)
  end

  @doc """
  Writes `<home>/clients.json` as a human would: a new file at `mode`, renamed into place,
  so a request never reads half a file.
  """
  def write_clients!(home, port, entries, mode \\ 0o600) do
    data = %{"version" => 1, "listen" => %{"port" => port}, "clients" => entries}
    tmp = Path.join(home, ".clients.json.#{System.unique_integer([:positive])}")
    File.write!(tmp, JSON.encode!(data))
    File.chmod!(tmp, mode)
    File.rename!(tmp, Path.join(home, "clients.json"))
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  ## A Runtime

  @doc """
  A run folder with a Runtime home (policy.json: slots s1, s2, buffer 1), a fake harness on
  PATH, and, unless `clients: nil`, a clients.json for a free loopback port. Options:
  `clients:` (entries, or nil for no file), `mode:` (the file's mode), `boot:` (`:ready`,
  the default, or `:fails`, which waits for the service to exit and keeps its log).
  """
  def runtime!(opts \\ []) do
    run = Path.join(build().dir, "rt#{System.unique_integer([:positive])}")
    File.rm_rf!(run)
    home = Path.join(run, "h")
    bin = Path.join(run, "bin")
    for d <- [home, bin, Path.join(run, "ws"), Path.join(run, "codex-home")], do: File.mkdir_p!(d)

    for tool <- ["git", "mkfifo"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    File.mkdir_p!(Path.join(run, "src"))

    for harness <- ["codex", "claude"] do
      words = Enum.map_join([build().fake, "work", run], " ", &sh_quote/1)
      sources = sh_quote("url.file://#{Path.join(run, "src")}/.insteadOf=#{@repositories}")

      # As Codex's sandbox prefix (managed repository preparation, D44), run Git in -C over a
      # local transport, as host_test.go does; otherwise act as the harness.
      File.write!(Path.join(bin, harness), """
      #!/bin/sh
      if [ "$1" = sandbox ]; then
        while [ "$1" != -C ]; do shift; done
        cd "$2" || exit 1
        while [ "$1" != -- ]; do shift; done
        shift 2
        exec git -c #{sources} "$@"
      fi
      exec #{words} "$0" "$@"
      """)

      File.chmod!(Path.join(bin, harness), 0o700)
    end

    File.write!(Path.join(home, "policy.json"), JSON.encode!(policy()))

    File.write!(Path.join(run, "boot.exs"), """
    [dir] = System.argv()
    File.write!(Path.join(Path.dirname(dir), "beam.pid"), System.pid())
    Code.eval_file(#{inspect(@service)})
    """)

    port = free_port()
    clients = Keyword.get(opts, :clients, [])
    if clients, do: write_clients!(home, port, clients, Keyword.get(opts, :mode, 0o600))

    rt = %{
      run: run,
      home: home,
      bin: bin,
      sock: Path.join(home, "backend.sock"),
      port: port,
      boots: 0
    }

    case Keyword.get(opts, :boot, :ready) do
      :ready -> boot!(rt, clients != nil)
      :fails -> boot_fails!(rt)
    end
  end

  defp sh_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  def policy do
    %{
      "version" => 1,
      "slots" => ["s1", "s2"],
      "buffer_size" => 1,
      "profiles" => %{
        "light_work" => %{
          "permissions" => [
            "read-only",
            "workspace-write",
            "materialized-folder",
            "dedicated-repository"
          ],
          "cost_classes" => ["low", "standard"],
          "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
        }
      }
    }
  end

  defp spawn_runtime(rt) do
    File.rm(Path.join(rt.home, "runtime.sock"))
    File.rm(Path.join(rt.run, "beam.pid"))
    boots = rt.boots + 1
    log = Path.join(rt.run, "service-#{boots}.log")

    env =
      for {k, v} <-
            [
              {"MIX_ENV", "test"},
              {"ATLAS_RUNTIME_EXECUTABLE", build().host},
              {"ATLAS_RUNTIME_HOME", rt.home},
              {"PATH", path(rt)},
              {"CODEX_HOME", Path.join(rt.run, "codex-home")},
              {"ELIXIR_ERL_OPTIONS", "+S 2:2"}
            ] ++ runtime_git_env(rt),
          do: {String.to_charlist(k), String.to_charlist(v)}

    args =
      ["detach", mix(), "run", "--no-start", "--no-compile", "--no-deps-check"] ++
        [Path.join(rt.run, "boot.exs"), rt.home]

    parent = self()

    owner =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, build().fake}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            cd: @project,
            env: env
          ])

        {:os_pid, pid} = Port.info(port, :os_pid)
        send(parent, {:booted, self(), pid})
        {:ok, file} = File.open(log, [:append, :binary])
        output(port, file)
      end)

    pgid =
      receive(do: ({:booted, ^owner, pid} -> pid), after: (10_000 -> flunk("no Runtime process")))

    Map.merge(rt, %{boots: boots, owner: owner, pgid: pgid, log: log})
  end

  @doc "Boots the Runtime and waits until backend.sock answers (and the TCP port, if `tcp?`)."
  def boot!(rt, tcp?) do
    rt = spawn_runtime(rt)

    await(
      fn ->
        if exited?(rt), do: flunk("the Runtime exited at boot; #{rt.log}:\n#{log(rt)}")
        match?({:ok, %{status: 200}}, try_request(rt, :sock, "GET", "/v1/capacity"))
      end,
      120_000,
      fn -> "backend.sock did not answer; #{rt.log}:\n#{log(rt)}" end
    )

    # host/service.exs starts the TCP listener right after backend.sock.
    if tcp? do
      await(fn -> match?({:ok, _}, try_request(rt, :tcp, "GET", "/v1/capacity")) end, @wait, fn ->
        "127.0.0.1:#{rt.port} did not answer; #{rt.log}:\n#{log(rt)}"
      end)
    end

    Map.put(rt, :beam, File.read!(Path.join(rt.run, "beam.pid")) |> String.trim())
  end

  @doc "Boots the Runtime and waits for the service to exit (a refused start)."
  def boot_fails!(rt) do
    rt = spawn_runtime(rt)

    # It exits, or it came up after all: backend.sock and then the TCP port answer.
    await(
      fn -> exited?(rt) or match?({:ok, _}, try_request(rt, :tcp, "GET", "/v1/capacity")) end,
      120_000,
      fn -> "the Runtime neither exited nor served; #{rt.log}:\n#{log(rt)}" end
    )

    refute match?({:ok, _}, try_request(rt, :tcp, "GET", "/v1/capacity")),
           "the start was not refused: 127.0.0.1:#{rt.port} serves; #{rt.log}"

    rt
  end

  def exited?(rt), do: log(rt) =~ "[e2e: Runtime exited"
  def log(rt), do: File.read!(rt.log)

  defp path(rt) do
    Enum.join(
      [rt.bin, Path.dirname(elixir()), Path.dirname(erl()), "/usr/bin:/bin:/usr/sbin:/sbin"],
      ":"
    )
  end

  defp output(port, file) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(file, data)
        output(port, file)

      {^port, {:exit_status, status}} ->
        IO.binwrite(file, "\n[e2e: Runtime exited #{status}]\n")
        File.close(file)
    end
  end

  defp mix, do: Path.join(Path.dirname(elixir()), "mix")
  defp elixir, do: Path.join(:code.lib_dir(:elixir), "../../bin/elixir") |> Path.expand()
  defp erl, do: Path.join(:code.root_dir(), "bin/erl")

  @doc """
  Ends everything this run started: the Runtime group and any turn still alive, then its
  run folder (a process that still writes there may keep a part of it; the suite's end
  removes the build folder, and with it every run folder).
  """
  def cleanup(rt) do
    System.cmd("kill", ["-KILL", "-#{rt.pgid}"], stderr_to_stdout: true)

    for %{"pid" => pid} <- launches(rt) do
      System.cmd("kill", ["-KILL", "-#{pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "#{pid}"], stderr_to_stdout: true)
    end

    _ = File.rm_rf(rt.run)
    :ok
  end

  ## Raw HTTP/1.1: `via` is :sock (backend.sock), :tcp (127.0.0.1:<rt.port>) or
  ## {:tcp, address, port}. `token:` adds `Authorization: Bearer <token>`.

  def request(rt, via, method, path, opts \\ []) do
    case try_request(rt, via, method, path, opts) do
      {:ok, response} -> response
      {:error, reason} -> flunk("#{method} #{path} on #{inspect(via)}: #{inspect(reason)}")
    end
  end

  def try_request(rt, via, method, path, opts \\ []) do
    {payload, type} =
      case Keyword.fetch(opts, :body) do
        {:ok, raw} when is_binary(raw) -> {raw, [{"content-type", "application/json"}]}
        {:ok, body} -> {JSON.encode!(body), [{"content-type", "application/json"}]}
        :error -> {"", []}
      end

    head =
      [{"host", "localhost"}, {"connection", "close"}, {"content-length", byte_size(payload)}] ++
        type ++ auth(opts[:token]) ++ Keyword.get(opts, :headers, [])

    with {:ok, socket} <- connect(rt, via) do
      _ =
        :gen_tcp.send(socket, [
          method,
          " ",
          path,
          " HTTP/1.1\r\n",
          for({k, v} <- head, do: [k, ": ", to_string(v), "\r\n"]),
          "\r\n",
          payload
        ])

      result = recv_all(socket, "", System.monotonic_time(:millisecond) + 60_000)
      :gen_tcp.close(socket)
      with {:ok, raw} <- result, do: parse(raw)
    end
  end

  defp auth(nil), do: []
  defp auth(token), do: [{"authorization", "Bearer " <> token}]

  def connect(rt, via, opts \\ [:binary, active: false]) do
    case via do
      :sock -> :gen_tcp.connect({:local, rt.sock}, 0, opts, 5_000)
      :tcp -> :gen_tcp.connect({127, 0, 0, 1}, rt.port, opts, 5_000)
      {:tcp, address, port} -> :gen_tcp.connect(address, port, opts, 5_000)
    end
  end

  defp recv_all(socket, acc, deadline) do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 1)) do
      {:ok, data} -> recv_all(socket, acc <> data, deadline)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, {reason, acc}}
    end
  end

  @doc "A whole HTTP/1.1 answer as `{:ok, %{status, headers, body, json}}`."
  def parse(raw) do
    case String.split(raw, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [status_line | lines] = String.split(head, "\r\n")
        [_, status | _] = String.split(status_line, " ", parts: 3)

        headers =
          for line <- lines,
              [k, v] = String.split(line, ":", parts: 2),
              do: {String.downcase(k), String.trim(v)}

        body = if {"transfer-encoding", "chunked"} in headers, do: dechunk(body, ""), else: body
        type = header(%{headers: headers}, "content-type") || ""
        json = if body != "" and type =~ "json", do: JSON.decode!(body)
        {:ok, %{status: String.to_integer(status), headers: headers, body: body, json: json}}

      _ ->
        {:error, {:no_answer, raw}}
    end
  end

  defp dechunk(data, acc) do
    with [size, rest] <- String.split(data, "\r\n", parts: 2),
         {n, _} when n > 0 <- Integer.parse(size, 16) do
      dechunk(
        binary_part(rest, n, byte_size(rest) - n) |> String.trim_leading("\r\n"),
        acc <> binary_part(rest, 0, n)
      )
    else
      _ -> acc
    end
  end

  def header(%{headers: headers}, name),
    do: Enum.find_value(headers, fn {k, v} -> if k == name, do: v end)

  def headers(%{headers: headers}, name), do: for({^name, v} <- headers, do: v)

  ## The work API

  @doc """
  A work request. `kind` is its workspace: `:repository` (the default, the only form a TCP
  client may name, D44) or `:folder` (a path on the Runtime's machine: backend.sock only).
  """
  def work_request(rt, instructions, extra \\ %{}, kind \\ :repository) do
    Map.merge(
      %{
        "title" => instructions,
        "instructions" => instructions,
        "profile" => "light_work",
        "cost_class" => "standard",
        "workspace" => workspace(rt, instructions, kind)
      },
      extra
    )
  end

  defp workspace(rt, instructions, :folder) do
    folder = Path.join([rt.run, "ws", name(instructions)])
    File.mkdir_p!(folder)
    %{"kind" => "folder", "path" => folder, "permissions" => "read-only"}
  end

  defp workspace(rt, instructions, :repository) do
    name = name(instructions)
    # The host asks for the canonical `<owner>/<name>.git`.
    source = Path.join([rt.run, "src", name <> ".git"])

    unless File.dir?(source) do
      git!(rt.run, ["init", "-q", "-b", "develop", source])
      git!(source, ["commit", "--allow-empty", "-qm", "base"])
    end

    %{
      "kind" => "repository",
      "url" => @repositories <> name <> ".git",
      "branch" => "task/" <> name,
      "base" => "develop"
    }
  end

  @doc "Git never reads this machine's global or system configuration here."
  def git_env, do: [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

  # The Runtime passes only HOME (not GIT_CONFIG_GLOBAL) on to the native host, whose
  # repository preparation runs git: so the Runtime gets a HOME of its own, in the run folder.
  defp runtime_git_env(rt) do
    home = Path.join(rt.run, "home")
    File.mkdir_p!(home)
    [{"HOME", home} | git_env()]
  end

  defp name(instructions), do: Base.encode16(:crypto.hash(:md5, instructions), case: :lower)

  defp git!(cd, args) do
    identity = ["-c", "user.name=e2e", "-c", "user.email=e2e@example.invalid"]

    case System.cmd("git", identity ++ args, cd: cd, env: git_env(), stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> raise "git #{Enum.join(args, " ")} failed:\n#{out}"
    end
  end

  @doc """
  POST /v1/work on `via`; `key:` is the Idempotency-Key, `token:` the Bearer token. The
  workspace is a folder on backend.sock and a repository elsewhere (D44), unless
  `workspace:` says which.
  """
  def submit(rt, via, instructions, opts \\ []) do
    headers = if key = opts[:key], do: [{"idempotency-key", key}], else: []
    kind = Keyword.get(opts, :workspace, if(via == :sock, do: :folder, else: :repository))

    request(rt, via, "POST", "/v1/work",
      body: work_request(rt, instructions, Map.new(opts[:extra] || %{}), kind),
      headers: headers ++ Keyword.get(opts, :headers, []),
      token: opts[:token]
    )
  end

  @doc """
  `work` as a client without `choose_path` sees it (D44): no `path` in its
  `request.workspace` or in any attempt's `resume_point.workspace` or
  `result.work_product.workspace`.
  """
  def without_paths(work) do
    work
    |> drop_path(["request", "workspace"])
    |> Map.update!("attempts", fn attempts ->
      for attempt <- attempts do
        attempt
        |> drop_path(["resume_point", "workspace"])
        |> drop_path(["result", "work_product", "workspace"])
      end
    end)
  end

  defp drop_path(map, keys) do
    case get_in(map, keys) do
      %{} = workspace -> put_in(map, keys, Map.delete(workspace, "path"))
      _ -> map
    end
  end

  @doc "Every `path` an attempt shows (resume point and work product)."
  def attempt_paths(work) do
    for attempt <- work["attempts"],
        keys <- [["resume_point", "workspace"], ["result", "work_product", "workspace"]],
        path = get_in(attempt, keys ++ ["path"]),
        do: path
  end

  def submit!(rt, via, instructions, opts \\ []) do
    response = submit(rt, via, instructions, opts)
    assert response.status == 201, "submit #{instructions}: #{response.status} #{response.body}"
    response.json
  end

  def get(rt, via, id, opts \\ []), do: request(rt, via, "GET", "/v1/work/#{id}", opts)

  def cancel(rt, via, id, mode, opts \\ []),
    do: request(rt, via, "POST", "/v1/work/#{id}/cancel", [body: %{"mode" => mode}] ++ opts)

  def current(work), do: List.last(work["attempts"])
  def terminal?(work), do: work["state"] in @terminal

  def await_state(rt, id, state, timeout \\ @wait) do
    await(
      fn ->
        %{status: 200, json: work} = get(rt, :sock, id)
        work["state"] == state && work
      end,
      timeout,
      fn -> "work #{id} never became #{state}: #{inspect(get(rt, :sock, id).json)}" end
    )
  end

  def await_launch(rt, work) do
    goal = work["request"]["instructions"]

    await(fn -> Enum.any?(launches(rt), &(&1["goal"] == goal)) end, @wait, fn ->
      "#{goal} not launched; log: #{inspect(launches(rt))}"
    end)

    await_state(rt, work["work_id"], "running")
  end

  def launches(rt) do
    case File.read(Path.join(rt.run, "work-launches.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  @doc "Ends every live work (force, by its own client) and waits until the Runtime is idle."
  # Each work is cancelled by its own client (§3.2 Ownership: no client acts on another's
  # work): socket work on backend.sock, `token:<name>` work over TCP with `tokens[name]`.
  def quiesce(rt, tokens \\ %{}) do
    %{status: 200, json: %{"works" => works}} = request(rt, :sock, "GET", "/v1/work")

    for work <- works, not terminal?(work) do
      case work["client"] do
        "token:" <> name ->
          token = Map.fetch!(tokens, String.to_existing_atom(name))
          cancel(rt, :tcp, work["work_id"], "force", token: token)

        _local ->
          cancel(rt, :sock, work["work_id"], "force")
      end
    end

    await(
      fn ->
        %{json: %{"works" => works}} = request(rt, :sock, "GET", "/v1/work")
        %{json: capacity} = request(rt, :sock, "GET", "/v1/capacity")

        Enum.all?(works, &(terminal?(&1) and current(&1)["quiescent"])) and
          capacity["slots"]["free"] == 2 and capacity["buffer"]["used"] == 0
      end,
      40_000,
      fn -> "the Runtime did not become idle" end
    )
  end

  ## Server-Sent Events on GET /v1/events

  @doc """
  Opens the event stream on `via`; each frame arrives as `{:sse, ref, frame}` and the end
  of the stream as `{:sse_closed, ref}`.
  """
  def subscribe(rt, via, opts \\ []) do
    ref = make_ref()
    parent = self()

    lines =
      for {k, v} <- auth(opts[:token]) ++ Keyword.get(opts, :headers, []),
          do: [k, ": ", v, "\r\n"]

    pid =
      spawn_link(fn ->
        {:ok, socket} = connect(rt, via)

        :ok =
          :gen_tcp.send(socket, ["GET /v1/events HTTP/1.1\r\nhost: localhost\r\n", lines, "\r\n"])

        send(parent, {:sse_open, ref})
        sse(socket, parent, ref, :head, "")
      end)

    receive(do: ({:sse_open, ^ref} -> :ok), after: (5_000 -> flunk("event stream did not open")))

    receive do
      {:sse_status, ^ref, 200} -> :ok
      {:sse_status, ^ref, status} -> flunk("GET /v1/events on #{inspect(via)} answered #{status}")
    after
      5_000 -> flunk("GET /v1/events did not answer")
    end

    {pid, ref}
  end

  defp sse(socket, parent, ref, phase, buffer) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, data} ->
        {phase, buffer} = sse_data(parent, ref, phase, buffer <> data)
        sse(socket, parent, ref, phase, buffer)

      {:error, _} ->
        send(parent, {:sse_closed, ref})
    end
  end

  defp sse_data(parent, ref, :head, buffer) do
    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [head, rest] ->
        [_, status | _] = String.split(head, " ", parts: 3)
        send(parent, {:sse_status, ref, String.to_integer(status)})
        sse_data(parent, ref, {:body, ""}, rest)

      [_] ->
        {:head, buffer}
    end
  end

  # The last chunk ends the stream (the server's answer is over; HTTP/1.1 keeps the
  # connection open after it).
  defp sse_data(parent, ref, {:body, _text}, "0\r\n\r\n" <> _) do
    send(parent, {:sse_closed, ref})
    {:ended, ""}
  end

  defp sse_data(_parent, _ref, :ended, _buffer), do: {:ended, ""}

  defp sse_data(parent, ref, {:body, text}, buffer) do
    with [size, rest] <- String.split(buffer, "\r\n", parts: 2),
         {n, _} <- Integer.parse(size, 16),
         true <- byte_size(rest) >= n + 2 do
      text = text <> binary_part(rest, 0, n)
      buffer = binary_part(rest, n + 2, byte_size(rest) - n - 2)
      {frames, [text]} = Enum.split(String.split(text, "\n\n"), -1)
      for frame <- frames, frame != "", do: send(parent, {:sse, ref, frame(frame)})
      sse_data(parent, ref, {:body, text}, buffer)
    else
      _ -> {{:body, text}, buffer}
    end
  end

  defp frame(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, frame ->
      case String.split(line, ":", parts: 2) do
        ["event", v] -> Map.put(frame, "event", String.trim(v))
        ["id", v] -> Map.put(frame, "id", String.to_integer(String.trim(v)))
        ["data", v] -> Map.put(frame, "data", JSON.decode!(String.trim(v)))
        _ -> frame
      end
    end)
  end

  @doc "The first frame of `event` matching `check` within `timeout`, skipping the others."
  def await_frame({_pid, ref}, event, check \\ fn _ -> true end, timeout \\ @wait) do
    deadline = System.monotonic_time(:millisecond) + timeout
    next_frame(ref, event, check, deadline, [])
  end

  defp next_frame(ref, event, check, deadline, seen) do
    receive do
      {:sse, ^ref, %{"event" => ^event} = frame} ->
        if check.(frame), do: frame, else: next_frame(ref, event, check, deadline, [frame | seen])

      {:sse, ^ref, frame} ->
        next_frame(ref, event, check, deadline, [frame | seen])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("no #{event} event; frames seen: #{inspect(Enum.reverse(seen))}")
    end
  end

  @doc "Every frame received so far on the stream (non-blocking), in order."
  def frames({_pid, ref}, acc \\ []) do
    receive do
      {:sse, ^ref, frame} -> frames({nil, ref}, [frame | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc "Whether the server ended the stream within `timeout`."
  def closed?({_pid, ref}, timeout) do
    receive do
      {:sse_closed, ^ref} -> true
    after
      timeout -> false
    end
  end

  def close({pid, _ref}) do
    Process.unlink(pid)
    Process.exit(pid, :kill)
  end

  ## The TLS stand-in for `tailscale serve --https=<P> http://127.0.0.1:<P>`

  defmodule Serve do
    @moduledoc """
    TLS ends here (an in-test CA, a certificate for `localhost`), and each connection is
    piped to `127.0.0.1:<backend>` as it is; when nothing listens there it answers 502, as
    `tailscale serve` does with its backend down. Options: `pki:` (another stand-in's, so
    both are trusted alike; default a fresh one) and `redirect: {status, location}` (answer
    every request with that redirect instead of piping it).
    """

    def start!(backend, opts \\ []) do
      {:ok, _} = Application.ensure_all_started(:ssl)
      pki = Keyword.get_lazy(opts, :pki, &pki/0)
      redirect = Keyword.get(opts, :redirect)
      parent = self()

      pid =
        spawn(fn ->
          {:ok, listen} =
            :ssl.listen(
              0,
              [ip: {127, 0, 0, 1}, reuseaddr: true, active: false, mode: :binary] ++
                pki.server
            )

          {:ok, {_, port}} = :ssl.sockname(listen)
          :persistent_term.put({__MODULE__, self()}, backend)
          :persistent_term.put({__MODULE__, self(), :redirect}, redirect)
          send(parent, {:serve, self(), port})
          accept(listen)
        end)

      port = receive(do: ({:serve, ^pid, port} -> port), after: (10_000 -> raise "no serve"))

      dir =
        Path.join(
          RuntimeBackendTcpE2E.build().dir,
          "serve-ca-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      ca = Path.join(dir, "ca.pem")

      File.write!(
        ca,
        :public_key.pem_encode(for der <- pki.cacerts, do: {:Certificate, der, :not_encrypted})
      )

      %{pid: pid, port: port, pki: pki, cacerts: pki.cacerts, cacertfile: ca}
    end

    def stop(%{pid: pid}), do: Process.exit(pid, :kill)

    @doc "Points the stand-in at another backend port (one where nothing listens: 502)."
    def retarget(%{pid: pid}, backend), do: :persistent_term.put({__MODULE__, pid}, backend)

    @doc "A test CA and a `localhost` server certificate it signed (RSA: OTP's TLS 1.3 needs it here)."
    def pki do
      key = {:rsa, 2048, 65_537}
      san = {:Extension, {2, 5, 29, 17}, false, [dNSName: ~c"localhost"]}

      data =
        :public_key.pkix_test_data(%{
          server_chain: %{
            root: [key: key],
            intermediates: [[key: key]],
            peer: [key: key, extensions: [san]]
          },
          client_chain: %{root: [key: key], intermediates: [[key: key]], peer: [key: key]}
        })

      %{
        server: Keyword.take(data.server_config, [:cert, :key, :cacerts]),
        cacerts: Keyword.fetch!(data.client_config, :cacerts)
      }
    end

    defp accept(listen) do
      {:ok, tls} = :ssl.transport_accept(listen)
      backend = :persistent_term.get({__MODULE__, self()})

      backend =
        case :persistent_term.get({__MODULE__, self(), :redirect}) do
          nil -> backend
          redirect -> {:redirect, redirect}
        end

      pid = spawn(fn -> receive(do: (:go -> serve(tls, backend))) end)
      :ok = :ssl.controlling_process(tls, pid)
      send(pid, :go)
      accept(listen)
    end

    defp serve(tls, {:redirect, {status, location}}) do
      with {:ok, tls} <- :ssl.handshake(tls, 10_000) do
        _ = :ssl.recv(tls, 0, 5_000)

        :ssl.send(
          tls,
          "HTTP/1.1 #{status} Redirect\r\nlocation: #{location}\r\ncontent-length: 0\r\n" <>
            "connection: close\r\n\r\n"
        )

        :ssl.close(tls)
      end
    end

    defp serve(tls, backend) do
      with {:ok, tls} <- :ssl.handshake(tls, 10_000) do
        case :gen_tcp.connect({127, 0, 0, 1}, backend, [:binary, active: true], 5_000) do
          {:ok, tcp} ->
            :ok = :ssl.setopts(tls, active: true)
            pipe(tls, tcp)

          {:error, _} ->
            _ = :ssl.recv(tls, 0, 5_000)
            body = "Bad Gateway"

            :ssl.send(
              tls,
              "HTTP/1.1 502 Bad Gateway\r\ncontent-type: text/plain\r\ncontent-length: " <>
                "#{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
            )

            :ssl.close(tls)
        end
      end
    end

    defp pipe(tls, tcp) do
      receive do
        {:ssl, ^tls, data} ->
          :gen_tcp.send(tcp, data)
          pipe(tls, tcp)

        {:tcp, ^tcp, data} ->
          :ssl.send(tls, data)
          pipe(tls, tcp)

        {closed, _} when closed in [:ssl_closed, :tcp_closed] ->
          :ssl.close(tls)
          :gen_tcp.close(tcp)
      end
    end

    @doc "One request over verified TLS to the stand-in, as a client of `serve --https` does."
    def request(serve, method, path, opts \\ []) do
      cacerts = Keyword.get(opts, :cacerts, serve.cacerts)

      tls_opts = [
        verify: :verify_peer,
        cacerts: cacerts,
        server_name_indication: ~c"localhost",
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)],
        active: false,
        mode: :binary
      ]

      with {:ok, tls} <- :ssl.connect(~c"localhost", serve.port, tls_opts, 10_000) do
        auth = if t = opts[:token], do: ["authorization: Bearer ", t, "\r\n"], else: []

        :ok =
          :ssl.send(tls, [
            method,
            " ",
            path,
            " HTTP/1.1\r\nhost: localhost\r\nconnection: close\r\ncontent-length: 0\r\n",
            auth,
            "\r\n"
          ])

        raw = recv_all(tls, "")
        :ssl.close(tls)
        RuntimeBackendTcpE2E.parse(raw)
      end
    end

    defp recv_all(tls, acc) do
      case :ssl.recv(tls, 0, 30_000) do
        {:ok, data} -> recv_all(tls, acc <> data)
        {:error, _} -> acc
      end
    end
  end

  ## Waiting

  def await(fun, timeout \\ @wait, message \\ fn -> "condition not met in time" end) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, deadline, message)
  end

  defp do_await(fun, deadline, message) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk(message.())
        Process.sleep(50)
        do_await(fun, deadline, message)
    end
  end
end

RuntimeBackendTcpE2E.build!()

defmodule RuntimeBackendTcpE2E.TcpTest do
  @moduledoc """
  One Runtime with a clients.json, driven over 127.0.0.1:<port> and backend.sock with
  plain HTTP. Each test starts and ends with the Runtime idle and the file as written here.
  """
  use ExUnit.Case, async: false
  import RuntimeBackendTcpE2E
  alias RuntimeBackendTcpE2E.Serve

  @tcp_rights ["submit", "cancel", "read", "read_all"]

  setup_all do
    t = Map.new(~w(writer reader all off revocable narrowing)a, &{&1, token()})
    rt = runtime!(clients: entries(t))
    on_exit(fn -> cleanup(rt) end)
    %{rt: rt, t: t}
  end

  setup %{rt: rt, t: t} do
    quiesce(rt, t)

    on_exit(fn ->
      write_clients!(rt.home, rt.port, entries(t))
      quiesce(rt, t)
    end)

    :ok
  end

  defp entries(t, changes \\ %{}) do
    base = %{
      writer: ["submit", "cancel", "read"],
      reader: ["read"],
      all: @tcp_rights,
      off: @tcp_rights,
      revocable: ["read"],
      narrowing: ["submit", "read"]
    }

    for {name, rights} <- Map.merge(base, changes) do
      extra = if name in [:off], do: %{"disabled" => true}, else: %{}

      {rights, extra} =
        case rights do
          {:disabled, rights} -> {rights, %{"disabled" => true}}
          rights -> {rights, extra}
        end

      entry(Atom.to_string(name), t[name], rights, extra)
    end
  end

  # No token and no hash of one ever reaches the service's log (P2: never logged or echoed).
  defp refute_secrets_logged(rt, t) do
    text = log(rt)

    for {name, token} <- t do
      refute text =~ token, "the #{name} token is in #{rt.log}"
      refute text =~ sha256(token), "the #{name} token's hash is in #{rt.log}"
    end
  end

  test "submit, get, cancel and events over TCP; the work's client is token:writer",
       %{rt: rt, t: t} do
    events = subscribe(rt, :tcp, token: t.writer)
    response = submit(rt, :tcp, "hang tcp-flow", token: t.writer, key: "tcp-flow")
    assert response.status == 201, response.body
    work = response.json
    id = work["work_id"]
    assert work["client"] == "token:writer"
    assert work["client_key"] == "tcp-flow"
    assert header(response, "location") == "/v1/work/#{id}"

    got = get(rt, :tcp, id, token: t.writer)
    assert got.status == 200
    assert got.json["work_id"] == id and got.json["client"] == "token:writer"

    await_launch(rt, work)
    cancelled = cancel(rt, :tcp, id, "graceful", token: t.writer)
    assert cancelled.status == 202, cancelled.body
    assert cancelled.json["state"] == "cancelling"
    assert await_state(rt, id, "cancelled")["client"] == "token:writer"

    frame =
      await_frame(
        events,
        "work",
        &(&1["data"]["work_id"] == id and &1["data"]["state"] == "cancelled")
      )

    assert frame["id"] == frame["data"]["sequence"]
    close(events)
    refute_secrets_logged(rt, t)
  end

  test "missing, unknown, malformed, bare and disabled tokens get the same 401", %{rt: rt, t: t} do
    refusals = [
      none: [],
      unknown: [token: token()],
      disabled: [token: t.off],
      bare: [headers: [{"authorization", t.writer}]],
      basic: [headers: [{"authorization", "Basic " <> Base.encode64("writer:" <> t.writer)}]],
      malformed: [headers: [{"authorization", "Bearer not a token!"}]],
      lowercase_scheme: [headers: [{"authorization", "bearer " <> t.writer}]]
    ]

    answers =
      for {name, opts} <- refusals,
          {method, path, body} <- [
            {"GET", "/v1/capacity", nil},
            {"POST", "/v1/work", work_request(rt, "complete never-401")},
            {"GET", "/v1/events", nil}
          ] do
        opts = if body, do: [body: body] ++ opts, else: opts
        response = request(rt, :tcp, method, path, opts)
        assert response.status == 401, "#{name} #{method} #{path}: #{response.status}"
        assert header(response, "www-authenticate") == "Bearer", "#{name}"
        assert header(response, "content-type") =~ "application/problem+json"
        assert response.json["type"] == "unauthenticated"
        response.body
      end

    assert [_one] = Enum.uniq(answers), "the 401 bodies differ: #{inspect(Enum.uniq(answers))}"
    assert launches(rt) |> Enum.filter(&(&1["goal"] == "complete never-401")) == []

    # A valid token on the same listener is served (the refusals above are the token's).
    assert request(rt, :tcp, "GET", "/v1/capacity", token: t.reader).status == 200
    refute_secrets_logged(rt, t)
  end

  test "a read-only token cannot submit or cancel: 403 not-permitted", %{rt: rt, t: t} do
    refused = submit(rt, :tcp, "complete reader-submit", token: t.reader)
    assert refused.status == 403, refused.body
    assert refused.json["type"] == "not-permitted"

    work = submit!(rt, :tcp, "hang reader-cancel", token: t.writer)
    await_launch(rt, work)
    # The writer's own work is not the reader's: no read_all, so it is not found to it at
    # all; the cancel right is still checked first.
    no = cancel(rt, :tcp, work["work_id"], "force", token: t.reader)
    assert no.status in [403, 404], no.body
    assert get(rt, :sock, work["work_id"]).json["state"] == "running"
    assert launches(rt) |> Enum.filter(&(&1["goal"] == "complete reader-submit")) == []
  end

  test "without read_all a token sees neither socket-submitted work nor its events (D31)",
       %{rt: rt, t: t} do
    reader_events = subscribe(rt, :tcp, token: t.reader)
    writer_events = subscribe(rt, :tcp, token: t.writer)
    all_events = subscribe(rt, :tcp, token: t.all)

    local = submit!(rt, :sock, "complete d31-socket")
    id = local["work_id"]
    assert local["client"] =~ ~r/^local:/
    await_state(rt, id, "completed")

    for {who, token} <- [reader: t.reader, writer: t.writer] do
      hidden = get(rt, :tcp, id, token: token)
      assert hidden.status == 404, "#{who}: #{hidden.status} #{hidden.body}"

      %{status: 200, json: %{"works" => works}} =
        request(rt, :tcp, "GET", "/v1/work", token: token)

      refute Enum.any?(works, &(&1["work_id"] == id)), "#{who} lists socket work"
    end

    seen = get(rt, :tcp, id, token: t.all)
    assert seen.status == 200 and seen.json["client"] == local["client"]

    # read_all sees the work's events to its end; then, after that frame, the others'
    # streams have had the same chance and carry none of them.
    await_frame(
      all_events,
      "work",
      &(&1["data"]["work_id"] == id and &1["data"]["state"] == "completed")
    )

    Process.sleep(500)

    for {who, events} <- [reader: reader_events, writer: writer_events] do
      leaked =
        for %{"event" => "work", "data" => %{"work_id" => ^id}} = f <- frames(events), do: f

      assert leaked == [], "#{who} received socket work events: #{inspect(leaked)}"
    end

    Enum.each([reader_events, writer_events, all_events], &close/1)
  end

  test "Origin is refused with 403 origin-refused before auth, whatever its value",
       %{rt: rt, t: t} do
    for origin <- ["http://localhost", "null", "https://evil.example", ""],
        opts <- [[token: t.writer], [token: token()], []] do
      response =
        request(
          rt,
          :tcp,
          "POST",
          "/v1/work",
          [body: work_request(rt, "complete origin"), headers: [{"origin", origin}]] ++ opts
        )

      assert response.status == 403,
             "Origin #{inspect(origin)} #{inspect(opts)}: #{response.body}"

      assert header(response, "content-type") =~ "application/problem+json"
      assert response.json["type"] == "origin-refused"
    end

    assert launches(rt) |> Enum.filter(&(&1["goal"] == "complete origin")) == []
    # The socket is not the hardened listener: S1's behaviour is unchanged there.
    assert request(rt, :sock, "GET", "/v1/capacity", headers: [{"origin", "null"}]).status == 200
  end

  test "ETag and 304 on GET /v1/work/{id}, Idempotent-Replayed on a replay, over TCP and socket",
       %{rt: rt, t: t} do
    first = submit(rt, :tcp, "complete etag", token: t.writer, key: "etag-1")
    assert first.status == 201
    assert headers(first, "idempotent-replayed") == [], "a fresh submit is never marked replayed"
    id = first.json["work_id"]

    done =
      await(fn ->
        w = get(rt, :sock, id).json
        terminal?(w) and current(w)["quiescent"] and w
      end)

    found = get(rt, :tcp, id, token: t.writer)
    assert found.status == 200
    tag = header(found, "etag")
    assert tag == ~s("#{done["revision"]}"), "ETag is the work's revision"

    for inm <- [tag, ~s("0", #{tag}), "*"] do
      same = get(rt, :tcp, id, token: t.writer, headers: [{"if-none-match", inm}])
      assert same.status == 304, "If-None-Match #{inm}: #{same.status}"
      assert same.body == ""
      assert header(same, "etag") == tag
    end

    stale = get(rt, :tcp, id, token: t.writer, headers: [{"if-none-match", ~s("0")}])
    assert stale.status == 200 and header(stale, "etag") == tag

    # One router: the socket answers the same.
    assert get(rt, :sock, id, headers: [{"if-none-match", tag}]).status == 304

    # Never 304 for a work that is not there; no tag on find_work or list_work.
    missing = get(rt, :tcp, "w-none", token: t.writer, headers: [{"if-none-match", "*"}])
    assert missing.status == 404 and header(missing, "etag") == nil

    find = request(rt, :tcp, "GET", "/v1/work?key=etag-1", token: t.writer)
    assert find.status == 200 and header(find, "etag") == nil

    again = submit(rt, :tcp, "complete etag", token: t.writer, key: "etag-1")
    assert again.status == 200
    assert again.json["work_id"] == id
    assert header(again, "idempotent-replayed") == "true"
    assert [_once] = Enum.filter(launches(rt), &(&1["goal"] == "complete etag"))
  end

  test "socket and TCP see the same work", %{rt: rt, t: t} do
    local = submit!(rt, :sock, "complete same-socket")
    remote = submit!(rt, :tcp, "complete same-tcp", token: t.writer)

    for work <- [local, remote], do: await_state(rt, work["work_id"], "completed")

    for work <- [local, remote] do
      over_sock = get(rt, :sock, work["work_id"]).json
      over_tcp = get(rt, :tcp, work["work_id"], token: t.all).json
      # The same work; only the paths on the Runtime's machine stay on the socket (D44).
      assert attempt_paths(over_sock) != []
      assert attempt_paths(over_tcp) == []
      assert without_paths(over_sock) == without_paths(over_tcp)
    end

    assert get(rt, :sock, remote["work_id"]).json["client"] == "token:writer"
    assert get(rt, :tcp, local["work_id"], token: t.all).json["client"] =~ ~r/^local:/
  end

  test "D44: a TCP token never names a path and is never shown one", %{rt: rt, t: t} do
    # Every TCP right (read_all included) and still no folder: refused before anything is
    # stored or launched.
    refused = submit(rt, :tcp, "complete d44-folder", token: t.all, workspace: :folder)
    assert refused.status == 403, refused.body
    assert refused.json["type"] == "not-permitted"
    # No refusal text reaches a TCP client (§3.2): the reason only.
    assert refused.json["reason"] == "not_permitted"
    refute Map.has_key?(refused.json, "detail"), refused.body
    refute refused.body =~ "choose_path"

    %{status: 200, json: %{"works" => works}} =
      request(rt, :tcp, "GET", "/v1/work", token: t.all)

    refute Enum.any?(works, &(&1["request"]["instructions"] == "complete d44-folder"))
    assert launches(rt) |> Enum.filter(&(&1["goal"] == "complete d44-folder")) == []

    # The socket names its folder; that path and its resume point's are the socket's alone.
    local = submit!(rt, :sock, "complete d44-socket")
    await_state(rt, local["work_id"], "completed")
    over_sock = get(rt, :sock, local["work_id"]).json
    over_tcp = get(rt, :tcp, local["work_id"], token: t.all).json
    assert [_ | _] = attempt_paths(over_sock)
    assert attempt_paths(over_tcp) == []
    folder = over_sock["request"]["workspace"]["path"]
    assert is_binary(folder)
    assert over_tcp["request"]["workspace"] == %{"kind" => "folder", "permissions" => "read-only"}
    refute JSON.encode!(over_tcp) =~ folder

    %{json: %{"works" => listed}} = request(rt, :tcp, "GET", "/v1/work", token: t.all)

    for work <- listed,
        do: refute(Map.has_key?(work["request"]["workspace"], "path"), work["work_id"])

    # A repository work submitted over TCP: the Runtime chose its folder, and TCP never sees it.
    remote = submit!(rt, :tcp, "complete d44-repository", token: t.all)
    await_state(rt, remote["work_id"], "completed")
    assert [_ | _] = attempt_paths(get(rt, :sock, remote["work_id"]).json)
    assert attempt_paths(get(rt, :tcp, remote["work_id"], token: t.all).json) == []
  end

  test "D44: a TCP token names a repository only as https on a listed host; the socket as before",
       %{rt: rt, t: t} do
    # Designer decision 2026-11-17: policy.json names no repository_hosts, so github.com only.
    listed = work_request(rt, "complete d44-url")["workspace"]
    source = Path.join([rt.run, "src", Path.basename(listed["url"])])
    assert File.dir?(source)

    for url <- [
          source,
          "file://" <> source,
          "git@github.com:s3-e2e/d44-url.git",
          "https://example.com/s3-e2e/d44-url.git"
        ] do
      refused =
        submit(rt, :tcp, "complete d44-url",
          token: t.all,
          extra: %{"workspace" => Map.put(listed, "url", url)}
        )

      assert refused.status == 403, "#{url}: #{refused.body}"
      assert refused.json["type"] == "not-permitted"
      assert refused.json["reason"] == "not_permitted"
      refute Map.has_key?(refused.json, "detail"), refused.body
    end

    %{status: 200, json: %{"works" => works}} =
      request(rt, :tcp, "GET", "/v1/work", token: t.all)

    refute Enum.any?(works, &(&1["request"]["instructions"] == "complete d44-url"))
    assert launches(rt) |> Enum.filter(&(&1["goal"] == "complete d44-url")) == []

    # The listed host is accepted over TCP and runs.
    remote = submit!(rt, :tcp, "complete d44-url", token: t.all)
    assert remote["request"]["workspace"]["url"] == listed["url"]
    await_state(rt, remote["work_id"], "completed")

    # The socket (choose_path) still submits any URL; what the helper then does is unchanged.
    local =
      submit!(rt, :sock, "complete d44-url-socket",
        workspace: :repository,
        extra: %{"workspace" => Map.put(listed, "url", source)}
      )

    assert local["request"]["workspace"]["url"] == source
    await(fn -> terminal?(get(rt, :sock, local["work_id"]).json) end)
  end

  test "read_all reads another client's work over TCP, but never cancels or retries it",
       %{rt: rt, t: t} do
    work = submit!(rt, :tcp, "hang owned", token: t.writer)
    id = work["work_id"]
    await_launch(rt, work)

    assert get(rt, :tcp, id, token: t.all).status == 200

    for {method, path, body} <- [
          {"POST", "/v1/work/#{id}/cancel", %{"mode" => "force"}},
          {"POST", "/v1/work/#{id}/attempts", %{}}
        ] do
      no = request(rt, :tcp, method, path, body: body, token: t.all)
      assert no.status == 403, "#{path}: #{no.status} #{no.body}"
      assert no.json["type"] == "not-permitted" and no.json["reason"] == "not_permitted"
      refute Map.has_key?(no.json, "detail")
    end

    # Untouched: one attempt, still running; its owner cancels it.
    assert [%{"state" => "running"}] = get(rt, :sock, id).json["attempts"]
    assert cancel(rt, :tcp, id, "force", token: t.writer).status == 202
    await_state(rt, id, "cancelled")
  end

  test "a body of 1 MiB + 1 byte is 400 invalid on TCP", %{rt: rt, t: t} do
    body = ~s({"title":") <> String.duplicate("a", 1_048_577) <> ~s("})

    response = request(rt, :tcp, "POST", "/v1/work", body: body, token: t.writer)
    assert response.status == 400, "#{response.status}"
    assert response.json["type"] == "invalid"
  end

  test "the TCP listener answers on 127.0.0.1 only, never on this machine's other addresses",
       %{rt: rt, t: t} do
    assert request(rt, :tcp, "GET", "/v1/capacity", token: t.reader).status == 200
    {:ok, interfaces} = :inet.getifaddrs()

    addresses =
      for {_name, opts} <- interfaces,
          {:addr, address} <- opts,
          tuple_size(address) == 4 and elem(address, 0) != 127,
          do: address

    if addresses == [],
      do:
        IO.puts("runtime_backend_tcp: no non-loopback IPv4 address here; only 127.0.0.1 checked")

    for address <- addresses do
      assert match?({:error, :econnrefused}, connect(rt, {:tcp, address, rt.port})),
             "127.0.0.1:#{rt.port} also answers on #{:inet.ntoa(address)}"
    end
  end

  test "revoking or narrowing a token applies on the next request; open streams end within a heartbeat",
       %{rt: rt, t: t} do
    assert request(rt, :tcp, "GET", "/v1/capacity", token: t.revocable).status == 200
    revoked_stream = subscribe(rt, :tcp, token: t.revocable)
    narrowed_stream = subscribe(rt, :tcp, token: t.narrowing)
    kept_stream = subscribe(rt, :tcp, token: t.reader)

    write_clients!(
      rt.home,
      rt.port,
      entries(t, %{revocable: {:disabled, ["read"]}, narrowing: ["read"]})
    )

    # The next request: no wait, no restart, no signal.
    gone = request(rt, :tcp, "GET", "/v1/capacity", token: t.revocable)
    assert gone.status == 401 and gone.json["type"] == "unauthenticated"

    narrowed = submit(rt, :tcp, "complete narrowed", token: t.narrowing)
    assert narrowed.status == 403 and narrowed.json["type"] == "not-permitted"
    assert request(rt, :tcp, "GET", "/v1/capacity", token: t.narrowing).status == 200

    assert closed?(revoked_stream, heartbeat_wait()), "the revoked token's stream is still open"
    assert closed?(narrowed_stream, 2_000), "the narrowed token's stream is still open"
    refute closed?(kept_stream, 0), "an unchanged token's stream ended"
    close(kept_stream)

    # Removing the file: every TCP request is refused, and its log line names no secret.
    File.rm!(Path.join(rt.home, "clients.json"))
    assert request(rt, :tcp, "GET", "/v1/capacity", token: t.reader).status == 401
    assert request(rt, :sock, "GET", "/v1/capacity").status == 200
    refute_secrets_logged(rt, t)
  end

  test "an edit that changes no token's rights (reordered, another entry added) keeps open streams",
       %{rt: rt, t: t} do
    stream = subscribe(rt, :tcp, token: t.narrowing)
    newcomer = token()

    write_clients!(
      rt.home,
      rt.port,
      entries(t, %{narrowing: ["read", "submit"]}) ++ [entry("newcomer", newcomer, ["read"])]
    )

    # Its rights are the same set: the heartbeat's re-check finds nothing changed (B3).
    refute closed?(stream, heartbeat_wait()), "a stream ended though its rights did not change"
    assert request(rt, :tcp, "GET", "/v1/capacity", token: newcomer).status == 200
    close(stream)
  end

  test "through a TLS stand-in for `tailscale serve`: verified TLS, Bearer kept, 502 when down",
       %{rt: rt, t: t} do
    serve = Serve.start!(rt.port)
    on_exit(fn -> Serve.stop(serve) end)

    assert {:ok, ok} = Serve.request(serve, "GET", "/v1/capacity", token: t.reader)
    assert ok.status == 200 and is_map(ok.json["slots"])

    assert {:ok, no} = Serve.request(serve, "GET", "/v1/capacity")
    assert no.status == 401 and no.json["type"] == "unauthenticated"

    other = Serve.pki().cacerts
    assert {:error, {:tls_alert, _}} = Serve.request(serve, "GET", "/v1/capacity", cacerts: other)

    down = Serve.start!(free_port())
    on_exit(fn -> Serve.stop(down) end)
    assert {:ok, bad} = Serve.request(down, "GET", "/v1/capacity", token: t.reader)
    assert bad.status == 502
  end
end

defmodule RuntimeBackendTcpE2E.StartTest do
  @moduledoc "How host/service.exs starts the TCP listener, each on a Runtime of its own."
  use ExUnit.Case, async: false
  import RuntimeBackendTcpE2E

  test "no clients.json: nothing listens on the port; the socket serves as in S1" do
    rt = runtime!(clients: nil)
    on_exit(fn -> cleanup(rt) end)

    assert request(rt, :sock, "GET", "/v1/capacity").status == 200
    assert {:error, :econnrefused} = connect(rt, :tcp)
    refute log(rt) =~ "listening on loopback TCP"
  end

  test "a clients.json that is not mode 0600 stops the start, naming the mode" do
    secret = token()
    rt = runtime!(clients: [entry("core", secret, ["read"])], mode: 0o644, boot: :fails)
    on_exit(fn -> cleanup(rt) end)

    assert log(rt) =~ "Runtime backend not listening on loopback TCP"
    assert log(rt) =~ "0600"
    refute log(rt) =~ secret or log(rt) =~ sha256(secret)
    assert {:error, :econnrefused} = connect(rt, :tcp)
  end

  test "choose_slot in an entry makes the file invalid and stops the start" do
    secret = token()
    rt = runtime!(clients: [entry("core", secret, ["read", "choose_slot"])], boot: :fails)
    on_exit(fn -> cleanup(rt) end)

    assert log(rt) =~ "Runtime backend not listening on loopback TCP"
    refute log(rt) =~ secret or log(rt) =~ sha256(secret)
    assert {:error, :econnrefused} = connect(rt, :tcp)
  end
end

defmodule RuntimeBackendTcpE2E.RemoteTest do
  @moduledoc """
  S3 P6 end to end: `AtlasRuntime.Remote` in this VM → the fixtures' CONNECT proxy on
  localhost:1055 → the TLS serve stand-in → 127.0.0.1:<port> → the Runtime. Excluded until
  P6 is in the tree (see RuntimeBackendTcpE2E.RemoteSeam).
  """
  use ExUnit.Case, async: false
  import RuntimeBackendTcpE2E
  alias RuntimeBackendTcpE2E.{RemoteSeam, Serve}

  @moduletag :remote
  @proxy_port 1055

  setup_all do
    t = %{core: token(), reader: token()}

    clients = [
      entry("core", t.core, ["submit", "cancel", "read"]),
      entry("reader", t.reader, ["read"])
    ]

    rt = runtime!(clients: clients)
    serve = Serve.start!(rt.port)
    _proxy = RemoteSeam.proxy!(@proxy_port)
    RemoteSeam.start!("https://localhost:#{serve.port}", t.core, serve.cacertfile)

    on_exit(fn ->
      RemoteSeam.stop_proxy(RemoteSeam.current_proxy())
      Serve.stop(serve)
      cleanup(rt)
    end)

    %{rt: rt, t: t, serve: serve, clients: clients}
  end

  setup %{rt: rt, t: t, clients: clients} do
    quiesce(rt, t)
    on_exit(fn -> write_clients!(rt.home, rt.port, clients) end)
    :ok
  end

  # A repository workspace: the core never names a path on the mini (D44).
  defp request_input(rt, instructions, key) do
    workspace = work_request(rt, instructions)["workspace"]

    %{
      client_key: key,
      title: instructions,
      instructions: instructions,
      profile: "light_work",
      cost_class: :standard,
      workspace: %{
        kind: :repository,
        url: workspace["url"],
        branch: workspace["branch"],
        base: workspace["base"]
      }
    }
  end

  test "probe: one GET /v1/capacity through exactly one CONNECT; the token left the env",
       %{serve: serve} do
    proxy = RemoteSeam.current_proxy()
    before = length(RemoteSeam.connects(proxy))
    assert {:ok, capacity} = RemoteSeam.remote().probe()
    assert capacity.slots.total == 2
    assert Enum.drop(RemoteSeam.connects(proxy), before) == [{"localhost", serve.port}]
    assert System.get_env("ATLAS_RUNTIME_BACKEND_TOKEN") == nil
  end

  test "submit, get_work (ETag/304), replay, cancel and subscribe with resume",
       %{rt: rt, t: t} do
    r = RemoteSeam.remote()
    assert {:ok, events} = r.subscribe(%{}, [])
    input = request_input(rt, "hang remote-flow", "remote-flow")
    assert {:accepted, %{work: work}} = r.submit(input, [])
    assert work.client == "token:core"
    assert {:existing, %{work: %{work_id: id}}} = r.submit(input, [])
    assert id == work.work_id

    assert {:found, %{work: found}} = r.get_work(%{work_id: id}, [])
    assert :not_modified = r.get_work(%{work_id: id}, if_none_match: found.revision)

    await_launch(rt, get(rt, :sock, id).json)
    assert {:cancelling, %{work: _}} = r.cancel(%{work_id: id, mode: :graceful}, [])
    await_state(rt, id, "cancelled")

    seen =
      events
      |> Stream.filter(&match?({:work, %{work_id: ^id}}, &1))
      |> Enum.find(&match?({:work, %{state: :cancelled}}, &1))

    assert {:work, %{sequence: last}} = seen

    # Resume after an earlier event: the stream starts after it, with no reset.
    assert {:ok, resumed} = r.subscribe(%{from: last - 1}, [])
    assert {first_name, _} = Enum.at(resumed, 0)
    refute first_name == :reset

    # Another token without read_all does not see core's work.
    assert get(rt, :tcp, id, token: t.reader).status == 404
  end

  test "typed outcomes: not_found, unauthenticated, unreachable (stand-in 502, proxy down, CONNECT refused)",
       %{rt: rt, t: t, serve: serve, clients: clients} do
    r = RemoteSeam.remote()
    assert r.get_work(%{work_id: "w-none"}, []) in [:not_found, {:not_found, %{}}]

    write_clients!(rt.home, rt.port, [entry("reader", t.reader, ["read"])])
    assert {:error, :unauthenticated} = r.probe()
    write_clients!(rt.home, rt.port, clients)
    assert {:ok, _} = r.probe()

    # The serve stand-in with its backend down answers 502 (no problem type): unreachable.
    Serve.retarget(serve, free_port())
    assert {:error, :unreachable} = r.probe()
    Serve.retarget(serve, rt.port)
    assert {:ok, _} = r.probe()

    RemoteSeam.stop_proxy(RemoteSeam.current_proxy())
    assert {:error, :unreachable} = r.probe()
    refused = RemoteSeam.proxy!(@proxy_port, 403)
    assert {:error, :unreachable} = r.probe()
    RemoteSeam.stop_proxy(refused)
    _ = RemoteSeam.proxy!(@proxy_port)
    assert {:ok, _} = r.probe()
  end

  test "a man in the middle with another CA's certificate is unreachable, and the token stays",
       %{rt: rt, t: t, serve: serve} do
    r = RemoteSeam.remote()
    # The impostor pipes to the real Runtime: only the certificate check stops the request.
    impostor = Serve.start!(rt.port)
    RemoteSeam.stop_proxy(RemoteSeam.current_proxy())
    mitm = RemoteSeam.proxy!(@proxy_port, :ok, upstream: impostor.port)

    try do
      log =
        ExUnit.CaptureLog.capture_log(fn -> assert {:error, :unreachable} = r.probe() end)

      assert RemoteSeam.connects(mitm) == [{"localhost", serve.port}]
      refute log =~ t.core
    after
      RemoteSeam.stop_proxy(mitm)
      Serve.stop(impostor)
      RemoteSeam.proxy!(@proxy_port)
    end

    assert {:ok, _} = r.probe()
  end

  test "a redirect on the path is never followed: unreachable, and no other host is reached",
       %{rt: rt, serve: serve} do
    r = RemoteSeam.remote()
    # Another host that would answer (its certificate is trusted like the real one's).
    other = Serve.start!(rt.port, pki: serve.pki)
    location = "https://localhost:#{other.port}/v1/capacity"

    redirectors =
      for code <- [301, 302, 303, 307, 308],
          do: {code, Serve.start!(rt.port, pki: serve.pki, redirect: {code, location})}

    try do
      for {code, redirector} <- redirectors do
        RemoteSeam.stop_proxy(RemoteSeam.current_proxy())
        mitm = RemoteSeam.proxy!(@proxy_port, :ok, upstream: %{serve.port => redirector.port})

        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :unreachable} = r.probe(), "#{code}"
          assert {:error, :unreachable} = r.get_work(%{work_id: "w-none"}, []), "#{code}"
        end)

        assert Enum.uniq(RemoteSeam.connects(mitm)) == [{"localhost", serve.port}],
               "#{code}: a CONNECT to another host"
      end
    after
      RemoteSeam.stop_proxy(RemoteSeam.current_proxy())
      Enum.each([other | Keyword.values(redirectors)], &Serve.stop/1)
      RemoteSeam.proxy!(@proxy_port)
    end

    assert {:ok, _} = r.probe()
  end

  test "an http:// backend URL is refused at start: nothing is configured, nothing is sent",
       %{rt: rt, t: t, serve: serve} do
    r = RemoteSeam.remote()
    proxy = RemoteSeam.current_proxy()
    before = length(RemoteSeam.connects(proxy))

    try do
      # Plain HTTP straight to the TCP listener would work, were it allowed (§9: TLS only).
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, reason} =
                   RemoteSeam.restart!(%{
                     "ATLAS_RUNTIME_BACKEND_URL" => "http://localhost:#{rt.port}",
                     "ATLAS_RUNTIME_BACKEND_TOKEN" => t.core
                   })

          assert inspect(reason) =~ "invalid_config"
          assert inspect(reason) =~ "https://"
          assert {:error, :not_configured} = r.probe()
        end)

      assert System.get_env("ATLAS_RUNTIME_BACKEND_TOKEN") == nil
      assert length(RemoteSeam.connects(proxy)) == before
      refute log =~ t.core
      refute log(rt) =~ t.core
    after
      assert {:ok, _} =
               RemoteSeam.restart!(%{
                 "ATLAS_RUNTIME_BACKEND_URL" => "https://localhost:#{serve.port}",
                 "ATLAS_RUNTIME_BACKEND_TOKEN" => t.core
               })
    end

    assert {:ok, _} = r.probe()
  end

  test "the token appears in no log line, error term or process status", %{rt: rt, t: t} do
    r = RemoteSeam.remote()

    captured =
      ExUnit.CaptureLog.capture_log(fn ->
        _ = r.probe()
        _ = r.get_work(%{work_id: "w-none"}, [])
      end)

    refute captured =~ t.core
    refute log(rt) =~ t.core

    for pid <- Process.list(),
        {:dictionary, d} <- [Process.info(pid, :dictionary)],
        {module, _, _} <- [d[:"$initial_call"]],
        module |> Atom.to_string() |> String.starts_with?("Elixir.AtlasRuntime.Remote") do
      refute inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity) =~ t.core
    end
  end
end
