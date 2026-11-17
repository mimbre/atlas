defmodule AtlasRuntime.Work do
  @moduledoc """
  The Runtime's work core, the executor: an implementation of the work contract
  (`AtlasRuntime.Boundary.Work.Implementation`, design §1.5). Callers never call it; they
  call the facade `AtlasRuntime.Boundary.Work`, which checks rights, input and outcomes.
  Since the CLI cut-over (M2 A6) the facade's implementation is the local work source's
  (`AtlasRuntime.Sources.Local.Work`), which reaches this one as the `local` source; the
  work sources' pullers reach it through `accept_lease/3` and the calls below.

  The behaviour lives in `AtlasRuntime.Work.Server` (the process that owns the work
  records) and the modules under `AtlasRuntime.Work`: `Store` (persistence through the
  private model), `Queue` (slots, buffer, start gate, retry and cancel tables), `Turns`
  (the Service's turns), `Notifications`, `Restart` and `Prune`.

  It is started only by `host/service.exs`, after the Service, never by
  `AtlasRuntime.Application`. While it is not running every capability answers with a
  declared outcome meaning "not running": `submit`/`retry` `at_capacity: not_accepting`,
  `get_work`/`find_work`/`turn_output`/`cancel` `not_found`, `list_work` empty, `capacity`
  not accepting, `subscribe` `subscribed` with no notifications. `get_frozen` and
  `get_frozen_blob` (S5a) `not_found`.

  `get_frozen` answers a completed attempt's frozen result (`frozen`, or
  `fingerprint_mismatch` when a given fingerprint is no root's), `pruned` once retention
  turned it into a tombstone, `not_found` otherwise. `get_frozen_blob` answers a `blob` whose
  `content` is a lazy stream of at most 64 KiB chunks, read when the caller enumerates it,
  and only for a write entry of that very frozen result (s5a-plan B1, B12, B13).

  A subscriber receives `{:atlas_runtime_work, notification}` messages, where
  `notification` is a `AtlasRuntime.Boundary.Work.WorkChanged`, `CapacityAvailable` or
  `Heartbeat` struct (`AtlasRuntime.Work.Notifications`).
  """
  use AtlasRuntime.Boundary.Work.Implementation

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Work.Server

  # A start runs inside the core's process (workspace preparation included), so a call
  # may wait for one.
  @timeout 150_000

  @doc "Starts the core on the Service's home `dir`; see `AtlasRuntime.Work.Server` for `opts`."
  defdelegate start_link(dir, opts \\ []), to: Server

  @doc """
  The Service's `release` of `worker_id` (F2): a human confirms the slot free, so an attempt
  there whose end was never confirmed becomes quiescent. A no-op while the core is not running.
  """
  def released(worker_id) do
    case GenServer.whereis(Server) do
      nil -> :ok
      pid -> send(pid, {:released, worker_id})
    end

    :ok
  end

  ## For the operations (design §13.1 Q8, Q9; I-K): internal, never through a facade

  @doc """
  The Runtime's mode (I-K): the persisted `open`, `paused` or `draining`
  (`AtlasRuntime.Work.Mode`), or `:stopping` once a stop began (`stop/2`, or a Service stop
  the core heard of), which is never persisted. `:open` while the core is not running.
  """
  @spec mode() :: :open | :paused | :draining | :stopping
  def mode, do: call(:mode, fn -> :open end)

  @doc """
  Sets the persisted mode (I-K, §13.1 Q5): `:paused`, `:draining` or `:open` (resume), by
  the client id `by`, and answers `mode/0` after it. `mode.json` is written before the
  answer, and so is every buffered attempt a drain returns; the same mode again changes
  nothing. A no-op answering `stopping` while the core is not running.
  """
  @spec set_mode(:open | :paused | :draining, String.t()) ::
          :open | :paused | :draining | :stopping
  def set_mode(mode, by) when mode in [:open, :paused, :draining] and is_binary(by),
    do: call({:set_mode, mode, by}, fn -> :stopping end)

  @doc """
  What runtime info shows of the core, or nil while it is not running: `home`,
  `runtime_build`, `incarnation` and `policy_version` exactly as `capacity` answers them,
  `mode` (`mode/0`) and `slots`, the policy's slots in order as `{name, busy}`, busy as
  `capacity` counts it.
  """
  def runtime, do: call(:runtime, fn -> nil end)

  @doc """
  Releases `slot` for `by` (§13.1 Q8): `:busy` while a process of the slot is alive (a turn
  the Service owns now, or one the process probe finds running). Otherwise the Service's
  `release` clears the slot's admission latch and ends a turn of a previous Service it left
  unknown; every attempt there whose end was never confirmed becomes quiescent with
  `released_by`/`released_at`, persisted before the answer, and `work_changed` goes out.
  `:released` also when there was nothing to release, which changes no record.
  `:not_running` while the core is not running.
  """
  def mark_released(slot, by), do: call({:mark_released, slot, by}, fn -> :not_running end)

  @doc """
  Begins the Runtime's stop (§13.1 Q9) for `by` and returns once the mode is `:stopping`:
  no new work and no start; buffered work stays. Running attempts get the cancel stages'
  signal and, after `cancel_grace`, the kill (with `force`, the kill at once), and end
  `interrupted`, reason `runtime_stop`, retryable. Once none runs, the Service's own
  service stop ends the process. A repeat changes nothing. While the core is not running,
  the Service is stopped directly.
  """
  def stop(force, by), do: call({:stop, force == true, by}, &stop_service/0)

  @doc """
  Clears the quota mark of `harness` in the Service's process
  (`AtlasRuntime.Availability.clear_quota_mark/2`): `:cleared`, `:unmarked`, `:not_found`,
  or `:not_running`. A cleared mark lets waiting work start, and `capacity_available` goes
  out if the Runtime takes new work again (§3.6).
  """
  def clear_quota_mark(harness),
    do: call({:clear_quota_mark, harness}, fn -> :not_running end)

  ## For the work sources' pullers (decision §5.3 item 1; M2 plan C2, C3): internal

  @doc """
  Accepts `lease` (the work source contract's `lease`: `lease_id`, `work`) from source
  `name` as a work of that source's client (`AtlasRuntime.Sources.Rights.client/1`): the
  same submit checks as that client's, keyed by `client_key = lease_id`, with the turn's
  `idempotency_key = work_key`. Its attempt is persisted `buffered` and held before the
  answer (I2), and does not start until `release_lease/1`.

  `imported` (M2 A3) is what the puller imported of the lease's input from that source
  (`AtlasRuntime.Sources.Import.base/5`: `baseline_id`, and `change_set` when the lease
  names one): the work materializes from that baseline and change set, from the source's
  own store, never from the source's `base_id`; a change set it lacks is
  `{:refused, :invalid}`. **Accept first (Main's #330 F5 (b)):** without `imported` (as
  the puller accepts every remote lease), the work is recorded with its import pending:
  held, `holdings/1` shows it `importing`, and `release_lease/1` keeps it held until
  `lease_imported/2` set the imported base.

  Answers `{:accepted, work_id}`, `{:existing, work_id}` (the same lease again: the same
  work, one attempt), `{:refused, reason}` with a reason of the work source contract's
  `refused`, `{:unavailable, reason}` for a local retry's lease whose profile is
  unavailable now (F5 (c): nothing recorded; the lease is to be left unanswered, so the
  work stays queued at the source), or `:not_running` while the core is not running.
  Never `at_capacity`. A lease
  that is not exactly the contract's shape (`AtlasRuntime.Sources.LeaseShape`) is
  `{:refused, :invalid}`, and nothing of it is used or logged.
  """
  @spec accept_lease(String.t(), map(), nil | AtlasRuntime.Sources.Import.imported()) ::
          {:accepted | :existing, String.t()}
          | {:refused, atom()}
          | {:unavailable, atom()}
          | :not_running
  def accept_lease(source, lease, imported \\ nil) when is_binary(source),
    do: call({:accept_lease, source, lease, imported}, fn -> :not_running end)

  @doc """
  The `at_capacity` outcome a submit gets for `reason` now (M2 A6: the local work source's
  add answers `not_accepting` as the work contract does), or the stopped core's while the
  core is not running.
  """
  @spec at_capacity(:not_accepting) :: B.Outcome.AtCapacity.t()
  def at_capacity(reason) when reason in [:not_accepting],
    do: call({:at_capacity, reason}, &not_accepting/0)

  @doc """
  Checks `input` (a work request) for `client` as a submit would, without creating
  anything and without its client key (M2 A5: the local work source refuses a typo when the
  work is added). `:ok` (a profile unavailable now included: the work waits),
  `{:refused, reason, detail}` with a reason of the work contract's `refused`, or
  `{:refused, :not_accepting, detail}` while the core takes no new work or is not running.
  """
  @spec check_request(AtlasRuntime.Sources.Rights.client(), B.WorkRequest.t()) ::
          :ok | {:refused, atom(), String.t() | nil}
  def check_request(client, %B.WorkRequest{} = input),
    do:
      call({:check_request, client, input}, fn ->
        {:refused, :not_accepting, "the work core is not running"}
      end)

  @doc """
  The source recorded the accept of `work_id`'s lease: its held attempt may start.
  `:released` (also when nothing was held), `:importing` (still held: its import is
  pending, F5 (b)), `:not_found`, or `:not_running`.
  """
  @spec release_lease(String.t()) :: :released | :importing | :not_found | :not_running
  def release_lease(work_id) when is_binary(work_id),
    do: call({:release_lease, work_id}, fn -> :not_running end)

  @doc """
  The free slots offered to source `name` for the poll it is about to send (decision §5.5,
  with Main's O1 and O2), as the work source contract's `offer`.

  - **What (O1):** the total of free slots it may lease, and the profiles available now.
    On the contract's map, each available profile names that same total: the source leases
    at most that many in all, not that many per profile. `%{}` when full, paused, draining
    or stopping, or for a source the policy does not name.
  - **Who (O2):** only the sources polling right now share the free slots. They are this
    source and the others whose poll is open with an empty offer, ordered by priority, each
    up to its `max_slots` minus what it holds. A source that does not poll is held nothing.
  - **How long:** the slots are reserved for this poll only, until `offer_done/2` or the end
    of the calling process (the core monitors it). No other source and no direct submit
    takes them meanwhile, and each lease accepted from them takes one. A new offer to the
    same source replaces its reservation.

  `:not_running` while the core is not running.
  """
  @spec offer(String.t()) :: %{String.t() => non_neg_integer()} | :not_running
  def offer(name) when is_binary(name), do: call({:offer, name}, fn -> :not_running end)

  @doc """
  The `{profile, permission}` pairs of `pairs` that are available now, by the one rule the
  offer and a retry's check use (`AtlasRuntime.Policy.available?/6`, Main's #330 round 3):
  an option of the profile that serves that permission is installed and not quota-marked.
  The local source leases a queued work only when its pair is among them. `[]` while the
  core is not running.
  """
  @spec available([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def available(pairs) when is_list(pairs), do: call({:available, pairs}, fn -> [] end)

  @doc """
  The poll that carried source `name`'s offer is over, with `used` leases accepted from it:
  what is left of the reservation is free again. `:ok`, or `:not_running`.
  """
  @spec offer_done(String.t(), non_neg_integer()) :: :ok | :not_running
  def offer_done(name, used) when is_binary(name) and is_integer(used) and used >= 0,
    do: call({:offer_done, name, used}, fn -> :not_running end)

  @doc """
  The import of accepted work `work_id`'s input ended (Main's #330 F5 (b)).
  `{:ok, imported}` (`AtlasRuntime.Sources.Import.base/5`'s answer) sets the imported
  baseline as its base, with the change set the lease named: `:ok`, then
  `release_lease/1` lets it start; an import that does not match the lease is
  `{:refused, :invalid}` and ends it as below. `{:failed, retryable, detail}` ends the held
  attempt `failed` (reason `workspace`, never started), so its slot is free: `:failed`.
  `:not_pending` when its import is not pending (or its attempt not held), `:not_found`,
  or `:not_running`.
  """
  @spec lease_imported(String.t(), {:ok, map()} | {:failed, boolean(), String.t()}) ::
          :ok | :failed | {:refused, :invalid} | :not_pending | :not_found | :not_running
  def lease_imported(work_id, outcome) when is_binary(work_id),
    do: call({:lease_imported, work_id, outcome}, fn -> :not_running end)

  @doc """
  Source `name`'s puller renewed its leases (P3): `stamps` is `lease_id => %{stamp,
  received}` for every live lease it holds (replacing what was kept), the `LeaseClock`
  stamps of its last real renewal and of the send time of the poll that delivered it; and
  `ttl_ms` the source's `lease_ttl` (or nil). Kept in the core's memory, so a restarted
  puller fences from the real renewal (`renewals/1`). `:ok`, or `:not_running`.
  """
  @spec renewed(String.t(), pos_integer() | nil, %{String.t() => term()}) :: :ok | :not_running
  def renewed(name, ttl_ms, stamps) when is_binary(name) and is_map(stamps),
    do: call({:renewed, name, ttl_ms, stamps}, fn -> :not_running end)

  @doc """
  What `renewed/3` last kept for source `name`: `%{ttl_ms, stamps}`, or nil when nothing
  was kept (the core started since) or the core is not running.
  """
  @spec renewals(String.t()) :: %{ttl_ms: pos_integer() | nil, stamps: map()} | nil
  def renewals(name) when is_binary(name), do: call({:renewals, name}, fn -> nil end)

  @doc """
  The leases source `name` holds here, from the persisted records of its client
  (decision §5.1, §5.3 item 5): one map per work it leased, `lease_id`, `work_id`, the
  current attempt's `attempt` number and `state`, `held` (waiting for `release_lease/1`), `importing` (its import pending, F5 (b)),
  `ran` (it reached `running`), `quiescent` and `last_progress_at` (or nil). `[]` while the
  core is not running.
  """
  @spec holdings(String.t()) :: [map()]
  def holdings(name) when is_binary(name), do: call({:holdings, name}, fn -> [] end)

  @impl true
  def submit(client, input), do: call({:submit, client, input}, &not_accepting/0)

  @impl true
  def retry(client, input), do: call({:retry, client, input}, &not_accepting/0)

  @impl true
  def cancel(client, input), do: call({:cancel, client, input}, &not_found/0)

  @impl true
  def get_work(client, input), do: call({:get_work, client, input}, &not_found/0)

  @impl true
  def find_work(client, input), do: call({:find_work, client, input}, &not_found/0)

  @impl true
  def list_work(client, input),
    do: call({:list_work, client, input}, fn -> %B.Outcome.Works{works: [], sequence: 0} end)

  @impl true
  def capacity(client),
    do:
      call({:capacity, client}, fn ->
        struct!(B.Outcome.Capacity, Map.from_struct(stopped_capacity()))
      end)

  @impl true
  def turn_output(client, input), do: call({:turn_output, client, input}, &not_found/0)

  @impl true
  def subscribe(client, input),
    do: call({:subscribe, client, input, self()}, fn -> %B.Outcome.Subscribed{} end)

  # S5a P8 (design §3.9 "Reading a frozen result"): through the one reply path, as every
  # capability, so a later reply rule (B32) covers them too; `not_found` without the core.
  @impl true
  def get_frozen(client, %B.GetFrozenInput{} = input),
    do: call({:get_frozen, client, input}, &not_found/0)

  @impl true
  def get_frozen_blob(client, %B.GetFrozenBlobInput{} = input),
    do: call({:get_frozen_blob, client, input}, &not_found/0)

  defp call(message, stopped) do
    case GenServer.whereis(Server) do
      nil -> stopped.()
      pid -> GenServer.call(pid, message, @timeout)
    end
  end

  defp not_found, do: %B.Outcome.NotFound{}

  # Without the core only the Service's service stop is left; its exit follows the answer.
  defp stop_service do
    with pid when is_pid(pid) <- GenServer.whereis(AtlasRuntime.Service),
         {_reply, true} <- GenServer.call(pid, %{"command" => "service-stop"}, @timeout) do
      Process.send_after(pid, :shutdown, 200)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp not_accepting,
    do: %B.Outcome.AtCapacity{
      reason: :not_accepting,
      retry_after: 60,
      capacity: stopped_capacity()
    }

  defp stopped_capacity do
    %B.Capacity{
      slots: %B.SlotCounts{total: 0, busy: 0, free: 0},
      buffer: %B.BufferCounts{size: 0, used: 0, free: 0},
      profiles: [],
      accepting: false,
      policy_version: 0,
      runtime_build: AtlasRuntime.Provenance.context().runtime_build,
      incarnation: "stopped",
      retry_after: 60
    }
  end
end
