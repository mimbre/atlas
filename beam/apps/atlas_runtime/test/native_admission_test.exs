defmodule AtlasRuntime.NativeAdmissionTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.{BackendPolicy, CommandAdmissions, Service}

  @moduletag capture_log: true

  setup do
    dir = Path.join(System.tmp_dir!(), "aa-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}")
    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    previous_path = System.fetch_env!("PATH")
    previous_home = System.get_env("CODEX_HOME")
    System.put_env("CODEX_HOME", Path.join(dir, "codex-home"))
    for tool <- ["git", "mkfifo"] do
      File.ln_s!(System.find_executable(tool), Path.join(bin, tool))
    end

    for backend <- ["codex", "claude"] do
      AtlasRuntime.FakeNative.install!(Path.join(bin, backend), "admission", [dir])
    end

    System.put_env("PATH", bin)
    on_exit(fn ->
      System.put_env("PATH", previous_path)
      if previous_home, do: System.put_env("CODEX_HOME", previous_home), else: System.delete_env("CODEX_HOME")
      File.rm_rf!(dir)
    end)
    %{dir: dir, bin: bin, workspace: workspace, service: launch_service(dir)}
  end

  defp launch_service(dir) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, dir)
    on_exit(fn ->
      if Process.alive?(pid) do
        monitor = Process.monitor(pid)
        Process.exit(pid, :kill)
        receive do
          {:DOWN, ^monitor, :process, ^pid, _} -> :ok
        after
          5_000 -> flunk("Runtime service did not stop")
        end
      end
    end)
    pid
  end

  defp call(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    reply
  end

  defp start_request(context, id, changes \\ %{}) do
    Map.merge(%{"command" => "start", "request_id" => id,
      "cwd" => context.workspace, "assignment" => "admit:" <> id}, changes)
  end

  defp launches(dir) do
    case raw_read(Path.join(dir, "native-starts.jsonl")) do
      {:ok, bytes} -> bytes |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      {:error, :enoent} -> []
    end
  end

  # A FIFO journal write blocks the file server; observe and release it through raw descriptors.
  defp raw_read(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, file} ->
        try do
          case :file.read(file, 1024 * 1024) do
            :eof -> {:ok, ""}
            result -> result
          end
        after
          :file.close(file)
        end
      error -> error
    end
  end

  defp await(fun), do: await(fun, System.monotonic_time(:millisecond) + 5_000)
  defp await(fun, deadline) do
    case fun.() do
      value when value not in [false, nil] -> value
      _ ->
        if System.monotonic_time(:millisecond) >= deadline, do: flunk("Missing native admission evidence")
        Process.sleep(10)
        await(fun, deadline)
    end
  end

  defp finished(pid, worker \\ "default") do
    await(fn ->
      run = call(pid, %{"command" => "status", "worker_id" => worker})
      if run[:state] == "finished", do: run
    end)
  end

  defp accepted(dir, reply) do
    assert reply["admission"] == "accepted"
    assert reply["requires_reconciliation"] == false
    assert reply["recorded_result"]["state"] == "running"
    record = CommandAdmissions.load(dir, reply["request_id"])
    assert CommandAdmissions.public(record) == reply
    run = Path.join([dir, "turns", reply["turn_id"], "turn.json"]) |> File.read!() |> JSON.decode!()
    assert run["request_id"] == reply["request_id"]
    journal = Path.join(dir, "execution-events.json") |> File.read!() |> JSON.decode!()
    assert Enum.any?(journal["events"], &(&1["turn_id"] == reply["turn_id"] and &1["kind"] == "execution_accepted"))
    record
  end

  defp command_error(pid, request) do
    assert %{command_error: error} = call(pid, request)
    error
  end

  defp caught_call(pid, request) do
    call(pid, request)
  catch
    :exit, reason -> {:exit, reason}
  end

  test "concurrent identical starts admit one native process and retain the original snapshot", context do
    request = start_request(context, "concurrent")
    tasks = for _ <- 1..12, do: Task.async(fn -> call(context.service, request) end)
    replies = Enum.map(tasks, &Task.await(&1, 10_000))
    [reply] = Enum.uniq(replies)
    record = accepted(context.dir, reply)
    assert record["binding"]["worker_id"] == "default"
    assert record["binding"]["source_turn_id"] == nil
    assert record["binding"]["backend"] == "codex"
    run = finished(context.service)
    assert run.id == reply["turn_id"]
    assert run.request_id == "concurrent"
    assert reply["recorded_result"]["session_id"] == nil
    assert is_binary(run.session_id)
    assert call(context.service, request) == reply
    normalized = Map.merge(request, %{"cwd" => context.workspace <> "/.",
      "sandbox" => "read-only", "questions_enabled" => false})
    assert call(context.service, normalized) == reply
    [launch] = launches(context.dir)
    assert launch["record"]["request_id"] == "concurrent"
    assert launch["record"]["turn_id"] == reply["turn_id"]
  end

  test "one global ID refuses changed caller intent before worker or backend resolution", context do
    request = start_request(context, "conflicts")
    reply = call(context.service, request)
    accepted(context.dir, reply)
    finished(context.service)

    conflicts = [
      Map.put(request, "assignment", "admit:changed"),
      Map.put(request, "worker_id", "default"),
      Map.put(request, "worker_id", "other"),
      Map.put(request, "cwd", Path.join(context.dir, "missing")),
      Map.put(request, "sandbox", "workspace-write"),
      Map.put(request, "permissions", "dedicated-repository"),
      Map.put(request, "backend", "codex"),
      Map.put(request, "backend", "claude"),
      Map.put(request, "questions_enabled", true),
      %{"command" => "continue", "request_id" => "conflicts", "assignment" => request["assignment"]},
      %{"command" => "start", "request_id" => "conflicts", "assignment" => request["assignment"],
        "repository" => "https://example.invalid/repository.git", "branch" => "feature", "permissions" => "dedicated-repository"}
    ]

    for conflict <- conflicts do
      assert command_error(context.service, conflict) =~ "Conflicting request ID"
    end
    assert command_error(context.service, Map.put(request, "extra", true)) != ""
    assert call(context.service, request) == reply
    assert length(launches(context.dir)) == 1
  end

  test "replay ignores changed workers, policy, quota, executable, metadata and deleted cwd across restart", context do
    request = start_request(context, "pinned")
    reply = call(context.service, request)
    accepted(context.dir, reply)
    finished(context.service)
    second = Path.join(context.dir, "second")
    File.mkdir_p!(second)
    plain = call(context.service, %{"command" => "start", "worker_id" => "other", "cwd" => second, "assignment" => "plain:other"})
    refute Map.has_key?(plain, :request_id)
    refute Map.has_key?(plain, "admission")
    finished(context.service, "other")
    call(context.service, %{"command" => "preferences",
      "preferred" => %{"backend" => "claude", "model" => "sonnet"},
      "fallback" => %{"backend" => "codex", "model" => "changed-model"}})
    :sys.replace_state(context.service, fn state ->
      evidence = %{"status" => "rejected", "rateLimitType" => "seven_day", "resetsAt" => nil}
      %{state | policy: BackendPolicy.record_quota(state.policy, evidence, reply["turn_id"], System.system_time(:second))}
    end)
    File.rm!(Path.join(context.bin, "codex"))
    File.rm_rf!(context.workspace)
    File.write!(Path.join([context.dir, "turns", reply["turn_id"], "turn.json"]), "corrupt metadata")
    assert call(context.service, request) == reply
    GenServer.stop(context.service)
    restarted = launch_service(context.dir)
    assert call(restarted, request) == reply
    assert length(launches(context.dir)) == 2
  end

  test "concurrent omitted-selector continuation binds one exact source and survives successors", context do
    source = call(context.service, %{"command" => "start", "cwd" => context.workspace, "assignment" => "plain:source"})
    source = Map.merge(source, finished(context.service))
    request = %{"command" => "continue", "request_id" => "resume", "assignment" => "admit:resume"}
    tasks = for _ <- 1..10, do: Task.async(fn -> call(context.service, request) end)
    [reply] = tasks |> Enum.map(&Task.await(&1, 10_000)) |> Enum.uniq()
    record = accepted(context.dir, reply)
    assert reply["source_turn_id"] == source.id
    assert record["binding"]["session_id"] == source.session_id
    assert record["binding"]["source_turn_id"] == source.id
    resumed_run = finished(context.service)
    assert resumed_run.source_turn_id == source.id
    assert record["recorded_result"]["source_turn_id"] == source.id
    assert JSON.decode!(File.read!(Path.join(resumed_run.artifacts, "turn.json")))["source_turn_id"] == source.id
    successor = call(context.service, %{"command" => "continue", "assignment" => "plain:successor"})
    assert successor.source_turn_id == resumed_run.id
    finished(context.service)
    assert successor.id != reply["turn_id"]
    assert call(context.service, request) == reply
    for changes <- [%{"turn_id" => source.id}, %{"turn_id" => successor.id}, %{"worker_id" => "default"},
                    %{"assignment" => "admit:changed"}] do
      assert command_error(context.service, Map.merge(request, changes)) =~ "Conflicting request ID"
    end
    File.rm_rf!(Path.join([context.dir, "turns", source.id]))
    assert call(context.service, request) == reply
    GenServer.stop(context.service)
    restarted = launch_service(context.dir)
    assert call(restarted, request) == reply
    [_, resumed, _] = launches(context.dir)
    assert resumed["resumed"]
    assert resumed["session_id"] == source.session_id
    assert resumed["record"]["binding"]["source_turn_id"] == source.id
  end

  test "explicit saved continuation records its owner and refuses a changed source", context do
    call(context.service, %{"command" => "start", "worker_id" => "alpha", "cwd" => context.workspace, "assignment" => "plain:alpha"})
    source = finished(context.service, "alpha")
    request = %{"command" => "continue", "request_id" => "explicit", "turn_id" => source.id, "assignment" => "admit:explicit"}
    reply = call(context.service, request)
    record = accepted(context.dir, reply)
    assert record["binding"]["worker_id"] == "alpha"
    assert record["binding"]["source_turn_id"] == source.id
    resumed_run = finished(context.service, "alpha")
    assert resumed_run.source_turn_id == source.id
    assert record["recorded_result"]["source_turn_id"] == source.id
    assert command_error(context.service, Map.put(request, "turn_id", reply["turn_id"])) =~ "Conflicting request ID"
    assert command_error(context.service, Map.delete(request, "turn_id")) =~ "Conflicting request ID"
    assert call(context.service, request) == reply
    assert length(launches(context.dir)) == 2
  end

  test "malformed input and capability refusals leave no reservation or native process", context do
    base = start_request(context, "refused")
    rejected = [
      Map.put(base, "request_id", "../escape"), Map.put(base, "request_id", nil),
      Map.put(base, "assignment", "  "), Map.put(base, "assignment", 1),
      Map.put(base, "assignment", String.duplicate("x", 131_073)),
      Map.put(base, "worker_id", "INVALID"), Map.put(base, "cwd", Path.join(context.dir, "missing")),
      Map.put(base, "permissions", "unknown"), Map.put(base, "sandbox", "danger-full-access"),
      Map.put(base, "permissions", "dedicated-repository"),
      Map.put(base, "questions_enabled", "true"), Map.put(base, "questions_enabled", true),
      Map.put(base, "backend", nil), Map.put(base, "unknown", true),
      Map.merge(base, %{"backend" => "claude", "sandbox" => "workspace-write"}),
      %{"command" => "continue", "request_id" => "refused", "assignment" => "admit:continue"},
      %{"command" => "continue", "request_id" => "refused", "assignment" => "admit:continue", "turn_id" => "turn-0000000000000001"},
      %{"command" => "status", "request_id" => "refused"}
    ]
    for request <- rejected, do: assert(command_error(context.service, request) != "")
    File.rm!(Path.join(context.bin, "codex"))
    assert command_error(context.service, base) =~ "Install codex"
    refute File.exists?(Path.join(context.dir, "admissions/refused.json"))
    assert launches(context.dir) == []
  end

  test "managed start admits its repository without Code; the host resolves develop", context do
    # Managed paths must be symlink-free; the macOS temporary directory is behind /var.
    real = AtlasRuntime.Workspaces.workspace_path(context.dir)
    context = %{context | dir: real, service: launch_service(real)}
    request = %{"command" => "start", "request_id" => "managed", "assignment" => "admit:managed",
      "repository" => "https://github.com/Owner/Repo", "branch" => "task/code", "permissions" => "dedicated-repository"}
    # A configured but unreachable Code is never contacted.
    {:ok, listener} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, closed} = :inet.port(listener)
    :gen_tcp.close(listener)
    token = Path.join(context.dir, "code.token")
    File.write!(token, "secret-token\n")
    File.write!(Path.join(context.dir, "code.json"), JSON.encode!(%{"url" => "http://127.0.0.1:#{closed}", "token_file" => token}))

    reply = call(context.service, request)
    assert CommandAdmissions.load(context.dir, "managed")["binding"]["repository"] ==
             %{"url" => "https://github.com/owner/repo.git", "branch" => "task/code"}
    assert call(context.service, request) == reply
    # The fixture cannot clone; wait for that preparation failure before cleanup.
    await(fn -> call(context.service, %{"command" => "status"})[:state] not in [nil, "running"] end)
  end

  test "worker and workspace collisions still refuse new IDs while identical admission replays", context do
    File.write!(Path.join(context.dir, "hold"), "")
    request = start_request(context, "active", %{"worker_id" => "alpha"})
    reply = call(context.service, request)
    accepted(context.dir, reply)
    await(fn -> length(launches(context.dir)) == 1 end)
    nested = Path.join(context.workspace, "nested")
    File.mkdir_p!(nested)
    for refused <- [start_request(context, "same-worker", %{"worker_id" => "alpha"}),
                    start_request(context, "same-workspace", %{"worker_id" => "beta"}),
                    start_request(context, "nested-workspace", %{"worker_id" => "beta", "cwd" => nested})] do
      assert command_error(context.service, refused) =~ ~r/active agent|overlaps active worker/
      refute File.exists?(Path.join([context.dir, "admissions", refused["request_id"] <> ".json"]))
    end
    continue = %{"command" => "continue", "request_id" => "active-resume", "worker_id" => "alpha", "assignment" => "admit:active-resume"}
    assert command_error(context.service, continue) =~ "active agent"
    refute File.exists?(Path.join(context.dir, "admissions/active-resume.json"))
    assert call(context.service, request) == reply
    assert length(launches(context.dir)) == 1
    File.rm!(Path.join(context.dir, "hold"))
    finished(context.service, "alpha")
  end

  test "native startup failure after reservation stays indeterminate after repair and restart", context do
    File.write!(Path.join(context.dir, "turns"), "not a directory")
    request = start_request(context, "failed-start")
    reply = call(context.service, request)
    assert reply["admission"] == "indeterminate"
    assert reply["requires_reconciliation"] == true
    assert reply["recorded_result"] == nil
    assert CommandAdmissions.public(CommandAdmissions.load(context.dir, "failed-start")) == reply
    assert launches(context.dir) == []
    File.rm!(Path.join(context.dir, "turns"))
    assert call(context.service, request) == reply
    GenServer.stop(context.service)
    restarted = launch_service(context.dir)
    assert call(restarted, request) == reply
    assert launches(context.dir) == []
  end

  test "admission storage refusal is fatal before native startup", context do
    File.write!(Path.join(context.dir, "admissions"), "not a directory")
    request = start_request(context, "storage-failure")
    assert {:exit, _} = caught_call(context.service, request)
    refute Process.alive?(context.service)
    assert launches(context.dir) == []
  end

  test "corrupt accepted admission is fatal instead of becoming a fresh command", context do
    request = start_request(context, "corruption")
    reply = call(context.service, request)
    accepted(context.dir, reply)
    finished(context.service)
    File.write!(Path.join(context.dir, "admissions/corruption.json"), "{broken")
    assert {:exit, _} = caught_call(context.service, request)
    refute Process.alive?(context.service)
    assert length(launches(context.dir)) == 1
  end

  for failure <- [:journal, :acceptance] do
    @tag admission_failure: failure
    test "failure at #{failure} after native execution leaves a durable indeterminate admission", context do
      failure = context.admission_failure
      request = start_request(context, Atom.to_string(failure))
      fifo = Path.join(context.dir, "execution-events.json.tmp")
      {_, 0} = System.cmd("mkfifo", [fifo])
      pending = Task.async(fn -> caught_call(context.service, request) end)
      await(fn -> length(launches(context.dir)) == 1 end)
      [launch] = launches(context.dir)
      assert launch["record"]["admission"] == "indeterminate"
      {:ok, bytes} = raw_read(Path.join(context.dir, "admissions/#{request["request_id"]}.json"))
      record = JSON.decode!(bytes)
      assert record["recorded_result"] == nil
      await(fn -> match?({:ok, _}, raw_read(Path.join([context.dir, "turns", record["turn_id"], "turn.json"]))) end)
      journal = Path.join(context.dir, "execution-events.json")

      {:ok, journal_bytes} = raw_read(fifo)
      assert {:exit, _} = Task.await(pending, 10_000)
      refute Process.alive?(context.service)
      assert CommandAdmissions.load(context.dir, request["request_id"])["admission"] == "indeterminate"
      File.rm_rf!(journal)
      File.rm_rf!(fifo)
      File.write!(journal, journal_bytes)
      File.rm_rf!(Path.join(context.dir, record["record_ref"] <> ".tmp"))
      restarted = launch_service(context.dir)
      assert call(restarted, request) == CommandAdmissions.public(record)
      assert length(launches(context.dir)) == 1
    end
  end

  test "a lost caller after native execution can recover accepted evidence without resending", context do
    File.write!(Path.join(context.dir, "hold"), "")
    request = start_request(context, "lost-response")
    fifo = Path.join(context.dir, "execution-events.json.tmp")
    {_, 0} = System.cmd("mkfifo", [fifo])
    caller = spawn(fn -> call(context.service, request) end)
    await(fn -> length(launches(context.dir)) == 1 end)
    {:ok, bytes} = raw_read(Path.join(context.dir, "admissions/lost-response.json"))
    assert JSON.decode!(bytes)["admission"] == "indeterminate"
    Process.exit(caller, :kill)
    {:ok, journal_bytes} = raw_read(fifo)
    call(context.service, %{"command" => "service-status"})
    journal = Path.join(context.dir, "execution-events.json")
    File.rm!(journal)
    File.write!(journal, journal_bytes)
    record = CommandAdmissions.load(context.dir, "lost-response")
    reply = CommandAdmissions.public(record)
    accepted(context.dir, reply)
    assert call(context.service, request) == reply
    File.rm!(Path.join(context.dir, "hold"))
    finished(context.service)
    assert length(launches(context.dir)) == 1
  end

  test "ordinary pre-admission File.Error remains a command error for ID and legacy callers", context do
    call(context.service, %{"command" => "start", "backend" => "claude", "cwd" => context.workspace, "assignment" => "plain:claude"})
    source = finished(context.service)
    File.rm!(Path.join(source.artifacts, "claude-context.json"))
    request = %{"command" => "continue", "assignment" => "admit:missing-context", "request_id" => "missing-context"}
    assert command_error(context.service, request) =~ "claude-context.json"
    assert command_error(context.service, Map.delete(request, "request_id")) =~ "claude-context.json"
    assert Process.alive?(context.service)
    refute File.exists?(Path.join(context.dir, "admissions/missing-context.json"))
    assert length(launches(context.dir)) == 1
  end

  # Records dest under home as snapshot materialize would, for one empty repository at path.
  defp materialize!(home, dest, path) do
    manifest = ~s({"entries":[],"repositories":[{"path":"#{path}","repository":"r","revision":"rev_#{String.duplicate("a", 64)}"}],"version":2})
    hex = :crypto.hash(:sha256, manifest) |> Base.encode16(case: :lower)
    baseline = Path.join([home, "snapshots", hex])
    record = Path.join([home, "materializations", Base.encode16(:crypto.hash(:sha256, dest), case: :lower) <> ".json"])
    File.mkdir_p!(Path.join(baseline, "tree"))
    File.mkdir_p!(Path.dirname(record))
    File.mkdir_p!(Path.join(dest, path))
    File.write!(Path.join(baseline, "manifest.json"), manifest)
    File.write!(Path.join(baseline, "complete"), "sha256:#{hex}\n")
    File.write!(record, JSON.encode!(%{"destination" => dest, "snapshot_id" => "sha256:" <> hex}))
    %{"profile" => "materialized-folder", "version" => 1, "root" => dest, "snapshot_id" => "sha256:" <> hex,
      "repositories" => [path], "home" => home, "record" => record, "baseline" => baseline}
  end

  defp overlap(dest, home),
    do: "Materialized folder #{dest} overlaps the Runtime home #{home}; materialize it outside the Runtime home"

  # The worker observes the host's own resolved executable, never a PATH lookup.
  defp host_executable do
    executable = System.fetch_env!("ATLAS_RUNTIME_EXECUTABLE")
    Path.join(AtlasRuntime.Workspaces.workspace_path(Path.dirname(executable)), Path.basename(executable))
  end

  test "materialized-folder binds its verified snapshot for Codex and continuation never rebinds", context do
    # Folder scopes require canonical paths; the macOS temporary directory is behind /var.
    real = AtlasRuntime.Workspaces.workspace_path(context.dir)
    context = %{context | dir: real, service: launch_service(real)}
    # Workers cannot read the Runtime home, so the folder must lie outside it.
    dest = real <> "-folder"
    on_exit(fn -> File.rm_rf!(dest) end)
    scope = materialize!(real, dest, "repo")
    git_log = Path.join(real, "git.log")
    File.rm!(Path.join(context.bin, "git"))
    File.write!(Path.join(context.bin, "git"), "#!/bin/sh\necho \"$@\" >> '#{git_log}'\nexit 1\n")
    File.chmod!(Path.join(context.bin, "git"), 0o755)
    request = start_request(context, "folder", %{"cwd" => dest, "permissions" => "materialized-folder"})

    assert command_error(context.service, Map.put(request, "sandbox", "read-only")) =~ "cannot be combined with sandbox"
    # A folder inside the Runtime home is refused before any native launch.
    inside = Path.join(real, "folder")
    inside_scope = materialize!(real, inside, "repo")
    assert command_error(context.service, start_request(context, "inside", %{"cwd" => inside, "permissions" => "materialized-folder"})) ==
             overlap(inside, real)
    assert launches(context.dir) == []
    record = accepted(context.dir, call(context.service, request))
    assert record["binding"]["permissions"] == scope
    assert record["binding"]["backend"] == "codex"
    finished(context.service)

    continued = call(context.service, %{"command" => "continue", "request_id" => "folder-next", "assignment" => "admit:folder-next"})
    assert accepted(context.dir, continued)["binding"]["permissions"] == scope
    finished(context.service)
    [start, resume] = launches(context.dir)
    assert ~s(default_permissions="atlas_folder") in start["argv"]
    assert resume["resumed"] and ~s(default_permissions="atlas_folder") in resume["argv"]
    assert start["executable"] == host_executable() and resume["executable"] == host_executable()

    # A saved turn of a folder inside the Runtime home cannot continue.
    legacy = "turn-00000000000000aa"
    File.mkdir_p!(Path.join([real, "turns", legacy]))
    File.write!(Path.join([real, "turns", legacy, "turn.json"]), JSON.encode!(%{
      "worker_id" => "legacy", "state" => "finished", "backend" => "codex", "session_id" => "legacy-session",
      "cwd" => inside, "sandbox" => nil, "permissions" => inside_scope}))
    assert command_error(context.service, %{"command" => "continue", "turn_id" => legacy, "assignment" => "plain:legacy"}) ==
             overlap(inside, real)
    assert length(launches(context.dir)) == 2

    # Rebinding the folder to another snapshot is refused, not refreshed.
    rebound = materialize!(real, dest, "other")
    assert rebound["snapshot_id"] != scope["snapshot_id"]
    assert command_error(context.service, %{"command" => "continue", "assignment" => "plain:rebound"}) =~
             "permission scope changed"
    assert length(launches(context.dir)) == 2
    refute File.exists?(git_log)
  end

  test "Claude materialized-folder binds the snapshot scope as its Git-free context and never rebinds", context do
    real = AtlasRuntime.Workspaces.workspace_path(context.dir)
    context = %{context | dir: real, service: launch_service(real)}
    # Claude's sandbox denies writes below system temp roots, so the folder must lie outside TMPDIR.
    previous_tmp = System.get_env("TMPDIR")
    tmp = Path.join(real, "tmp")
    File.mkdir_p!(tmp)
    System.put_env("TMPDIR", tmp)
    on_exit(fn -> if previous_tmp, do: System.put_env("TMPDIR", previous_tmp), else: System.delete_env("TMPDIR") end)
    # Claude's denies win over its allows, so the folder must also lie outside the Runtime home.
    dest = real <> "-folder"
    on_exit(fn -> File.rm_rf!(dest) end)
    scope = materialize!(real, dest, "repo")
    git_log = Path.join(real, "git.log")
    File.rm!(Path.join(context.bin, "git"))
    File.write!(Path.join(context.bin, "git"), "#!/bin/sh\necho \"$@\" >> '#{git_log}'\nexit 1\n")
    File.chmod!(Path.join(context.bin, "git"), 0o755)
    request = start_request(context, "claude-folder", %{"cwd" => dest, "permissions" => "materialized-folder", "backend" => "claude"})

    record = accepted(context.dir, call(context.service, request))
    assert record["binding"]["permissions"] == scope
    assert record["binding"]["backend"] == "claude"
    finished(context.service)
    saved = Path.join([real, "turns", record["turn_id"], "claude-context.json"]) |> File.read!() |> JSON.decode!()
    assert saved == %{"cwd" => dest, "git" => nil, "permissions" => scope}

    continued = call(context.service, %{"command" => "continue", "request_id" => "claude-folder-next", "assignment" => "admit:claude-folder-next"})
    assert accepted(context.dir, continued)["binding"]["permissions"] == scope
    finished(context.service)
    [start, resume] = launches(context.dir)
    for launch <- [start, resume] do
      settings = launch["argv"] |> Enum.drop_while(&(&1 != "--settings")) |> Enum.at(1) |> JSON.decode!()
      assert hd(settings["sandbox"]["filesystem"]["allowWrite"]) == dest
      assert "Read(/#{real})" in settings["permissions"]["deny"]
    end
    assert resume["resumed"]
    assert start["executable"] == host_executable() and resume["executable"] == host_executable()

    # Rebinding the folder to another snapshot is refused, not refreshed.
    materialize!(real, dest, "other")
    assert command_error(context.service, %{"command" => "continue", "assignment" => "plain:rebound"}) =~
             "permission scope changed"
    assert length(launches(context.dir)) == 2
    refute File.exists?(git_log)
  end
end
