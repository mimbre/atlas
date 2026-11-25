defmodule AtlasRuntime.Sources.Puller.Target do
  @moduledoc """
  How a puller reaches its work source (M2 plan A2): the `work_source` contract's `poll` and
  `report`, answered in the puller's terms, and the source as `AtlasRuntime.Sources.Upload`
  reaches it for one lease's `ended` at a given report revision. The in-BEAM target is
  `AtlasRuntime.Sources.InBeamTarget`, the HTTP client target
  `AtlasRuntime.Sources.HttpTarget`. A target may also export `close(ref)`, called when the
  puller ends.
  """

  @type polled :: %{
          leases: [map()],
          cancel: [String.t()],
          lease_lost: [String.t()],
          timing: %{lease_ttl: pos_integer(), poll_max: pos_integer()}
        }

  @callback poll(ref :: term(), input :: map()) ::
              {:polled, polled()} | {:rejected, atom()} | {:error, term()}
  @callback send_report(ref :: term(), input :: map()) ::
              {:recorded, [String.t()]} | :lease_lost | {:rejected, atom()} | {:error, term()}
  @callback uploader(ref :: term(), revision :: pos_integer()) ::
              AtlasRuntime.Sources.Upload.source()
  @doc """
  One blob of the lease's input (`get_blob`, M2 A3): `{:ok, %{sha256, size, content}}`, the
  content an Enumerable of binaries, or anything else when the source does not serve it.
  """
  @callback get_blob(ref :: term(), lease_id :: String.t(), sha256 :: String.t()) ::
              {:ok, AtlasRuntime.Sources.Store.blob()} | term()
end

defmodule AtlasRuntime.Sources.Puller do
  @moduledoc """
  The puller of one work source (decision §5.2, §5.3; M2 plan A2): the only thing that talks
  to the source, and the source's only way to the executor.

  **The fence check never waits on I/O (Main's round 2).** The puller process itself only
  reads its clock, its leases and the executor. Everything that reaches the source or the
  disk for a lease (the poll, the import of a lease's input, every report, the upload of
  `ended` and its blobs) runs in a task under the puller's own `Task.Supervisor`, at most one
  per lease at a time. Its answer comes back as a message. Each task but the poll has a
  deadline, read from the puller's clock at each check:
  - an import: `import_timeout_ms`, always below the grace (`lease_ttl` + 2 min). A timeout
    kills the task, and the accepted attempt ends `failed` (reason `workspace`, never
    started), which is reported `ended`;
  - a report: `report_timeout_ms` (35 s); an upload: `upload_timeout_ms` (10 min). A
    timeout kills the task, and the next check sends the report again.

  So a slow import or a hung report never delays self-fencing. A fenced or lost lease's
  task is killed, and its answer is dropped.

  **One poll, always open.** The poll carries the Runtime's `runtime_id`, the core's
  `incarnation` (new on each boot), `build`, `policy_version`, the offer (`Work.offer/1`,
  empty when full, paused or draining) and the holdings (the persisted records of the
  source's client, `Work.holdings/1`). It is sent also when the offer is empty: it is the
  renewal and the cancel channel. While a poll with an empty offer is open, each check asks
  `Work.offer/1` again: when a slot is free again, that poll is ended and sent at once with
  the new offer. A poll that offers slots is left to its answer, and the next one takes the
  new offer: ending it could lose a lease the source has already granted.

  **The answer.**
  - `timing` sets `lease_ttl` and `poll_max`.
  - `configuration`, when the source serves one (IS-Atlas-27): the `policy.json` its
    supervisor set through Control, applied or refused by `AtlasRuntime.Configuration`
    once the rest of the answer is handled. A refusal (`%{version, reason}`) goes with
    every later poll as `configuration_refused` until a configuration is applied; the next
    poll after an applied one carries its version as `policy_version`.
  - Every holding it carried that is not in `lease_lost` is renewed **at the poll's send
    time** (`LeaseClock.stamp/1` read just before the poll left), never at the reply's.
  - `lease_lost`: the attempt is cancelled (never started when it had not), and nothing of
    that lease is reported again.
  - `cancel`: the attempt is cancelled through the cancel stages (§3.7); the lease stays
    current, and its `ended` is uploaded.
  - each lease: **accepted first** (Main's #330 F5 (b)): `Work.accept_lease/2` (persisted,
    held, its import pending), then the report `accepted`, well within the source's 30 s
    accept deadline. A refused accept is reported `refused(reason)` and creates no work.
    On `recorded`, a remote lease's input is imported in a task (phase `:importing`; M2 A3:
    `AtlasRuntime.Sources.Import.base/5`, every blob from this source through the target's
    `get_blob`, into its own store), under the lease's normal renewal and fenced like any
    running work. Its held attempt keeps its slot while that import runs, and only then
    (F5 (a)). Once imported, `Work.lease_imported/2` sets the base and
    `Work.release_lease/1` lets the attempt start. An import that is refused, fails or
    passes its deadline ends the attempt `failed` (never started), so its slot is free, and
    it is reported `ended`. The local source's leases carry their request and no input, so
    nothing is imported: they are released on `recorded`. A local retry's lease whose
    profile is unavailable now (`{:unavailable, _}`, F5 (c)) is left unanswered, so the
    source queues it again at its accept deadline.

  **Reports.** The revision of a lease's report follows from its attempt, so nothing more is
  persisted and a restart sends the same revisions again (each is idempotent at the source):
  `accepted` 1; `started` 2, once the attempt reached `running`; `ended` 3 after a start, 2
  for an attempt that never started (cancelled, returned). `ended` and the result's blobs go
  through `AtlasRuntime.Sources.Upload` once the attempt is terminal and quiescent.
  A report the source could not be reached for is sent again at the next check. An
  `accepted` that is not `recorded` within the accept deadline (30 s, §5.3 item 1) is given
  up: the attempt is cancelled and never starts.

  **Self-fencing (§5.3 item 2, F2).** Every `check_interval_ms` (5 s) each live lease whose
  age (`LeaseClock`: the larger of the monotonic and the wall-clock time since its last
  renewal, so a sleep counts) has reached `lease_ttl` gets the cancel stages
  (`cancel_reason: cancel`, M2 plan C4), and the cause is logged. A fenced lease is never
  reported again: its late `ended` is not uploaded.

  **Pause and drain.** The offer is empty and the polls go on, renewing. A drain returns
  the held and unstarted attempts (the executor's rule); each is reported `ended(returned)`.

  **Restart (P3).** The puller takes over the holdings the records name, each reported
  again from its attempt as above (an interrupted attempt is ended); the source decides on
  a fresh attempt. A restart never renews a lease: each one keeps its **last real
  renewal**, which the puller hands to the core (`Work.renewed/3`) whenever it changes and
  reads back at its start (`Work.renewals/1`), with `lease_ttl`. So a puller that crashed
  and restarted fences on the same schedule as before. A lease whose renewal the core does
  not know (the core started since) is fenced conservatively: it is `unrenewed` until a
  poll renews it, and it is fenced when a poll fails before that, or when none renewed it
  within the accept deadline of the puller's start. A held lease whose accept the source
  had recorded (kept with its renewal, Main's #330 round 3) is restored as accepted and
  importing: renewed and fenced as before, and never given up for the accept deadline, how
  long ago its poll was. It waits for the source to deliver it again, then imports it (or
  starts it at once when its import had already set the base).

  **Expired work never starts (round 3).** Before an attempt is released (its accept
  recorded, its import done) the lease's age is checked as the fence checks it: a lease due
  to be fenced is fenced then, so an answer that comes after a sleep, before the next
  check, never starts its work.

  **The cancel** of a fenced, lost or source-cancelled lease goes to the executor itself
  (`AtlasRuntime.Work.cancel/2`, under the source's client), never through
  `AtlasRuntime.Boundary.Work`, whose implementation is the local source's process (which
  writes to disk): the fence waits on nothing but the executor.

  `poll_now/1` and `check_now/1` answer once the tasks they started (and what those led to,
  such as a lease's `accepted` after its import) have ended; the puller goes on checking
  meanwhile.

  Options: `name:` the source (required); `target:` `{module, ref}` (a
  `AtlasRuntime.Sources.Puller.Target`) or `open:` `{module, fun, args}` answering
  `{:ok, ref}` for `module` (a failure is logged and the puller does not start); `clock:` a
  `LeaseClock` clock (default `LeaseClock.now/0`); `tick:` the check interval in ms (default
  `LeaseClock.check_interval_ms/0`) or `:manual` (only `check_now/1`); `polling:` `:auto`
  (default) or `:manual` (only `poll_now/1`); `retry_ms:` the wait after a failed poll
  (5 s); `min_poll_ms:` the least time between two polls without news (1 s);
  `accept_deadline_ms:` (30 s); `runtime_id:` (default the machine's name); `upload:` options
  for `Upload.run/5`; `import:` options for `Import.base/5` (`max_base_bytes`,
  `max_base_entries`, `timeout_ms`); `import_timeout_ms:` (default and most: the grace
  bound, `lease_ttl` + 2 min less two check intervals); `report_timeout_ms:` (35 s);
  `upload_timeout_ms:` (10 min); `register:` a name to register the puller under (the local
  source's puller, which that source nudges when work is added: a `:poll` message polls at
  once).
  """
  use GenServer
  require Logger

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.{Configuration, Policy, Provenance, Work}
  alias AtlasRuntime.Sources.{Credential, Import, LeaseClock, LeaseShape, Rights, Store, Upload}
  alias AtlasRuntime.Work.Queue

  @accept_deadline_ms 30_000
  # The source's grace after lease_ttl (decision §5.3): an import must end before it.
  @grace_ms 120_000
  @report_timeout_ms 35_000
  @upload_timeout_ms 600_000
  @active [:accepting, :importing, :released, :started]

  ## API

  def child_spec(opts),
    do: %{id: {__MODULE__, Keyword.fetch!(opts, :name)}, start: {__MODULE__, :start_link, [opts]}}

  def start_link(opts) do
    case Keyword.fetch(opts, :register) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Sends a poll now (or waits for the open one) and answers once its answer is handled and
  the tasks it started have ended.
  """
  def poll_now(pid), do: GenServer.call(pid, :poll_now, 120_000)

  @doc """
  Runs one check now: the fence and the task deadlines, then each lease's reports and
  upload. Answers once the tasks it started have ended.
  """
  def check_now(pid), do: GenServer.call(pid, :check_now, 120_000)

  @doc "The leases the puller holds: `lease_id => %{work_id, phase, stamp, received}`."
  def leases(pid), do: GenServer.call(pid, :leases)

  @doc "The tasks running for the leases now: `[%{lease_id, kind}]`, `kind` `:import`, `:report` or `:upload`."
  def jobs(pid), do: GenServer.call(pid, :jobs)

  ## Process

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)

    case target(opts) do
      {:ok, target} ->
        clock = Keyword.get(opts, :clock, &LeaseClock.now/0)
        boot = LeaseClock.stamp(clock)
        {:ok, tasks} = Task.Supervisor.start_link()
        kept = Work.renewals(name) || %{ttl_ms: nil, stamps: %{}}

        state = %{
          name: name,
          client: Rights.client(name),
          target: target,
          clock: clock,
          tick: Keyword.get(opts, :tick, LeaseClock.check_interval_ms()),
          polling: Keyword.get(opts, :polling, :auto),
          retry_ms: Keyword.get(opts, :retry_ms, 5_000),
          min_poll_ms: Keyword.get(opts, :min_poll_ms, 1_000),
          accept_deadline_ms: Keyword.get(opts, :accept_deadline_ms, @accept_deadline_ms),
          runtime_id: Keyword.get_lazy(opts, :runtime_id, fn -> Provenance.context().machine end),
          upload: Keyword.get(opts, :upload, []),
          import: Keyword.get(opts, :import, []),
          import_timeout_ms: Keyword.get(opts, :import_timeout_ms),
          report_timeout_ms: Keyword.get(opts, :report_timeout_ms, @report_timeout_ms),
          upload_timeout_ms: Keyword.get(opts, :upload_timeout_ms, @upload_timeout_ms),
          lease_ttl_ms: kept.ttl_ms,
          boot: boot,
          leases: adopt(name, kept.stamps, boot),
          # What was last handed to the core with Work.renewed/3: {ttl_ms, stamps}.
          renewed: {kept.ttl_ms, kept.stamps},
          poll: nil,
          waiting: [],
          next_poll: nil,
          # The lease tasks: task ref => %{lease_id, kind, task, started, timeout_ms, group,
          # ctx}; at most one per lease.
          tasks: tasks,
          jobs: %{},
          # The callers of poll_now/check_now waiting for the tasks of their group:
          # group => {reply, [from]}; `group` is the one new tasks join now.
          groups: %{},
          group: nil,
          # The last configuration this source served that was refused (IS-Atlas-27):
          # %{version, reason}, sent on every poll until another one is applied; or nil.
          configuration_refused: nil
        }

        if is_integer(state.tick), do: Process.send_after(self(), :tick, state.tick)
        if state.polling == :auto, do: send(self(), :poll)
        {:ok, state}

      {:error, reason} ->
        Logger.error("work source #{name}: not pulled: #{inspect(short(reason))}")
        :ignore
    end
  end

  defp target(opts) do
    case Keyword.fetch(opts, :target) do
      {:ok, {module, _ref} = target} when is_atom(module) ->
        {:ok, target}

      :error ->
        {module, fun, args} = Keyword.fetch!(opts, :open)

        case apply(module, fun, args) do
          {:ok, ref} -> {:ok, {module, ref}}
          {:error, _} = error -> error
        end
    end
  end

  # The leases the records name (§5.3 item 5): each one goes on from what its attempt
  # shows, with its last real renewal and the send time of the poll that delivered it (P3),
  # as the core kept them. A lease the core kept nothing of is `:unrenewed` (fenced
  # conservatively), its accept deadline counted from the puller's start.
  #
  # A held lease whose accept the source recorded (Main's #330 round 3, kept with its
  # renewal) is accepted and importing again, renewed and fenced as before, never given up
  # for its accept deadline: it waits for the source to deliver it again, at most the
  # import's deadline from when its import began. Without that kept (the core restarted
  # too), it is accepting, as conservative as before.
  defp adopt(name, stamps, boot) do
    for h <- Work.holdings(name), into: %{} do
      kept = Map.get(stamps, h.lease_id, %{stamp: :unrenewed, received: boot})

      phase =
        cond do
          not h.held -> :released
          Map.get(kept, :recorded) == true -> :importing
          true -> :accepting
        end

      lease = %{work_id: h.work_id, phase: phase, stamp: kept.stamp, received: kept.received}

      lease =
        if phase == :importing,
          do: Map.merge(lease, %{importing_at: kept.importing_at, waiting: kept.importing_at}),
          else: lease

      {h.lease_id, lease}
    end
  end

  # Hands the last real renewal of every live lease to the core when it changed (P3).
  defp remember(state) do
    stamps =
      for {id, %{phase: phase, stamp: stamp} = lease} <- state.leases,
          phase in @active and stamp != :unrenewed,
          into: %{},
          do: {id, kept(lease)}

    kept = {state.lease_ttl_ms, stamps}

    if kept != state.renewed do
      _ = Work.renewed(state.name, state.lease_ttl_ms, stamps)
    end

    %{state | renewed: kept}
  end

  # What the core keeps of a live lease: its last renewal and, once the source recorded its
  # accept (round 3), that, with when its import began.
  defp kept(%{phase: :importing} = lease),
    do: %{
      stamp: lease.stamp,
      received: lease.received,
      recorded: true,
      importing_at: lease.importing_at
    }

  defp kept(lease), do: %{stamp: lease.stamp, received: lease.received}

  @impl true
  def handle_call(:poll_now, from, state) do
    state = %{state | waiting: [from | state.waiting]}
    {:noreply, if(state.poll, do: state, else: start_poll(state))}
  end

  def handle_call(:check_now, from, state),
    do: {:noreply, grouped(state, :ok, [from], &check/1)}

  # Without the lease's body, which only the import reads.
  def handle_call(:leases, _from, state),
    do: {:reply, Map.new(state.leases, fn {id, l} -> {id, Map.delete(l, :lease)} end), state}

  def handle_call(:jobs, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.map(&%{lease_id: &1.lease_id, kind: &1.kind})
      |> Enum.sort()

    {:reply, jobs, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick)
    {:noreply, state |> check() |> refresh_offer() |> settle()}
  end

  def handle_info(:poll, state) do
    state = %{state | next_poll: nil}
    {:noreply, if(state.poll, do: state, else: start_poll(state))}
  end

  def handle_info({ref, answer}, %{poll: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, answered(state, answer)}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{poll: %{task: %Task{ref: ref}}} = state
      ),
      do: {:noreply, answered(state, {:error, {:poll_failed, reason}})}

  def handle_info({ref, result}, %{jobs: jobs} = state)
      when is_reference(ref) and is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_job(state, ref, {:done, result})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{jobs: jobs} = state)
      when is_map_key(jobs, ref),
      do: {:noreply, finish_job(state, ref, {:exit, reason})}

  def handle_info(_message, state), do: {:noreply, state}

  # A crash report shows neither the last message (a source's answer, its leases included)
  # nor the state: only that they were left out.
  @impl true
  def format_status(status) do
    status
    |> Map.replace(:message, :redacted)
    |> Map.replace(:state, :redacted)
    |> Map.replace(:queue, [])
  end

  @impl true
  def terminate(_reason, state) do
    _ = Work.offer_done(state.name, 0)
    {module, ref} = state.target
    if function_exported?(module, :close, 1), do: module.close(ref)
    :ok
  catch
    _, _ -> :ok
  end

  ## The lease tasks

  # Runs `fun` under the puller's task supervisor for lease `id`, with a deadline of
  # `timeout_ms` on the puller's clock; its answer comes back to `job_done/3`.
  defp start_job(state, id, kind, timeout_ms, fun, ctx \\ %{}) do
    task = Task.Supervisor.async_nolink(state.tasks, fun)

    job = %{
      lease_id: id,
      kind: kind,
      task: task,
      started: LeaseClock.stamp(state.clock),
      timeout_ms: timeout_ms,
      group: state.group,
      ctx: ctx
    }

    %{state | jobs: Map.put(state.jobs, task.ref, job)}
  end

  defp busy?(state, id), do: Enum.any?(state.jobs, fn {_ref, job} -> job.lease_id == id end)

  # A task ended (`{:done, answer}`) or did not (`{:exit, reason}`, `:timeout` when its
  # deadline passed): what it led to joins its own group.
  defp finish_job(state, ref, outcome) do
    {job, jobs} = Map.pop(state.jobs, ref)
    outer = state.group

    %{state | jobs: jobs, group: job.group}
    |> job_done(job, outcome)
    |> Map.put(:group, outer)
    |> settle()
  end

  # Every task whose deadline has passed on the puller's clock is killed.
  defp expire_jobs(state) do
    expired =
      for {ref, job} <- state.jobs,
          LeaseClock.age(job.started, state.clock) >= job.timeout_ms,
          do: {ref, job}

    Enum.reduce(expired, state, fn {ref, job}, state ->
      outcome =
        case Task.shutdown(job.task, :brutal_kill) do
          {:ok, answer} -> {:done, answer}
          _killed -> {:exit, :timeout}
        end

      finish_job(state, ref, outcome)
    end)
  end

  # A fenced or lost lease: its task is killed and its answer dropped.
  defp drop_jobs(state, id) do
    dropped = for {ref, %{lease_id: ^id} = job} <- state.jobs, do: {ref, job}

    state =
      Enum.reduce(dropped, state, fn {ref, job}, state ->
        _ = Task.shutdown(job.task, :brutal_kill)
        %{state | jobs: Map.delete(state.jobs, ref)}
      end)

    settle(state)
  end

  # Runs `fun` on `state` with the tasks it starts in a new group, whose waiters (`froms`)
  # get `reply` once that group has no task left.
  defp grouped(state, reply, froms, fun) do
    group = make_ref()
    state = %{state | group: group} |> fun.() |> Map.put(:group, nil)
    settle(%{state | groups: Map.put(state.groups, group, {reply, froms})})
  end

  defp settle(state) do
    open = MapSet.new(Map.values(state.jobs), & &1.group)

    {done, groups} = Map.split_with(state.groups, fn {g, _} -> not MapSet.member?(open, g) end)

    for {_group, {reply, froms}} <- done, from <- froms, do: GenServer.reply(from, reply)
    %{state | groups: groups}
  end

  # The import of an accepted lease ended (F5 (b)): imported, the attempt may start;
  # otherwise it ends failed, never started, and its slot is free.
  defp job_done(state, %{kind: :import, lease_id: id}, outcome) do
    case state.leases[id] do
      %{phase: :importing, work_id: work_id} ->
        case outcome do
          # Round 3: `release/2` checks the lease's age first; expired work never starts.
          {:done, {:ok, %{} = imported}} ->
            case Work.lease_imported(work_id, {:ok, imported}) do
              :ok ->
                release(state, id)

              other ->
                give_up(state, id, "the import does not match the lease (#{inspect(other)})")
            end

          {:done, {:refused, reason, rule}} ->
            give_up(state, id, "its input was refused: #{reason}: #{rule}", false)

          {:done, {:error, detail}} ->
            give_up(state, id, "its input was not imported: #{detail}")

          {:done, _other} ->
            give_up(state, id, "its input was not imported")

          {:exit, :timeout} ->
            give_up(state, id, "its input was not imported within #{import_timeout(state)} ms")

          {:exit, reason} ->
            give_up(state, id, "its import failed: #{inspect(short(reason))}")
        end

      _ ->
        state
    end
  end

  defp job_done(state, %{kind: :report, lease_id: id, ctx: %{on: on}}, outcome) do
    answer =
      case outcome do
        {:done, answer} -> answer
        {:exit, :timeout} -> {:error, :timeout}
        {:exit, _reason} -> {:error, :report_failed}
      end

    reported(state, id, on, answer)
  end

  defp job_done(state, %{kind: :upload, lease_id: id}, outcome) do
    answer =
      case outcome do
        {:done, answer} -> answer
        {:exit, :timeout} -> {:error, :timeout}
        {:exit, _reason} -> {:error, :upload_failed}
      end

    uploaded(state, id, answer)
  end

  ## The poll

  defp start_poll(state, offer \\ nil) do
    case Work.runtime() do
      nil ->
        answered(%{state | poll: %{task: nil, offer: %{}}}, {:error, :core_not_running})

      runtime ->
        offer = offer || current_offer(state)
        holdings = holdings(state)

        input = %{
          runtime_id: state.runtime_id,
          incarnation: runtime.incarnation,
          build: runtime.runtime_build,
          policy_version: runtime.policy_version,
          offer: offer,
          holdings: for(h <- holdings, do: holding(h))
        }

        # Only while there is a refusal to report: a source that serves no configuration
        # takes no such field (Flow's work source refuses a body field it does not know).
        input =
          case state.configuration_refused do
            nil -> input
            refused -> Map.put(input, :configuration_refused, refused)
          end

        # The send time: a renewal counts from here, however late the answer comes.
        sent = LeaseClock.stamp(state.clock)
        {module, ref} = state.target
        task = Task.async(fn -> module.poll(ref, input) end)

        %{
          state
          | poll: %{
              task: task,
              sent: sent,
              offer: offer,
              holdings: Enum.map(holdings, & &1.lease_id)
            }
        }
    end
  end

  defp current_offer(state) do
    case Work.offer(state.name) do
      %{} = offer -> offer
      _not_running -> %{}
    end
  end

  # The live leases this puller holds, as the records show them.
  defp holdings(state) do
    for h <- Work.holdings(state.name),
        match?(%{phase: phase} when phase in @active, state.leases[h.lease_id]),
        do: h
  end

  defp holding(h) do
    %{lease_id: h.lease_id, state: h.state, last_progress_at: h.last_progress_at}
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp answered(state, answer) do
    poll = state.poll
    waiting = Enum.reverse(state.waiting)
    state = %{state | poll: nil, waiting: []}

    answer =
      case answer do
        {:polled, polled} -> if polled?(polled), do: answer, else: {:error, :malformed}
        other -> other
      end

    {state, news?} =
      case answer do
        {:polled, polled} ->
          state = grouped(state, answer_name(answer), waiting, &polled(&1, poll, polled))
          {state, polled.leases != [] or polled.cancel != [] or polled.lease_lost != []}

        {:rejected, reason} ->
          Logger.warning("work source #{state.name}: poll rejected: #{inspect(short(reason))}")
          _ = Work.offer_done(state.name, 0)
          {grouped(state, :rejected, waiting, &fence_unrenewed/1), false}

        {:error, reason} ->
          Logger.warning("work source #{state.name}: poll failed: #{inspect(short(reason))}")
          _ = Work.offer_done(state.name, 0)
          {grouped(state, :error, waiting, &fence_unrenewed/1), false}
      end

    if state.polling == :auto do
      delay =
        cond do
          not match?({:polled, _}, answer) -> state.retry_ms
          news? -> 0
          true -> state.min_poll_ms
        end

      %{state | next_poll: Process.send_after(self(), :poll, delay)}
    else
      state
    end
  end

  defp answer_name({name, _}), do: name

  # The answer's own shape (its leases are checked one by one, by the executor): lists of
  # leases and of lease ids, and a timing within the contract's ranges.
  defp polled?(%{leases: leases, cancel: cancel, lease_lost: lost, timing: timing})
       when is_list(leases) and is_list(cancel) and is_list(lost) do
    Enum.all?(cancel ++ lost, &is_binary/1) and
      match?(%{lease_ttl: ttl, poll_max: max} when ttl in 1..86_400 and max in 1..25, timing)
  end

  defp polled?(_polled), do: false

  # What a log line may show of an error: its tag. Never the rest, which can quote what the
  # source sent (the HTTP client's `{:invalid_response, reasons}` does).
  defp short(reason) when is_atom(reason), do: reason
  defp short({tag, why}) when is_atom(tag) and is_atom(why), do: {tag, why}
  defp short({tag, _detail}) when is_atom(tag), do: tag
  defp short(_reason), do: :failed

  # A usable lease id, or nil: without one a lease cannot even be refused.
  defp lease_id(%{lease_id: id}) when is_binary(id) and id != "", do: id
  defp lease_id(_lease), do: nil

  defp polled(state, poll, polled) do
    lost = MapSet.new(polled.lease_lost)
    state = %{state | lease_ttl_ms: polled.timing.lease_ttl * 1_000}

    state =
      Enum.reduce(poll.holdings, state, fn id, state ->
        if MapSet.member?(lost, id), do: state, else: renew(state, id, poll.sent)
      end)

    state =
      Enum.reduce(polled.lease_lost, state, fn id, state ->
        lose(state, id, "the source answered lease_lost")
      end)

    state = Enum.reduce(polled.cancel, state, &cancel_by_source(&2, &1))

    {state, used} =
      Enum.reduce(polled.leases, {state, 0}, fn lease, {state, used} ->
        accept(state, lease, poll.sent, used)
      end)

    _ = Work.offer_done(state.name, used)
    state |> remember() |> configure(Map.get(polled, :configuration))
  end

  # IS-Atlas-27: the configuration its supervisor set through Control, when the source
  # serves one (`AtlasRuntime.Configuration`). Applied, it is what every attempt not yet
  # started runs under, and the next poll carries its version; refused, the refusal goes
  # with every poll until a configuration is applied.
  defp configure(state, document) when is_binary(document) do
    case runtime_home() do
      nil ->
        state

      home ->
        case Configuration.apply(home, state.name, document) do
          {:applied, _version} ->
            %{state | configuration_refused: nil}

          :current ->
            %{state | configuration_refused: nil}

          {:refused, version, reason} ->
            %{state | configuration_refused: %{version: version, reason: reason}}
        end
    end
  end

  defp configure(state, _none), do: state

  defp renew(state, id, sent) do
    case state.leases[id] do
      %{phase: phase} = lease when phase in @active ->
        put_in(state.leases[id], %{lease | stamp: sent})

      _ ->
        state
    end
  end

  defp cancel_by_source(state, id) do
    case state.leases[id] do
      %{phase: phase, work_id: work_id} when phase in @active ->
        Logger.info("work source #{state.name}: cancel of lease #{id}")
        cancel_attempt(state, work_id)
        state

      _ ->
        state
    end
  end

  # A lease from the poll: persisted and held by the executor, then reported accepted; a
  # remote lease's input is imported once that accept is recorded (F5 (b)).
  defp accept(state, lease, sent, used) do
    case lease_id(lease) do
      nil ->
        Logger.warning(
          "work source #{state.name}: a lease without a usable lease_id was dropped",
          lease_dropped: :no_lease_id
        )

        {state, used}

      id ->
        accept(state, id, lease, sent, used)
    end
  end

  defp accept(state, id, lease, sent, used), do: accepted(state, id, lease, sent, used)

  # Imports the input of accepted lease `id` in a task (its accept was recorded). A lease
  # adopted at a restart has no input known here: it waits, renewed and fenced as usual,
  # for the source to deliver it again (then `step/3` imports it), at most the import's
  # deadline from now.
  defp start_import(state, id) do
    # Kept from the first import of the lease: a restart measures from that one (round 3).
    began = Map.get(state.leases[id], :importing_at) || LeaseClock.stamp(state.clock)
    state = update_in(state.leases[id], &%{&1 | phase: :importing})
    state = put_in(state.leases[id][:importing_at], began)

    case state.leases[id] do
      %{lease: %{} = lease} ->
        import_input = import_fun(state, id, lease, runtime_home())
        start_job(state, id, :import, import_timeout(state), import_input)

      _ ->
        Logger.info(
          "work source #{state.name}: lease #{id}: its input waits to be delivered again"
        )

        put_in(state.leases[id][:waiting], LeaseClock.stamp(state.clock))
    end
  end

  # The accepted lease's import did not complete: its attempt ends failed, never started
  # (its slot free again), and the lease goes on to report that end.
  defp give_up(state, id, why, retryable \\ true) do
    Logger.warning("work source #{state.name}: lease #{id}: #{why}")
    _ = Work.lease_imported(state.leases[id].work_id, {:failed, retryable, why})
    state = put_in(state.leases[id].phase, :released)
    next_step(state, id)
  end

  defp runtime_home do
    case Work.runtime() do
      %{home: home} -> home
      _ -> nil
    end
  end

  # The longest an import may take: below the grace (`lease_ttl` + 2 min), by two check
  # intervals, as the deadline is read at each check. A smaller `import_timeout_ms` is kept.
  defp import_timeout(state) do
    bound = max(state.lease_ttl_ms + @grace_ms - 2 * LeaseClock.check_interval_ms(), 1)

    case state.import_timeout_ms do
      ms when is_integer(ms) and ms > 0 -> min(ms, bound)
      _ -> bound
    end
  end

  # M2 A3: the input of a remote source's lease, imported from that source into its own
  # store before anything is accepted. Its shape first: nothing of a malformed lease is read
  # or logged here; the executor refuses it `invalid` with its own structural log
  # (`LeaseShape`), before it looks at an import. The helper's own timeout is kept below the
  # task's deadline, so the helper is stopped (and its staging removed) by the import itself.
  defp import_fun(state, id, lease, home) do
    {module, ref} = state.target
    name = state.name
    options = Keyword.put(state.import, :deadline_ms, import_timeout(state))

    fn ->
      with {:ok, lease} <- LeaseShape.check(lease),
           true <- is_binary(home),
           %{} = source <- policy_source(home, name) do
        git = %{url: source["git_url"], env: fn -> git_env(home, name) end}
        options = Keyword.put_new(options, :git, git)
        Import.base(home, source, lease, &module.get_blob(ref, id, &1), options)
      else
        {:error, {_rule, _path}} -> {:ok, nil}
        _ -> {:error, "the core is not running, or the policy no longer names the source"}
      end
    end
  end

  # Git's environment for a fetch from the source's Code: its bearer token as an extra header,
  # never on Git's command line.
  defp git_env(home, name) do
    {:ok, header} = Credential.load(home, name)

    [
      {"GIT_CONFIG_COUNT", "1"},
      {"GIT_CONFIG_KEY_0", "http.extraHeader"},
      {"GIT_CONFIG_VALUE_0", "Authorization: " <> header.()}
    ]
  end

  defp policy_source(home, name),
    do: Enum.find(Policy.sources(Policy.load(home)), &(&1["name"] == name))

  defp accepted(state, id, lease, sent, used) do
    case Work.accept_lease(state.name, lease) do
      {:accepted, work_id} ->
        state = put_in(state.leases[id], fresh(work_id, lease, sent))
        {state |> remember() |> send_accepted(id), used + 1}

      {:existing, work_id} ->
        case state.leases[id] do
          nil ->
            state = put_in(state.leases[id], fresh(work_id, lease, sent))
            {state |> remember() |> send_accepted(id), used}

          %{} = known ->
            # Delivered again: the lease's input is kept for an import still to come, and
            # a lease waiting for it (adopted at a restart) imports it now.
            state = put_in(state.leases[id], Map.put(known, :lease, lease))

            if known.phase == :importing and not busy?(state, id),
              do: {start_import(state, id), used},
              else: {state, used}
        end

      {:refused, reason} ->
        {refuse(state, id, reason), used}

      {:unavailable, _reason} ->
        Logger.info(
          "work source #{state.name}: lease #{id} left unanswered: its profile is unavailable now"
        )

        {state, used}

      :not_running ->
        Logger.warning(
          "work source #{state.name}: lease #{id} not accepted: the core is not running"
        )

        {state, used}
    end
  end

  defp fresh(work_id, lease, sent),
    do: %{work_id: work_id, phase: :accepting, stamp: sent, received: sent, lease: lease}

  defp refuse(state, id, reason), do: report(state, id, 1, %{state: :refused, reason: reason})

  # While a poll with an empty offer is open (the Runtime was full, paused or draining): a
  # slot free again ends it, and it is sent again with the new offer at once. Nothing can be
  # lost by ending it, as the source cannot lease within an empty offer. A poll that offers
  # slots is left to its answer (a source may have leased within it already, and a lease
  # whose answer is cut off is lost until the accept deadline); the next poll takes the new
  # offer.
  defp refresh_offer(%{polling: :auto, poll: %{task: %Task{} = task, offer: offer}} = state)
       when offer == %{} do
    case current_offer(state) do
      empty when empty == %{} ->
        state

      changed ->
        case Task.shutdown(task, :brutal_kill) do
          {:ok, answer} -> answered(state, answer)
          _ -> start_poll(%{state | poll: nil}, changed)
        end
    end
  end

  defp refresh_offer(state), do: state

  ## The check

  # The fence and the task deadlines first: neither waits on anything a task does.
  defp check(state) do
    state = state |> fence() |> expire_jobs()
    holdings = Map.new(Work.holdings(state.name), &{&1.lease_id, &1})

    state.leases
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(state, fn id, state -> step(state, id, holdings[id]) end)
  end

  defp fence(state) do
    Enum.reduce(Enum.sort(Map.keys(state.leases)), state, fn id, state ->
      lease = state.leases[id]

      case lease.phase in @active and due(state, lease) do
        why when is_binary(why) -> fence(state, id, why)
        _ -> state
      end
    end)
  end

  # Why live lease `lease` is to be fenced now, or nil (its age on the puller's clock). The
  # check runs at each check and, round 3, before any of its work is released: so expired
  # work never starts, also when a task's answer comes before the next check (a sleep stops
  # the monotonic timers, not the wall clock).
  defp due(state, lease) do
    cond do
      lease.stamp == :unrenewed ->
        if LeaseClock.age(state.boot, state.clock) >= state.accept_deadline_ms,
          do: "no poll renewed it within #{state.accept_deadline_ms} ms of a restart"

      is_integer(state.lease_ttl_ms) and
          LeaseClock.expired?(lease.stamp, state.clock, state.lease_ttl_ms) ->
        "not renewed for #{state.lease_ttl_ms} ms"

      true ->
        nil
    end
  end

  # Lets lease `id`'s held attempt start (its accept recorded, its input imported), unless
  # the lease is due to be fenced: then it is fenced, and the attempt never starts.
  defp release(state, id) do
    case due(state, state.leases[id]) do
      nil ->
        _ = Work.release_lease(state.leases[id].work_id)
        state = put_in(state.leases[id].phase, :released)
        state |> remember() |> next_step(id)

      why ->
        fence(state, id, why)
    end
  end

  # A poll failed: every lease whose renewal is not known since a restart is fenced (P3).
  defp fence_unrenewed(state) do
    state.leases
    |> Enum.filter(fn {_id, l} -> l.phase in @active and l.stamp == :unrenewed end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
    |> Enum.reduce(state, &fence(&2, &1, "a poll failed before any renewed it since a restart"))
  end

  defp fence(state, id, why) do
    lease = state.leases[id]

    Logger.warning(
      "work source #{state.name}: lease #{id} #{why}: self-fencing, cancelling #{lease.work_id}"
    )

    cancel_attempt(state, lease.work_id)
    state = put_in(state.leases[id].phase, :fenced)
    drop_jobs(state, id)
  end

  defp step(state, id, holding) do
    lease = state.leases[id]

    cond do
      lease.phase not in @active ->
        state

      is_nil(holding) ->
        put_in(state.leases[id].phase, :done)

      lease.phase == :accepting and
          LeaseClock.age(lease.received, state.clock) >= state.accept_deadline_ms ->
        lose(state, id, "no recorded accept within #{state.accept_deadline_ms} ms")

      busy?(state, id) ->
        state

      # Adopted at a restart after its import set the base: it may start now.
      lease.phase == :importing and not holding.importing ->
        release(state, id)

      # Adopted at a restart: imported once delivered again, or given up at the deadline.
      lease.phase == :importing and is_map_key(lease, :lease) ->
        start_import(state, id)

      lease.phase == :importing and is_map_key(lease, :waiting) ->
        if LeaseClock.age(lease.waiting, state.clock) >= import_timeout(state),
          do:
            give_up(state, id, "its input was not delivered again within the import's deadline"),
          else: state

      lease.phase == :importing ->
        give_up(state, id, "its import ended without an answer")

      lease.phase == :accepting ->
        send_accepted(state, id)

      lease.phase == :released and holding.ran ->
        send_started(state, id)

      holding.state in Queue.terminal() and holding.quiescent ->
        upload(state, id, if(lease.phase == :started, do: 3, else: 2), holding.ran)

      true ->
        state
    end
  end

  # A lease's next step once its report was recorded, from what its record shows now.
  defp next_step(state, id) do
    case Enum.find(Work.holdings(state.name), &(&1.lease_id == id)) do
      nil -> state
      holding -> step(state, id, holding)
    end
  end

  defp send_accepted(state, id), do: report(state, id, 1, %{state: :accepted}, :accepted)

  defp send_started(state, id), do: report(state, id, 2, %{state: :started}, :started)

  # The answer to a report, if its lease is still where the report left it.
  defp reported(state, _id, :refused, _answer), do: state

  defp reported(state, id, on, answer) do
    expected = if on == :accepted, do: :accepting, else: :released

    case state.leases[id] do
      %{phase: ^expected} -> reported_now(state, id, on, answer)
      _ -> state
    end
  end

  defp reported_now(state, id, on, answer) do
    case answer do
      {:recorded, _} when on == :accepted ->
        # Round 3: a lease expired by the time its accept was recorded never starts.
        case due(state, state.leases[id]) do
          nil ->
            case Work.release_lease(state.leases[id].work_id) do
              # F5 (b): the input is imported now, and the attempt released once it is.
              # Kept with the renewal, so a restart restores it as accepted and importing.
              :importing ->
                state |> start_import(id) |> remember()

              _ ->
                state = put_in(state.leases[id].phase, :released)
                state |> remember() |> next_step(id)
            end

          why ->
            fence(state, id, why)
        end

      {:recorded, _} ->
        state = put_in(state.leases[id].phase, :started)
        next_step(state, id)

      :lease_lost ->
        lose(state, id, "the source answered lease_lost to #{on}")

      {:rejected, reason} ->
        lose(state, id, "the source rejected #{on}: #{inspect(short(reason))}")

      {:error, reason} ->
        Logger.warning(
          "work source #{state.name}: #{on} of #{id} not sent: #{inspect(short(reason))}"
        )

        state
    end
  end

  # An attempt that never ran (its input not prepared, or returned before it started) has no
  # result: it is reported ended without one, never pushed over Git from a folder it lacks.
  defp upload(state, id, revision, ran) do
    {module, ref} = state.target
    work_id = state.leases[id].work_id
    git = if ran, do: git_result(state, id, work_id), else: []
    {client, options} = {state.client, git ++ state.upload}

    start_job(state, id, :upload, state.upload_timeout_ms, fn ->
      Upload.run(client, module.uploader(ref, revision), id, work_id, options)
    end)
  end

  # A lease whose input names a result_ref: the result goes back to the source's Code as a
  # commit on the base, pushed from the source's Git cache, instead of as a change set.
  defp git_result(state, id, work_id) do
    name = state.name

    with %{work: %{input: %{result_ref: result_ref, base: base}}} when is_binary(result_ref) <-
           state.leases[id][:lease],
         home when is_binary(home) <- runtime_home(),
         %{"git_url" => url} <- policy_source(home, name) do
      {:ok, manifest} = Store.get(home, name, base.manifest)
      %{"roots" => [%{"root" => root}]} = manifest |> File.read!() |> JSON.decode!()

      [
        git: %{
          url: url <> "/bases/" <> base.base_id,
          env: fn -> git_env(home, name) end,
          dir: Path.join([home, "sources", name, "git"]),
          base: "refs/atlas/bases/" <> base.base_id,
          ref: result_ref,
          tree: Path.join(Work.Folders.path(home, work_id), root)
        }
      ]
    else
      _ -> []
    end
  end

  defp uploaded(state, id, answer) do
    case {state.leases[id], answer} do
      {%{phase: phase}, _} when phase not in @active ->
        state

      {_, {:ok, _}} ->
        put_in(state.leases[id].phase, :done)

      {_, {:stopped, :lease_lost}} ->
        put_in(state.leases[id].phase, :lost)

      {_, {:stopped, _reason}} ->
        put_in(state.leases[id].phase, :done)

      {_, {:error, reason}} ->
        Logger.warning(
          "work source #{state.name}: upload of #{id} not done: #{inspect(short(reason))}"
        )

        state
    end
  end

  # The lease is not this Runtime's any more: its attempt is cancelled (never started when it
  # had not) and nothing of it is reported again.
  defp lose(state, id, why) do
    case state.leases[id] do
      %{phase: phase, work_id: work_id} when phase in @active ->
        Logger.warning(
          "work source #{state.name}: lease #{id} lost (#{why}); cancelling #{work_id}"
        )

        cancel_attempt(state, work_id)
        state = put_in(state.leases[id].phase, :lost)
        drop_jobs(state, id)

      _ ->
        state
    end
  end

  # Straight to the executor (round-2 rule (2)): never through the CLI facade, whose
  # implementation is the local source's process.
  defp cancel_attempt(state, work_id),
    do: Work.cancel(state.client, %B.CancelInput{work_id: work_id, mode: :graceful})

  # A report of lease `id`, sent in a task; its answer comes back to `reported/4` as `on`.
  defp report(state, id, revision, report, on \\ :refused) do
    {module, ref} = state.target
    input = %{lease_id: id, revision: revision, report: report}

    start_job(
      state,
      id,
      :report,
      state.report_timeout_ms,
      fn -> module.send_report(ref, input) end,
      %{on: on}
    )
  end
end
