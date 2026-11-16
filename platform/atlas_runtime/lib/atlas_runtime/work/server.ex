defmodule AtlasRuntime.Work.Server do
  @moduledoc """
  The work core's process: it owns the work records and is the only writer of
  `$ATLAS_RUNTIME_HOME/work/` (`AtlasRuntime.Work.Store`). `AtlasRuntime.Work`, the
  boundary's implementation, calls it; nothing else does.

  **Write-ahead (I2).** Every change is persisted (record, then sequence) before any
  notification or answer mentions it: `commit/2` writes, then notifies, and handlers reply
  after it.

  **Turns.** Attempts start only through the Service's own `start`/`continue` commands with
  a derived `request_id` (`AtlasRuntime.Work.Turns`). Ends and progress come from following
  the Service's events (`{:follow, pid, cursor}`) and reading the turn record; a follower
  behind the Service's 256-entry journal re-reads every live attempt's turn. Nothing polls:
  the heartbeat timer (15 s) sends the heartbeat, probes unconfirmed turns and prunes.

  **Options** (tests): `name`, `service` (the Service process, default `AtlasRuntime.Service`),
  `heartbeat_ms`, `cancel_grace_ms` (default the policy's 30 s), `retention` (seconds, 30
  days), `window` (notifications kept, 10 000), `processes` (taken once per heartbeat, gives the
  probe that heartbeat uses; `AtlasRuntime.Work.Restart.processes/0`), `probe` (a fixed
  probe instead), `start_timeout_ms` (how long a start may take, 120 s), `after_write` (called
  with each record just written, before anything mentions it) and `stop_exit_ms` (how long
  after the last attempt of a stop ended the Service exits, 200 ms, so the stop's answer is
  out first).

  **Stop (design §13.1 Q9).** From `{:stop, force, by}` on the core is `stopping` (in memory
  only, never persisted): it takes no new work and starts nothing; buffered work stays.
  Without `force` the Service's own service stop signals what it runs, and after
  `cancel_grace` the core kills what still runs; with `force` the core kills at once. A
  stop is not a cancel: no attempt passes through `cancelling` or gets a `cancel_reason`.
  Each attempt ends `interrupted`, reason `runtime_stop`, retryable, with its resume point,
  persisted (I2). Once no attempt is live the Service's service stop ends the process.
  """
  use GenServer
  require Logger

  alias AtlasRuntime.{Availability, CommandAdmissions, Policy, Provenance}
  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Persistence.History
  alias AtlasRuntime.Work.{Mode, Notifications, Prune, Queue, Restart, Store, Translation, Turns}

  @doc """
  Loads the store and the persisted mode and starts the core; a store or `mode.json` it
  cannot read is a logged refusal.
  """
  def start_link(dir, opts \\ []) do
    with {:store, {:ok, loaded}} <- {:store, Store.load(dir)},
         {:mode, {:ok, mode}} <- {:mode, Mode.load(dir)} do
      GenServer.start_link(__MODULE__, {dir, Map.put(loaded, :mode, mode), opts},
        name: Keyword.get(opts, :name, __MODULE__)
      )
    else
      {:store, {:error, why}} ->
        Logger.error("runtime work: not started, its store is refused: #{why}")
        {:error, {:store, why}}

      {:mode, {:error, why}} ->
        Logger.error("runtime work: not started, its mode is refused: #{why}")
        {:error, {:mode, why}}
    end
  end

  @impl true
  def init({dir, loaded, opts}) do
    # A boot is a change of its own: the sequence moves on, so every position a subscriber
    # holds from before it lies outside the new (empty) window and gets `reset` (§6 step 3).
    sequence = loaded.sequence + 1
    Store.put_sequence!(dir, sequence)

    state = %{
      dir: dir,
      service: Keyword.get(opts, :service, AtlasRuntime.Service),
      works: loaded.works,
      index: loaded.index,
      sequence: sequence,
      incarnation: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
      notifications: Notifications.new(sequence, Keyword.get(opts, :window, 10_000)),
      cursor: nil,
      # false once the Service stops or a stop began (mode/0 is then `stopping`).
      accepting: true,
      # The persisted mode (AtlasRuntime.Work.Mode): new work and starts only while open.
      mode: loaded.mode,
      room: true,
      blocked: MapSet.new(),
      # Slots a latch of a turn not the core's holds: free again only on `{:released, slot}`.
      latched: MapSet.new(),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms, 15_000),
      cancel_grace_ms: Keyword.get(opts, :cancel_grace_ms),
      retention: Keyword.get(opts, :retention, Prune.default_retention()),
      processes: processes(opts),
      after_write: Keyword.get(opts, :after_write, fn _record -> :ok end),
      start_timeout_ms: Keyword.get(opts, :start_timeout_ms, 120_000),
      stop_exit_ms: Keyword.get(opts, :stop_exit_ms, 200),
      # nil, or the stop: %{force, by, exiting} (exiting: the Service is asked to exit).
      stopping: nil,
      context: Provenance.context()
    }

    {:ok, state, {:continue, :boot}}
  end

  ## Boot (design §6)

  @impl true
  def handle_continue(:boot, state) do
    owned = owned_turns(state)

    state =
      state.works
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(state, &boot_work(&2, &1, owned))

    state = follow(state)
    state = refresh_all(state)

    state =
      Enum.reduce(Policy.slots(Policy.load(state.dir)), state, &maybe_release(&2, &1))

    schedule_heartbeat(state)
    {:noreply, state |> Map.put(:room, room?(state)) |> dispatch()}
  end

  def handle_continue(:dispatch, state), do: {:noreply, dispatch(state)}

  # Every live attempt of the work, not only the current one: a superseded attempt may
  # still be cancelling behind a buffered successor.
  defp boot_work(state, id, owned) do
    state.works[id].attempts
    |> Enum.filter(&Queue.live?/1)
    |> Enum.reduce(state, fn attempt, state -> boot_attempt(state, id, attempt, owned) end)
  end

  defp boot_attempt(state, id, attempt, owned) do
    record = state.works[id]
    turn_id = attempt.turn_id || admitted_turn(state, record, attempt)
    turn = turn_id && Turns.read_turn(state.dir, turn_id)
    owned? = turn_id != nil and MapSet.member?(owned, turn_id)

    case Restart.classify(attempt, turn, owned?) do
      :keep when owned? and is_nil(attempt.turn_id) and attempt.state == :starting ->
        running(state, id, attempt.attempt, turn_id)

      :keep when owned? and is_nil(attempt.turn_id) ->
        # A cancel that reached a start the Service left unanswered: stop the turn it found.
        state |> put_turn(id, attempt.attempt, turn_id) |> signal(id, attempt.attempt, "stop")

      :keep ->
        # Only the core restarted: the turn runs on, and so does its time limit.
        if attempt.state == :running and attempt.timestamps.running_at,
          do: deadline(state, record, attempt)

        state

      {:end, outcome} ->
        end_attempt(state, id, attempt.attempt, turn, outcome, turn_id)
    end
  end

  # A starting attempt whose turn ID was not recorded (or one cancelled while so): the
  # Service's admission of its request ID names the turn, if one was started.
  defp admitted_turn(state, record, %{state: live, turn_id: nil} = attempt)
       when live in [:starting, :cancelling] do
    case CommandAdmissions.load(state.dir, Turns.request_id(record.work_id, attempt.attempt)) do
      %{"turn_id" => turn} -> turn
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp admitted_turn(_state, _record, _attempt), do: nil

  defp owned_turns(state) do
    case Turns.read(state.service, {:read, "workers", %{}}) do
      %{"workers" => workers} ->
        for %{"state" => live, "turn" => %{"turn_id" => turn}} <- workers,
            live in ["running", "stopping", "killing"],
            into: MapSet.new(),
            do: turn

      _ ->
        MapSet.new()
    end
  end

  ## Capabilities

  @impl true
  def handle_call({:submit, client, %B.WorkRequest{} = input}, _from, state) do
    case submit(state, client, input) do
      {:reply, outcome, state} -> {:reply, outcome, state, {:continue, :dispatch}}
    end
  end

  def handle_call({:retry, client, %B.RetryInput{} = input}, _from, state) do
    {outcome, state} = retry(state, client, input)
    {:reply, outcome, state, {:continue, :dispatch}}
  end

  def handle_call({:cancel, client, %B.CancelInput{} = input}, _from, state) do
    {outcome, state} = cancel(state, client, input)
    {:reply, outcome, state, {:continue, :dispatch}}
  end

  def handle_call({:get_work, client, %B.GetWorkInput{work_id: id}}, _from, state) do
    outcome =
      case visible(state, client, id) do
        nil ->
          case Enum.find(Map.values(state.index), &(&1.work_id == id and &1.pruned)) do
            %{client: owner} = entry ->
              if Notifications.sees?(client, owner),
                do: %B.Outcome.Pruned{work_id: id, kind: entry.final_kind},
                else: %B.Outcome.NotFound{}

            nil ->
              %B.Outcome.NotFound{}
          end

        record ->
          %B.Outcome.Found{work: view(record, client)}
      end

    {:reply, outcome, state}
  end

  def handle_call(
        {:find_work, {client_id, _} = client, %B.FindWorkInput{client_key: key}},
        _from,
        state
      ) do
    outcome =
      case state.index[{client_id, key}] do
        nil ->
          %B.Outcome.NotFound{}

        %{pruned: true} = entry ->
          %B.Outcome.Pruned{work_id: entry.work_id, kind: entry.final_kind}

        entry ->
          case state.works[entry.work_id] do
            nil -> %B.Outcome.NotFound{}
            record -> %B.Outcome.Found{work: view(record, client)}
          end
      end

    {:reply, outcome, state}
  end

  def handle_call({:list_work, client, %B.ListWorkInput{} = input}, _from, state) do
    works =
      state.works
      |> Map.values()
      |> Enum.filter(&Notifications.sees?(client, &1.client))
      |> Enum.filter(&(is_nil(input.changed_since) or &1.sequence > input.changed_since))
      |> Enum.map(&view(&1, client))
      |> Enum.filter(&(is_nil(input.state) or &1.state == input.state))
      |> Enum.sort_by(& &1.sequence)

    {:reply, %B.Outcome.Works{works: works, sequence: state.sequence}, state}
  end

  def handle_call({:capacity, _client}, _from, state),
    do: {:reply, struct!(B.Outcome.Capacity, Map.from_struct(capacity(state))), state}

  def handle_call({:turn_output, client, %B.TurnOutputInput{} = input}, _from, state) do
    outcome =
      if turn_visible?(state, client, input.turn_id),
        do: output(state, input),
        else: %B.Outcome.NotFound{}

    {:reply, outcome, state}
  end

  def handle_call({:subscribe, client, %B.SubscribeInput{from: from}, pid}, _from, state) do
    {answer, notifications} =
      Notifications.subscribe(state.notifications, pid, client, from, state.sequence)

    outcome =
      case answer do
        :subscribed -> %B.Outcome.Subscribed{}
        {:reset, current} -> %B.Outcome.Reset{current_sequence: current}
      end

    {:reply, outcome, %{state | notifications: notifications}}
  end

  ## Operations (design §13.1 Q8, Q9; `AtlasRuntime.Work`'s I-K functions)

  def handle_call(:mode, _from, state), do: {:reply, mode(state), state}

  def handle_call({:set_mode, mode, by}, _from, state) do
    state = set_mode(state, mode, by)
    {:reply, mode(state), state, {:continue, :dispatch}}
  end

  def handle_call(:runtime, _from, state) do
    capacity = capacity(state)
    busy = Queue.busy(state.works)

    runtime = %{
      home: state.dir,
      runtime_build: capacity.runtime_build,
      incarnation: capacity.incarnation,
      policy_version: capacity.policy_version,
      mode: mode(state),
      slots: for(slot <- Policy.slots(Policy.load(state.dir)), do: {slot, slot in busy})
    }

    {:reply, runtime, state}
  end

  # One stop: a repeat answers the same and signals nothing again.
  def handle_call({:stop, _force, _by}, _from, %{stopping: %{}} = state),
    do: {:reply, :ok, state}

  def handle_call({:stop, force, by}, _from, state) do
    state = %{state | accepting: false, stopping: %{force: force, by: by, exiting: false}}
    state = Enum.reduce(stoppable(state), state, fn {id, n}, state -> find_turn(state, id, n) end)
    if force, do: kill_all(state)
    # The Service stops what it still runs (signal) and starts nothing from here on.
    service_stop(state)
    if not force, do: Process.send_after(self(), :stop_grace, grace_ms(state))
    {:reply, :ok, check_room(state), {:continue, :dispatch}}
  end

  def handle_call({:mark_released, slot, by}, _from, state) do
    if slot_alive?(state, slot) do
      {:reply, :busy, state}
    else
      case Turns.command(state.service, %{"command" => "release", "worker_id" => slot}, 30_000) do
        {:ok, _} ->
          now = now()

          state =
            Enum.reduce(unsettled(state), state, fn {id, attempt}, state ->
              if attempt.slot == slot,
                do: released(state, id, attempt.attempt, by, now),
                else: state
            end)

          state = %{
            state
            | blocked: MapSet.delete(state.blocked, slot),
              latched: MapSet.delete(state.latched, slot)
          }

          {:reply, :released, state, {:continue, :dispatch}}

        {:error, why} ->
          Logger.warning("runtime work: release of #{slot} refused: #{inspect(why)}")
          {:reply, :busy, state}
      end
    end
  end

  def handle_call({:clear_quota_mark, harness}, _from, state) do
    case GenServer.call(state.service, {:clear_quota_mark, harness}, 30_000) do
      :cleared -> {:reply, :cleared, check_room(state), {:continue, :dispatch}}
      answer -> {:reply, answer, state}
    end
  end

  ## Messages

  @impl true
  def handle_info({:events_appended, _sequence}, state),
    do: {:noreply, state |> pull() |> ask_unanswered() |> dispatch()}

  def handle_info(:service_stopping, state), do: {:noreply, service_stopping(state)}

  # The cancel stages' kill for whatever a stop's signal did not end.
  def handle_info(:stop_grace, %{stopping: %{exiting: false}} = state) do
    kill_all(state)
    {:noreply, dispatch(state)}
  end

  def handle_info(:unanswered, state), do: {:noreply, state |> ask_unanswered() |> dispatch()}

  def handle_info({:released, slot}, state) do
    state =
      Enum.reduce(unsettled(state), state, fn {id, attempt}, state ->
        if attempt.slot == slot, do: settle(state, id, attempt.attempt), else: state
      end)

    state = %{
      state
      | blocked: MapSet.delete(state.blocked, slot),
        latched: MapSet.delete(state.latched, slot)
    }

    {:noreply, dispatch(state)}
  end

  def handle_info({:grace, id, n}, state) do
    state =
      case attempt_of(state, id, n) do
        %{state: :cancelling, cancel_stage: stage} when stage in [:requested, :signalled] ->
          signal(state, id, n, "kill")

        _ ->
          state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({:deadline, id, n}, state) do
    state =
      case attempt_of(state, id, n) do
        %{state: :running} -> request_cancel(state, id, n, :time_limit, :graceful)
        _ -> state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info(:heartbeat, state) do
    # One process listing per heartbeat serves the probe and every attempt's `alive`.
    processes = state.processes.()

    state =
      state
      |> probe(processes)
      |> ask_unanswered()
      |> prune()
      |> Map.put(:blocked, MapSet.new())
      |> dispatch()

    heartbeat(state, processes)
    schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | notifications: Notifications.down(state.notifications, pid)}}

  def handle_info(_message, state), do: {:noreply, state}

  ## Submit (§3.2, §3.3)

  defp submit(state, {_client_id, rights} = client, input) do
    cond do
      input.slot && not Enum.member?(rights, :choose_slot) ->
        refused(state, :not_permitted, "naming a slot needs the right choose_slot")

      # D44: only a client holding choose_path (the socket's) names a path on this machine.
      match?(%B.Folder{}, input.workspace) and not Enum.member?(rights, :choose_path) ->
        refused(state, :not_permitted, "a folder workspace needs the right choose_path")

      # The contract leaves folder.path optional (a work shows it only with choose_path);
      # a request must name it.
      match?(%B.Folder{path: nil}, input.workspace) ->
        refused(state, :invalid, "a folder workspace needs its path")

      true ->
        admit(state, client, input)
    end
  end

  defp admit(state, {client_id, _rights} = client, input) do
    policy = Policy.load(state.dir)
    key = input.client_key
    entry = key && state.index[{client_id, key}]
    request = Translation.to_model(input)

    cond do
      entry && entry.pruned ->
        refused(state, :conflict, "client key #{key} named work #{entry.work_id}, pruned")

      entry ->
        case state.works[entry.work_id] do
          %{request: ^request} = record ->
            {:reply, %B.Outcome.Existing{work: view(record, client)}, state}

          _ ->
            refused(state, :conflict, "client key #{key} names another request")
        end

      not open?(state) ->
        {:reply, at_capacity(state, :not_accepting), state}

      input.slot && input.slot not in Policy.slots(policy) ->
        refused(state, :invalid, "unknown slot #{input.slot}")

      match?(%B.Repository{base: base} when base != "develop", input.workspace) ->
        refused(state, :unsupported_workspace, "a repository's base must be develop")

      # S5a guards (s5a-plan P4), each until its package lands: base (P7a), from_work
      # (P9), after_check (P10a). Nothing past them knows these forms yet.
      match?(%B.Base{}, input.workspace) ->
        refused(state, :unsupported_workspace, "base not available")

      match?(%B.FromWork{}, input.workspace) ->
        refused(state, :unsupported_workspace, "from_work not available")

      input.after_check != nil ->
        refused(state, :invalid, "after_check not available")

      true ->
        with {:ok, resume} <- resume_from(state, client, input),
             {:ok, _selection} <- check_policy(state, policy, request, resume),
             true <- room?(state) || {:full} do
          create(state, client, key, request, resume)
        else
          {:refused, reason, detail} -> refused(state, reason, detail)
          {:at_capacity, reason, _} -> {:reply, at_capacity(state, reason), state}
          {:full} -> {:reply, at_capacity(state, :full), state}
        end
    end
  end

  defp resume_from(_state, _client, %{resume_from: nil}), do: {:ok, nil}

  # A turn the caller may not read (§3.2) is one it cannot continue either.
  defp resume_from(state, client, %{resume_from: turn_id, slot: slot}) do
    turn = if turn_visible?(state, client, turn_id), do: Turns.read_turn(state.dir, turn_id)
    point = turn && Turns.resume_point(turn)

    cond do
      is_nil(point) ->
        {:refused, :resume_unavailable, "turn #{turn_id} has no conversation to continue"}

      slot && slot != turn["worker_id"] ->
        {:refused, :resume_unavailable, "turn #{turn_id} continues on slot #{turn["worker_id"]}"}

      true ->
        {:ok, point}
    end
  end

  defp create(state, {client_id, _rights} = client, key, request, resume) do
    id = "work-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    now = now()

    attempt =
      M.Attempt.new!(
        attempt: 1,
        state: :buffered,
        timestamps: M.Timestamps.new!(received_at: now, accepted_at: now),
        resume_point: model_resume_point(resume),
        quiescent: true
      )

    record =
      M.WorkRecord.new!(
        work_id: id,
        client: client_id,
        client_key: key,
        idempotency_key: key || id,
        revision: 0,
        sequence: 0,
        request: request,
        attempts: [attempt]
      )

    state = commit(state, record)

    state =
      if key do
        entry =
          M.KeyIndexEntry.new!(client: client_id, client_key: key, work_id: id, pruned: false)

        index = Map.put(state.index, {client_id, key}, entry)
        Store.put_index!(state.dir, index)
        %{state | index: index}
      else
        state
      end

    {:reply, %B.Outcome.Accepted{work: view(state.works[id], client)}, state}
  end

  ## Retry (§3.2 retry table)

  defp retry(state, client, input) do
    case visible(state, client, input.work_id) do
      nil ->
        {%B.Outcome.NotFound{}, state}

      record when record.client != elem(client, 0) ->
        not_owner(state)

      record ->
        current = Queue.current(record)
        rule = Queue.retry_rule(current)
        resume = if input.resume, do: resume_source(state, record)
        policy = Policy.load(state.dir)

        check =
          cond do
            input.resume && is_nil(resume) ->
              {:refused, :resume_unavailable,
               "no earlier attempt left a conversation to continue"}

            true ->
              check_policy(state, policy, record.request, resume)
          end

        cond do
          match?({:refused, _, _}, check) ->
            {:refused, reason, detail} = check
            {%B.Outcome.Refused{reason: reason, detail: detail}, state}

          match?({:at_capacity, _, _}, check) ->
            {at_capacity(state, :profile_unavailable), state}

          not open?(state) ->
            {at_capacity(state, :not_accepting), state}

          rule != :replace and not room?(state) ->
            {at_capacity(state, :full), state}

          true ->
            state = add_attempt(state, record, current, rule, resume)

            {%B.Outcome.Accepted{work: view(state.works[record.work_id], client)}, state}
        end
    end
  end

  # The newest attempt's conversation: from its turn if it ran, else the point it would
  # have resumed from.
  defp resume_source(state, record) do
    record.attempts
    |> Enum.reverse()
    |> Enum.find_value(fn attempt ->
      turn = attempt.turn_id && Turns.read_turn(state.dir, attempt.turn_id)
      (turn && Turns.resume_point(turn)) || public_point(attempt.resume_point)
    end)
  end

  defp public_point(nil), do: nil

  defp public_point(%M.ResumePoint{} = point),
    do: %{
      turn_id: point.turn_id,
      conversation_id: point.conversation_id,
      workspace: point.workspace && Map.from_struct(point.workspace)
    }

  defp add_attempt(state, record, current, rule, resume) do
    now = now()

    next =
      M.Attempt.new!(
        attempt: current.attempt + 1,
        state: :buffered,
        timestamps: M.Timestamps.new!(received_at: now, accepted_at: now),
        resume_point: model_resume_point(resume),
        quiescent: true
      )

    replaced =
      if rule == :replace,
        do: never_started(current, :superseded, now),
        else: current

    record = %{record | attempts: List.replace_at(record.attempts, -1, replaced) ++ [next]}
    state = commit(state, record)

    if rule == :supersede,
      do: request_cancel(state, record.work_id, current.attempt, :superseded, :graceful),
      else: state
  end

  ## Cancel (§3.7)

  defp cancel(state, client, input) do
    case visible(state, client, input.work_id) do
      nil ->
        {%B.Outcome.NotFound{}, state}

      record when record.client != elem(client, 0) ->
        not_owner(state)

      record ->
        current = Queue.current(record)
        id = record.work_id

        state =
          case Queue.cancel_rule(current) do
            :ended ->
              state

            :never_started ->
              commit(state, put_attempt(record, never_started(current, :cancel, now())))

            :request ->
              request_cancel(state, id, current.attempt, :cancel, input.mode)

            {:escalate, stage} ->
              if input.mode == :force and stage != :forced,
                do: signal(state, id, current.attempt, "kill"),
                else: state
          end

        record = state.works[id]
        current = Queue.current(record)
        work = view(record, client)

        outcome =
          if current.state == :cancelling,
            do: %B.Outcome.Cancelling{stage: current.cancel_stage, work: work},
            else: %B.Outcome.Ended{work: work}

        {outcome, state}
    end
  end

  defp never_started(attempt, reason, now) do
    %{
      attempt
      | state: :cancelled,
        cancel_reason: reason,
        quiescent: true,
        timestamps: %{attempt.timestamps | cancel_requested_at: now, ended_at: now},
        result:
          M.Result.new!(
            kind: :cancelled,
            reason: Atom.to_string(reason),
            retryable: false,
            never_started: true
          )
    }
  end

  # requested is durable before the Service is asked; the signal then moves it on.
  defp request_cancel(state, id, n, reason, mode) do
    attempt = attempt_of(state, id, n)

    attempt = %{
      attempt
      | state: :cancelling,
        cancel_stage: :requested,
        cancel_reason: reason,
        timestamps: %{attempt.timestamps | cancel_requested_at: now()}
    }

    state = commit(state, put_attempt(state.works[id], attempt))
    signal(state, id, n, if(mode == :force, do: "kill", else: "stop"))
  end

  # A cancel of a start the Service left unanswered has no turn ID to signal yet: the
  # admission names the turn if the Service started one; otherwise `ask_unanswered/1`
  # resolves it.
  defp signal(state, id, n, name) do
    state = find_turn(state, id, n)

    case attempt_of(state, id, n) do
      %{turn_id: nil} ->
        send(self(), :unanswered)
        state

      _ ->
        send_signal(state, id, n, name)
    end
  end

  defp send_signal(state, id, n, name) do
    attempt = attempt_of(state, id, n)
    request = %{"command" => name, "worker_id" => attempt.slot, "turn_id" => attempt.turn_id}

    case Turns.command(state.service, request, 30_000) do
      {:ok, _run} ->
        {stage, field} =
          if name == "kill", do: {:forced, :forced_at}, else: {:signalled, :signalled_at}

        attempt = attempt_of(state, id, n)

        attempt = %{
          attempt
          | cancel_stage: stage,
            timestamps: Map.put(attempt.timestamps, field, now())
        }

        state = commit(state, put_attempt(state.works[id], attempt))
        if name == "stop", do: grace(state, id, n)
        state

      {:error, why} ->
        turn = Turns.read_turn(state.dir, attempt.turn_id)

        if turn && not Turns.live?(turn) do
          end_attempt(state, id, n, turn, Turns.outcome(turn, attempt))
        else
          Logger.warning(
            "runtime work: #{name} of #{attempt.turn_id} not confirmed: #{inspect(why)}"
          )

          grace(state, id, n)
          state
        end
    end
  end

  defp find_turn(state, id, n) do
    case admitted_turn(state, state.works[id], attempt_of(state, id, n)) do
      nil -> state
      turn -> put_turn(state, id, n, turn)
    end
  end

  defp put_turn(state, id, n, turn) do
    attempt = %{attempt_of(state, id, n) | turn_id: turn, turn_folder: Path.join("turns", turn)}
    commit(state, put_attempt(state.works[id], attempt))
  end

  defp grace(state, id, n), do: Process.send_after(self(), {:grace, id, n}, grace_ms(state))

  defp grace_ms(state),
    do: state.cancel_grace_ms || Policy.limits(Policy.load(state.dir), "").cancel_grace * 1000

  ## Modes (§3.4, §13.1 Q5, Q6)

  # Persisted (I2) before the work it returns and before the answer. The same mode again
  # writes nothing and returns nothing.
  defp set_mode(%{mode: mode} = state, mode, _by), do: state

  defp set_mode(state, mode, by) do
    Mode.put!(state.dir, mode, by)
    state = %{state | mode: mode}
    state = if mode == :draining, do: return_buffered(state), else: state
    # resume: capacity_available once, when the Runtime takes new work again.
    check_room(state)
  end

  # `stopping` overrides the persisted mode in memory only; it is never written (Q6).
  # `accepting` is false exactly from a stop (`{:stop, …}`) or a Service stop on.
  defp mode(state), do: Mode.effective(state.mode, not state.accepting)

  # New work and starts only while open and not stopping ("mode ≠ open", O1's stop gate).
  defp open?(state), do: state.accepting and state.mode == :open

  # A draining Runtime holds no buffered attempt: each one is returned, never started and
  # retryable, with one work_changed per work (§5). Also an attempt that went back to the
  # buffer while draining, and any left by a crash between `mode.json` and its returns.
  defp return_buffered(state) do
    Enum.reduce(Queue.buffered(state.works), state, fn {id, attempt}, state ->
      now = now()

      returned = %{
        attempt
        | state: :returned,
          quiescent: true,
          timestamps: %{attempt.timestamps | ended_at: now},
          result:
            M.Result.new!(
              kind: :returned,
              retryable: Turns.retryable?(:returned, nil),
              never_started: true
            )
      }

      commit(state, put_attempt(state.works[id], returned))
    end)
  end

  ## Starting (I1)

  defp dispatch(%{mode: :draining} = state), do: state |> return_buffered() |> stop_check()

  defp dispatch(state) do
    Queue.buffered(state.works)
    |> Enum.reduce(state, fn {id, _attempt}, state -> try_start(state, id) end)
    |> stop_check()
  end

  # The gate is read again for each start: a start that found the Service stopping closes
  # it for the ones after it.
  defp try_start(state, id) do
    if open?(state), do: start(state, id), else: state
  end

  defp start(state, id) do
    policy = Policy.load(state.dir)

    # The start path re-reads the record before it takes a slot (§3.7): a cancelled,
    # replaced or returned attempt never starts.
    with %M.WorkRecord{} = record <- Store.read_work(state.dir, id),
         true <- record == state.works[id],
         %{state: :buffered} = attempt <- Queue.current(record),
         true <- Queue.previous_settled?(record),
         {:ok, fixed} <- fixed_slot(state, record, attempt),
         blocked = MapSet.union(state.blocked, state.latched),
         slot when is_binary(slot) <-
           Queue.slot(Policy.slots(policy), Queue.busy(state.works), blocked, fixed) do
      case check_policy(state, policy, record.request, public_point(attempt.resume_point)) do
        {:ok, _selection} -> launch(state, record, attempt, slot)
        {:at_capacity, _reason, _} -> state
        {:refused, reason, detail} -> start_failed(state, id, "launch", "#{reason}: #{detail}")
      end
    else
      {:error, why} -> start_failed(state, id, "launch", why)
      _ -> state
    end
  end

  defp fixed_slot(state, record, attempt) do
    case attempt.resume_point do
      %M.ResumePoint{turn_id: turn_id} ->
        case Turns.read_turn(state.dir, turn_id) do
          %{"worker_id" => slot} -> {:ok, slot}
          _ -> {:error, "the turn to continue, #{turn_id}, is gone"}
        end

      nil ->
        {:ok, record.request.slot}
    end
  end

  defp launch(state, record, attempt, slot) do
    attempt = %{
      attempt
      | state: :starting,
        slot: slot,
        timestamps: %{attempt.timestamps | started_at: now()}
    }

    state = commit(state, put_attempt(record, attempt))
    ask_start(state, record, attempt, slot)
  end

  defp ask_start(state, record, attempt, slot) do
    id = record.work_id
    n = attempt.attempt
    resume = attempt.resume_point && attempt.resume_point.turn_id
    request = Turns.start_request(record, attempt, slot, resume)

    case Turns.command(state.service, request, state.start_timeout_ms) do
      {:ok, %{"admission" => "accepted", "turn_id" => turn}} ->
        running(state, id, n, turn)

      {:ok, reply} ->
        start_failed(state, id, "launch", "not admitted: #{inspect(reply)}")

      {:error, why} when is_binary(why) ->
        cond do
          why =~ "Runtime service is stopping" ->
            back_to_buffer(%{state | accepting: false}, id, nil)

          why =~ ~r/latched/ ->
            # A stop's latch: lifted if the stopped turn is the core's own and settled. Until
            # the Service reports the release, the slot is not tried again: events and
            # heartbeats clear `blocked`, which would start and buffer the attempt each time.
            state = back_to_buffer(state, id, slot)
            maybe_release(%{state | latched: MapSet.put(state.latched, slot)}, slot)

          why =~ ~r/already has an active agent|overlaps active worker/ ->
            back_to_buffer(state, id, slot)

          why =~ ~r/working directory|[Rr]epository|permission scope|[Ww]orkspace/ ->
            start_failed(state, id, "workspace", why)

          true ->
            start_failed(state, id, "launch", why)
        end

      {:error, why} ->
        # The Service may still start the turn (I1): the attempt keeps its slot, and the
        # next event or heartbeat asks the same request there again; the Service's
        # admission of its request ID answers with that turn, if one started
        # (`ask_unanswered/1`).
        Logger.warning("runtime work: Service did not answer a start: #{inspect(why)}")
        state
    end
  end

  # An attempt `starting` outside `launch/4` is a start the Service left unanswered; so is
  # one `cancelling` without a turn, which a cancel reached while so.
  defp ask_unanswered(state) do
    for {id, record} <- state.works,
        %{slot: slot} = attempt <- record.attempts,
        is_binary(slot),
        reduce: state do
      state ->
        case attempt do
          %{state: :starting} when state.accepting ->
            ask_start(state, state.works[id], attempt, slot)

          %{state: :cancelling, turn_id: nil} ->
            resolve_cancelled_start(state, state.works[id], attempt, slot)

          _ ->
            state
        end
    end
  end

  # The same request again: its admission answers the first one's turn, which the cancel
  # then stops. Any other answer means the Service has taken the first request (it takes
  # one at a time) and started nothing for it, unless its admission now names a turn.
  defp resolve_cancelled_start(state, record, attempt, slot) do
    id = record.work_id
    n = attempt.attempt
    resume = attempt.resume_point && attempt.resume_point.turn_id
    request = Turns.start_request(record, attempt, slot, resume)

    case Turns.command(state.service, request, state.start_timeout_ms) do
      {:error, why} when not is_binary(why) ->
        Logger.warning("runtime work: Service did not answer a start: #{inspect(why)}")
        state

      answer ->
        state =
          case answer do
            {:ok, %{"admission" => "accepted", "turn_id" => turn}} -> put_turn(state, id, n, turn)
            _ -> find_turn(state, id, n)
          end

        case attempt_of(state, id, n) do
          %{turn_id: nil, cancel_reason: why} ->
            end_attempt(state, id, n, nil, %{
              kind: :cancelled,
              reason: Atom.to_string(why || :cancel),
              native_outcome: nil,
              quiescent: true,
              answer: nil
            })

          _ ->
            send_signal(state, id, n, "stop")
        end
    end
  end

  defp running(state, id, n, turn) do
    attempt = attempt_of(state, id, n)

    attempt = %{
      attempt
      | state: :running,
        turn_id: turn,
        turn_folder: Path.join("turns", turn),
        timestamps: %{attempt.timestamps | running_at: now()}
    }

    state = commit(state, put_attempt(state.works[id], attempt))
    deadline(state, state.works[id], attempt)
    # A start answered late (asked again after a timeout) may name a turn that has already
    # ended: its end events were pulled while the attempt had no turn ID, so only
    # `turn.json` still tells.
    refresh(state, turn)
  end

  # max_duration counts from running_at.
  defp deadline(state, record, attempt) do
    limits = Policy.limits(Policy.load(state.dir), record.request.profile)
    elapsed = DateTime.diff(now(), attempt.timestamps.running_at, :millisecond)
    remaining = max(limits.max_duration * 1000 - elapsed, 0)
    Process.send_after(self(), {:deadline, record.work_id, attempt.attempt}, remaining)
  end

  defp back_to_buffer(state, id, slot) do
    attempt = Queue.current(state.works[id])

    attempt = %{
      attempt
      | state: :buffered,
        slot: nil,
        timestamps: %{attempt.timestamps | started_at: nil}
    }

    state = commit(state, put_attempt(state.works[id], attempt))
    if slot, do: %{state | blocked: MapSet.put(state.blocked, slot)}, else: state
  end

  defp start_failed(state, id, reason, detail) do
    Logger.warning("runtime work: #{id} did not start (#{reason}): #{detail}")
    attempt = Queue.current(state.works[id])
    now = now()

    attempt = %{
      attempt
      | state: :failed,
        quiescent: true,
        timestamps: %{
          attempt.timestamps
          | started_at: attempt.timestamps.started_at || now,
            ended_at: now
        },
        result:
          M.Result.new!(kind: :failed, reason: reason, retryable: false, never_started: false)
    }

    commit(state, put_attempt(state.works[id], attempt))
  end

  ## Ends

  defp pull(%{cursor: nil} = state), do: state |> follow() |> refresh_all()

  defp pull(state) do
    case Turns.read(state.service, {:follow, self(), state.cursor}) do
      %{"events" => events, "cursor" => cursor} = page ->
        state = %{state | cursor: cursor, blocked: MapSet.new()}

        state =
          if page["reset"],
            do: refresh_all(state),
            else: Enum.reduce(events, state, &refresh(&2, &1["turn_id"]))

        if page["more"], do: pull(state), else: state

      :service_stopping ->
        service_stopping(state)

      _ ->
        state |> follow() |> refresh_all()
    end
  end

  defp follow(state) do
    with %{"events_cursor" => head} <- Turns.read(state.service, {:read, "workers", %{}}),
         %{"cursor" => cursor} <- Turns.read(state.service, {:follow, self(), head}) do
      %{state | cursor: cursor}
    else
      :service_stopping -> service_stopping(%{state | cursor: nil})
      _ -> %{state | cursor: nil}
    end
  end

  defp refresh_all(state) do
    for(
      {id, record} <- state.works,
      attempt <- record.attempts,
      Queue.live?(attempt),
      attempt.turn_id,
      do: {id, attempt.turn_id}
    )
    |> Enum.reduce(state, fn {_id, turn}, state -> refresh(state, turn) end)
  end

  defp refresh(state, turn_id) when is_binary(turn_id) do
    found =
      Enum.find_value(state.works, fn {id, record} ->
        Enum.find_value(
          record.attempts,
          &((&1.turn_id == turn_id and Queue.live?(&1)) && {id, &1})
        )
      end)

    with {id, attempt} <- found,
         %{} = turn <- Turns.read_turn(state.dir, turn_id),
         false <- Turns.live?(turn) do
      end_attempt(state, id, attempt.attempt, turn, Turns.outcome(turn, attempt))
    else
      _ -> state
    end
  end

  defp refresh(state, _turn_id), do: state

  defp end_attempt(state, id, n, turn, outcome, turn_id \\ nil) do
    # A turn a stop ended is the stop's (§13.1 Q9): interrupted, runtime_stop.
    outcome =
      if state.stopping && outcome.kind == :interrupted,
        do: %{outcome | reason: "runtime_stop"},
        else: outcome

    record = state.works[id]
    attempt = attempt_of(state, id, n)
    turn_id = turn_id || attempt.turn_id
    now = now()
    ended_at = (turn && time(turn["ended_at"])) || now

    result =
      M.Result.new!(
        kind: outcome.kind,
        reason: outcome.reason,
        retryable: Turns.retryable?(outcome.kind, outcome.reason),
        native_outcome: outcome.native_outcome,
        never_started: false,
        answer: outcome.answer,
        log:
          turn_id &&
            M.Log.new!(
              complete: turn != nil and outcome.kind != :crashed,
              missing_bytes: 0,
              ref: turn_id
            )
      )

    attempt = %{
      attempt
      | state: outcome.kind,
        turn_id: turn_id,
        quiescent: outcome.quiescent,
        result: result,
        resume_point:
          (turn && model_resume_point(Turns.resume_point(turn))) || attempt.resume_point,
        provenance: turn && provenance(state, record, attempt, turn),
        timestamps: %{attempt.timestamps | ended_at: ended_at}
    }

    state = commit(state, put_attempt(record, attempt))
    if attempt.quiescent and attempt.slot, do: maybe_release(state, attempt.slot), else: state
  end

  # One record per turn, written once, when the attempt ends.
  defp provenance(state, record, attempt, turn) do
    selection =
      case turn["selection"] do
        %{"profile" => profile} = selection when is_binary(profile) ->
          selection

        other ->
          %{
            "profile" => record.request.profile,
            "policy_version" => Policy.version(Policy.load(state.dir)) || 0,
            "option" => Turns.option(turn),
            "reason" => (is_map(other) && other["reason"]) || "continuation",
            "skipped" => []
          }
      end

    fields = Provenance.record(turn, selection, state.context)
    option = fields["selection"]["option"]

    skipped =
      for skipped <- fields["selection"]["skipped"] || [],
          is_map(skipped["option"]),
          do:
            M.SkippedOption.new!(
              option: Translation.model_option(skipped["option"]),
              why: to_string(skipped["why"])
            )

    M.Provenance.new(
      executor_kind: :agent,
      provider: fields["provider"] || "unknown",
      harness: fields["harness"] || "unknown",
      harness_version: fields["harness_version"],
      runtime_build: fields["runtime_build"],
      machine: fields["machine"],
      slot: fields["slot"] || attempt.slot,
      # Required at the boundary: the turn's, else the model it reported.
      configured_model: fields["configured_model"] || fields["reported_model"] || "unknown",
      reported_model: fields["reported_model"],
      selection:
        M.Selection.new!(
          profile: fields["selection"]["profile"] || record.request.profile,
          policy_version: fields["selection"]["policy_version"] || 0,
          option:
            if(is_map(option),
              do: Translation.model_option(option),
              else: M.Option.new!(provider: "unknown", harness: "unknown", model: "unknown")
            ),
          reason: fields["selection"]["reason"] || "preferred",
          skipped: skipped
        ),
      conversation_id: fields["conversation_id"],
      turn_id: fields["turn_id"],
      continues: fields["continues"],
      started_at: time(fields["started_at"]) || attempt.timestamps.started_at || now(),
      ended_at: time(fields["ended_at"])
    )
    |> case do
      {:ok, provenance} ->
        provenance

      {:error, error} ->
        Logger.warning(
          "runtime work: provenance of #{turn["id"]} not recorded: #{inspect(error)}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning(
        "runtime work: provenance of #{turn["id"]} not recorded: #{Exception.message(error)}"
      )

      nil
  end

  ## Quiescence (I1): the probe, release

  defp unsettled(state) do
    for {id, record} <- state.works,
        attempt <- record.attempts,
        Queue.terminal?(attempt) and not attempt.quiescent,
        do: {id, attempt}
  end

  defp processes(opts) do
    case Keyword.fetch(opts, :probe) do
      {:ok, probe} -> fn -> probe end
      :error -> Keyword.get(opts, :processes, &Restart.processes/0)
    end
  end

  defp probe(state, processes) do
    Enum.reduce(unsettled(state), state, fn {id, attempt}, state ->
      if attempt.turn_id && Restart.gone?(state.dir, attempt.turn_id, processes),
        do: settle(state, id, attempt.attempt),
        else: state
    end)
  end

  defp settle(state, id, n) do
    attempt = %{attempt_of(state, id, n) | quiescent: true}
    state = commit(state, put_attempt(state.works[id], attempt))
    if attempt.slot, do: maybe_release(state, attempt.slot), else: state
  end

  # The admission latch a stop left on a slot is the core's to lift once its own turn there
  # has ended for certain and nothing of the core holds the slot.
  defp maybe_release(state, slot) do
    latch =
      try do
        History.latch(state.dir, slot)
      rescue
        _ -> nil
      end

    ours? =
      latch != nil and
        Enum.any?(Map.values(state.works), fn record ->
          Enum.any?(record.attempts, &(&1.turn_id == latch["turn_id"]))
        end)

    if ours? and not MapSet.member?(Queue.busy(state.works), slot) do
      case Turns.command(state.service, %{"command" => "release", "worker_id" => slot}, 30_000) do
        {:ok, _} ->
          :ok

        {:error, why} ->
          Logger.warning("runtime work: release of #{slot} refused: #{inspect(why)}")
      end
    end

    state
  end

  ## Stop (§13.1 Q9)

  # The Service is exiting (its service stop, from wherever it was asked): no new work.
  defp service_stopping(state),
    do: %{
      state
      | accepting: false,
        stopping: state.stopping || %{force: false, by: nil, exiting: true}
    }

  # Every live attempt: what a stop must see end.
  defp stoppable(state) do
    for {id, record} <- state.works,
        attempt <- record.attempts,
        Queue.live?(attempt),
        do: {id, attempt.attempt}
  end

  # The kill, through the Service's own `kill`, for each live attempt that has a turn. The
  # attempt itself is unchanged: it ends when its turn does.
  defp kill_all(state) do
    for {id, n} <- stoppable(state),
        %{turn_id: turn, slot: slot} when is_binary(turn) <- [attempt_of(state, id, n)] do
      request = %{"command" => "kill", "worker_id" => slot, "turn_id" => turn}

      case Turns.command(state.service, request, 30_000) do
        {:ok, _} -> :ok
        {:error, why} -> Logger.warning("runtime work: kill of #{turn} refused: #{inspect(why)}")
      end
    end

    :ok
  end

  defp service_stop(state) do
    case GenServer.call(state.service, %{"command" => "service-stop"}, 60_000) do
      {%{command_error: why}, _shutdown?} -> {:pending, why}
      {_reply, shutdown?} -> {:ok, shutdown?}
    end
  catch
    :exit, why -> {:pending, {:exit, why}}
  end

  # Once no attempt is live the Service's service stop ends the process (it does once it
  # owns nothing either; until then each event or heartbeat asks again). A start the Service
  # never answered is asked for its turn first; with none, now that the Service starts
  # nothing, it never started.
  defp stop_check(%{stopping: %{exiting: false}} = state) do
    state =
      for {id, record} <- state.works,
          %{state: :starting, turn_id: nil, attempt: n} <- record.attempts,
          service_stopping?(state),
          reduce: state do
        state ->
          state = find_turn(state, id, n)

          case attempt_of(state, id, n) do
            %{turn_id: nil} ->
              end_attempt(state, id, n, nil, %{
                kind: :interrupted,
                reason: nil,
                native_outcome: nil,
                quiescent: true,
                answer: nil
              })

            _ ->
              state
          end
      end

    with [] <- stoppable(state),
         {:ok, true} <- service_stop(state) do
      Process.send_after(state.service, :shutdown, state.stop_exit_ms)
      put_in(state.stopping.exiting, true)
    else
      _ -> state
    end
  end

  defp stop_check(state), do: state

  defp service_stopping?(state),
    do: match?(%{"service" => "stopping"}, Turns.read(state.service, {:read, "workers", %{}}))

  ## Release (§13.1 Q8)

  # Alive: a turn of the slot runs in this incarnation (the core's live attempt, or a turn
  # the Service owns), or the process probe finds the process of the slot's unconfirmed
  # turn, or of the turn its latch names, still there.
  defp slot_alive?(state, slot) do
    live? = Enum.any?(stoppable(state), fn {id, n} -> attempt_of(state, id, n).slot == slot end)

    owned? =
      case Turns.read(state.service, {:read, "workers", %{}}) do
        %{"workers" => workers} ->
          Enum.any?(
            workers,
            &(&1["worker_id"] == slot and &1["state"] in ["running", "stopping", "killing"])
          )

        _ ->
          false
      end

    latched =
      try do
        History.latch(state.dir, slot)
      rescue
        _ -> nil
      end

    turns =
      for({_id, attempt} <- unsettled(state), attempt.slot == slot, do: attempt.turn_id) ++
        [latched && latched["turn_id"]]

    live? or owned? or probed_alive?(state, turns)
  end

  # One process listing for this release decision, as the heartbeat takes one per beat.
  defp probed_alive?(state, turns) do
    case Enum.filter(turns, &is_binary/1) do
      [] ->
        false

      turns ->
        processes = state.processes.()
        Enum.any?(turns, &Restart.alive?(state.dir, &1, processes))
    end
  end

  defp released(state, id, n, by, now) do
    attempt = %{attempt_of(state, id, n) | quiescent: true, released_by: by, released_at: now}
    commit(state, put_attempt(state.works[id], attempt))
  end

  ## Pruning

  # The tombstone is written, then the record deleted, then the change mentioned (I2, I7).
  # A work without a client key keeps its tombstone under `{:pruned, work_id}`, which no
  # client key looks up (`Store`).
  defp prune(state) do
    Enum.reduce(Prune.due(state.works, now(), state.retention), state, fn id, state ->
      record = state.works[id]
      final = Queue.current(record).state

      entry =
        M.KeyIndexEntry.new!(
          client: record.client,
          client_key: record.client_key || id,
          work_id: id,
          final_kind: final,
          pruned: true
        )

      key = if record.client_key, do: {record.client, record.client_key}, else: {:pruned, id}
      index = Map.put(state.index, key, entry)
      Store.put_index!(state.dir, index)
      Store.delete_work!(state.dir, id)

      sequence = state.sequence + 1
      Store.put_sequence!(state.dir, sequence)

      change = %B.WorkChanged{
        sequence: sequence,
        work_id: id,
        revision: record.revision + 1,
        state: final
      }

      %{
        state
        | index: index,
          works: Map.delete(state.works, id),
          sequence: sequence,
          notifications: Notifications.work_changed(state.notifications, change, record.client)
      }
    end)
  end

  ## Persisting and notifying

  # Write-ahead (I2): written, then mentioned.
  defp commit(state, record) do
    sequence = state.sequence + 1
    record = %{record | revision: record.revision + 1, sequence: sequence}
    Store.put_work!(state.dir, record)
    Store.put_sequence!(state.dir, sequence)
    state.after_write.(record)
    state = %{state | works: Map.put(state.works, record.work_id, record), sequence: sequence}

    change = %B.WorkChanged{
      sequence: sequence,
      work_id: record.work_id,
      revision: record.revision,
      state: Queue.current(record).state
    }

    notifications = Notifications.work_changed(state.notifications, change, record.client)
    check_room(%{state | notifications: notifications})
  end

  # capacity_available once, when the Runtime goes from taking no new work to taking some.
  defp check_room(state) do
    room = room?(state)

    if room and not state.room do
      sequence = state.sequence + 1
      Store.put_sequence!(state.dir, sequence)
      change = %B.CapacityAvailable{sequence: sequence, capacity: capacity(state)}
      notifications = Notifications.capacity_available(state.notifications, change)
      %{state | sequence: sequence, notifications: notifications, room: true}
    else
      %{state | room: room}
    end
  end

  defp heartbeat(state, processes) do
    activity =
      case Turns.read(state.service, {:read, "workers", %{}}) do
        %{"workers" => workers} ->
          for %{"turn" => %{"turn_id" => turn} = info} <- workers,
              into: %{},
              do: {turn, info["activity"]}

        _ ->
          %{}
      end

    running =
      for {id, record} <- state.works,
          attempt <- record.attempts,
          Queue.live?(attempt) do
        {record.client,
         %B.RunningAttempt{
           work_id: id,
           attempt: attempt.attempt,
           state: attempt.state,
           alive:
             attempt.turn_id != nil and Restart.alive?(state.dir, attempt.turn_id, processes),
           last_progress_at: attempt.turn_id && progress(state.dir, attempt.turn_id),
           activity: attempt.turn_id && activity[attempt.turn_id]
         }}
      end

    Notifications.heartbeat(state.notifications, now(), capacity(state), running)
  end

  # The time of the turn's last harness event or output byte: its newest file.
  defp progress(dir, turn_id) do
    folder = Path.join([dir, "turns", turn_id])

    case File.ls(folder) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn name ->
          case File.stat(Path.join(folder, name), time: :posix) do
            {:ok, %{type: :regular, mtime: mtime}} -> [mtime]
            _ -> []
          end
        end)
        |> Enum.max(fn -> nil end)
        |> then(&(&1 && DateTime.from_unix!(&1)))

      _ ->
        nil
    end
  end

  defp schedule_heartbeat(state), do: Process.send_after(self(), :heartbeat, state.heartbeat_ms)

  ## Capacity (§3.4)

  defp room?(state) do
    policy = Policy.load(state.dir)

    open?(state) and
      Queue.counts(state.works, Policy.slots(policy), Policy.buffer_size(policy)).available > 0
  end

  defp capacity(state) do
    policy = Policy.load(state.dir)
    counts = Queue.counts(state.works, Policy.slots(policy), Policy.buffer_size(policy))
    room = open?(state) and counts.available > 0

    profiles =
      policy
      |> Policy.profiles(availability(state), &installed?/1, System.system_time(:second))
      |> Enum.sort()
      |> Enum.map(fn {name, status} ->
        %B.ProfileAvailability{
          profile: name,
          available: status.available,
          reason: status[:reason],
          until: status[:until]
        }
      end)

    %B.Capacity{
      slots: struct!(B.SlotCounts, counts.slots),
      buffer: struct!(B.BufferCounts, counts.buffer),
      profiles: profiles,
      accepting: open?(state),
      policy_version: Policy.version(policy) || 0,
      runtime_build: state.context.runtime_build,
      incarnation: state.incarnation,
      retry_after: if(room, do: nil, else: Policy.limits(policy, "").retry_after)
    }
  end

  defp at_capacity(state, reason) do
    capacity = capacity(state)

    %B.Outcome.AtCapacity{
      reason: reason,
      retry_after: capacity.retry_after || Policy.limits(Policy.load(state.dir), "").retry_after,
      capacity: capacity
    }
  end

  ## Policy (design §7, through D1's `AtlasRuntime.Policy`)

  defp check_policy(state, policy, request, resume) do
    resume_option =
      case resume do
        nil -> nil
        %{turn_id: turn_id} -> (turn = Turns.read_turn(state.dir, turn_id)) && Turns.option(turn)
      end

    if resume && is_nil(resume_option) do
      {:refused, :resume_unavailable, "the turn to continue names no option"}
    else
      Policy.resolve(
        policy,
        availability(state),
        %{
          profile: request.profile,
          cost_class: request.cost_class,
          permission: Turns.permission(request.workspace),
          resume: resume_option
        },
        &installed?/1,
        System.system_time(:second)
      )
    end
  end

  defp availability(state) do
    Availability.load(state.dir)
  rescue
    error ->
      Logger.error("runtime work: availability unreadable: #{Exception.message(error)}")
      Availability.empty()
  end

  defp installed?(harness), do: System.find_executable(harness) != nil

  ## Turn output

  defp output(state, %{turn_id: turn_id, cursor: cursor}) do
    args =
      if cursor, do: %{"turn_id" => turn_id, "cursor" => cursor}, else: %{"turn_id" => turn_id}

    case Turns.read(state.service, {:read, "output", args}) do
      %{"events" => events, "cursor" => next} = page ->
        %B.Outcome.Page{
          events: Enum.flat_map(events, &output_event/1),
          cursor: next,
          more: page["more"] == true
        }

      %{"error" => %{"code" => "unknown_turn"}} ->
        %B.Outcome.NotFound{}

      _ ->
        %B.Outcome.Page{events: [], cursor: cursor || "", more: false}
    end
  end

  defp output_event(%{"sequence" => sequence, "kind" => kind, "text" => text})
       when kind in ["text", "activity"],
       do: [%B.OutputEvent{sequence: sequence, kind: String.to_existing_atom(kind), text: text}]

  defp output_event(%{"sequence" => sequence, "kind" => "tool"} = event),
    do: [
      %B.OutputEvent{
        sequence: sequence,
        kind: :activity,
        text: "#{event["tool_name"]} #{event["status"]}"
      }
    ]

  defp output_event(_), do: []

  ## Helpers

  # The owner of the work that ran the turn may read it; a turn of no work only read_all.
  defp turn_visible?(state, client, turn_id) do
    owner =
      Enum.find_value(Map.values(state.works), fn record ->
        if Enum.any?(record.attempts, &(&1.turn_id == turn_id)), do: record.client
      end)

    Notifications.sees?(client, owner)
  end

  defp visible(state, client, id) do
    case state.works[id] do
      %{client: owner} = record -> if Notifications.sees?(client, owner), do: record
      nil -> nil
    end
  end

  # A work as this client may see it: paths on this machine only with choose_path (D44).
  defp view(record, {_id, rights}), do: Translation.from_model(record, rights)

  defp refused(state, reason, detail),
    do: {:reply, %B.Outcome.Refused{reason: reason, detail: detail}, state}

  # §3.2 Ownership: retry and cancel act only on the caller's own work. A work another
  # client owns is visible here only through read_all, which grants reading, never acting.
  defp not_owner(state),
    do:
      {%B.Outcome.Refused{reason: :not_permitted, detail: "the work is another client's"}, state}

  # nil once the work is gone (a timer may outlive a pruned work).
  defp attempt_of(state, id, n) do
    case state.works[id] do
      nil -> nil
      record -> Enum.find(record.attempts, &(&1.attempt == n))
    end
  end

  defp put_attempt(record, attempt) do
    %{
      record
      | attempts:
          Enum.map(record.attempts, fn a ->
            if a.attempt == attempt.attempt, do: attempt, else: a
          end)
    }
  end

  defp model_resume_point(nil), do: nil

  defp model_resume_point(point) do
    M.ResumePoint.new!(
      turn_id: point.turn_id,
      conversation_id: point.conversation_id,
      workspace:
        point.workspace &&
          M.WorkspaceState.new!(
            path: point.workspace.path,
            branch: point.workspace[:branch],
            commit: point.workspace[:commit]
          )
    )
  end

  defp time(nil), do: nil

  defp time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> DateTime.truncate(at, :millisecond)
      _ -> nil
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:millisecond)
end
