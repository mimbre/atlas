defmodule AtlasFlow.Runtime.HttpContractTest do
  @moduledoc """
  The contract test of Flow's Runtime client (plan 2026-11-17 §6 F1.1): `Client.Http` and
  `Link` against the Runtime's real backend, started here with only its work core and its
  loopback TCP listener (S3, `AtlasRuntime.Backend.TcpListener`) on a temporary
  `ATLAS_RUNTIME_HOME`, with a test `clients.json` and no `server.json`. The stub harness
  (`fake_native`, which never launches a provider) and the Runtime's workspace command
  (`ATLAS_RUNTIME_EXECUTABLE`) are built in `setup_all` with `go build`.

  Flow is a TCP client: its token's rights are `submit`, `cancel` and `read`, cut to the
  TCP ceiling, and it never holds `choose_path`. So it names no path on the Runtime's
  machine (D44): its work uses `repository` workspaces. Here every
  `https://github.com/flow-contract/<name>.git` is cloned from `<home>/src/<name>.git`
  through `insteadOf`, by a `codex sandbox` stand-in that runs Git (as S3's
  `integration/runtime_backend_tcp.exs` and the host's tests do). A `folder` workspace
  over TCP is refused `not_permitted`.

  This is the one Flow source that names the Runtime's modules: it starts the Runtime in
  the test (`atlas_runtime` is a test-only dependency). Flow's own code reaches the Runtime
  only over HTTP.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Runtime.{Config, Link}
  alias AtlasFlow.Runtime.Client.Http, as: C
  alias AtlasRuntime.Backend.TcpListener

  @token_env "ATLAS_FLOW_CONTRACT_TEST_TOKEN"
  @token "flow-contract-token"
  @rights [:submit, :cancel, :read]
  # The work's client as the TCP listener names it: "token:" and the clients.json entry.
  @client "token:flow"
  @wait 10_000
  # Repository workspaces (D44): every URL under here is cloned from <home>/src/<name>.git.
  @repositories "https://github.com/flow-contract/"

  setup_all do
    root = Path.expand("../../..", __DIR__)
    dir = Path.join(System.tmp_dir!(), "afc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    host = Path.join(dir, "atlas-runtime")
    fake = Path.join(dir, "fake-native")

    # As the Runtime's own tests do (atlas_runtime/test/test_helper.exs): the workspace
    # command is built from this tree, never taken from the developer's shell.
    go!(["build", "-o", host, "."], Path.join(root, "atlas_runtime/host"), "the Runtime host")

    go!(
      ["build", "-o", fake, "main.go"],
      Path.join(root, "atlas_runtime/test/support/fake_native"),
      "the stub harness"
    )

    previous = System.get_env("ATLAS_RUNTIME_EXECUTABLE")
    System.put_env("ATLAS_RUNTIME_EXECUTABLE", host)

    on_exit(fn ->
      if previous,
        do: System.put_env("ATLAS_RUNTIME_EXECUTABLE", previous),
        else: System.delete_env("ATLAS_RUNTIME_EXECUTABLE")

      File.rm_rf!(dir)
    end)

    %{fake: fake}
  end

  setup %{fake: fake} = context do
    home = Path.join(System.tmp_dir!(), "afr-#{System.unique_integer([:positive])}")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    for dir <- ["workspace", "src", "git-home"], do: File.mkdir_p!(Path.join(home, dir))

    for tool <- ["git", "mkfifo"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    sources = sh_quote("url.file://#{Path.join(home, "src")}/.insteadOf=#{@repositories}")

    for harness <- ["codex", "claude"] do
      script = Path.join(bin, harness)

      # As Codex's sandbox prefix (managed repository preparation, D44), run Git in -C over a
      # local transport; otherwise act as the harness.
      File.write!(script, """
      #!/bin/sh
      if [ "$1" = sandbox ]; then
        while [ "$1" != -C ]; do shift; done
        cd "$2" || exit 1
        while [ "$1" != -- ]; do shift; done
        shift 2
        exec git -c #{sources} "$@"
      fi
      exec #{sh_quote(fake)} work #{sh_quote(home)} "$0" "$@"
      """)

      File.chmod!(script, 0o700)
    end

    names = ["PATH", "HOME", "CODEX_HOME", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"]

    previous =
      for name <- names ++ ["ATLAS_RUNTIME_HOME", @token_env], do: {name, System.get_env(name)}

    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    # The Runtime passes HOME (not GIT_CONFIG_GLOBAL) on to the host, whose repository
    # preparation runs Git: a HOME of the test's own, so no user configuration is read.
    System.put_env("HOME", Path.join(home, "git-home"))
    System.put_env("CODEX_HOME", Path.join(home, "codex-home"))
    System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
    System.put_env("GIT_CONFIG_NOSYSTEM", "1")
    System.put_env("ATLAS_RUNTIME_HOME", home)
    System.put_env(@token_env, @token)

    File.write!(
      Path.join(home, "policy.json"),
      JSON.encode!(%{
        "version" => 1,
        "slots" => ["s1"],
        "buffer_size" => 1,
        "profiles" => %{
          "deep_coding" => %{
            "permissions" => [
              "read-only",
              "workspace-write",
              "materialized-folder",
              "dedicated-repository"
            ],
            "cost_classes" => ["standard"],
            "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
          }
        }
      })
    )

    # As the runbook writes it (host/README.md): the token's hash only, mode 0600. Flow's
    # rights never include choose_path (D44), nor could they: the TCP ceiling has none.
    clients = Path.join(home, "clients.json")

    File.write!(
      clients,
      JSON.encode!(%{
        "version" => 1,
        "listen" => %{"port" => free_port()},
        "clients" => [
          %{
            "name" => "flow",
            "token_sha256" => Base.encode16(:crypto.hash(:sha256, @token), case: :lower),
            "rights" => Enum.map(@rights, &Atom.to_string/1)
          }
        ]
      })
    )

    File.chmod!(clients, 0o600)

    runtime = %{
      home: home,
      # A test's own `@tag work:` options win over these.
      work: Keyword.merge([heartbeat_ms: 100, cancel_grace_ms: 300], Map.get(context, :work, []))
    }

    start_runtime(runtime)
    port = listen(home)

    on_exit(fn ->
      stop_runtime()

      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(home)
    end)

    machinery = %Config{name: "test", url: "http://127.0.0.1:#{port}", token_env: @token_env}
    %{runtime: runtime, port: port, m: machinery, home: home}
  end

  defp go!(args, cd, what) do
    case System.cmd("go", args, cd: cd, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "building #{what} failed:\n#{output}"
    end
  end

  ## The Runtime, as the test runs it

  defp start_runtime(%{home: home, work: options}) do
    File.rm(Path.join(home, "runtime.sock"))
    File.rm(Path.join(home, "read.sock"))
    {:ok, service} = GenServer.start(AtlasRuntime.Service, {home, nil, [], []})
    {:ok, work} = AtlasRuntime.Work.start_link(home, Keyword.put(options, :service, service))
    Process.unlink(work)
    :ok
  end

  # As a SIGKILL of the Runtime would: the helpers lose their parent and end their groups.
  defp stop_runtime do
    stop_listener()

    for name <- [AtlasRuntime.Work.Server], pid = GenServer.whereis(name), do: kill(pid)

    for pid <- Process.list(),
        {:dictionary, dictionary} <- [Process.info(pid, :dictionary)],
        dictionary[:"$initial_call"] in [
          {AtlasRuntime.Service, :init, 1},
          {AtlasRuntime.Agent.Native, :init, 1}
        ],
        do: kill(pid)

    :ok
  end

  # The Runtime's TCP listener, as host/service.exs starts it (TcpListener.serve!/2): on
  # the port clients.json names, so a listener started again is on the same port.
  defp listen(home) do
    {:ok, pid} = TcpListener.start_link(home: home, router: AtlasRuntime.Backend.Rest)
    Process.unlink(pid)
    Process.put(:listener, pid)
    {{127, 0, 0, 1}, port} = TcpListener.address(pid)
    port
  end

  defp stop_listener do
    case Process.delete(:listener) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp sh_quote(word), do: "'" <> String.replace(word, "'", "'\\''") <> "'"

  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^monitor, :process, ^pid, _} -> :ok
    after
      5_000 -> flunk("#{inspect(pid)} did not stop")
    end
  end

  ## Requests and waiting

  # A request in a repository of its own, named by its instructions: the same instructions
  # are the same request. Flow passes the request through and names no path (D44); the
  # Runtime chooses the folder. The source is made once, with an empty develop.
  defp request(home, instructions) do
    name = Base.encode16(:crypto.hash(:md5, instructions), case: :lower)
    source = Path.join([home, "src", name <> ".git"])

    unless File.dir?(source) do
      git!(home, ["init", "-q", "-b", "develop", source])
      git!(source, ["commit", "--allow-empty", "-qm", "base"])
    end

    %{
      title: instructions,
      instructions: instructions,
      profile: "deep_coding",
      cost_class: "standard",
      workspace: %{
        kind: "repository",
        url: @repositories <> name <> ".git",
        branch: "task/" <> name,
        base: "develop"
      }
    }
  end

  # A folder on the Runtime's machine: only a client holding choose_path names one (D44).
  defp folder_request(home, instructions) do
    folder = Path.join([home, "workspace", Base.encode16(:crypto.hash(:md5, instructions))])
    File.mkdir_p!(folder)

    %{
      title: instructions,
      instructions: instructions,
      profile: "deep_coding",
      cost_class: "standard",
      workspace: %{kind: "folder", path: folder, permissions: "read-only"}
    }
  end

  defp git!(cd, args) do
    identity = ["-c", "user.name=flow-contract", "-c", "user.email=flow@example.invalid"]
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_NOSYSTEM", "1"}]

    case System.cmd("git", identity ++ args, cd: cd, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, _} -> raise "git #{Enum.join(args, " ")} failed:\n#{output}"
    end
  end

  defp link!(m, options \\ []) do
    pid =
      start_supervised!(
        {Link, [machinery: m, notify: self(), backoff: {50, 200}, idle_ms: 2_000] ++ options}
      )

    await(fn -> Link.info(pid).connected end)
    pid
  end

  defp await(fun, deadline \\ System.monotonic_time(:millisecond) + @wait) do
    case fun.() do
      value when value not in [nil, false] ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline, do: flunk("condition not met in time")
        Process.sleep(20)
        await(fun, deadline)
    end
  end

  defp state(m, work_id, state),
    do: await(fn -> match?({:found, %{"state" => ^state}}, C.get_work(m, work_id)) end)

  defp launches(home) do
    case File.read(Path.join(home, "work-launches.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  # The work snapshot of `work_id` the link sent, once one in `state` arrived.
  defp changed(work_id, state, timeout \\ @wait) do
    receive do
      {:work_changed, %{"work_id" => ^work_id, "state" => ^state} = work} -> work
    after
      timeout -> flunk("no {:work_changed, #{work_id} #{state}} received")
    end
  end

  defp flush_capacity do
    receive do
      {:capacity, _} -> flush_capacity()
    after
      0 -> :ok
    end
  end

  ## Cases (plan §6 F1.1)

  test "idempotent resubmit: the task key is the Idempotency-Key; the same key is the same work",
       %{m: m, home: home} do
    key = "TK-alpha-1"
    assert {:accepted, work} = C.submit(m, key, request(home, "complete keyed"))
    assert work["client_key"] == key
    assert work["client"] == @client
    assert work["idempotency_key"] == key

    # Sent again (as after a transport error): the same work, not a second one.
    assert {:existing, again} = C.submit(m, key, request(home, "complete keyed"))
    assert again["work_id"] == work["work_id"]

    # The key is the only one: a client_key in the request does not replace it.
    assert {:existing, %{"work_id" => id}} =
             C.submit(m, key, Map.put(request(home, "complete keyed"), :client_key, "other"))

    assert id == work["work_id"]

    assert {:found, %{"work_id" => ^id}} = C.find_work(m, key)
    assert {:refused, :conflict} = C.submit(m, key, request(home, "complete something else"))

    state(m, id, "completed")
    assert {:found, %{"revision" => revision, "attempts" => [_one]}} = C.get_work(m, id)
    assert is_integer(revision)
    assert Enum.count(launches(home), &(&1["goal"] == "complete keyed")) == 1
  end

  @tag work: [heartbeat_ms: 60_000]
  test "503 at_capacity with Retry-After, then the capacity_available event as {:capacity, c}",
       %{m: m, home: home} do
    link!(m)
    assert {:accepted, running} = C.submit(m, "TK-cap-1", request(home, "hang one"))
    state(m, running["work_id"], "running")
    assert {:accepted, _buffered} = C.submit(m, "TK-cap-2", request(home, "hang two"))

    assert {:capacity, %{"accepting" => true, "buffer" => %{"free" => 0}} = full} = C.capacity(m)
    assert is_integer(full["retry_after"])

    assert {:at_capacity, retry_after} = C.submit(m, "TK-cap-3", request(home, "hang three"))
    assert is_integer(retry_after) and retry_after > 0
    # Refused for capacity, it never became work.
    assert :not_found = C.find_work(m, "TK-cap-3")

    flush_capacity()
    assert {:cancelling, _} = C.cancel(m, running["work_id"], :force, "contract test")
    assert_receive {:capacity, %{"accepting" => true} = capacity}, @wait
    assert %{"slots" => _, "buffer" => _, "profiles" => _} = capacity

    assert {:accepted, _} =
             await(fn ->
               case C.submit(m, "TK-cap-3", request(home, "hang three")) do
                 {:accepted, _} = accepted -> accepted
                 {:at_capacity, _} -> nil
               end
             end)
  end

  test "heartbeats carry capacity: {:capacity, c} without any change", %{m: m} do
    link!(m)
    flush_capacity()
    assert_receive {:capacity, %{"slots" => %{"total" => 1}}}, 2_000
  end

  test "SSE resume: after a lost stream the link resumes with Last-Event-ID and gets what it missed",
       %{m: m, home: home, port: port} do
    link = link!(m)
    assert %{reconciles: 1, resets: 0} = Link.info(link)

    assert {:accepted, first} = C.submit(m, "TK-sse-1", request(home, "complete before"))
    changed(first["work_id"], "completed")
    before = Link.info(link).sequence
    assert is_integer(before)

    # The listener goes; the Runtime keeps working. A change made while it is down.
    stop_listener()
    await(fn -> not Link.info(link).connected end)

    assert %AtlasRuntime.Boundary.Work.Outcome.Accepted{work: missed} =
             AtlasRuntime.Boundary.Work.submit(
               {@client, @rights},
               Map.put(request(home, "complete while away"), :client_key, "TK-sse-2")
             )

    # It ends while the stream is down, so only a replay can tell the link.
    await(fn ->
      match?(
        %AtlasRuntime.Boundary.Work.Outcome.Found{work: %{state: :completed}},
        AtlasRuntime.Boundary.Work.get_work({@client, @rights}, %{work_id: missed.work_id})
      )
    end)

    missed_id = missed.work_id
    refute_received {:work_changed, %{"work_id" => ^missed_id}}
    ^port = listen(home)
    changed(missed.work_id, "completed")

    # A replay inside the window, not a reset: list_work was not read again.
    info = Link.info(link)
    assert info.connected and info.connects >= 2
    assert %{reconciles: 1, resets: 0} = info
    assert info.sequence > before
  end

  test "reset after a Runtime restart: the link re-reads list_work(changed_since:)",
       %{m: m, home: home, port: port, runtime: runtime} do
    link = link!(m)
    assert {:accepted, work} = C.submit(m, "TK-reset-1", request(home, "hang across restart"))
    changed(work["work_id"], "running")

    stop_runtime()
    await(fn -> not Link.info(link).connected end)
    start_runtime(runtime)
    ^port = listen(home)

    # Restarted, the Runtime made the running attempt interrupted; the link learns it
    # from list_work after the reset, not from a replay (the window was in memory).
    interrupted = changed(work["work_id"], "interrupted")
    assert interrupted["revision"] > work["revision"]
    assert %{resets: 1, reconciles: 2} = Link.info(link)
  end

  @tag work: [retention: 0]
  test "404 is never seen, 410 is pruned: the key is not new work again", %{m: m, home: home} do
    key = "TK-prune-1"
    assert {:accepted, work} = C.submit(m, key, request(home, "complete then pruned"))
    id = work["work_id"]

    assert {:pruned, ^id, "completed"} =
             await(fn ->
               case C.find_work(m, key) do
                 {:pruned, _, _} = pruned -> pruned
                 _ -> nil
               end
             end)

    assert {:pruned, ^id, "completed"} = C.get_work(m, id)
    assert :not_found = C.find_work(m, "TK-never-1")
    assert :not_found = C.get_work(m, "w-never")
    assert {:refused, :conflict} = C.submit(m, key, request(home, "complete then pruned"))
  end

  test "listener down: every capability is unreachable; back up, the same key is the same work",
       %{m: m, home: home, port: port} do
    assert {:accepted, work} = C.submit(m, "TK-down-1", request(home, "complete down"))
    stop_listener()

    assert {:unreachable, _} = C.submit(m, "TK-down-2", request(home, "complete down two"))
    assert {:unreachable, _} = C.get_work(m, work["work_id"])
    assert {:unreachable, _} = C.find_work(m, "TK-down-1")
    assert {:unreachable, _} = C.list_work(m, 0)
    assert {:unreachable, _} = C.capacity(m)
    assert {:unreachable, _} = C.retry(m, work["work_id"], false)
    assert {:unreachable, _} = C.cancel(m, work["work_id"], :graceful, nil)

    ^port = listen(home)

    assert {:existing, %{"work_id" => id}} =
             C.submit(m, "TK-down-1", request(home, "complete down"))

    assert id == work["work_id"]
    assert {:accepted, _} = C.submit(m, "TK-down-2", request(home, "complete down two"))
  end

  test "D44 from Flow's side: a folder workspace over TCP is refused not_permitted, nothing written",
       %{m: m, home: home} do
    key = "TK-folder-1"
    assert {:refused, :not_permitted} = C.submit(m, key, folder_request(home, "complete folder"))
    assert :not_found = C.find_work(m, key)
    assert {:works, [], _sequence} = C.list_work(m, nil)
    assert launches(home) == []

    # The same work in a repository is accepted: the refusal is the folder's, not the token's.
    assert {:accepted, %{"client_key" => ^key}} =
             C.submit(m, key, request(home, "complete folder"))
  end

  test "the token: none or a wrong one is refused as unauthenticated; retry and list_work",
       %{m: m, home: home} do
    assert {:accepted, work} = C.submit(m, "TK-auth-1", request(home, "complete auth"))
    state(m, work["work_id"], "completed")
    assert {:works, works, sequence} = C.list_work(m, nil)
    assert Enum.any?(works, &(&1["work_id"] == work["work_id"]))
    assert {:works, [], ^sequence} = C.list_work(m, sequence)
    assert {:accepted, %{"attempts" => [_, _]}} = C.retry(m, work["work_id"], false)

    System.put_env(@token_env, "wrong")
    assert {:refused, :unauthenticated} = C.capacity(m)
    System.delete_env(@token_env)
    assert {:refused, :unauthenticated} = C.find_work(m, "TK-auth-1")
  end
end
