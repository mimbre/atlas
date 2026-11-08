defmodule AtlasRuntime.Service do
  use GenServer
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.BackendPolicy
  alias AtlasRuntime.CommandAdmissions
  alias AtlasRuntime.ExecutionEvents
  alias AtlasRuntime.HandoffRecords
  alias AtlasRuntime.PeerQuestionRecords
  alias AtlasRuntime.QuestionRecords
  alias AtlasRuntime.Entrypoints.Socket
  alias AtlasRuntime.Handoffs.Commands, as: Handoffs
  alias AtlasRuntime.Interactions.Commands, as: Interactions
  alias AtlasRuntime.Persistence.History
  alias AtlasRuntime.Workspaces
  import AtlasRuntime.Execution.Identity

  def start(dir), do: GenServer.start_link(__MODULE__, dir, name: __MODULE__)

  def init(dir) do
    policy = BackendPolicy.load(dir)
    events = History.recover(dir)
    Socket.start(dir, __MODULE__)
    {:ok, %{dir: dir, policy: policy, events: events, workers: %{}, stopping: false}}
  end


  def handle_call(request, _from, state) do
    {reply, next, shutdown?} =
      try do
        command(request, state)
      rescue
        error in [QuestionRecords.StorageError, PeerQuestionRecords.StorageError, CommandAdmissions.StorageError, HandoffRecords.StorageError] -> reraise error, __STACKTRACE__
        error -> {%{command_error: Exception.message(error)}, state, false}
      catch
        :exit, why -> {%{command_error: "Operation not confirmed: #{inspect(why)}"}, state, false}
      end

    next = record_changes(state, next)
    reply =
      case {request, reply} do
        {_, {:admission, record, run}} ->
          state.dir |> CommandAdmissions.accept(record, run) |> CommandAdmissions.public()
        {%{"command" => "stop"}, %{worker_id: id}} ->
          Map.get(next.workers, id, %{run: reply}).run
        {%{"command" => "service-stop"}, %{workers: _}} ->
          reply = Map.put(reply, :workers, worker_runs(next))
          if Map.has_key?(reply, :agent), do: Map.put(reply, :agent, sole_run(next)), else: reply
        _ -> reply
      end
    {:reply, {reply, shutdown?}, next}
  end

  defp command(%{"request_id" => _} = request, state) do
    canonical = CommandAdmissions.canonical(request)
    request_id = request["request_id"]

    case CommandAdmissions.load(state.dir, request_id) do
      nil ->
        if state.stopping, do: raise("Runtime service is stopping")
        request = Map.delete(request, "request_id")
        {worker_id, saved} = select_worker(request, state)
        worker = Map.get(state.workers, worker_id, idle_worker(worker_id))
        worker_command(request, worker_id, worker, saved, state, {request_id, canonical})

      record ->
        if record["request"] != canonical,
          do: raise(ArgumentError, "Conflicting request ID: #{request_id}")
        {CommandAdmissions.public(record), state, false}
    end
  end

  # A completed service-stop whose caller disappeared has stopped every worker and still refuses
  # new work, so status and a repeated stop stay available; the repeat only requests shutdown.
  defp command(%{"command" => "service-status"} = request, %{stopping: true} = state)
       when map_size(request) == 1,
       do: service_status(state, "stopping")

  defp command(%{"command" => "service-stop"} = request, %{stopping: true} = state)
       when map_size(request) == 1 do
    reply = %{service: "stopping", workers: worker_runs(state)}
    run = sole_run(state)
    {if(run, do: Map.put(reply, :agent, run), else: reply), state, true}
  end

  defp command(_, %{stopping: true}), do: raise("Runtime service is stopping")

  defp command(%{"command" => name} = request, state)
       when name in ["handoff", "submit-handoff"] do
    {reply, events} = Handoffs.execute(request, state.dir, state.events)
    {reply, %{state | events: events}, false}
  end

  defp command(%{"command" => name} = request, state)
       when name in ["question", "answer", "peer-question", "route-peer-question", "bind-peer-reply"] do
    {reply, events, workers} = Interactions.execute(request, state.dir, state.events, state.workers)
    {reply, %{state | events: events, workers: workers}, false}
  end


  defp command(%{"command" => name} = request, state)
       when name in ["start", "status", "output", "stop", "continue"] do
    {worker_id, saved} = select_worker(request, state)
    worker = Map.get(state.workers, worker_id, idle_worker(worker_id))
    worker_command(request, worker_id, worker, saved, state)
  end

  defp command(%{"worker_id" => _}, _),
    do: raise("This command does not accept a worker")

  defp command(%{"command" => "service-status"}, state), do: service_status(state, "running")

  defp command(%{"command" => "service-stop"}, state) do
    {workers, errors} =
      Enum.reduce(Enum.sort(state.workers), {state.workers, []}, fn {id, worker}, {workers, errors} ->
        try do
          {Map.put(workers, id, stop(worker)), errors}
        rescue
          error -> {workers, errors ++ ["#{id}: #{Exception.message(error)}"]}
        catch
          :exit, reason -> {workers, errors ++ ["#{id}: #{inspect(reason)}"]}
        end
      end)
    next = %{state | workers: workers, stopping: errors == []}
    if errors == [] do
      reply = %{service: "stopping", workers: worker_runs(next)}
      run = sole_run(next)
      {if(run, do: Map.put(reply, :agent, run), else: reply), next, true}
    else
      {%{command_error: "Stop not confirmed: " <> Enum.join(errors, "; "),
         workers: worker_runs(next)}, next, false}
    end
  end

  defp command(%{"command" => "events"} = request, state) do
    if Map.keys(request) -- ["command", "cursor", "limit"] != [],
      do: raise("Events accepts only an optional cursor and limit")
    reply = ExecutionEvents.query(state.events, Map.get(request, "cursor"), Map.get(request, "limit", 50))
    {reply, state, false}
  end

  defp command(%{"command" => "turns"}, state),
    do: {History.list(state.dir, state.workers), state, false}


  defp command(%{"command" => "preferences"} = request, state) do
    now = System.system_time(:second)
    policy = case request do
      %{"preferred" => preferred, "fallback" => fallback} when map_size(request) == 3 ->
        BackendPolicy.configure(state.policy, preferred, fallback)
      %{"reenable" => backend} when map_size(request) == 2 ->
        BackendPolicy.reenable(state.policy, backend, now)
      _ when map_size(request) == 1 -> state.policy
      _ -> raise("Use preferences, a preferred/fallback pair, or reenable; modes cannot mix")
    end
    if policy != state.policy, do: BackendPolicy.persist(state.dir, policy)
    {BackendPolicy.view(policy, now), %{state | policy: policy}, false}
  end

  defp command(_, _), do: raise("Unknown or malformed command")

  defp service_status(state, service) do
    reply = %{service: service, pid: System.pid(), workers: worker_runs(state)}
    run = sole_run(state)
    {if(run, do: Map.put(reply, :agent_state, run.state), else: reply), state, false}
  end



  defp worker_command(request, id, worker, saved, state, admission \\ nil)

  defp worker_command(%{"command" => "status"}, _id, worker, saved, state, _admission),
    do: {saved || worker.run, state, false}

  defp worker_command(%{"command" => "output"}, _id, worker, saved, state, _admission) do
    run = saved || worker.run
    {Map.merge(run, History.output(run[:artifacts] || run["artifacts"])), state, false}
  end

  defp worker_command(%{"command" => "stop"}, id, worker, _saved, state, _admission) do
    next = stop(worker)
    workers = if Map.has_key?(state.workers, id), do: Map.put(state.workers, id, next), else: state.workers
    {next.run, %{state | workers: workers}, false}
  end

  defp worker_command(%{"command" => "start", "repository" => url, "branch" => branch,
                 "permissions" => "dedicated-repository", "assignment" => assignment} = request,
                 worker_id, worker, _saved, state, admission)
       when is_binary(url) and is_binary(branch) and is_binary(assignment) do
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; use status or stop")
    selection = select_backend(request, state)
    if Map.keys(request) -- ["command", "repository", "branch", "permissions", "assignment", "backend", "worker_id", "questions_enabled"] != [],
      do: raise("Repository provisioning cannot be combined with cwd or sandbox")
    prepared = Workspaces.repository_request(Path.join([state.dir, "workers", worker_id]), url, branch)
    scope = prepared["permissions"]
    # Code resolves the exact base before anything is reserved, cloned or launched.
    commit = Workspaces.Code.resolve!(state.dir, prepared["repository"]["url"], "develop")
    repository = Map.put(prepared["repository"], "resolved_commit", commit)
    start_turn(assignment, scope["root"], nil, scope, nil, state, worker_id, repository, selection, nil, Map.get(request, "questions_enabled", false), admission)
  end

  defp worker_command(%{"command" => "start", "cwd" => cwd, "assignment" => assignment} = request,
                      worker_id, worker, _saved, state, admission)
       when is_binary(cwd) and is_binary(assignment) do
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; use status or stop")
    if Map.keys(request) -- ["command", "cwd", "assignment", "permissions", "sandbox", "backend", "worker_id", "questions_enabled"] != [],
      do: raise("Unknown start fields")
    if Map.has_key?(request, "repository") or Map.has_key?(request, "branch"),
      do: raise("Repository provisioning requires a URL, branch and dedicated-repository permissions")
    selection = select_backend(request, state)
    {sandbox, scope} =
      case Map.get(request, "permissions") do
        nil ->
          sandbox = Map.get(request, "sandbox", "read-only")
          if sandbox not in ["read-only", "workspace-write"],
            do: raise("Sandbox must be read-only or workspace-write")
          {sandbox, nil}
        profile when profile in ["dedicated-repository", "materialized-folder"] ->
          if Map.has_key?(request, "sandbox"), do: raise("Permissions cannot be combined with sandbox")
          {nil, current_scope(profile, cwd, state)}
        _ -> raise("Unknown permission profile")
      end
    start_turn(assignment, cwd, sandbox, scope, nil, state, worker_id, nil, selection, nil, Map.get(request, "questions_enabled", false), admission)
  end

  defp worker_command(%{"command" => "continue", "assignment" => assignment} = request,
                      worker_id, worker, saved, state, admission)
       when is_binary(assignment) do
    if Map.keys(request) -- ["command", "assignment", "turn_id", "worker_id"] != [],
      do: raise("Continue accepts only an assignment, worker and optional turn ID; working directory and permissions cannot change")
    if worker.agent, do: raise("Worker #{worker_id} already has an active agent; wait for completion or stop it")
    run = saved || string_keys(worker.run)
    backend = Map.get(run, "backend", "codex")
    if backend not in ["codex", "claude"], do: raise("Unknown saved backend; sessions cannot switch vendors")
    questions_enabled = questions_enabled!(run, backend)
    if run["state"] != "finished",
      do: raise("Continue requires a successfully finished turn")
    session = run["session_id"]
    cwd = run["cwd"]
    sandbox = run["sandbox"]
    scope = run["permissions"]
    if not is_binary(session) or String.trim(session) == "",
      do: raise("The selected turn has no confirmed native session")
    if not is_binary(cwd) or Path.type(cwd) != :absolute or
         not ((is_nil(scope) and sandbox in ["read-only", "workspace-write"]) or
           (is_map(scope) and is_nil(sandbox))),
      do: raise("The selected turn has no valid saved working directory and permissions")
    if scope && scope != current_scope(scope["profile"], cwd, state),
      do: raise("The selected turn's permission scope changed")
    context =
      if backend == "claude" do
        if not is_binary(run["model"]) or run["model"] == "",
          do: raise("The selected Claude turn has no confirmed model")
        Path.join(run["artifacts"], "claude-context.json") |> File.read!() |> JSON.decode!()
      end
    target = %{"backend" => backend, "model" => run["model"] || run["requested_model"]}
    selection = %{"requested" => target, "selected" => target, "reason" => "continuation"}
    start_turn(assignment, cwd, sandbox, scope, session, state, worker_id, run["repository"], selection, context, questions_enabled, admission, run["id"])
  end

  defp worker_command(_, _, _, _, _, _), do: raise("Unknown or malformed command")

  defp current_scope("materialized-folder", cwd, state), do: Workspaces.folder_scope(cwd, state.dir)
  defp current_scope(_dedicated, cwd, _state), do: Workspaces.permission_scope(cwd)

  defp select_worker(request, state) do
    explicit? = Map.has_key?(request, "worker_id")
    requested = request["worker_id"]
    if explicit? and not valid_worker_id?(requested), do: raise("Invalid worker ID")
    saved =
      if Map.has_key?(request, "turn_id") do
        if request["command"] not in ["output", "continue"],
          do: raise("This command does not accept a turn ID")
        History.historical(request["turn_id"], state.dir, state.workers)
      end

    worker_id =
      cond do
        saved ->
          if explicit? and requested != saved["worker_id"],
            do: raise("Turn belongs to worker #{saved["worker_id"]}, not #{requested}")
          saved["worker_id"]
        explicit? -> requested
        map_size(state.workers) == 0 -> "default"
        map_size(state.workers) == 1 -> state.workers |> Map.keys() |> hd()
        true -> raise("Multiple workers are registered; specify --worker")
      end

    if explicit? and is_nil(saved) and request["command"] != "start" and
         not Map.has_key?(state.workers, worker_id),
      do: raise("Unknown worker: #{worker_id}")
    {worker_id, saved}
  end


  defp idle_worker(id), do: %{agent: nil, monitor: nil, run: %{worker_id: id, state: "idle"}}
  defp worker_runs(state), do: Map.new(state.workers, fn {id, worker} -> {id, worker.run} end)

  defp sole_run(%{workers: workers}) when map_size(workers) == 0, do: idle_worker("default").run
  defp sole_run(%{workers: workers}) when map_size(workers) == 1 do
    {_id, worker} = Enum.at(workers, 0)
    worker.run
  end
  defp sole_run(_), do: nil

  defp select_backend(request, state) do
    if Map.has_key?(request, "backend") and is_nil(request["backend"]),
      do: raise("Backend must be codex or claude")
    selection = BackendPolicy.select(state.policy, request["backend"], request, System.system_time(:second))
    questions_enabled!(request, selection["selected"]["backend"])
    selection
  end

  defp questions_enabled!(settings, backend) do
    enabled = Map.get(settings, "questions_enabled", false)
    if not is_boolean(enabled), do: raise("questions_enabled must be a boolean")
    if enabled and backend != "claude", do: raise("Questions are supported only by Claude")
    enabled
  end

  defp start_turn(assignment, cwd, sandbox, scope, session, state, worker_id, repository, selection, context, questions_enabled, admission, source_turn_id \\ nil) do
    backend = selection["selected"]["backend"]
    model = selection["selected"]["model"]
    if (not File.dir?(cwd) and is_nil(repository)) or String.trim(assignment) == "",
      do: raise("An existing working directory and nonempty assignment are required")
    cwd = Workspaces.workspace_path(cwd)
    Enum.each(state.workers, fn {id, worker} ->
      if not is_nil(worker.agent) and overlapping_paths?(cwd, worker.run.cwd),
        do: raise("Workspace overlaps active worker #{id}")
    end)

    executable = System.find_executable(backend) || raise("Install #{backend} and authenticate with its official CLI")
    key = "turn-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    turns = Path.join(state.dir, "turns")

    settings = %{
      "command" => executable,
      "backend" => backend,
      "model" => model,
      "workspace" => Path.expand(cwd),
      "goal" => assignment,
      "sandbox" => sandbox,
      "permissions" => scope,
      "repository" => repository,
      "session_id" => session,
      "resume_context" => context,
      "questions_enabled" => questions_enabled
    }

    run = %{
      id: key,
      worker_id: worker_id,
      backend: backend,
      questions_enabled: questions_enabled,
      pending_question: nil,
      last_answer: nil,
      model: nil,
      requested_model: model,
      selection: selection,
      started_at: DateTime.to_iso8601(DateTime.utc_now()),
      state: "running",
      cwd: Path.expand(cwd),
      assignment: assignment,
      sandbox: sandbox,
      session_id: session,
      artifacts: Path.join(turns, key)
    }
    run = if scope, do: Map.put(run, :permissions, scope), else: run
    run = if repository, do: Map.put(run, :repository, repository), else: run
    run = if admission, do: Map.put(run, :request_id, elem(admission, 0)), else: run
    run = if source_turn_id, do: Map.put(run, :source_turn_id, source_turn_id), else: run

    record =
      if admission do
        {request_id, canonical} = admission
        binding = %{
          "worker_id" => worker_id,
          "source_turn_id" => source_turn_id,
          "cwd" => run.cwd,
          "sandbox" => sandbox,
          "permissions" => scope,
          "repository" => repository,
          "backend" => backend,
          "model" => model,
          "session_id" => session,
          "questions_enabled" => questions_enabled
        }
        CommandAdmissions.reserve(state.dir, request_id, canonical, binding, key, run)
      end

    result =
      try do
        Native.start(%{key: key}, agent: settings, turns_dir: turns)
      rescue
        error ->
          if record, do: {:error, error}, else: reraise(error, __STACKTRACE__)
      catch
        :exit, reason ->
          if record, do: {:error, reason}, else: exit(reason)
      end

    case result do
      {:ok, pid} ->
        worker = %{agent: pid, monitor: Process.monitor(pid), run: run}
        next = %{state | workers: Map.put(state.workers, worker_id, worker)}
        reply = if record, do: {:admission, record, run}, else: run
        {reply, next, false}

      {:error, why} ->
        if record,
          do: {CommandAdmissions.public(record), state, false},
          else: raise("#{backend} start failed: #{inspect(why)}")
    end
  end


  defp stop(%{agent: nil} = state), do: state

  defp stop(state) do
    :ok = Native.stop(state.agent)
    Process.demonitor(state.monitor, [:flush])
    %{state | agent: nil, monitor: nil,
      run: Map.merge(state.run, %{state: "stopped", pending_question: nil, ended_at: DateTime.to_iso8601(DateTime.utc_now())})}
  end

  def handle_info({:agent, pid, message}, state) when is_pid(pid) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.agent == pid end) do
      nil -> {:noreply, state}
      {id, worker} -> {:noreply, agent_message(message, id, worker, state)}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.workers, fn {_id, worker} ->
           worker.agent == pid and worker.monitor == ref and is_reference(ref)
         end) do
      nil -> {:noreply, state}
      {id, worker} ->
        run = Map.merge(worker.run, %{state: "failed", pending_question: nil, error: inspect(reason),
          ended_at: DateTime.to_iso8601(DateTime.utc_now())})
        next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
        {:noreply, record_changes(state, next)}
    end
  end

  def handle_info(:shutdown, state) do
    System.stop(0)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp agent_message({kind, _} = message, id, worker, state) when kind in [:question, :answer] do
    {run, events} = Interactions.observe(message, worker.run, id, state.dir, state.events)
    if run == worker.run and events == state.events,
      do: state,
      else: update_run(%{state | events: events}, id, worker, run)
  end

  defp agent_message({:repository, repository}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :repository, repository))

  defp agent_message({:quota, evidence}, id, %{run: %{backend: "claude"}} = worker, state) do
    policy = BackendPolicy.record_quota(state.policy, evidence, worker.run.id, System.system_time(:second))
    if policy != state.policy, do: BackendPolicy.persist(state.dir, policy)
    update_run(%{state | policy: policy}, id, worker, Map.put(worker.run, :quota, policy["claude_quota"]))
  end

  defp agent_message({:identity, backend, model}, id, %{run: %{backend: backend}} = worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :model, model))

  defp agent_message({:session, session}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :session_id, session))

  defp agent_message({:activity, text}, id, worker, state),
    do: put_worker(state, id, %{worker | run: Map.put(worker.run, :activity, text)})

  defp agent_message({:ended, text}, id, worker, state) do
    Process.demonitor(worker.monitor, [:flush])
    run = Map.merge(worker.run, %{state: "finished", pending_question: nil, result: text,
      ended_at: DateTime.to_iso8601(DateTime.utc_now())})
    next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
    record_changes(state, next)
  end

  defp agent_message(_, _, _, state), do: state

  defp put_worker(state, id, worker),
    do: %{state | workers: Map.put(state.workers, id, worker)}

  defp update_run(state, id, worker, run),
    do: record_changes(state, put_worker(state, id, %{worker | run: run}))

  defp record_changes(previous, next) do
    {events, workers} = History.checkpoint(next.dir, next.events, previous.workers, next.workers)
    %{next | events: events, workers: workers}
  end

  defp overlapping_paths?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/") or left == "/" or right == "/"
  end

end