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
  probe instead), `start_timeout_ms` (how long a start may take, 120 s), `prepare_timeout_ms`
  (how long preparing a Runtime-chosen folder may take, 600 s), `prepare_hook` (called by a
  preparer with `:moved_aside`, and with `:composing` for `from_work`, tests), `freeze_hook` (called with each frozen result once it
  is written and before the `completed` commit names it, tests), `after_write` (called with
  each record just written, before anything mentions it), `stop_exit_ms` (how long after the last attempt of a stop
  ended the Service exits, 200 ms, so the stop's answer is out first) and `check_helper`
  (`{executable, leading_args}` that runs `host check`, default `$ATLAS_RUNTIME_EXECUTABLE`;
  tests pass a stand-in).

  **Runtime-chosen folders (s5a-plan B6, B25, B30).** A `base` work runs in
  `<home>/workers/work-<work_id>` (`AtlasRuntime.Work.Folders`). `launch/4` commits `starting`
  with the attempt's `folder` and `preparing: true`, then a preparer materializes the base
  there; the server never waits on it. Its helper's OS pid is committed as `prepare_pid`
  before the preparer waits on it. When the folder is ready the core commits `preparing:
  false` and only then asks the Service to start. A failed, crashed or timed-out preparation
  ends the attempt `failed: workspace`, not retryable, and no turn is asked. A cancel or a
  `max_duration` deadline while preparing records `cancel_stage: requested` and nothing more:
  when the preparer ends the attempt ends `cancelled` (or `failed: time_limit`). At boot,
  `Folders.sweep/1` runs first, and a `preparing` attempt ends `interrupted` with `quiescent`
  false while its `prepare_pid` may live. A fresh retry rebuilds the folder; it starts only
  once every earlier attempt is terminal and quiescent (`Queue.previous_settled?/1`), so no
  process of an earlier attempt can still write the folder. A `retry resume: true` continues
  in the same folder without preparing it.

  **New work based on an earlier result (design §3.9; s5a-plan B2–B5, P9).** A `from_work`
  work names a work the caller may read (unknown or unreadable: `refused: not_permitted`, one
  detail for both) and, optionally, one of its attempts; without one, the latest `completed`
  attempt, resolved at accept and pinned on the record as `source` (the stored request stays
  the submitted one). A work without a frozen result there is `unsupported_workspace`, a pruned
  one `pruned` (a result another work still names is retained and accepted). Its folder is
  the same `<home>/workers/work-<work_id>`, composed at start by a preparer from the source's
  frozen result: the base it was frozen against plus exactly its change set, read-only on disk
  or writable (`snapshot compose`, never Code). Every attempt composes from the pinned source,
  so a fresh retry rebuilds the same starting tree. It always runs in a fresh conversation:
  `resume_from` is `invalid`, `retry resume: true` is `resume_unavailable`. A completed
  attempt is frozen against the original base (cumulative) and records `based_on`, the
  source's attempt and fingerprints.

  **Frozen results (design §3.9; s5a-plan B8–B11).** An attempt that ends `completed` in a
  `base` folder (or a `folder{materialized-folder}` with a materialization record) is frozen
  first (`AtlasRuntime.Work.Frozen`): the frozen record is written, and only then the
  `completed` commit names it in `work_product` (`workspace`, `frozen`), so nothing reports
  `completed` before the frozen result exists (I2). A freeze that is refused (a change outside
  every root, a helper refusal, a missing baseline of a Runtime-chosen folder) ends the
  attempt `failed: workspace`, not retryable, with its answer and log; it never ends
  `completed` without its frozen result. At boot, a frozen record whose attempt was never
  committed `completed` is deleted (`Restart.orphans/2`), and that attempt ends
  `interrupted`, not `completed`.

  **After-check (design §3.10; s5a-plan B16–B18, B23, B24, B28; P10a).** A work may carry
  `after_check: {command, timeout}`. At submit it is checked in this order: only a `base` or
  `from_work` work (the folder the Runtime chose, whose turn ran as `materialized-folder` or
  read-only, the two profiles the check can carry; otherwise `unsupported_workspace`), the
  argv rules and the timeout cap (`invalid`), the profile's `allow_after_check`
  (`policy_forbids`), and `codex` on the core's `PATH` (`AtlasRuntime.Work.Check.available?/0`,
  never cached; without it `policy_forbids`, detail `after_check_unavailable`). When the turn
  ends with a result that would make the attempt `completed` (and no cancel was asked for), the
  frozen result is written first, then the agent's result is committed with the private
  `checking: true` and `check_started_at`; the attempt stays `running` at the boundary and its
  result is not projected. The `max_duration` timer is cancelled. The check then runs beside
  the server (`Check.start/2`) with the turn's own sandbox (from its `turn.json`), in the
  work's folder, its scratch `<home>/scratch/check-<work_id>.<n>`, and the only write that
  reports `completed` carries `work_product.check` and `check_ended_at` (I2). Whatever the
  check does, the attempt ends `completed`: a helper refusal and a `codex` gone at check time
  (`sandbox_unavailable`, nothing started) are `check.error`, as is a helper that failed
  after starting the check (`helper_failed`, I-H3 amendment (c)). A check whose group was not
  confirmed gone (that failure, or `group_gone: false`) leaves the attempt not `quiescent`
  until the probe finds the group gone. A client without `choose_path` reads the check's
  output tail with the work folder as `.` and any other Runtime home path as `<runtime-home>`
  (designer decision 2026-11-17).

  **Checking under cancel, deadline, restart (design §5, §6 step 2; s5a-plan B19–B21, P10b).**
  `checking` is a sub-stage of `running`: whatever stops the check, the attempt ends
  `completed`, never `cancelling`, `cancelled`, `failed` or `interrupted`. A `cancel` (or a
  `retry` that supersedes it) runs the cancel stages on the check's group: `cancel_stage:
  requested` and `cancel_requested_at` are committed, then the helper is told
  `{"stop":"signal"}` (`signalled`, `signalled_at`) or, with `force`, `{"stop":"kill"}`
  (`forced`, `forced_at`), and after `cancel_grace` a check still running is killed. The
  answer is `cancelling(stage, work)` while the attempt stays `running`; it ends `completed`
  with `check.cancelled: true`. A `max_duration` deadline that reaches the core during the
  check is ignored. At boot a `checking` attempt is not checked again: it ends `completed`
  with `check.interrupted: true` and `check_ended_at` = the boot time, its frozen result kept
  (B9), and not `quiescent` while a recorded `check_pgid` may live (the old helper lost its
  stdin and stops the group itself). The heartbeat probe settles it once that group is
  provably gone, and only then removes the check's scratch (B24); the same holds for a check
  that ended without its group confirmed gone. While checking, the heartbeat's `alive` is the
  check group's.

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

  alias AtlasRuntime.Work.{
    Check,
    Folders,
    Frozen,
    FrozenStore,
    Mode,
    Notifications,
    Prune,
    Queue,
    Restart,
    Store,
    Translation,
    Turns
  }

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
      freeze_hook: Keyword.get(opts, :freeze_hook, fn _frozen -> :ok end),
      # At boot: the attempts whose frozen record a crash left uncommitted (B9).
      orphaned: MapSet.new(),
      start_timeout_ms: Keyword.get(opts, :start_timeout_ms, 120_000),
      prepare_timeout_ms: Keyword.get(opts, :prepare_timeout_ms, 600_000),
      prepare_hook: Keyword.get(opts, :prepare_hook),
      # The running preparers (B25): their monitor ref => {work_id, attempt}.
      preparers: %{},
      stop_exit_ms: Keyword.get(opts, :stop_exit_ms, 200),
      check_helper: Keyword.get(opts, :check_helper),
      # The running after-checks (P10a): their monitor ref => {work_id, attempt, pid}.
      checks: %{},
      # The max_duration timers: {work_id, attempt} => timer ref, cancelled when checking starts.
      deadlines: %{},
      # nil, or the stop: %{force, by, exiting} (exiting: the Service is asked to exit).
      stopping: nil,
      context: Provenance.context()
    }

    {:ok, state, {:continue, :boot}}
  end

  ## Boot (design §6)

  @impl true
  def handle_continue(:boot, state) do
    # Before any attempt starts: a rebuild's moved-aside folder a crash left (B30).
    Folders.sweep(state.dir)
    # Before any attempt ends: a frozen record its attempt never committed (B9).
    state = %{state | orphaned: Restart.orphans(state.dir, state.works)}
    # Retention of frozen results, after the orphans are gone (B12).
    state = prune_frozen(state)
    owned = owned_turns(state)

    state =
      state.works
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(state, &boot_work(&2, &1, owned))

    state = %{state | orphaned: MapSet.new()}
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
      :checking ->
        # The check is never run again (B21): completed, interrupted, its frozen result kept.
        finish_check(state, id, attempt.attempt, Restart.interrupted_check(attempt, now()))

      :keep when owned? and is_nil(attempt.turn_id) and attempt.state == :starting ->
        running(state, id, attempt.attempt, turn_id)

      :keep when owned? and is_nil(attempt.turn_id) ->
        # A cancel that reached a start the Service left unanswered: stop the turn it found.
        state |> put_turn(id, attempt.attempt, turn_id) |> signal(id, attempt.attempt, "stop")

      :keep ->
        # Only the core restarted: the turn runs on, and so does its time limit.
        if attempt.state == :running and attempt.timestamps.running_at,
          do: deadline(state, record, attempt),
          else: state

      {:end, outcome} ->
        outcome =
          if MapSet.member?(state.orphaned, {id, attempt.attempt}),
            do: Restart.unfrozen(outcome),
            else: outcome

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
          case Store.tombstone(state.index, id) do
            %{client: owner} = entry ->
              if Notifications.sees?(client, owner),
                do: %B.Outcome.Pruned{work_id: id, kind: entry.final_kind},
                else: %B.Outcome.NotFound{}

            nil ->
              %B.Outcome.NotFound{}
          end

        record ->
          %B.Outcome.Found{work: project(state, client, record)}
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
            record -> %B.Outcome.Found{work: project(state, client, record)}
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
      |> Enum.map(&project(state, client, &1))
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

  def handle_call({:get_frozen, client, %B.GetFrozenInput{} = input}, _from, state),
    do: {:reply, get_frozen(state, client, input), state}

  def handle_call({:get_frozen_blob, client, %B.GetFrozenBlobInput{} = input}, _from, state),
    do: {:reply, get_frozen_blob(state, client, input), state}

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
        %{checking: true, cancel_stage: stage} when stage in [:requested, :signalled] ->
          signal(state, id, n, "kill")

        %{state: :cancelling, cancel_stage: stage} when stage in [:requested, :signalled] ->
          signal(state, id, n, "kill")

        _ ->
          state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({:prepare_pid, ref, os_pid, preparer}, state),
    do: {:noreply, prepare_pid(state, ref, os_pid, preparer)}

  def handle_info({:folder_ready, ref, result}, state),
    do: {:noreply, state |> folder_ready(ref, result) |> dispatch()}

  def handle_info({:prepare_deadline, id, n}, state) do
    state =
      case attempt_of(state, id, n) do
        %{state: :starting, preparing: true} ->
          request_cancel(state, id, n, :time_limit, :graceful)

        _ ->
          state
      end

    {:noreply, dispatch(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{preparers: preparers} = state)
      when is_map_key(preparers, ref),
      do:
        {:noreply,
         state |> folder_ready(ref, {:error, "preparer ended: #{inspect(reason)}"}) |> dispatch()}

  def handle_info({:check_started, pid, pgid}, state),
    do: {:noreply, check_started(state, pid, pgid)}

  def handle_info({:check_ended, pid, result}, state) do
    case Enum.find(state.checks, fn {_ref, {_id, _n, check}} -> check == pid end) do
      {ref, {id, n, _pid}} ->
        Process.demonitor(ref, [:flush])
        state = %{state | checks: Map.delete(state.checks, ref)}
        {:noreply, state |> finish_check(id, n, result) |> dispatch()}

      nil ->
        {:noreply, state}
    end
  end

  # A check process that ended without its result: its helper may have started the group.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{checks: checks} = state)
      when is_map_key(checks, ref) do
    {{id, n, _pid}, checks} = Map.pop(checks, ref)
    Logger.warning("runtime work: #{id} attempt #{n}: the check ended early: #{inspect(reason)}")

    pgid =
      case attempt_of(state, id, n) do
        %{check_pgid: pgid} -> pgid
        nil -> nil
      end

    result = %{Check.refused(:helper_failed) | pgid: pgid, quiescent: is_nil(pgid)}
    {:noreply, %{state | checks: checks} |> finish_check(id, n, result) |> dispatch()}
  end

  def handle_info({:deadline, id, n}, state) do
    state =
      case attempt_of(state, id, n) do
        # The check is not counted in max_duration (§3.10, B20): a deadline that raced it is late.
        %{checking: true} -> state
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
            {:reply, %B.Outcome.Existing{work: project(state, client, record)}, state}

          _ ->
            refused(state, :conflict, "client key #{key} names another request")
        end

      not open?(state) ->
        {:reply, at_capacity(state, :not_accepting), state}

      input.slot && input.slot not in Policy.slots(policy) ->
        refused(state, :invalid, "unknown slot #{input.slot}")

      match?(%B.Repository{base: base} when base != "develop", input.workspace) ->
        refused(state, :unsupported_workspace, "a repository's base must be develop")

      # Until S5c a base is a Code snapshot (§12 exception, B27).
      match?(%B.Base{}, input.workspace) and
          not Regex.match?(~r/\Asha256:[0-9a-f]{64}\z/, input.workspace.base_id) ->
        refused(state, :invalid, "base_id must be a Code snapshot id until S5c")

      # The conversation's folder would not be this work's folder (B29, DQ10).
      match?(%B.Base{}, input.workspace) and input.resume_from != nil ->
        refused(state, :invalid, "resume_from cannot continue into a base workspace")

      # A from_work work always runs in a fresh conversation (§3.9, B5).
      match?(%B.FromWork{}, input.workspace) and input.resume_from != nil ->
        refused(state, :invalid, "resume_from cannot be combined with from_work")

      # The after-check runs in the Runtime-chosen folder only, whose turn ran under one of
      # the two profiles `host check` carries (materialized-folder, read-only; B18, P10a).
      input.after_check != nil and
          not match?(%kind{} when kind in [B.Base, B.FromWork], input.workspace) ->
        refused(
          state,
          :unsupported_workspace,
          "after_check runs only in a base or from_work workspace"
        )

      input.after_check != nil and after_check(policy, input) != :ok ->
        {reason, detail} = after_check(policy, input)
        refused(state, reason, detail)

      true ->
        with {:ok, source} <- source(state, client, input.workspace),
             {:ok, resume} <- resume_from(state, client, input),
             {:ok, _selection} <- check_policy(state, policy, request, resume),
             true <- room?(state) || {:full} do
          create(state, client, key, request, resume, source)
        else
          {:refused, reason, detail} -> refused(state, reason, detail)
          {:pruned, outcome} -> {:reply, outcome, state}
          {:at_capacity, reason, _} -> {:reply, at_capacity(state, reason), state}
          {:full} -> {:reply, at_capacity(state, :full), state}
        end
    end
  end

  # B16, in order: the argv and timeout (invalid), the profile (policy_forbids), and a
  # `codex` on the core's PATH, looked up now (B23: never cached).
  defp after_check(policy, %B.WorkRequest{after_check: check, profile: profile}) do
    rules = Policy.after_check(policy, profile)

    with :ok <- Check.validate(check, rules.max_timeout) do
      cond do
        not rules.allowed -> {:policy_forbids, "after_check not allowed by profile"}
        not Check.available?() -> {:policy_forbids, "after_check_unavailable"}
        true -> :ok
      end
    end
  end

  # The frozen result a from_work work composes from (§3.9; B2–B4): `{:ok, %M.Source{}}`
  # (nil for every other workspace), `{:refused, …}` or `{:pruned, outcome}`. Visibility is
  # get_work's (read_all widens); an unknown work and one the caller may not read get the same
  # answer, so nothing tells them apart. Without `attempt`, the latest completed one, resolved
  # now and pinned. Once the work record is pruned, its key tombstone decides visibility and a
  # result another work still names is retained (B12), so it is accepted; otherwise `pruned`.
  defp source(state, client, %B.FromWork{work_id: id, attempt: n}) do
    hidden = {:refused, :not_permitted, "from_work names no work this client may read"}

    case state.works[id] do
      %M.WorkRecord{client: owner} = record ->
        n = n || latest_completed(record)

        cond do
          not Notifications.sees?(client, owner) ->
            hidden

          Frozen.kind(record) == :never ->
            {:refused, :unsupported_workspace,
             "work #{id} has no frozen result: its workspace has no base"}

          is_integer(n) and match?(%{state: :completed}, attempt_of(state, id, n)) and
              match?({:ok, %{pruned: false}}, FrozenStore.read(state.dir, id, n)) ->
            {:ok, M.Source.new!(work_id: id, attempt: n)}

          true ->
            {:refused, :unsupported_workspace,
             "work #{id} has no completed attempt#{n && " #{n}"} with a frozen result"}
        end

      nil ->
        with %M.KeyIndexEntry{client: owner} = entry <- Store.tombstone(state.index, id),
             true <- Notifications.sees?(client, owner) do
          n = n || List.last(FrozenStore.attempts(state.dir, id))

          case is_integer(n) && FrozenStore.read(state.dir, id, n) do
            {:ok, %{pruned: false}} -> {:ok, M.Source.new!(work_id: id, attempt: n)}
            _ -> {:pruned, %B.Outcome.Pruned{work_id: id, kind: entry.final_kind}}
          end
        else
          _ -> hidden
        end
    end
  end

  defp source(_state, _client, _workspace), do: {:ok, nil}

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

  defp create(state, {client_id, _rights} = client, key, request, resume, source) do
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
        attempts: [attempt],
        source: source
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

    {:reply, %B.Outcome.Accepted{work: project(state, client, state.works[id])}, state}
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
            # A from_work work always runs in a fresh conversation (§3.9, B5).
            input.resume && match?(%M.FromWork{}, record.request.workspace) ->
              {:refused, :resume_unavailable,
               "a from_work work always runs in a fresh conversation"}

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

            {%B.Outcome.Accepted{work: project(state, client, state.works[record.work_id])},
             state}
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
          case cancel_rule(current) do
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
        work = project(state, client, record)

        outcome =
          if current.state == :cancelling or check_cancelling?(current),
            do: %B.Outcome.Cancelling{stage: current.cancel_stage, work: work},
            else: %B.Outcome.Ended{work: work}

        {outcome, state}
    end
  end

  # A check being cancelled stays `running` at the boundary (B20): a second cancel only
  # escalates its stage, as for a `cancelling` attempt.
  defp cancel_rule(attempt) do
    if check_cancelling?(attempt),
      do: {:escalate, attempt.cancel_stage},
      else: Queue.cancel_rule(attempt)
  end

  defp check_cancelling?(attempt),
    do: Map.get(attempt, :checking) == true and attempt.cancel_stage != nil

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

  # requested is durable before the Service is asked; the signal then moves it on. During the
  # check the attempt stays running (B20): the stages apply to the check's group, and the end
  # is the check's, completed.
  defp request_cancel(state, id, n, reason, mode) do
    case attempt_of(state, id, n) do
      %{checking: true, cancel_stage: stage} when stage != nil ->
        if mode == :force and stage != :forced, do: signal(state, id, n, "kill"), else: state

      attempt ->
        request_stage(state, id, n, attempt, reason, mode)
    end
  end

  defp request_stage(state, id, n, attempt, reason, mode) do
    attempt = %{
      attempt
      | state: if(attempt.checking == true, do: attempt.state, else: :cancelling),
        cancel_stage: :requested,
        cancel_reason: reason,
        timestamps: %{attempt.timestamps | cancel_requested_at: now()}
    }

    state = commit(state, put_attempt(state.works[id], attempt))
    signal(state, id, n, if(mode == :force, do: "kill", else: "stop"))
  end

  # While its folder is being prepared no turn was asked: the cancel stays `requested` until
  # the preparer ends (B25).
  defp signal(state, id, n, name) do
    case attempt_of(state, id, n) do
      %{preparing: true} -> state
      %{checking: true} -> signal_check(state, id, n, name)
      _ -> signal_turn(state, id, n, name)
    end
  end

  # The cancel stages on a check (B19, B20): the helper signals the group (SIGINT) or kills it
  # (SIGKILL); the stage and its time are committed once the helper was told, and a signal is
  # followed by the kill after cancel_grace.
  defp signal_check(state, id, n, name) do
    case Enum.find(state.checks, fn {_ref, {i, m, _pid}} -> i == id and m == n end) do
      {_ref, {_id, _n, pid}} ->
        Check.stop(pid, if(name == "kill", do: :kill, else: :signal))

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

      nil ->
        # No check process (it is ending): its end completes the attempt.
        state
    end
  end

  # A cancel of a start the Service left unanswered has no turn ID to signal yet: the
  # admission names the turn if the Service started one; otherwise `ask_unanswered/1`
  # resolves it.
  defp signal_turn(state, id, n, name) do
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

  defp launch(state, %{request: %{workspace: %kind{}}} = record, attempt, slot)
       when kind in [M.Base, M.FromWork] do
    folder = Folders.path(state.dir, record.work_id)
    # A resume continues the conversation in the folder as its turn left it (B29); a
    # from_work attempt never resumes (B5), so it is always composed.
    preparing = is_nil(attempt.resume_point)

    attempt = %{
      attempt
      | state: :starting,
        slot: slot,
        folder: folder,
        preparing: preparing,
        prepare_pid: nil,
        timestamps: %{attempt.timestamps | started_at: now()}
    }

    state = commit(state, put_attempt(record, attempt))

    if preparing,
      do: prepare(state, record, attempt),
      else: ask_start(state, record, attempt, slot)
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

  # The preparer runs beside the server (F17); its deadline counts from the start, as the
  # turn's will count from running_at (B25).
  defp prepare(state, record, attempt) do
    spec = %{
      home: state.dir,
      work_id: record.work_id,
      attempt: attempt.attempt,
      read_only: record.request.workspace.permissions == :read_only,
      timeout_ms: state.prepare_timeout_ms,
      hook: state.prepare_hook
    }

    # base: materialized from base_id; from_work: composed from the pinned source (B4).
    {kind, spec} =
      case record.request.workspace do
        %M.Base{base_id: base_id} ->
          {:materialize, Map.put(spec, :base_id, base_id)}

        %M.FromWork{} ->
          {:compose, Map.put(spec, :source, {record.source.work_id, record.source.attempt})}
      end

    {_pid, ref} = Folders.prepare(kind, spec, self())
    limits = Policy.limits(Policy.load(state.dir), record.request.profile)

    Process.send_after(
      self(),
      {:prepare_deadline, record.work_id, attempt.attempt},
      limits.max_duration * 1000
    )

    %{state | preparers: Map.put(state.preparers, ref, {record.work_id, attempt.attempt})}
  end

  defp prepare_pid(state, ref, os_pid, preparer) do
    case state.preparers[ref] do
      {id, n} ->
        state =
          case attempt_of(state, id, n) do
            %{preparing: true} = attempt ->
              commit(state, put_attempt(state.works[id], %{attempt | prepare_pid: os_pid}))

            _ ->
              state
          end

        send(preparer, {:prepare_pid_recorded, ref})
        state

      nil ->
        send(preparer, {:prepare_pid_recorded, ref})
        state
    end
  end

  # The preparer ended: with its result, or (a `:DOWN` without one) as a failure.
  defp folder_ready(state, ref, result) do
    case Map.pop(state.preparers, ref) do
      {nil, _} ->
        state

      {{id, n}, preparers} ->
        Process.demonitor(ref, [:flush])
        state = %{state | preparers: preparers}

        case attempt_of(state, id, n) do
          %{state: :starting, preparing: true} = attempt when result == :ok ->
            attempt = %{attempt | preparing: false}
            state = commit(state, put_attempt(state.works[id], attempt))
            ask_start(state, state.works[id], attempt, attempt.slot)

          %{state: :starting, preparing: true} ->
            {:error, detail} = result
            prepare_failed(state, id, n, detail)

          %{state: :cancelling, preparing: true} = attempt ->
            {kind, reason} =
              if attempt.cancel_reason == :time_limit,
                do: {:failed, "time_limit"},
                else: {:cancelled, Atom.to_string(attempt.cancel_reason || :cancel)}

            end_attempt(state, id, n, nil, %{
              kind: kind,
              reason: reason,
              native_outcome: nil,
              quiescent: true,
              answer: nil
            })

          _ ->
            state
        end
    end
  end

  # As start_failed/4, for attempt n: the detail goes only to the log (F17).
  defp prepare_failed(state, id, n, detail) do
    Logger.warning("runtime work: #{id} attempt #{n} did not start (workspace): #{detail}")
    attempt = attempt_of(state, id, n)
    now = now()

    attempt = %{
      attempt
      | state: :failed,
        preparing: false,
        quiescent: true,
        timestamps: %{attempt.timestamps | ended_at: now},
        result:
          M.Result.new!(
            kind: :failed,
            reason: "workspace",
            retryable: false,
            never_started: false
          )
    }

    state = commit(state, put_attempt(state.works[id], attempt))
    maybe_release(state, attempt.slot)
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
          # A folder being prepared has asked nothing yet (B25).
          %{preparing: true} ->
            state

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
    state = deadline(state, state.works[id], attempt)
    # A start answered late (asked again after a timeout) may name a turn that has already
    # ended: its end events were pulled while the attempt had no turn ID, so only
    # `turn.json` still tells.
    refresh(state, turn)
  end

  # max_duration counts from running_at. Its timer is kept so that the check can cancel it
  # (P10a: the check is not counted in max_duration, §3.10).
  defp deadline(state, record, attempt) do
    limits = Policy.limits(Policy.load(state.dir), record.request.profile)
    elapsed = DateTime.diff(now(), attempt.timestamps.running_at, :millisecond)
    remaining = max(limits.max_duration * 1000 - elapsed, 0)
    key = {record.work_id, attempt.attempt}
    timer = Process.send_after(self(), {:deadline, record.work_id, attempt.attempt}, remaining)
    %{state | deadlines: Map.put(state.deadlines, key, timer)}
  end

  defp cancel_deadline(state, id, n) do
    case Map.pop(state.deadlines, {id, n}) do
      {nil, _} ->
        state

      {timer, deadlines} ->
        # A timer that already fired has its message queued: it is taken back too.
        if Process.cancel_timer(timer) == false do
          receive do
            {:deadline, ^id, ^n} -> :ok
          after
            0 -> :ok
          end
        end

        %{state | deadlines: deadlines}
    end
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

  # An attempt in its checking sub-stage has its agent's end persisted already: only the
  # check's end moves it on (P10a; the turn's events, a refresh or a signal's answer never
  # end it again, and so never freeze or check it twice).
  defp end_attempt(state, id, n, turn, outcome, turn_id \\ nil) do
    case attempt_of(state, id, n) do
      %{checking: true} -> state
      _ -> agent_ended(state, id, n, turn, outcome, turn_id)
    end
  end

  defp agent_ended(state, id, n, turn, outcome, turn_id) do
    # A turn a stop ended is the stop's (§13.1 Q9): interrupted, runtime_stop.
    outcome =
      if state.stopping && outcome.kind == :interrupted,
        do: %{outcome | reason: "runtime_stop"},
        else: outcome

    record = state.works[id]
    attempt = attempt_of(state, id, n)
    # Frozen before the commit that reports completed (I2, B9); refused, it is failed (B10).
    {outcome, work_product} = freeze(state, record, attempt, outcome)
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
        work_product: work_product,
        log:
          turn_id &&
            M.Log.new!(
              complete: turn != nil and outcome.kind != :crashed,
              missing_bytes: 0,
              ref: turn_id
            )
      )

    ended = %{
      attempt
      | state: outcome.kind,
        turn_id: turn_id,
        preparing: if(attempt.preparing, do: false, else: attempt.preparing),
        quiescent: outcome.quiescent,
        result: result,
        resume_point:
          (turn && model_resume_point(Turns.resume_point(turn))) || attempt.resume_point,
        provenance: turn && provenance(state, record, attempt, turn),
        timestamps: %{attempt.timestamps | ended_at: ended_at}
    }

    cond do
      check?(record, attempt, outcome, work_product) and attempt.cancel_stage != nil ->
        # A cancel asked for before this result, which the result wins (§5): the cancel stops
        # only the check (§3.10, B20, D43), here before it starts. One write, completed, carries
        # the check as cancelled; nothing is run (P10a fix M1).
        check = check_record(record, Check.cancelled())
        product = %{work_product | check: check}

        ended = %{
          ended
          | result: %{result | work_product: product},
            timestamps: %{
              ended.timestamps
              | check_started_at: now,
                check_ended_at: now,
                ended_at: now
            }
        }

        state = commit(state, put_attempt(record, ended))
        if ended.quiescent and ended.slot, do: maybe_release(state, ended.slot), else: state

      check?(record, attempt, outcome, work_product) ->
        # The agent's result, work_product.workspace and the frozen result are persisted before
        # the check starts (§3.10, I2); the attempt stays running until the check's end.
        checking = %{
          ended
          | state: attempt.state,
            checking: true,
            check_pgid: nil,
            timestamps: %{attempt.timestamps | check_started_at: now()}
        }

        state = commit(state, put_attempt(record, checking))
        state |> cancel_deadline(id, n) |> start_check(id, n)

      true ->
        state = commit(state, put_attempt(record, ended))
        if ended.quiescent and ended.slot, do: maybe_release(state, ended.slot), else: state
    end
  end

  # Only an attempt that ends completed (its result frozen: a base or from_work folder) has a
  # check (§3.10). One whose cancel was asked for before its result records the check as
  # cancelled without running it (`agent_ended/6`).
  defp check?(
         %{request: %{after_check: %M.AfterCheck{}}},
         _attempt,
         %{kind: :completed},
         product
       ),
       do: product != nil

  defp check?(_record, _attempt, _outcome, _product), do: false

  defp check_record(record, result) do
    M.CheckResult.new!(
      command: record.request.after_check.command,
      exit_status: result.exit_status,
      signal: result.signal,
      error: result.error,
      timed_out: result.timed_out,
      cancelled: result.cancelled,
      interrupted: Map.get(result, :interrupted, false),
      duration_ms: result.duration_ms,
      output: M.CheckOutput.new!(tail: result.output.tail, complete: result.output.complete)
    )
  end

  ## After-check (§3.10; s5a-plan B18, B23, B24, B28)

  # codex gone since submit: the check is not run, and nothing is started (B23).
  defp start_check(state, id, n) do
    record = state.works[id]
    attempt = attempt_of(state, id, n)
    sandbox = Check.sandbox(Turns.read_turn(state.dir, attempt.turn_id) || %{})

    cond do
      not Check.available?() ->
        finish_check(state, id, n, Check.unavailable())

      sandbox == :unsupported ->
        Logger.warning(
          "runtime work: #{id} attempt #{n}: its turn's sandbox cannot run the check; not run"
        )

        finish_check(state, id, n, Check.unavailable())

      true ->
        rules = Policy.after_check(Policy.load(state.dir), record.request.profile)
        check = record.request.after_check

        spec = %{
          home: state.dir,
          cwd: Frozen.folder(record, attempt),
          sandbox: sandbox,
          scratch: Check.scratch(state.dir, id, n),
          timeout: check.timeout || rules.default_timeout,
          grace: max(div(grace_ms(state) + 999, 1000), 1),
          command: check.command,
          helper: state.check_helper
        }

        {:ok, pid} = Check.start(spec, self())
        ref = Process.monitor(pid)
        %{state | checks: Map.put(state.checks, ref, {id, n, pid})}
    end
  end

  defp check_started(state, pid, pgid) do
    case Enum.find(state.checks, fn {_ref, {_id, _n, check}} -> check == pid end) do
      {_ref, {id, n, _pid}} ->
        case attempt_of(state, id, n) do
          %{checking: true} = attempt ->
            commit(state, put_attempt(state.works[id], %{attempt | check_pgid: pgid}))

          _ ->
            state
        end

      nil ->
        state
    end
  end

  # The one write that reports completed carries the check (I2). The attempt is quiescent once
  # its turn was and the check's group is confirmed gone; otherwise the probe settles it.
  defp finish_check(state, id, n, result) do
    case attempt_of(state, id, n) do
      %{checking: true} = attempt ->
        record = state.works[id]
        now = now()

        check = check_record(record, result)
        product = %{attempt.result.work_product | check: check}

        attempt = %{
          attempt
          | state: :completed,
            checking: false,
            check_pgid: result.pgid || attempt.check_pgid,
            quiescent: attempt.quiescent and result.quiescent,
            result: %{attempt.result | work_product: product},
            timestamps: %{attempt.timestamps | check_ended_at: now, ended_at: now}
        }

        state = commit(state, put_attempt(record, attempt))
        if attempt.quiescent and attempt.slot, do: maybe_release(state, attempt.slot), else: state

      _ ->
        state
    end
  end

  # Only a completed attempt is frozen; every other end keeps no work product (B8).
  defp freeze(state, record, attempt, %{kind: :completed} = outcome) do
    folder = Frozen.folder(record, attempt)

    with {:ok, based_on} <- based_on(state, record),
         {:ok, frozen} <- Frozen.freeze(state.dir, record, attempt, folder) do
      state.freeze_hook.(frozen)

      product =
        M.WorkProduct.new!(
          workspace:
            M.ProductWorkspace.new!(
              path: folder,
              changed: Enum.any?(frozen.roots, &(&1.entries != []))
            ),
          frozen:
            M.FrozenRef.new!(
              base: frozen.base,
              fingerprints:
                for(root <- frozen.roots, do: %{root: root.root, fingerprint: root.fingerprint})
            ),
          based_on: based_on
        )

      {outcome, product}
    else
      :not_frozen ->
        {outcome, nil}

      {:error, detail} ->
        Logger.warning(
          "runtime work: #{record.work_id} attempt #{attempt.attempt} failed (workspace), " <>
            "its result could not be frozen: #{detail}"
        )

        {%{outcome | kind: :failed, reason: "workspace"}, nil}
    end
  end

  defp freeze(_state, _record, _attempt, outcome), do: {outcome, nil}

  # A from_work result records the frozen result it was composed from: the pinned source's
  # attempt and fingerprints (§3.9). That result is retained while this work exists (B12),
  # and a tombstone keeps its fingerprints too.
  defp based_on(_state, %M.WorkRecord{source: nil}), do: {:ok, nil}

  defp based_on(state, %M.WorkRecord{source: %{work_id: id, attempt: n}}) do
    case FrozenStore.read(state.dir, id, n) do
      {:ok, source} ->
        {:ok,
         M.BasedOn.new!(
           work_id: id,
           attempt: n,
           fingerprints:
             for(root <- source.roots, do: %{root: root.root, fingerprint: root.fingerprint})
         )}

      :not_found ->
        {:error, "the frozen result #{id}.#{n} it was composed from is gone"}
    end
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

  # A turn whose end was never confirmed, or (B25) the helper of a preparation a restart
  # interrupted, once provably gone.
  defp probe(state, processes) do
    Enum.reduce(unsettled(state), state, fn {id, attempt}, state ->
      # A check whose group was not confirmed gone (P10a) must be gone too.
      gone? =
        if attempt.turn_id,
          do:
            Restart.gone?(state.dir, attempt.turn_id, processes) and
              Check.gone?(attempt, processes),
          else: Restart.prepare_gone?(attempt, processes)

      cond do
        not gone? ->
          state

        attempt.timestamps.check_started_at ->
          # The check's group is provably gone: its scratch may go now, never before (B21,
          # B24); the helper keeps it when it could not confirm that itself.
          Restart.remove_check_scratch(state.dir, id, attempt.attempt)
          settle(state, id, attempt.attempt)

        true ->
          settle(state, id, attempt.attempt)
      end
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
          %{state: :starting, turn_id: nil, attempt: n} = attempt <- record.attempts,
          attempt.preparing != true,
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
  # Once works are pruned, the frozen results nothing retains any longer become tombstones
  # and their unshared blobs go (B12, `prune_frozen/1`).
  defp prune(state) do
    case Prune.due(state.works, now(), state.retention) do
      [] -> state
      due -> due |> Enum.reduce(state, &prune_work(&2, &1)) |> prune_frozen()
    end
  end

  # Frozen results' retention (B12): after the works are pruned, and once at boot (a crash
  # between a work's deletion and this step leaves nothing behind). It runs inside this
  # process, so no freeze is between its helper's blobs and its record meanwhile.
  defp prune_frozen(state) do
    for {id, n} <- FrozenStore.prune(state.dir, state.works, state.index),
        do: Logger.info("runtime work: frozen result #{id}.#{n} pruned (tombstone kept)")

    state
  end

  defp prune_work(state, id) do
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
  end

  ## Reading frozen results (design §3.9; s5a-plan B1, B12, B13)

  # get_frozen: the change set with each root's fingerprint; a given fingerprint must be one
  # root's (else fingerprint_mismatch). Reads only: nothing is written.
  defp get_frozen(state, client, %B.GetFrozenInput{} = input) do
    case frozen_result(state, client, input.work_id, input.attempt) do
      {:ok, frozen} ->
        if input.fingerprint &&
             not Enum.any?(frozen.roots, &(&1.fingerprint == input.fingerprint)),
           do: %B.Outcome.FingerprintMismatch{},
           else:
             struct!(
               B.Outcome.Frozen,
               Map.from_struct(Translation.frozen(frozen, redaction(state, client, frozen)))
             )

      {:pruned, outcome} ->
        outcome

      :not_found ->
        %B.Outcome.NotFound{}
    end
  end

  # get_frozen_blob: only the content of a write entry of that very frozen result (B13); a
  # blob of any other result is not_found here even if the store holds it. A file's blob is
  # streamed from the store in chunks of at most 64 KiB, opened only when the caller reads
  # it (FrozenStore.blob/2); a symlink's content is its target.
  defp get_frozen_blob(state, client, %B.GetFrozenBlobInput{} = input) do
    with {:ok, frozen} <- frozen_result(state, client, input.work_id, input.attempt),
         %{} = entry <- write_entry(frozen, input.sha256),
         content when content != nil <- blob_content(state, client, frozen, entry) do
      %B.Outcome.Blob{sha256: entry.sha256, size: entry.size, content: content}
    else
      {:pruned, outcome} -> outcome
      _ -> %B.Outcome.NotFound{}
    end
  end

  # Attempt n (default: the latest completed one) of a work the client may read:
  # `{:ok, frozen}`, `{:pruned, outcome}` for a tombstone, or `:not_found`. While the work
  # record exists it decides visibility (read_all widens, as for get_work), and only a
  # `completed` attempt's result is readable. Once the record is pruned the key tombstone's
  # client decides visibility, and the store the default attempt (only completed attempts are
  # ever frozen, B9): a retained result still answers `frozen` (B12).
  defp frozen_result(state, client, id, n) do
    case state.works[id] do
      %M.WorkRecord{client: owner} = record ->
        with true <- Notifications.sees?(client, owner),
             n when is_integer(n) <- n || latest_completed(record),
             %{state: :completed} <- Enum.find(record.attempts, &(&1.attempt == n)) do
          stored(state, id, n, :completed)
        else
          _ -> :not_found
        end

      nil ->
        with %M.KeyIndexEntry{client: owner} = entry <- Store.tombstone(state.index, id),
             true <- Notifications.sees?(client, owner),
             n when is_integer(n) <- n || List.last(FrozenStore.attempts(state.dir, id)) do
          stored(state, id, n, entry.final_kind)
        else
          _ -> :not_found
        end
    end
  end

  defp stored(state, id, n, kind) do
    case FrozenStore.read(state.dir, id, n) do
      {:ok, %{pruned: true}} -> {:pruned, %B.Outcome.Pruned{work_id: id, kind: kind}}
      {:ok, frozen} -> {:ok, frozen}
      :not_found -> :not_found
    end
  end

  defp latest_completed(record) do
    record.attempts
    |> Enum.filter(&(&1.state == :completed))
    |> List.last()
    |> case do
      nil -> nil
      attempt -> attempt.attempt
    end
  end

  defp write_entry(frozen, sha256) do
    Enum.find_value(frozen.roots, fn root ->
      Enum.find(root.entries, &(&1.op == :write and &1.sha256 == sha256))
    end)
  end

  defp blob_content(state, _client, _frozen, %{kind: :file, sha256: sha}),
    do: FrozenStore.blob(state.dir, sha)

  defp blob_content(state, client, frozen, %{kind: :symlink, target: target}),
    do: [redaction(state, client, frozen).(target)]

  # D44 (designer's open item on frozen-result paths): a client without choose_path never
  # sees a path on the Runtime's machine. A symlink target is the one free text a change set
  # carries; as for a check's output tail, the work's folder becomes `.` and any other path
  # under the Runtime home `<runtime-home>`, by plain prefix replacement. The fingerprint and
  # sha256 stay those of the frozen content. A client with choose_path sees the target as is.
  defp redaction(state, client, %{work_id: id}), do: redaction(state, client, id, nil)

  # `folder`: a client-named folder the work ran in (a socket client's `folder` work), also `.`.
  defp redaction(state, {_id, rights}, work_id, folder) do
    if :choose_path in rights do
      & &1
    else
      home = Path.expand(state.dir)
      real_home = Folders.real(home)
      own = Folders.path(state.dir, work_id)

      prefixes =
        Enum.uniq(
          for(path <- [folder], is_binary(path), do: {path, "."}) ++
            [
              {own, "."},
              {Path.join([home, "workers", "work-" <> work_id]), "."},
              {real_home, "<runtime-home>"},
              {home, "<runtime-home>"}
            ]
        )

      fn text ->
        Enum.reduce(prefixes, text, fn {from, to}, text -> String.replace(text, from, to) end)
      end
    end
  end

  # A work as this client may see it: paths on this machine only with choose_path (D44); and
  # (designer decision 2026-11-17 on the check's output tail) for a client without choose_path
  # the tail names its work folder `.` and any other Runtime home path `<runtime-home>`; exit
  # status, signal and the flags are unchanged.
  defp project(state, {_id, rights} = client, %M.WorkRecord{} = record) do
    folder =
      case record.request.workspace do
        %M.Folder{path: path} -> path
        _ -> nil
      end

    Translation.from_model_redacting(
      record,
      rights,
      redaction(state, client, record.work_id, folder)
    )
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
           alive: alive?(state, attempt, processes),
           last_progress_at: attempt.turn_id && progress(state.dir, attempt.turn_id),
           activity: attempt.turn_id && activity[attempt.turn_id]
         }}
      end

    Notifications.heartbeat(state.notifications, now(), capacity(state), running)
  end

  # While checking, the check's group is what runs (B21); otherwise the turn's.
  defp alive?(_state, %{checking: true} = attempt, processes),
    do: Restart.check_alive?(attempt, processes)

  defp alive?(state, attempt, processes),
    do: attempt.turn_id != nil and Restart.alive?(state.dir, attempt.turn_id, processes)

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
