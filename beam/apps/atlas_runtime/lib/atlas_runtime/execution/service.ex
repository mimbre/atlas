defmodule AtlasRuntime.Service do
  use GenServer
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.BackendPolicy
  alias AtlasRuntime.CommandAdmissions
  alias AtlasRuntime.ExecutionEvents
  alias AtlasRuntime.HandoffRecords
  alias AtlasRuntime.PeerQuestionRecords
  alias AtlasRuntime.QuestionRecords
  alias AtlasRuntime.Entrypoints.{ReadSocket, Socket}
  alias AtlasRuntime.Execution.RestartReconciliation
  alias AtlasRuntime.Handoffs.Commands, as: Handoffs
  alias AtlasRuntime.Integrations.AtlasServer.Lifecycle
  alias AtlasRuntime.Inspection.Reads
  alias AtlasRuntime.Interactions.Commands, as: Interactions
  alias AtlasRuntime.Output
  alias AtlasRuntime.Persistence.History
  alias AtlasRuntime.Workspaces
  import AtlasRuntime.Execution.Identity

  # Open read.sock follow connections; more are refused with `too_many_followers`.
  @followers 32

  @doc "Start the service; `server` (without its token) opts into Atlas Server lifecycle reporting."
  def start(dir, server \\ nil),
    do: GenServer.start_link(__MODULE__, {dir, server}, name: __MODULE__)

  def init(dir) when is_binary(dir), do: init({dir, nil, []})
  def init({dir, server}), do: init({dir, server, []})
  def init({dir, server, reporting}), do: init({dir, server, reporting, []})

  # `reporting` and `options` are explicit dependency injection for tests: bounded Talk
  # timing; `follow:` read.sock follow timing, `halt:` the exit after a service stop and
  # `process_probe:` the liveness check of restart reconciliation.
  def init({dir, server, reporting, options}) do
    policy = BackendPolicy.load(dir)
    events = History.recover(dir)
    Socket.start(dir, __MODULE__)
    # The bound socket proves no other service runs here, and this one owns no port yet.
    probe = Keyword.get(options, :process_probe, &RestartReconciliation.process_state/2)
    events = RestartReconciliation.reconcile(dir, events, probe)
    ReadSocket.start(dir, self(), Keyword.get(options, :follow, []))

    state = %{
      dir: dir,
      policy: policy,
      events: events,
      workers: %{},
      stopping: false,
      followers: %{},
      halt: Keyword.get(options, :halt, &System.stop/1)
    }

    if server do
      {:ok, reporter} = Lifecycle.start(server, reporting)
      {:ok, Map.put(state, :server, %{config: server, reporter: reporter})}
    else
      {:ok, state}
    end
  end

  # Every callback that grew the journal signals the read.sock followers afterwards. Decided
  # here, at the boundary, because some paths store new events before `record_changes/2`.
  def handle_call(request, from, state), do: signal(state, serve_call(request, from, state))
  def handle_info(message, state), do: signal(state, serve_info(message, state))

  # A fixed-size message per follower and never a wait: each one reads its pages itself.
  defp signal(previous, result) do
    next = elem(result, tuple_size(result) - 1)
    sequence = next.events["sequence"]

    if sequence > previous.events["sequence"],
      do: Enum.each(Map.keys(followers(next)), &send(&1, {:events_appended, sequence}))

    result
  end

  defp followers(state), do: Map.get(state, :followers, %{})

  # read.sock's admitted reads: answered from the state, which they never change, and never
  # dispatched as commands.
  defp serve_call({:read, op, args}, _from, state),
    do: {:reply, Reads.read(op, args, state), state}

  # A read.sock follow connection: registration and its first page in one call. Followers are
  # connection bookkeeping, never persisted or returned.
  # Once the shutdown began the service still answers until the exit lands, but a follow
  # started then would report a stopping Runtime reachable: it ends at once instead.
  defp serve_call({:follow, pid, cursor}, _from, state) when is_pid(pid) do
    followers = followers(state)
    page = fn -> Reads.read("events", %{"cursor" => cursor, "limit" => 100}, state) end

    cond do
      state[:shutdown] ->
        {:reply, :service_stopping, state}

      Map.has_key?(followers, pid) ->
        {:reply, page.(), state}

      map_size(followers) >= @followers ->
        {:reply, Reads.error("too_many_followers"), state}

      true ->
        case page.() do
          %{"error" => _} = error ->
            {:reply, error, state}

          reply ->
            followers = Map.put(followers, pid, Process.monitor(pid))
            {:reply, reply, Map.put(state, :followers, followers)}
        end
    end
  end

  defp serve_call(request, _from, state) do
    {reply, next, shutdown?} =
      try do
        command(request, state)
      rescue
        error in [
          QuestionRecords.StorageError,
          PeerQuestionRecords.StorageError,
          CommandAdmissions.StorageError,
          HandoffRecords.StorageError
        ] ->
          reraise error, __STACKTRACE__

        error ->
          {%{command_error: Exception.message(error)}, state, false}
      catch
        :exit, why -> {%{command_error: "Operation not confirmed: #{inspect(why)}"}, state, false}
      end

    next = record_changes(state, next)

    reply =
      case {request, reply} do
        {_, {:admission, record, run}} ->
          state.dir |> CommandAdmissions.accept(record, run) |> CommandAdmissions.public()

        {%{"command" => name}, %{worker_id: id, id: turn}} when name in ["stop", "kill"] ->
          case Map.get(next.workers, id) do
            %{run: %{id: ^turn} = run} -> run
            _ -> reply
          end

        {%{"command" => "service-stop"}, %{workers: _}} ->
          reply = Map.put(reply, :workers, worker_runs(next))
          if Map.has_key?(reply, :agent), do: Map.put(reply, :agent, sole_run(next)), else: reply

        _ ->
          reply
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
    case owned_workers(state) do
      [] ->
        reply = %{service: "stopping", workers: worker_runs(state)}
        run = sole_run(state)
        {if(run, do: Map.put(reply, :agent, run), else: reply), state, true}

      owned ->
        {pending_stop(owned, state), state, false}
    end
  end

  # While a service stop waits for owned executions, inspection and stop/kill stay available.
  defp command(%{"command" => name} = request, %{stopping: true} = state)
       when name in ["status", "output", "stop", "kill"],
       do: worker_request(request, state)

  defp command(%{"command" => name} = request, %{stopping: true} = state)
       when name in ["events", "turns"],
       do: command(request, %{state | stopping: false}) |> put_elem(1, state)

  defp command(_, %{stopping: true}), do: raise("Runtime service is stopping")

  defp command(%{"command" => name} = request, state)
       when name in ["handoff", "submit-handoff"] do
    {reply, events} = Handoffs.execute(request, state.dir, state.events)
    {reply, %{state | events: events}, false}
  end

  defp command(%{"command" => name} = request, state)
       when name in [
              "question",
              "answer",
              "peer-question",
              "route-peer-question",
              "bind-peer-reply"
            ] do
    {reply, events, workers} =
      Interactions.execute(request, state.dir, state.events, state.workers)

    {reply, %{state | events: events, workers: workers}, false}
  end

  defp command(%{"command" => name} = request, state)
       when name in ["start", "status", "output", "stop", "kill", "continue"],
       do: worker_request(request, state)

  # Release only clears the worker's admission latch; it starts and resumes nothing.
  defp command(%{"command" => "release"} = request, state) do
    if Map.keys(request) -- ["command", "worker_id"] != [] or
         not Map.has_key?(request, "worker_id"),
       do: raise("Release requires exactly --worker")

    id = request["worker_id"]
    if not valid_worker_id?(id), do: raise("Invalid worker ID")
    latch = History.latch(state.dir, id)

    case Map.get(state.workers, id) do
      %{agent: agent, run: run} when not is_nil(agent) and not is_nil(latch) ->
        raise(
          "Worker #{id} still owns turn #{run.id} (#{run.state}); release after its end is confirmed"
        )

      _ ->
        :ok
    end

    if latch, do: History.release_latch!(state.dir, id)
    {%{worker_id: id, released: latch, admission_latch: nil}, state, false}
  end

  defp command(%{"worker_id" => _}, _),
    do: raise("This command does not accept a worker")

  defp command(%{"command" => "service-status"}, state), do: service_status(state, "running")

  # Every running worker gets the same graceful stop as `stop`; the daemon exits only once no
  # owned execution remains, so a repeated service stop completes the shutdown.
  defp command(%{"command" => "service-stop"}, state) do
    {next, errors} =
      Enum.reduce(Enum.sort(state.workers), {state, []}, fn {id, worker}, {next, errors} ->
        if worker.agent && worker.run.state == "running" do
          try do
            {elem(control("stop", id, worker, next), 1), errors}
          rescue
            error -> {next, errors ++ ["#{id}: #{Exception.message(error)}"]}
          end
        else
          {next, errors}
        end
      end)

    next = %{next | stopping: errors == []}
    owned = owned_workers(next)

    cond do
      errors != [] ->
        {%{
           command_error: "Stop not confirmed: " <> Enum.join(errors, "; "),
           workers: worker_runs(next)
         }, next, false}

      owned != [] ->
        {pending_stop(owned, next), next, false}

      true ->
        reply = %{service: "stopping", workers: worker_runs(next)}
        run = sole_run(next)
        {if(run, do: Map.put(reply, :agent, run), else: reply), next, true}
    end
  end

  defp command(%{"command" => "events"} = request, state) do
    if Map.keys(request) -- ["command", "cursor", "limit"] != [],
      do: raise("Events accepts only an optional cursor and limit")

    reply =
      ExecutionEvents.query(
        state.events,
        Map.get(request, "cursor"),
        Map.get(request, "limit", 50)
      )

    {reply, state, false}
  end

  defp command(%{"command" => "turns"}, state),
    do: {History.list(state.dir, state.workers), state, false}

  defp command(%{"command" => "preferences"} = request, state) do
    now = System.system_time(:second)

    policy =
      case request do
        %{"preferred" => preferred, "fallback" => fallback} when map_size(request) == 3 ->
          BackendPolicy.configure(state.policy, preferred, fallback)

        %{"reenable" => backend} when map_size(request) == 2 ->
          BackendPolicy.reenable(state.policy, backend, now)

        _ when map_size(request) == 1 ->
          state.policy

        _ ->
          raise("Use preferences, a preferred/fallback pair, or reenable; modes cannot mix")
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

  defp worker_command(%{"command" => "status"}, id, worker, saved, state, _admission),
    do:
      {Map.put(saved || worker.run, :admission_latch, History.latch(state.dir, id)), state, false}

  defp worker_command(%{"command" => "output"}, _id, worker, saved, state, _admission) do
    run = saved || worker.run
    {Map.merge(run, History.output(run[:artifacts] || run["artifacts"])), state, false}
  end

  # Stop and kill target one exact worker and turn. Only the current owned execution can change;
  # an already stopped or killed turn repeats idempotently, anything else is a stale target.
  defp worker_command(%{"command" => name} = request, id, worker, saved, state, _admission)
       when name in ["stop", "kill"] do
    if Enum.sort(Map.keys(request)) != ["command", "turn_id", "worker_id"],
      do: raise("#{String.capitalize(name)} requires exactly --worker and --turn")

    turn = request["turn_id"]

    cond do
      worker.agent && worker.run.id == turn ->
        {run, next} = control(name, id, worker, state)
        {run, next, false}

      worker.run[:id] == turn and worker.run.state in ["stopped", "killed"] ->
        {worker.run, state, false}

      saved["state"] in ["stopped", "killed"] ->
        {saved, state, false}

      true ->
        state_name = if worker.run[:id] == turn, do: worker.run.state, else: saved["state"]

        raise(
          "Turn #{turn} has no execution owned by this Runtime service to #{name} (#{state_name})"
        )
    end
  end

  defp worker_command(
         %{
           "command" => "start",
           "repository" => url,
           "branch" => branch,
           "permissions" => "dedicated-repository",
           "assignment" => assignment
         } = request,
         worker_id,
         worker,
         _saved,
         state,
         admission
       )
       when is_binary(url) and is_binary(branch) and is_binary(assignment) do
    if worker.agent,
      do: raise("Worker #{worker_id} already has an active agent; use status or stop")

    unlatched!(state, worker_id)
    selection = select_backend(request, state)

    if Map.keys(request) --
         [
           "command",
           "repository",
           "branch",
           "permissions",
           "assignment",
           "backend",
           "worker_id",
           "questions_enabled"
         ] != [],
       do: raise("Repository provisioning cannot be combined with cwd or sandbox")

    prepared =
      Workspaces.repository_request(Path.join([state.dir, "workers", worker_id]), url, branch)

    scope = prepared["permissions"]
    # The host's own preparation fetches develop and branches from it; Code is not involved.
    start_turn(
      assignment,
      scope["root"],
      nil,
      scope,
      nil,
      state,
      worker_id,
      prepared["repository"],
      selection,
      nil,
      Map.get(request, "questions_enabled", false),
      admission
    )
  end

  defp worker_command(
         %{"command" => "start", "cwd" => cwd, "assignment" => assignment} = request,
         worker_id,
         worker,
         _saved,
         state,
         admission
       )
       when is_binary(cwd) and is_binary(assignment) do
    if worker.agent,
      do: raise("Worker #{worker_id} already has an active agent; use status or stop")

    unlatched!(state, worker_id)

    if Map.keys(request) --
         [
           "command",
           "cwd",
           "assignment",
           "permissions",
           "sandbox",
           "backend",
           "worker_id",
           "questions_enabled"
         ] != [],
       do: raise("Unknown start fields")

    if Map.has_key?(request, "repository") or Map.has_key?(request, "branch"),
      do:
        raise(
          "Repository provisioning requires a URL, branch and dedicated-repository permissions"
        )

    selection = select_backend(request, state)

    {sandbox, scope} =
      case Map.get(request, "permissions") do
        nil ->
          sandbox = Map.get(request, "sandbox", "read-only")

          if sandbox not in ["read-only", "workspace-write"],
            do: raise("Sandbox must be read-only or workspace-write")

          {sandbox, nil}

        profile when profile in ["dedicated-repository", "materialized-folder"] ->
          if Map.has_key?(request, "sandbox"),
            do: raise("Permissions cannot be combined with sandbox")

          {nil, current_scope(profile, cwd, state)}

        _ ->
          raise("Unknown permission profile")
      end

    start_turn(
      assignment,
      cwd,
      sandbox,
      scope,
      nil,
      state,
      worker_id,
      nil,
      selection,
      nil,
      Map.get(request, "questions_enabled", false),
      admission
    )
  end

  defp worker_command(
         %{"command" => "continue", "assignment" => assignment} = request,
         worker_id,
         worker,
         saved,
         state,
         admission
       )
       when is_binary(assignment) do
    if Map.keys(request) -- ["command", "assignment", "turn_id", "worker_id"] != [],
      do:
        raise(
          "Continue accepts only an assignment, worker and optional turn ID; working directory and permissions cannot change"
        )

    if worker.agent,
      do: raise("Worker #{worker_id} already has an active agent; wait for completion or stop it")

    unlatched!(state, worker_id)
    run = saved || string_keys(worker.run)
    backend = Map.get(run, "backend", "codex")

    if backend not in ["codex", "claude"],
      do: raise("Unknown saved backend; sessions cannot switch vendors")

    questions_enabled = questions_enabled!(run, backend)
    # A stopped or killed turn continues from its saved native session and the current files.
    if run["state"] not in ["finished", "stopped", "killed"],
      do: raise("Continue requires a finished, stopped or killed turn")

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

        case File.read(Path.join(run["artifacts"], "claude-context.json")) do
          {:ok, bytes} ->
            JSON.decode!(bytes)

          {:error, reason} ->
            raise(
              "The selected Claude turn has no saved native context: #{:file.format_error(reason)}"
            )
        end
      end

    target = %{"backend" => backend, "model" => run["model"] || run["requested_model"]}
    selection = %{"requested" => target, "selected" => target, "reason" => "continuation"}

    start_turn(
      assignment,
      cwd,
      sandbox,
      scope,
      session,
      state,
      worker_id,
      run["repository"],
      selection,
      context,
      questions_enabled,
      admission,
      run["id"]
    )
  end

  defp worker_command(_, _, _, _, _, _), do: raise("Unknown or malformed command")

  defp current_scope("materialized-folder", cwd, state),
    do: Workspaces.folder_scope(cwd, state.dir)

  defp current_scope(_dedicated, cwd, _state), do: Workspaces.permission_scope(cwd)

  defp select_worker(request, state) do
    explicit? = Map.has_key?(request, "worker_id")
    requested = request["worker_id"]
    if explicit? and not valid_worker_id?(requested), do: raise("Invalid worker ID")

    saved =
      if Map.has_key?(request, "turn_id") do
        if request["command"] not in ["output", "continue", "stop", "kill"],
          do: raise("This command does not accept a turn ID")

        History.historical(request["turn_id"], state.dir, state.workers)
      end

    worker_id =
      cond do
        saved ->
          if explicit? and requested != saved["worker_id"],
            do: raise("Turn belongs to worker #{saved["worker_id"]}, not #{requested}")

          saved["worker_id"]

        explicit? ->
          requested

        map_size(state.workers) == 0 ->
          "default"

        map_size(state.workers) == 1 ->
          state.workers |> Map.keys() |> hd()

        true ->
          raise("Multiple workers are registered; specify --worker")
      end

    # Restart clears registrations; the worker's latest saved turn, or a durable latch, still
    # identifies it, so status, output and continue select what they selected before.
    saved =
      if is_nil(saved) and request["command"] in ["status", "output", "continue"] and
           not Map.has_key?(state.workers, worker_id),
         do: History.latest(state.dir, worker_id),
         else: saved

    if explicit? and is_nil(saved) and request["command"] != "start" and
         not Map.has_key?(state.workers, worker_id) and
         is_nil(History.latch(state.dir, worker_id)),
       do: raise("Unknown worker: #{worker_id}")

    {worker_id, saved}
  end

  defp worker_request(request, state) do
    {worker_id, saved} = select_worker(request, state)
    worker = Map.get(state.workers, worker_id, idle_worker(worker_id))
    worker_command(request, worker_id, worker, saved, state)
  end

  defp unlatched!(state, worker_id) do
    if latch = History.latch(state.dir, worker_id),
      do:
        raise(
          "Worker #{worker_id} is latched after stopping turn #{latch["turn_id"]}; " <>
            "run atlas-runtime release --worker #{worker_id} first"
        )
  end

  defp owned_workers(state),
    do: for({id, %{agent: agent}} <- Enum.sort(state.workers), agent, do: id)

  defp pending_stop(owned, state) do
    names = Enum.map_join(owned, ", ", &"#{&1} (#{state.workers[&1].run.state})")

    %{
      command_error:
        "Service stop pending: still owned executions: #{names}; " <>
          "repeat service stop after their end is confirmed, or kill them",
      workers: worker_runs(state)
    }
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

    selection =
      BackendPolicy.select(state.policy, request["backend"], request, System.system_time(:second))

    questions_enabled!(request, selection["selected"]["backend"])
    selection
  end

  defp questions_enabled!(settings, backend) do
    enabled = Map.get(settings, "questions_enabled", false)
    if not is_boolean(enabled), do: raise("questions_enabled must be a boolean")
    if enabled and backend != "claude", do: raise("Questions are supported only by Claude")
    enabled
  end

  defp start_turn(
         assignment,
         cwd,
         sandbox,
         scope,
         session,
         state,
         worker_id,
         repository,
         selection,
         context,
         questions_enabled,
         admission,
         source_turn_id \\ nil
       ) do
    backend = selection["selected"]["backend"]
    model = selection["selected"]["model"]

    if (not File.dir?(cwd) and is_nil(repository)) or String.trim(assignment) == "",
      do: raise("An existing working directory and nonempty assignment are required")

    cwd = Workspaces.workspace_path(cwd)

    Enum.each(state.workers, fn {id, worker} ->
      if not is_nil(worker.agent) and overlapping_paths?(cwd, worker.run.cwd),
        do: raise("Workspace overlaps active worker #{id}")
    end)

    executable =
      System.find_executable(backend) ||
        raise("Install #{backend} and authenticate with its official CLI")

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
    # The Server identity is part of the turn from its first persistence, before any report.
    server = Lifecycle.identity(state[:server][:config], worker_id, key)
    run = if server, do: Map.put(run, :server, server), else: run

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
        Native.start_monitor(%{key: key}, agent: settings, turns_dir: turns)
      rescue
        error ->
          if record, do: {:error, error}, else: reraise(error, __STACKTRACE__)
      catch
        :exit, reason ->
          if record, do: {:error, reason}, else: exit(reason)
      end

    case result do
      {:ok, {pid, monitor}} ->
        # Before this call returns, no agent message is handled: the ring precedes all output.
        open_output(run)
        worker = %{agent: pid, monitor: monitor, run: run}
        next = %{state | workers: Map.put(state.workers, worker_id, worker)}
        reply = if record, do: {:admission, record, run}, else: run
        {reply, next, false}

      {:error, why} ->
        if record,
          do: {CommandAdmissions.public(record), state, false},
          else: raise("#{backend} start failed: #{inspect(why)}")
    end
  end

  # The latch and the requested mode are durable before the host is signalled. Kill wins over
  # stop; repeats keep their first request time and are forwarded, so the host re-attempts only
  # a refused signal. The worker stays owned until the host confirms the group gone.
  defp control(name, id, worker, state) do
    run = worker.run

    termination =
      run[:termination] ||
        %{
          "mode" => nil,
          "stop_requested_at" => nil,
          "stop_signalled_at" => nil,
          "kill_requested_at" => nil,
          "kill_signalled_at" => nil,
          "confirmed_at" => nil,
          "exit_code" => nil,
          "native_result" => nil,
          "error" => nil
        }

    now = DateTime.to_iso8601(DateTime.utc_now())

    if name == "stop" and termination["mode"] == "kill" do
      {run, state}
    else
      History.latch!(state.dir, id, run.id, now)

      termination =
        if termination["mode"] in [nil, "stop"] and termination["mode"] != name,
          do: %{termination | "mode" => name, (name <> "_requested_at") => now},
          else: termination

      run =
        Map.merge(run, %{
          state: if(name == "kill", do: "killing", else: "stopping"),
          pending_question: nil,
          termination: termination
        })

      state = update_run(state, id, worker, run)
      worker = state.workers[id]

      case Native.control(worker.agent, String.to_existing_atom(name)) do
        :ok ->
          {state.workers[id].run, state}

        {:error, reason} ->
          run =
            put_in(
              worker.run,
              [:termination, "error"],
              "#{name} not delivered: #{inspect(reason)}"
            )

          state = update_run(state, id, worker, run)
          {state.workers[id].run, state}
      end
    end
  end

  defp serve_info({:agent, pid, message}, state) when is_pid(pid) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.agent == pid end) do
      nil -> {:noreply, state}
      {id, worker} -> {:noreply, agent_message(message, id, worker, state)}
    end
  end

  defp serve_info({:DOWN, ref, :process, pid, _reason}, %{followers: followers} = state)
       when :erlang.map_get(pid, followers) == ref,
       do: {:noreply, %{state | followers: Map.delete(followers, pid)}}

  defp serve_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.workers, fn {_id, worker} ->
           worker.agent == pid and worker.monitor == ref and is_reference(ref)
         end) do
      nil ->
        {:noreply, state}

      {id, worker} ->
        finish_output(worker.run)

        run =
          Map.merge(worker.run, %{
            state: "failed",
            pending_question: nil,
            error: inspect(reason),
            ended_at: DateTime.to_iso8601(DateTime.utc_now())
          })

        run =
          if run[:termination],
            do: put_in(run, [:termination, "error"], inspect(reason)),
            else: run

        next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
        {:noreply, record_changes(state, next)}
    end
  end

  # Exact correlation: a report changes only the turn with this local ID and attempt.
  defp serve_info({:server_report, turn, attempt, report}, state) do
    case Enum.find(state.workers, fn {_id, worker} -> worker.run[:id] == turn end) do
      {id, %{run: %{server: %{"attempt" => ^attempt} = server}} = worker} ->
        {:noreply,
         update_run(
           state,
           id,
           worker,
           Map.put(worker.run, :server, Map.put(server, "report", report))
         )}

      nil ->
        History.server_report(state.dir, turn, attempt, report)
        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp serve_info(:shutdown, state) do
    # Followers write their `end` line best effort; the exit never waits for them. The exit
    # is asynchronous, so no follow is admitted from here on either.
    Enum.each(Map.keys(followers(state)), &send(&1, :service_stopping))
    state = Map.merge(state, %{shutdown: true, followers: %{}})
    # Ends already asked for get a bounded moment; Server never holds the exit up longer.
    if state[:server], do: Lifecycle.flush(state.server.reporter, 5_000)
    Map.get(state, :halt, &System.stop/1).(0)
    {:noreply, state}
  end

  defp serve_info(_, state), do: {:noreply, state}

  defp agent_message({kind, _} = message, id, worker, state) when kind in [:question, :answer] do
    {run, events} = Interactions.observe(message, worker.run, id, state.dir, state.events)

    if run == worker.run and events == state.events,
      do: state,
      else: update_run(%{state | events: events}, id, worker, run)
  end

  defp agent_message({:repository, repository}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :repository, repository))

  defp agent_message({:quota, evidence}, id, %{run: %{backend: "claude"}} = worker, state) do
    policy =
      BackendPolicy.record_quota(
        state.policy,
        evidence,
        worker.run.id,
        System.system_time(:second)
      )

    if policy != state.policy, do: BackendPolicy.persist(state.dir, policy)

    update_run(
      %{state | policy: policy},
      id,
      worker,
      Map.put(worker.run, :quota, policy["claude_quota"])
    )
  end

  defp agent_message(
         {:identity, backend, model},
         id,
         %{run: %{backend: backend}} = worker,
         state
       ),
       do: update_run(state, id, worker, Map.put(worker.run, :model, model))

  defp agent_message({:session, session}, id, worker, state),
    do: update_run(state, id, worker, Map.put(worker.run, :session_id, session))

  defp agent_message({:activity, text}, id, worker, state) do
    if state[:server] && worker.run[:server],
      do: Lifecycle.activity(state.server.reporter, worker.run, text)

    put_worker(state, id, %{worker | run: Map.put(worker.run, :activity, text)})
  end

  defp agent_message({:output, event}, _id, worker, state) do
    append_output(worker.run, event)
    state
  end

  defp agent_message({:ended, text}, id, worker, state) do
    Process.demonitor(worker.monitor, [:flush])
    finish_output(worker.run)

    run =
      Map.merge(worker.run, %{
        state: "finished",
        pending_question: nil,
        result: text,
        ended_at: DateTime.to_iso8601(DateTime.utc_now())
      })

    next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
    record_changes(state, next)
  end

  defp agent_message(
         {:signal, %{"control" => control} = signal},
         id,
         %{run: %{termination: %{}}} = worker,
         state
       )
       when control in ["stop", "kill"] do
    termination =
      case signal["error"] do
        nil ->
          Map.merge(worker.run.termination, %{
            (control <> "_signalled_at") => DateTime.to_iso8601(DateTime.utc_now()),
            "error" => nil
          })

        error ->
          Map.put(worker.run.termination, "error", "#{signal["signal"]} refused: #{error}")
      end

    update_run(state, id, worker, Map.put(worker.run, :termination, termination))
  end

  # The host confirmed the owned group gone and released its lock. A control the host never
  # applied (the execution ended first) leaves the natural outcome; the request stays recorded.
  defp agent_message({:terminated, info}, id, %{run: %{termination: %{}}} = worker, state) do
    Process.demonitor(worker.monitor, [:flush])
    finish_output(worker.run)
    now = DateTime.to_iso8601(DateTime.utc_now())

    {terminal, extra} =
      case {info["control"], info["native_result"]} do
        {"kill", _} ->
          {"killed", %{}}

        {"stop", _} ->
          {"stopped", %{}}

        {_, true} ->
          {"finished", %{result: info["result"]}}

        _ ->
          {"failed",
           %{
             error:
               "Native execution ended before the #{worker.run.termination["mode"]} was applied"
           }}
      end

    termination =
      Map.merge(worker.run.termination, %{
        "confirmed_at" => now,
        "exit_code" => info["exit_code"],
        "native_result" => info["native_result"]
      })

    run =
      worker.run
      |> Map.merge(extra)
      |> Map.merge(%{
        state: terminal,
        pending_question: nil,
        termination: termination,
        ended_at: now
      })

    next = put_worker(state, id, %{worker | agent: nil, monitor: nil, run: run})
    record_changes(state, next)
  end

  defp agent_message(_, _, _, state), do: state

  # A turn's public output (the provider's projection, as a connected turn's) is retained,
  # owned by this service: a reported turn's in Output under its exact Server identity, any
  # other's in the local buffer that only read.sock reads (`Reads.output_stream/1`). It never
  # waits for Server, and a missing ring never changes the native lifecycle.
  # Only a new event from the turn's own agent may reopen a lost ring, in a new epoch.
  defp open_output(run), do: output(run, &Output.open(&1, self(), &2))
  defp finish_output(run), do: output(run, &Output.finish/2)

  defp append_output(run, event) do
    case output(run, &Output.append(&1, event, &2)) do
      {:error, "output_unavailable"} ->
        with :ok <- open_output(run), do: output(run, &Output.append(&1, event, &2))

      result ->
        result
    end
  end

  defp output(run, call) do
    {buffer, execution} = Reads.output_stream(run)
    call.(execution, buffer)
  catch
    :exit, _ -> {:error, "output_unavailable"}
  end

  defp put_worker(state, id, worker),
    do: %{state | workers: Map.put(state.workers, id, worker)}

  defp update_run(state, id, worker, run),
    do: record_changes(state, put_worker(state, id, %{worker | run: run}))

  defp record_changes(previous, next) do
    {events, workers} = History.checkpoint(next.dir, next.events, previous.workers, next.workers)
    next = %{next | events: events, workers: workers}
    report(previous, next)
    next
  end

  # After the checkpoint: a reported turn is in turn.json before the reporter hears of it.
  defp report(previous, %{server: %{reporter: reporter}} = next) do
    Enum.each(next.workers, fn {id, worker} ->
      old = Map.get(previous.workers, id, idle_worker(id)).run
      new? = worker.run[:id] != old[:id]

      if worker.run[:server] do
        if new?, do: Lifecycle.started(reporter, worker.run)

        if worker.run.state in ["stopped", "killed", "finished", "failed"] and
             (new? or worker.run.state != old.state),
           do: Lifecycle.ended(reporter, worker.run)
      end
    end)
  end

  defp report(_previous, _next), do: :ok

  defp overlapping_paths?(left, right) do
    left == right or String.starts_with?(left, right <> "/") or
      String.starts_with?(right, left <> "/") or left == "/" or right == "/"
  end
end
