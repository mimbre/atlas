defmodule AtlasFlow.Runtime.HttpContractTest do
  @moduledoc """
  The contract test of Flow's Runtime client (plan 2026-11-17 §6 F1.1): `Client.Http` and
  `Link` against the Runtime's real backend, started here with only its work core and a
  loopback TCP listener on a temporary `ATLAS_RUNTIME_HOME`, with a test `clients.json` and
  no `server.json`. The stub harness (`fake_native`, which never launches a provider) is
  built in `setup_all` with `go build`.

  The Runtime's own TCP listener (S3) is not in the tree yet; its interface is (S3 P1: the
  `:tcp` rights ceiling, `__problem__/2` with `unauthenticated` and `origin-refused`). The
  listener below is a test stand-in on that interface: a Bearer token from `clients.json`
  (stored as a sha256, compared in constant time), its rights cut to the TCP ceiling,
  Origin refused, then the generated router. Replace it with the Runtime's listener when
  that lands.

  This is the one Flow source that names the Runtime's modules: it starts the Runtime in
  the test (`atlas_runtime` is a test-only dependency). Flow's own code reaches the Runtime
  only over HTTP.
  """
  use ExUnit.Case, async: false

  alias AtlasFlow.Runtime.{Config, Link}
  alias AtlasFlow.Runtime.Client.Http, as: C

  @token_env "ATLAS_FLOW_CONTRACT_TEST_TOKEN"
  @token "flow-contract-token"
  @rights [:submit, :cancel, :read]
  @wait 10_000

  defmodule TcpListener do
    @moduledoc false
    # The S3 listener's work, on its P1 interface: Origin refused, Bearer token required,
    # rights cut to the router's :tcp ceiling.
    @behaviour Plug
    import Plug.Conn

    @rights %{
      "submit" => :submit,
      "cancel" => :cancel,
      "read" => :read,
      "read_all" => :read_all,
      "choose_slot" => :choose_slot
    }

    @impl true
    def init(home), do: home

    @impl true
    def call(conn, home) do
      router = AtlasRuntime.Backend.Rest

      with [] <- get_req_header(conn, "origin"),
           {:ok, client} <- authenticate(conn, home, router) do
        conn |> assign(:client, client) |> router.call(router.init([]))
      else
        [_origin | _] -> router.__problem__(:origin_refused, conn)
        :error -> router.__problem__(:unauthenticated, conn)
      end
    end

    defp authenticate(conn, home, router) do
      with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
           {:ok, json} <- File.read(Path.join(home, "clients.json")),
           %{"clients" => clients} <- JSON.decode!(json),
           digest = Base.encode16(:crypto.hash(:sha256, token), case: :lower),
           %{"name" => name, "rights" => rights} <-
             Enum.find(clients, &Plug.Crypto.secure_compare(&1["token_sha256"], digest)) do
        granted = for r <- rights, right = @rights[r], right in router.__rights__(:tcp), do: right
        {:ok, {name, granted}}
      else
        _ -> :error
      end
    end
  end

  setup_all do
    root = Path.expand("../../..", __DIR__)
    dir = Path.join(System.tmp_dir!(), "afc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake = Path.join(dir, "fake-native")

    case System.cmd("go", ["build", "-o", fake, "main.go"],
           cd: Path.join(root, "atlas_runtime/test/support/fake_native"),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, _} -> raise "building the stub harness failed:\n#{output}"
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    %{fake: fake}
  end

  setup %{fake: fake} = context do
    home = Path.join(System.tmp_dir!(), "afr-#{System.unique_integer([:positive])}")
    bin = Path.join(home, "bin")
    File.mkdir_p!(bin)
    File.mkdir_p!(Path.join(home, "workspace"))

    for tool <- ["git", "mkfifo"],
        do: File.ln_s!(System.find_executable(tool), Path.join(bin, tool))

    for harness <- ["codex", "claude"] do
      script = Path.join(bin, harness)
      File.write!(script, "#!/bin/sh\nexec '#{fake}' work '#{home}' \"$0\" \"$@\"\n")
      File.chmod!(script, 0o700)
    end

    previous =
      for name <- ["PATH", "CODEX_HOME", "GIT_CONFIG_GLOBAL", "ATLAS_RUNTIME_HOME", @token_env],
          do: {name, System.get_env(name)}

    System.put_env("PATH", bin <> ":/usr/bin:/bin")
    System.put_env("CODEX_HOME", Path.join(home, "codex-home"))
    System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
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
            "permissions" => ["read-only", "workspace-write", "materialized-folder"],
            "cost_classes" => ["standard"],
            "options" => [%{"provider" => "openai", "harness" => "codex", "model" => "gpt-test"}]
          }
        }
      })
    )

    File.write!(
      Path.join(home, "clients.json"),
      JSON.encode!(%{
        "clients" => [
          %{
            "name" => "flow",
            "token_sha256" => Base.encode16(:crypto.hash(:sha256, @token), case: :lower),
            "rights" => Enum.map(@rights, &Atom.to_string/1)
          }
        ]
      })
    )

    runtime = %{
      home: home,
      # A test's own `@tag work:` options win over these.
      work: Keyword.merge([heartbeat_ms: 100, cancel_grace_ms: 300], Map.get(context, :work, []))
    }

    start_runtime(runtime)
    port = listen(home, 0)

    on_exit(fn ->
      stop_runtime()

      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))

      File.rm_rf!(home)
    end)

    machinery = %Config{name: "test", url: "http://127.0.0.1:#{port}", token_env: @token_env}
    %{runtime: runtime, port: port, m: machinery, home: home}
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

  defp listen(home, port) do
    {:ok, pid} =
      Bandit.start_link(
        plug: {TcpListener, home},
        ip: {127, 0, 0, 1},
        port: port,
        startup_log: false
      )

    Process.unlink(pid)
    Process.put(:listener, pid)
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    port
  end

  defp stop_listener do
    case Process.delete(:listener) do
      nil -> :ok
      pid -> if Process.alive?(pid), do: Supervisor.stop(pid)
    end
  end

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

  # A request in a folder of its own (the Runtime refuses two turns in overlapping folders).
  # The S1 Runtime runs only `folder` work, so the test names a folder of its own home; the
  # client passes the request through and names no path itself (D44).
  defp request(home, instructions) do
    folder =
      Path.join([
        home,
        "workspace",
        Base.encode16(:crypto.hash(:md5, instructions), case: :lower)
      ])

    File.mkdir_p!(folder)

    %{
      title: instructions,
      instructions: instructions,
      profile: "deep_coding",
      cost_class: "standard",
      workspace: %{kind: "folder", path: folder, permissions: "read-only"}
    }
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
    assert work["client"] == "flow"
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
               {"flow", @rights},
               Map.put(request(home, "complete while away"), :client_key, "TK-sse-2")
             )

    # It ends while the stream is down, so only a replay can tell the link.
    await(fn ->
      match?(
        %AtlasRuntime.Boundary.Work.Outcome.Found{work: %{state: :completed}},
        AtlasRuntime.Boundary.Work.get_work({"flow", @rights}, %{work_id: missed.work_id})
      )
    end)

    missed_id = missed.work_id
    refute_received {:work_changed, %{"work_id" => ^missed_id}}
    ^port = listen(home, port)
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
    ^port = listen(home, port)

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

    ^port = listen(home, port)

    assert {:existing, %{"work_id" => id}} =
             C.submit(m, "TK-down-1", request(home, "complete down"))

    assert id == work["work_id"]
    assert {:accepted, _} = C.submit(m, "TK-down-2", request(home, "complete down two"))
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
