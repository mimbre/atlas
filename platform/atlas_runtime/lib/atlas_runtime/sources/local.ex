defmodule AtlasRuntime.Sources.LocalFacade do
  @moduledoc """
  The `work_source` contract's in-BEAM Elixir target (M1) on the built-in local work source,
  `AtlasRuntime.Sources.Local` (M2 plan A5). The local source's puller reports and uploads
  through it exactly as it does to a remote source (C6).
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.WorkSource,
    implementation: AtlasRuntime.Sources.Local
end

defmodule AtlasRuntime.Sources.Local do
  @moduledoc """
  The built-in local work source (decision §5.4; M2 plan A5): the queue of the work the
  Runtime's owner adds through the CLI, kept in `AtlasRuntime.Sources.Local.Store` under
  `<home>/local-source/` (W7), and handed to the executor by the source's own puller, as a
  remote source's work is.

  **Add** (`add/3`). A work is checked against the policy at once (`Work.check_request/2`,
  the submit checks of the adding client): a typo is refused when it is added, `invalid` or
  `policy_forbids`, and `not_accepting` while the core takes no new work. The client key
  is the local source's (I3, I7): the same key and request is `existing`, another request
  `conflict`, and a key whose work was pruned `conflict` with the tombstone's work id.

  **Order.** The adder's priority (a lower number first), then FIFO (`Store.queued/1`). The
  `local` entry's own `priority` and `max_slots` in the policy's `sources` apply through the
  executor's offer, as for any source (decision §5.5).

  **Leases.** The puller's poll (`poll_local/1`, in-BEAM) leases queued work within the
  offer (Main's O1: at most its total, among the profiles it names), in order, and only a
  work whose profile is available for its own permission (`Work.available/1`, the one rule
  the executor's offer and a retry's check use, Main's #330 round 3): a work no option can
  serve now stays queued, unleased, until one can. A local lease
  carries the work contract's request as it was added: the work source contract's offered
  work cannot carry a folder, a repository, a slot or `resume_from`, which only this source
  may name (C1). The executor takes such a lease only from the source `local`
  (`Work.accept_lease/2`), with the socket client's checks. The renewals, `cancel`,
  `lease_lost` and the `timing` are the contract's rules (§5.3), with this source's clock:
  a lease not accepted within the accept deadline, or expired for `lease_ttl + grace`, is
  lost and its work queued again for a fresh lease. The executor keeps the local work id as
  its record's (Main's A6 Q1): a fresh lease of an attempt it has already recorded is
  refused, and the work ends `failed` here, so it never runs twice.

  **Retry** (`retry/4`, Main's round 2). An ended work is queued again, behind what was
  added before, for its next attempt (`attempt` + 1, `resume` as asked). A leased work
  whose attempt has ended at the executor, its `ended` not here yet, keeps the retry
  (`retry`, persisted) and is queued so once that `ended` (or its refusal) ends it here. Its next lease names
  that attempt (`work.attempt`), so the executor adds it to the same record (the same work
  id), and it is leased within the offer like any work: it counts against the `local`
  entry's `max_slots`. A lost lease of that attempt is the same attempt again: refused, and
  the work ends `failed`.

  **Reports and results** (C6) come through the contract (`AtlasRuntime.Sources.LocalFacade`):
  `report` (fenced on the current, unexpired lease; idempotent by revision) and `put_blob`
  (only the blobs the recorded `ended` references). An `ended` is kept under
  `local-source/results/` (the contract's `ended`, as JSON), with its blobs under
  `local-source/blobs/`, so `result/1` and
  `result_blob/1` serve it from this source's own store, also after the executor pruned
  its copy. The contract's `poll` renews and answers `cancel`, `lease_lost` and `timing`
  only: no local work can be given in its shape. `get_blob` finds nothing: a local work
  names no input blob.

  **Restart.** Queued work stays queued. A leased one keeps its lease, renewed from the
  restart, and its reports are taken again as the puller resends them.

  Options of `start_link/2`: `name:` (default this module), `clock:` a function answering
  milliseconds (default monotonic), `lease_ttl:` (900 s), `grace:` (120 s),
  `accept_deadline:` (30 s), `poll_max:` (25 s), `puller:` the local puller's registered
  name to nudge when work is added.
  """
  use GenServer
  use AtlasRuntime.Sources.LocalFacade.Implementation

  require Logger

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.LocalSource.QueuedWork
  alias AtlasRuntime.Sources.LocalFacade, as: F
  alias AtlasRuntime.Sources.Local.Store
  alias AtlasRuntime.Work

  @puller AtlasRuntime.Sources.Local.Puller

  ## API

  def start_link(home, opts \\ []) do
    GenServer.start_link(__MODULE__, {home, opts}, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The registered name of the local source's puller (`Sources.Supervisor` starts it)."
  def puller_name, do: @puller

  @doc """
  Adds a work for `client` (the adder, `{id, rights}`; the CLI's is the socket's) with
  `priority` (a lower number first): `{:added, work_id}`, `{:existing, work_id}`,
  `{:conflict, work_id}`, `{:refused, reason, detail}`, `{:pruned, work_id, kind}` (a
  `from_work` whose source was pruned) or `:not_running`.
  """
  def add(client, %B.WorkRequest{} = input, priority \\ 1, server \\ __MODULE__)
      when is_integer(priority),
      do: call(server, {:add, client, input, priority})

  @doc "The queued works in order (priority, then FIFO), as stored."
  def queue(server \\ __MODULE__), do: call(server, :queue)

  @doc "A work as stored: `{:ok, queued_work}`, `{:pruned, tombstone}` or `:not_found`."
  def get(work_id, server \\ __MODULE__), do: call(server, {:get, work_id})

  @doc """
  The result of an ended work from this source's own store (C6): `{:ok, %{result_ref,
  ended}}` with the `ended` report as recorded (its `change_set` included), or `:not_found`.
  """
  def result(work_id, server \\ __MODULE__), do: call(server, {:result, work_id})

  @doc "A result blob from this source's own store: `{:ok, bytes}` or `:not_found`."
  def result_blob(sha256, server \\ __MODULE__), do: call(server, {:result_blob, sha256})

  @doc """
  Cancels a work (M2 A6, the CLI's stop and kill): a queued one ends `cancelled` here at
  once, `{:ended, queued_work}`; a leased one has its lease cancelled through the next poll,
  `:ok` (its executor attempt gets the cancel stages); `:not_found` otherwise (an ended or
  unknown work).
  """
  def cancel(work_id, server \\ __MODULE__), do: call(server, {:cancel, work_id})

  @doc """
  What `client_id`'s client key names (M2 A6, the CLI's `status --key`): `{:ok,
  queued_work}`, `{:pruned, tombstone}` or `:not_found`.
  """
  def find(client_id, client_key, server \\ __MODULE__),
    do: call(server, {:find, client_id, client_key})

  @doc """
  Retries a work (Main's round 2, the CLI's retry): an ended one is queued again for its
  next attempt, `{:queued, queued_work}`; a leased one whose attempt has ended at the
  executor (`ended?`) keeps the retry until its `ended` comes, `{:pending, queued_work}`;
  `{:refused, reason, detail}` for one that is queued (nothing ran yet, `invalid`) or
  leased and not ended (`conflict`); `:not_found` otherwise.
  """
  def retry(work_id, resume? \\ false, ended? \\ false, server \\ __MODULE__),
    do: call(server, {:retry, work_id, resume? == true, ended? == true})

  @doc "Whether the local source runs (M2 A6: the CLI's work then goes through it)."
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @doc "Prunes an ended work (its key stays as a tombstone, I7): `:ok` or `:not_found`."
  def prune(work_id, server \\ __MODULE__), do: call(server, {:prune, work_id})

  @doc """
  The puller's poll, in-BEAM (`AtlasRuntime.Sources.Local.Target`): the contract's poll
  input; answers `%{leases, cancel, lease_lost, timing}` with local leases.
  """
  def poll_local(input, server \\ __MODULE__), do: call(server, {:poll, input, true})

  defp call(server, message) do
    GenServer.call(server, message, 30_000)
  catch
    :exit, {:noproc, _} -> :not_running
  end

  ## The contract (AtlasRuntime.Sources.LocalFacade)

  @impl AtlasRuntime.Sources.LocalFacade.Implementation
  def poll(_client, %F.PollInput{} = input) do
    case call(__MODULE__, {:poll, input, false}) do
      %{} = polled -> F.Outcome.Polled.new!(polled)
      :not_running -> %F.Outcome.Rejected{reason: :invalid, detail: "not running"}
    end
  end

  @impl AtlasRuntime.Sources.LocalFacade.Implementation
  def report(_client, %F.ReportInput{} = input) do
    case call(__MODULE__, {:report, input}) do
      :not_running -> %F.Outcome.LeaseLost{}
      outcome -> outcome
    end
  end

  @impl AtlasRuntime.Sources.LocalFacade.Implementation
  def get_blob(_client, %F.GetBlobInput{}), do: %F.Outcome.NotFound{}

  @impl AtlasRuntime.Sources.LocalFacade.Implementation
  def put_blob(_client, %F.PutBlobInput{lease_id: id, sha256: sha} = input) do
    case call(__MODULE__, {:may_put, id, sha}) do
      :ok -> receive_blob(input)
      :not_running -> %F.Outcome.LeaseLost{}
      outcome -> outcome
    end
  end

  # Read in the caller (the bytes are its stream), then stored by the source.
  defp receive_blob(input) do
    bytes = input.content |> Enum.to_list() |> IO.iodata_to_binary()

    if byte_size(bytes) != input.size or sha256(bytes) != input.sha256,
      do: %F.Outcome.Rejected{reason: :digest_mismatch},
      else: call(__MODULE__, {:put_blob, input.lease_id, input.sha256, bytes})
  end

  ## Process

  @impl true
  def init({home, opts}) do
    case Store.load(home) do
      {:ok, loaded} ->
        clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
        now = clock.()

        state = %{
          home: home,
          loaded: loaded,
          clock: clock,
          lease_ttl: Keyword.get(opts, :lease_ttl, 900),
          grace: Keyword.get(opts, :grace, 120),
          accept_deadline: Keyword.get(opts, :accept_deadline, 30),
          poll_max: Keyword.get(opts, :poll_max, 25),
          puller: Keyword.get(opts, :puller, @puller),
          leases: adopt(loaded, now, Keyword.get(opts, :lease_ttl, 900))
        }

        {:ok, state}

      {:error, why} ->
        Logger.error("runtime local source: the store is refused: #{why}")
        {:stop, {:store_refused, why}}
    end
  end

  # A leased work keeps its lease across a restart, renewed from now; which reports were
  # recorded is not known, so the next one the puller sends is taken as it comes.
  defp adopt(loaded, now, ttl) do
    for %QueuedWork{state: :leased, lease_id: id} = work <- Map.values(loaded.entries),
        is_binary(id),
        into: %{} do
      {id, lease(work.work_id, now, ttl) |> Map.merge(%{accepted: true, reports: :unknown})}
    end
  end

  defp lease(work_id, now, ttl) do
    %{
      work_id: work_id,
      offered_at: now,
      expires_at: now + ttl * 1_000,
      accepted: false,
      lost: false,
      cancel: false,
      reports: [],
      referenced: MapSet.new()
    }
  end

  @impl true
  def handle_call({:add, {client_id, _rights} = client, input, priority}, _from, state) do
    case Work.check_request(client, input) do
      :ok ->
        attrs = %{
          work_id: "work-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
          client: client_id,
          client_key: input.client_key,
          request: to_store(input),
          priority: priority,
          added_at: DateTime.utc_now()
        }

        case Store.add!(state.home, state.loaded, attrs) do
          {:added, work, loaded} ->
            nudge(state)
            {:reply, {:added, work.work_id}, %{state | loaded: loaded}}

          {:existing, work} ->
            {:reply, {:existing, work.work_id}, state}

          {:conflict, work_id} ->
            {:reply, {:conflict, work_id}, state}
        end

      {:refused, _reason, _detail} = refused ->
        {:reply, refused, state}

      {:pruned, _work_id, _kind} = pruned ->
        {:reply, pruned, state}
    end
  end

  def handle_call(:queue, _from, state), do: {:reply, Store.ordered(state.loaded), state}

  def handle_call({:get, work_id}, _from, state) do
    reply =
      case state.loaded.entries[work_id] do
        %QueuedWork{} = work ->
          {:ok, work}

        nil ->
          case Store.tombstone(state.loaded, work_id) do
            nil -> :not_found
            tombstone -> {:pruned, tombstone}
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:result, work_id}, _from, state) do
    reply =
      with %QueuedWork{state: :ended, result: ref} <- state.loaded.entries[work_id],
           {:ok, bytes} <- File.read(result_path(state.home, work_id)),
           {:ok, map} <- JSON.decode(bytes),
           {:ok, ended} <- F.Ended.new(map) do
        {:ok, %{result_ref: ref, ended: ended}}
      else
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:result_blob, sha}, _from, state) do
    reply =
      with true <- sha256?(sha), {:ok, bytes} <- File.read(blob_path(state.home, sha)) do
        {:ok, bytes}
      else
        _ -> :not_found
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel, work_id}, _from, state) do
    case {state.loaded.entries[work_id], current(state, work_id)} do
      {%QueuedWork{state: :queued}, _} ->
        state = finish(state, work_id, %{kind: :cancelled}, nil)
        {:reply, {:ended, state.loaded.entries[work_id]}, state}

      {_, nil} ->
        {:reply, :not_found, state}

      {_, id} ->
        {:reply, :ok, put_in(state.leases[id].cancel, true)}
    end
  end

  def handle_call({:retry, work_id, resume?, ended?}, _from, state) do
    case state.loaded.entries[work_id] do
      %QueuedWork{state: :ended} = work ->
        {queued, loaded} = Store.requeue!(state.home, state.loaded, work, resume?)
        nudge(state)
        {:reply, {:queued, queued}, %{state | loaded: loaded}}

      %QueuedWork{state: :leased, retry: nil} = work when ended? ->
        pending = QueuedWork.new!(%{work | retry: %{resume: resume?}})
        loaded = Store.put!(state.home, state.loaded, pending)
        {:reply, {:pending, pending}, %{state | loaded: loaded}}

      %QueuedWork{state: :leased, retry: %{}} = work when ended? ->
        {:reply, {:pending, work}, state}

      %QueuedWork{state: :queued} ->
        {:reply, {:refused, :invalid, "work #{work_id} has not started yet"}, state}

      %QueuedWork{state: :leased, attempt: attempt} ->
        {:reply,
         {:refused, :conflict, "attempt #{attempt || 1} of work #{work_id} has not ended"}, state}

      nil ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:find, client_id, client_key}, _from, state),
    do: {:reply, Store.find(state.loaded, client_id, client_key), state}

  def handle_call({:prune, work_id}, _from, state) do
    case state.loaded.entries[work_id] do
      %QueuedWork{state: :ended} ->
        loaded = Store.prune!(state.home, state.loaded, work_id)
        File.rm(result_path(state.home, work_id))
        {:reply, :ok, %{state | loaded: loaded}}

      _ ->
        {:reply, :not_found, state}
    end
  end

  def handle_call({:poll, input, with_leases?}, _from, state) do
    state = sweep(state)
    now = state.clock.()

    {renewed, lost, state} =
      Enum.reduce(input.holdings, {[], [], state}, fn holding, {ok, lost, state} ->
        id = holding.lease_id

        case live(state, id) do
          {:ok, _lease} ->
            {[id | ok], lost, put_in(state.leases[id].expires_at, now + state.lease_ttl * 1_000)}

          _ ->
            {ok, [id | lost], state}
        end
      end)

    cancel = for id <- Enum.reverse(renewed), state.leases[id].cancel, do: id
    {leases, state} = if with_leases?, do: grant(state, input.offer, now), else: {[], state}

    polled = %{
      leases: leases,
      cancel: cancel,
      lease_lost: Enum.reverse(lost),
      timing: %{lease_ttl: state.lease_ttl, poll_max: state.poll_max}
    }

    {:reply, polled, state}
  end

  def handle_call(
        {:report, %F.ReportInput{lease_id: id, revision: revision} = input},
        _from,
        state
      ) do
    state = sweep(state)
    kind = kind(input.report)

    with {:ok, lease} <- live(state, id),
         :ok <- in_time(state, lease, kind) do
      case reported(lease.reports, revision, input.report, kind) do
        :again ->
          {:reply, recorded(state, lease), state}

        :next ->
          lease = %{lease | reports: known(lease.reports) ++ [input.report]}
          {lease, state} = apply_report(state, id, lease, input.report)
          state = put_in(state.leases[id], lease)
          {:reply, recorded(state, lease), state}

        :conflict ->
          {:reply, %F.Outcome.Rejected{reason: :conflict, detail: "revision #{revision}"}, state}
      end
    else
      :late -> {:reply, %F.Outcome.LeaseLost{}, lose(state, id)}
      _ -> {:reply, %F.Outcome.LeaseLost{}, state}
    end
  end

  def handle_call({:may_put, id, sha}, _from, state) do
    reply =
      case live(state, id) do
        {:ok, lease} ->
          if MapSet.member?(lease.referenced, sha), do: :ok, else: %F.Outcome.NotReferenced{}

        _ ->
          %F.Outcome.LeaseLost{}
      end

    {:reply, reply, state}
  end

  def handle_call({:put_blob, id, sha, bytes}, _from, state) do
    case live(state, id) do
      {:ok, _lease} ->
        write!(blob_path(state.home, sha), bytes)
        {:reply, %F.Outcome.Stored{}, state}

      _ ->
        {:reply, %F.Outcome.LeaseLost{}, state}
    end
  end

  ## Rules

  # Leases within the offer (O1: at most its total, among the profiles it names), in the
  # queue's order. The offer names a profile available for some permission; a work is
  # leased only where its profile is available for that work's own permission (Main's #330
  # round 3, the executor's one rule, `Work.available/1`). So a retry the executor could
  # not take now stays queued, and is leased once an option can serve it.
  defp grant(state, offer, now) do
    {total, profiles} =
      if map_size(offer) == 0,
        do: {0, []},
        else: {offer |> Map.values() |> Enum.min(), Map.keys(offer)}

    candidates =
      state.loaded
      |> Store.queued()
      |> Enum.filter(&(&1.request.profile in profiles))

    available =
      if candidates == [] or total <= 0,
        do: MapSet.new(),
        else: candidates |> Enum.map(&need/1) |> Work.available() |> MapSet.new()

    candidates
    |> Enum.filter(&MapSet.member?(available, need(&1)))
    |> Enum.take(max(total, 0))
    |> Enum.map_reduce(state, fn work, state ->
      id = "local-lease-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      leased = QueuedWork.new!(%{work | state: :leased, lease_id: id})
      loaded = Store.put!(state.home, state.loaded, leased)

      state = %{
        state
        | loaded: loaded,
          leases: Map.put(state.leases, id, lease(work.work_id, now, state.lease_ttl))
      }

      wire = %{
        lease_id: id,
        expires_at: DateTime.add(DateTime.utc_now(), state.lease_ttl),
        work:
          %{work_key: work.work_id, request: to_request(work), attempt: work.attempt || 1}
          |> then(&if(work.resume, do: Map.put(&1, :resume, true), else: &1))
      }

      {wire, state}
    end)
  end

  # What a queued work needs of its profile: its permission (as `Policy` names it).
  defp need(%QueuedWork{request: %{profile: profile, workspace: workspace}}),
    do: {profile, permission(workspace)}

  defp permission(%{url: _}), do: "dedicated-repository"
  defp permission(%{permissions: permissions}), do: to_string(perm_to_request(permissions))

  # The lease if it is its work's current one and has not expired.
  defp live(state, id) do
    with %{lost: false} = lease <- state.leases[id],
         %QueuedWork{lease_id: ^id} <- state.loaded.entries[lease.work_id],
         true <- state.clock.() < lease.expires_at do
      {:ok, lease}
    else
      _ -> :lost
    end
  end

  defp current(state, work_id) do
    case state.loaded.entries[work_id] do
      %QueuedWork{state: :leased, lease_id: id} when is_map_key(state.leases, id) -> id
      _ -> nil
    end
  end

  defp in_time(state, lease, :accepted) do
    if state.clock.() - lease.offered_at > state.accept_deadline * 1_000,
      do: :late,
      else: :ok
  end

  defp in_time(_state, _lease, _kind), do: :ok

  # After a restart the reports so far are unknown: the one that comes is taken.
  defp reported(:unknown, _revision, _report, _kind), do: :next

  defp reported(reports, revision, report, kind) do
    last = length(reports)

    cond do
      revision == last and List.last(reports) == report -> :again
      revision == last + 1 and follows?(reports, kind) -> :next
      true -> :conflict
    end
  end

  defp known(:unknown), do: []
  defp known(reports), do: reports

  defp follows?([], kind), do: kind in [:accepted, :refused]

  defp follows?(reports, kind) do
    case {kind(List.last(reports)), kind} do
      {:accepted, k} -> k in [:started, :ended]
      {:started, :ended} -> true
      _ -> false
    end
  end

  defp apply_report(state, _id, lease, %F.Accepted{}), do: {%{lease | accepted: true}, state}

  defp apply_report(state, _id, lease, %F.Started{}), do: {lease, state}

  # The executor will not run the work: it ends here, failed, with the reason logged.
  defp apply_report(state, id, lease, %F.Refused{reason: reason}) do
    Logger.warning("runtime local source: lease #{id} of #{lease.work_id} refused: #{reason}")
    {lease, finish(state, lease.work_id, %{kind: :failed}, nil)}
  end

  defp apply_report(state, _id, lease, %F.Ended{} = ended) do
    referenced =
      for %{entries: entries} <- (ended.change_set && ended.change_set.roots) || [],
          %{op: :write, sha256: sha} when is_binary(sha) <- entries,
          into: MapSet.new(),
          do: sha

    {%{lease | referenced: referenced}, finish(state, lease.work_id, ended.result, ended)}
  end

  defp finish(state, work_id, result, ended) do
    work = state.loaded.entries[work_id]
    if ended, do: write!(result_path(state.home, work_id), JSON.encode!(F.Ended.dump(ended)))

    ref = %{
      kind: result.kind,
      attempt: work.attempt || 1,
      frozen_id: if(ended && ended.change_set, do: work_id),
      ended_at: DateTime.utc_now()
    }

    ended_work = QueuedWork.new!(%{work | state: :ended, result: ref})
    loaded = Store.put!(state.home, state.loaded, ended_work)

    # A retry kept while this attempt was ending: the work is queued for the next one.
    case work.retry do
      %{resume: resume?} ->
        {_queued, loaded} = Store.requeue!(state.home, loaded, ended_work, resume?)
        nudge(state)
        %{state | loaded: loaded}

      nil ->
        %{state | loaded: loaded}
    end
  end

  defp recorded(state, lease) do
    missing =
      case lease.reports do
        [_ | _] = reports ->
          if match?(%F.Ended{}, List.last(reports)),
            do:
              lease.referenced
              |> Enum.reject(&File.exists?(blob_path(state.home, &1)))
              |> Enum.sort(),
            else: []

        _ ->
          []
      end

    %F.Outcome.Recorded{missing: missing}
  end

  # Lost: no longer current; a work that has not ended is queued again for a fresh lease.
  defp lose(state, id) do
    lease = state.leases[id]
    state = put_in(state.leases[id].lost, true)

    case state.loaded.entries[lease.work_id] do
      %QueuedWork{state: :leased, lease_id: ^id} = work ->
        queued = QueuedWork.new!(%{work | state: :queued, lease_id: nil})
        %{state | loaded: Store.put!(state.home, state.loaded, queued)}

      _ ->
        state
    end
  end

  defp sweep(state) do
    now = state.clock.()

    Enum.reduce(state.leases, state, fn {id, lease}, state ->
      cond do
        lease.lost ->
          state

        not lease.accepted and now - lease.offered_at > state.accept_deadline * 1_000 ->
          lose(state, id)

        now >= lease.expires_at + state.grace * 1_000 ->
          lose(state, id)

        true ->
          state
      end
    end)
  end

  defp nudge(state) do
    case Process.whereis(state.puller) do
      nil -> :ok
      pid -> send(pid, :poll)
    end
  end

  defp kind(%F.Accepted{}), do: :accepted
  defp kind(%F.Refused{}), do: :refused
  defp kind(%F.Started{}), do: :started
  defp kind(%F.Ended{}), do: :ended

  ## The store's result files (below local-source/, denied to every worker, I8)

  defp result_path(home, work_id) do
    name = work_id <> ".json"
    Path.join([Store.folder(home), "results", name])
  end

  defp blob_path(home, sha), do: Path.join([Store.folder(home), "blobs", sha])

  defp sha256?(sha), do: is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha)

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp write!(path, bytes) do
    for folder <- [Path.dirname(Path.dirname(path)), Path.dirname(path)] do
      File.mkdir_p!(folder)
      File.chmod!(folder, 0o700)
    end

    temporary = path <> ".tmp"
    File.write!(temporary, bytes)
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, path)
  end

  ## The request: the work contract's, as the store keeps it

  @doc false
  def to_store(%B.WorkRequest{} = r) do
    %{
      title: r.title,
      instructions: r.instructions,
      profile: r.profile,
      cost_class: r.cost_class,
      workspace: workspace_to_store(r.workspace),
      resume_from: r.resume_from,
      slot: r.slot,
      after_check:
        r.after_check && %{command: r.after_check.command, timeout: r.after_check.timeout}
    }
    |> drop_nil()
  end

  defp workspace_to_store(%B.Repository{} = w),
    do: %{kind: :repository, url: w.url, branch: w.branch, base: w.base}

  defp workspace_to_store(%B.Folder{} = w),
    do: %{kind: :folder, path: w.path, permissions: perm_to_store(w.permissions)}

  defp workspace_to_store(%B.Base{} = w),
    do: %{kind: :base, base_id: w.base_id, permissions: perm_to_store(w.permissions)}

  defp workspace_to_store(%B.FromWork{} = w),
    do:
      %{
        kind: :from_work,
        work_id: w.work_id,
        attempt: w.attempt,
        permissions: perm_to_store(w.permissions)
      }
      |> drop_nil()

  defp perm_to_store(:"read-only"), do: :read_only
  defp perm_to_store(:"workspace-write"), do: :workspace_write
  defp perm_to_store(:"materialized-folder"), do: :materialized_folder

  @doc false
  def to_request(%QueuedWork{client_key: _key, request: r}) do
    %B.WorkRequest{
      title: r.title,
      instructions: r.instructions,
      profile: r.profile,
      cost_class: r.cost_class,
      workspace: workspace_to_request(r.workspace),
      resume_from: r.resume_from,
      slot: r.slot,
      after_check:
        r.after_check &&
          %B.AfterCheck{command: r.after_check.command, timeout: r.after_check.timeout}
    }
  end

  defp workspace_to_request(w) do
    case w |> Map.get(:__struct__) |> Module.split() |> List.last() do
      "Repository" ->
        %B.Repository{url: w.url, branch: w.branch, base: w.base}

      "Folder" ->
        %B.Folder{path: w.path, permissions: perm_to_request(w.permissions)}

      "Base" ->
        %B.Base{base_id: w.base_id, permissions: perm_to_request(w.permissions)}

      "FromWork" ->
        %B.FromWork{
          work_id: w.work_id,
          attempt: w.attempt,
          permissions: perm_to_request(w.permissions)
        }
    end
  end

  defp perm_to_request(:read_only), do: :"read-only"
  defp perm_to_request(:workspace_write), do: :"workspace-write"
  defp perm_to_request(:materialized_folder), do: :"materialized-folder"

  defp drop_nil(map), do: for({k, v} <- map, v != nil, into: %{}, do: {k, v})
end

defmodule AtlasRuntime.Sources.Local.Target do
  @moduledoc """
  The local source's puller target (`AtlasRuntime.Sources.Puller.Target`, M2 plan A5): the
  poll in-BEAM (`AtlasRuntime.Sources.Local.poll_local/2`, whose leases carry the work
  contract's request), and the reports and the upload through the `work_source` contract's
  in-BEAM target on the local source (`AtlasRuntime.Sources.LocalFacade`), as for any
  source. The ref is `%{server: name, client: {runtime_id, [:lease]}}`.
  """
  @behaviour AtlasRuntime.Sources.Puller.Target

  alias AtlasRuntime.Sources.{InBeamTarget, Local, LocalFacade}

  @doc "The target on the local source `server` (default `AtlasRuntime.Sources.Local`)."
  def new(server \\ Local), do: {__MODULE__, %{server: server, client: {"local", [:lease]}}}

  @impl true
  def poll(%{server: server}, input) do
    case Local.poll_local(input, server) do
      %{} = polled -> {:polled, polled}
      :not_running -> {:error, :local_source_not_running}
    end
  end

  @impl true
  def send_report(ref, input), do: InBeamTarget.send_report(facade(ref), input)

  @impl true
  def uploader(ref, revision), do: InBeamTarget.uploader(facade(ref), revision)

  # A local lease names no input blob (it carries its request), so nothing is imported.
  @impl true
  def get_blob(_ref, _lease_id, _sha256), do: :not_found

  defp facade(%{client: client}), do: %{facade: LocalFacade, client: client}
end
