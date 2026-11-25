defmodule AtlasFlow.Dispatch do
  @moduledoc """
  The work source's only granter (plan m3 §3.1, §3.2; decision 2026-11-17 §5.3, §5.6). A
  process of its own, attached to the Bus as `flow/dispatch`; it shares nothing with
  Delivery but Facts (Flow plan decision 11).

  **Ready set.** The tasks it may offer are the version-2 intents active runs hold
  (`pending.task`, `AtlasFlow.WorkSource.Translate`), read from Facts at boot, on
  `ready/2` (the Engine's cast once it made an intent) and on every resync (60 s). Today's
  intents (version 1) are never offered. Tasks are offered oldest first (`created_at`)
  among those whose profile the poll offers a slot for. The profiles of a poll share the
  Runtime's slots (it offers each profile its total of free slots): one poll is granted at
  most the largest of its counts, and each profile at most its own (IS-Atlas-113). A task
  Dispatch holds a lease of is not read for a grant: only once another writer changed its
  task fact (Dispatch listens to the `task` hints; Delivery may have ended the lease
  without a result), or once the sweep found the lease ended and let it go (a hint may be
  lost).

  **Grant (race-safe; §3.2).** For one slot:

  1. the subject's supervision (`AtlasFlow.Supervision`) must be `{:supervised, holder, _}`
     with the credential's holder;
  2. the lease is created on the task fact by a fenced change (`was` the previous
     `lease_id`): `lease_id`, `runtime`, `done_for` the holder, `granted_at`, `expires_at`
     (as granted), `attempt` n + 1, `lease_state` offered, and the lease's input (`input`,
     `base_id`, `base_snapshot`);
  3. the supervision is read again after the write: if it changed, the lease is written
     `lost` (`lease_end_cause` supervision) and not offered;
  4. the lease is in the poll's answer.

  A task whose last lease was lost goes, like any other, only to the Runtimes of the
  supervisor of the moment: the same holder's other Runtimes, as long as the supervisor
  did not change (decision 2).

  **Renewals and expiry (§3.2 "Expiry fence").** `poll` renews, in memory only, the
  holdings that are this Runtime's live leases; every other holding is `lease_lost`. A
  poll reads nothing but what its grants need: it renews, grants from the ready set
  Dispatch holds, and answers within `poll_max`, however slow Facts is (IS-Atlas-110). It
  starts no grant once half of `poll_max` has passed; the next poll takes the rest.

  The sweep runs on its own timer (every 5 s) and on `sweep/1`, never on a poll, in
  `AtlasFlow.Dispatch.Sweep`: a process of Dispatch's own that does the sweep's reads (up
  to 6 s each when Facts is slow) while Dispatch answers polls. Facts takes the task
  writes only from `flow/dispatch`, so the sweep hands each fence, with the fact it read,
  back to Dispatch, which writes it as a fenced change of that fact (`{:fence, …}`). An
  expiry fence is written only while the lease's renewed expiry has still passed: a lease a
  poll renewed meanwhile is never fenced. The sweep fence-writes:

  - `lost` (`late_accept`) for a lease still `offered` 30 s after its `granted_at` (durable,
    so a restart does not move the deadline); the task is ready again at once;
  - `expired` once a lease's renewed expiry has passed, and `lost` at expiry + grace
    (120 s); only then is the task leased again;
  - on a supervisor or span change (`done_for` no longer the supervisor): an `offered`
    lease → `lost`; an `accepted` or `started` one → `cancel_requested`, named in its
    holder's next poll's `cancel`; an `ended` one stands.

  Each `expired` or `lost` write, once stored, is cast to Delivery
  (`AtlasFlow.Delivery.lease_fenced/4`, never a call), which ends that lease's running
  `task_attempt` (F10). A `cancel_requested` write is not: the lease's work goes on until
  its Runtime ends it.

  **Boot.** Every live lease on a task fact counts as renewed at boot (§5.3 item 5). When
  Facts does not answer that read (a deploy that restarts rela with the core), every sweep
  reads again (in the sweep's process) until it does; until then a poll loses no holding,
  since Dispatch cannot tell a live one from a lost one. Otherwise each Runtime would cancel its running work, and the
  leases on the task facts would never be swept: their tasks leased forever.

  Options of `start_link/1`: `name` (default `AtlasFlow.Dispatch`), `model` (default the
  configured one), `clock`, `delivery` (the server fences are cast to, default
  `AtlasFlow.Delivery`), `health` (the table each poll is noted in, `AtlasFlow.Health`), and the timing (`config :atlas_flow, :work_source`):
  `lease_ttl` (900 s), `grace` (120 s), `accept_deadline` (30 s), `poll_max` (25 s),
  `poll_wait` (ms a poll with nothing to answer is held, default `poll_max`), `sweep_ms`
  (5 000) and `resync_ms` (60 000); nil for either means no timer (a test sweeps itself).
  """
  use GenServer

  require Logger

  alias AtlasFlow.Dispatch.Sweep
  alias AtlasFlow.Runs.{Clock, Store}
  alias AtlasFlow.{Supervision, Talk}
  alias AtlasFlow.WorkSource.{Leases, Translate}

  @endpoint "flow/dispatch"
  @live ~w(offered accepted started ended cancel_requested)
  @done_for "done_for"

  @defaults [
    lease_ttl: 900,
    grace: 120,
    accept_deadline: 30,
    poll_max: 25,
    poll_wait: nil,
    sweep_ms: 5_000,
    resync_ms: 60_000
  ]

  ## Interface

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  A Runtime's poll: `client` is `{runtime_id, holder}` (from its credential), `input` the
  contract's `poll_input` (atom or string keys). `{:polled, %{leases, cancel, lease_lost,
  timing}}` or `{:rejected, :invalid}`.
  """
  def poll(client, input, server \\ __MODULE__),
    do: GenServer.call(server, {:poll, client, input}, :infinity)

  @doc "The Engine made (or holds) the intent of `task_key`: read the ready set again."
  def ready(task_key, server \\ __MODULE__), do: GenServer.cast(server, {:ready, task_key})

  @doc """
  The Engine no longer wants task `task_key` (F2-P: the supervisor's answer moved its run
  on, Main's D1 ruling). A cast, sent while the Engine works out the run's next step:
  the task leaves the ready set at once, so it is not offered again meanwhile. `cause` is
  not used: the lease's `lease_end_cause` is `answer`, the one cause the Engine cancels
  a task for.

  The cancel itself follows the durable record, not this cast. The Engine's store writes
  the task fact's `state: cancelled` only after the run that no longer holds the task is
  stored (store first, then cancel). Every sweep (on its timer, and on `sweep/1`) cancels
  a live lease whose task fact says so, the way a supervision change cancels one: an
  `offered` lease is written `lost`, an `accepted` or `started` one `cancel_requested`
  and named in its holder's polls' `cancel` until its work ends; an `ended` one stands.
  So the cancel survives a Facts failure (the next sweep tries again) and a Dispatch
  restart (the fact is read again), and nothing about it is kept in memory.
  """
  def cancel(task_key, cause, server \\ __MODULE__),
    do: GenServer.cast(server, {:cancel, task_key, cause})

  @doc "Runs the sweep now and answers once it ran."
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep, :infinity)

  @doc "Reads the ready set again now."
  def resync(server \\ __MODULE__), do: GenServer.call(server, :resync, :infinity)

  @doc """
  Each Runtime's last poll and the leases Dispatch holds, with their renewed expiry (F5a).
  The task fact's `expires_at` is the expiry as granted, never renewed.
  """
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  ## Server

  @impl true
  def init(opts) do
    conf = Keyword.merge(@defaults, Application.get_env(:atlas_flow, :work_source, []))
    conf = Keyword.merge(conf, Keyword.take(opts, Keyword.keys(@defaults)))
    model = Keyword.get_lazy(opts, :model, &AtlasFlow.Model.configured!/0)

    :ok = AtlasBus.attach(@endpoint)
    :ok = AtlasBus.listen(Leases.task_kind())
    {:ok, sweeper} = Sweep.start_link(self())

    state = %{
      runner:
        AtlasFlow.Model.load(
          model,
          AtlasFlow.Model.environment(),
          Keyword.get(opts, :actors, AtlasBus.Actors.configured())
        ),
      clock: opts[:clock],
      delivery: Keyword.get(opts, :delivery, AtlasFlow.Delivery),
      ttl: conf[:lease_ttl],
      grace: conf[:grace],
      deadline: conf[:accept_deadline],
      poll_max: conf[:poll_max],
      wait: conf[:poll_wait] || conf[:poll_max] * 1000,
      sweep_ms: conf[:sweep_ms],
      resync_ms: conf[:resync_ms],
      ready: %{},
      leases: %{},
      parked: %{},
      polls: %{},
      health: Keyword.get(opts, :health, AtlasFlow.Health),
      booted: false,
      sweeper: sweeper,
      sweep: nil,
      touched: MapSet.new()
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = state |> resync_ready() |> boot_leases()
    every(state, :sweep_ms, :tick)
    every(state, :resync_ms, :resync_tick)
    {:noreply, state}
  end

  @impl true
  def handle_call({:poll, {runtime_id, holder} = client, input}, from, state)
      when is_binary(runtime_id) and is_binary(holder) do
    case poll_input(input, runtime_id) do
      {:ok, offer, holdings} ->
        # No sweep here (IS-Atlas-110): it runs on its own, in `Sweep`.
        budget = budget(state)
        state = put_in(state.polls[runtime_id], now(state))
        # Each Runtime's last poll, for Control's health page; never waits.
        AtlasFlow.Health.polled(runtime_id, state.polls[runtime_id], state.health)
        state = late_accepts(state, runtime_id, holdings, budget)
        {renewed, lost, state} = renew(state, runtime_id, holdings)
        cancel = for id <- renewed, state.leases[id].cancel, do: id
        {leases, state} = grant_offer(state, client, offer, budget)

        answer = %{leases: leases, cancel: cancel, lease_lost: lost, timing: timing(state)}

        if leases == [] and cancel == [] and state.wait > 0 and offer != %{} do
          {:noreply, park(state, runtime_id, from, client, offer, answer)}
        else
          {:reply, {:polled, answer}, state}
        end

      :error ->
        {:reply, {:rejected, :invalid}, state}
    end
  end

  def handle_call({:poll, _client, _input}, _from, state),
    do: {:reply, {:rejected, :invalid}, state}

  def handle_call(:sweep, from, state), do: {:noreply, start_sweep(state, from)}

  def handle_call(:resync, _from, state),
    do: {:reply, :ok, state |> resync_ready() |> serve_parked()}

  # The sweep's fence of lease `id`, on the task fact it read (see `Sweep`).
  def handle_call({:fence, id, fact, to, cause, apply}, _from, state) do
    if apply == :expired and not due?(state, id) do
      {:reply, :renewed, state}
    else
      change = Leases.change(fact, %{"lease_state" => to, "lease_end_cause" => cause})

      case Talk.put(Leases.task_kind(), change) do
        {:stored, _} ->
          if to in ~w(expired lost),
            do: AtlasFlow.Delivery.lease_fenced(fact["key"], id, cause, state.delivery)

          {:reply, :ended, learn(state, id, apply)}

        _refused_or_unanswered ->
          {:reply, :refused, state}
      end
    end
  end

  # The leases the sweep read while Dispatch could not at boot.
  def handle_call({:sweep_boot, facts}, _from, state) do
    state = if state.booted, do: state, else: take_leases(state, facts)
    {:reply, state.leases, state}
  end

  def handle_call(:status, _from, state) do
    leases =
      for {id, l} <- state.leases,
          do: %{lease_id: id, task_key: l.task_key, runtime: l.runtime, expires_at: l.expires_at}

    {:reply, %{polls: state.polls, leases: Enum.sort_by(leases, & &1.lease_id)}, state}
  end

  @impl true
  def handle_cast({:ready, _task_key}, state),
    do: {:noreply, state |> resync_ready() |> serve_parked()}

  # The lease is cancelled once the task fact says so (`cancel/3`); here only the ready set.
  def handle_cast({:cancel, task_key, _cause}, state),
    do: {:noreply, %{state | ready: Map.delete(state.ready, task_key)}}

  def handle_cast({:swept, id, what}, state), do: {:noreply, learn(state, id, what)}

  @impl true
  def handle_info(:tick, state) do
    every(state, :sweep_ms, :tick)
    {:noreply, start_sweep(state, nil)}
  end

  def handle_info({:swept, ref}, %{sweep: %{ref: ref} = sweep} = state) do
    for from <- sweep.waiters, do: GenServer.reply(from, :ok)
    state = serve_parked(%{state | sweep: nil})

    case sweep.again do
      [] -> {:noreply, state}
      again -> {:noreply, start_sweep(state, again)}
    end
  end

  def handle_info(:resync_tick, state) do
    every(state, :resync_ms, :resync_tick)
    {:noreply, state |> resync_ready() |> serve_parked()}
  end

  # Another writer (Delivery, Landing) changed a task fact Dispatch holds a lease of: the
  # next grant reads it once, since the lease may have ended without a result.
  def handle_info(
        {:atlas_bus, %AtlasBus.Envelope{class: "stored", address: by}, %{"key" => key}},
        state
      )
      when by != @endpoint and is_binary(key) do
    if Enum.any?(state.leases, fn {_, l} -> l.task_key == key end),
      do: {:noreply, %{state | touched: MapSet.put(state.touched, key)}},
      else: {:noreply, state}
  end

  def handle_info({:poll_max, runtime_id, ref}, state) do
    case state.parked[runtime_id] do
      %{ref: ^ref} = parked ->
        GenServer.reply(parked.from, {:polled, parked.answer})
        {:noreply, %{state | parked: Map.delete(state.parked, runtime_id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  ## Polls

  defp poll_input(input, runtime_id) do
    input = Translate.normal(input)

    with true <- is_map(input),
         ^runtime_id <- input["runtime_id"],
         %{} = offer <- input["offer"],
         true <- Enum.all?(offer, fn {p, n} -> is_binary(p) and is_integer(n) and n >= 0 end),
         holdings when is_list(holdings) <- input["holdings"],
         true <- Enum.all?(holdings, &is_binary((&1 || %{})["lease_id"])) do
      {:ok, offer, Enum.map(holdings, & &1["lease_id"])}
    else
      _ -> :error
    end
  end

  defp timing(state), do: %{lease_ttl: state.ttl, poll_max: state.poll_max}

  # Holdings this Runtime holds a live lease of are renewed; every other is lost to it, once
  # Dispatch has read the leases (before that, an unknown holding is neither).
  defp renew(state, runtime_id, holdings) do
    expires = DateTime.add(now(state), state.ttl, :second)

    {renewed, lost, leases} =
      Enum.reduce(holdings, {[], [], state.leases}, fn id, {ok, lost, leases} ->
        case leases[id] do
          %{runtime: ^runtime_id, state: s} = lease when s != :expired ->
            {[id | ok], lost, Map.put(leases, id, %{lease | expires_at: expires})}

          nil when not state.booted ->
            {ok, lost, leases}

          _ ->
            {ok, [id | lost], leases}
        end
      end)

    {Enum.reverse(renewed), Enum.reverse(lost), %{state | leases: leases}}
  end

  # This Runtime's own holdings still offered past the accept deadline are fenced here, as
  # the sweep would (`lost`, `late_accept`), so the poll answers them lost and grants their
  # task again at once. Only within the poll's budget: past it, the sweep does it.
  defp late_accepts(state, runtime_id, holdings, budget) do
    now = now(state)

    Enum.reduce(holdings, state, fn id, state ->
      case state.leases[id] do
        %{runtime: ^runtime_id, state: :offered} = lease ->
          if DateTime.diff(now, lease.granted_at, :second) > state.deadline and
               System.monotonic_time(:millisecond) < budget,
             do: late_accept(state, id, lease),
             else: state

        _ ->
          state
      end
    end)
  end

  defp late_accept(state, id, lease) do
    case Leases.read(lease.task_key) do
      {:ok, fact} ->
        cond do
          Leases.value(fact, "lease_id") == id and Leases.value(fact, "lease_state") == "offered" ->
            case end_lease(state, lease.task_key, id, ["offered"], "lost", "late_accept") do
              :ended -> drop(state, id)
              _ -> state
            end

          # Accepted in time (Delivery's).
          Leases.value(fact, "lease_id") == id ->
            put_in(state.leases[id].state, :live)

          true ->
            drop(state, id)
        end

      {:error, _} ->
        state
    end
  end

  # One open poll per Runtime: a newer one answers the one held before it, empty.
  defp park(state, runtime_id, from, client, offer, answer) do
    state =
      case state.parked[runtime_id] do
        %{from: earlier} = parked ->
          GenServer.reply(earlier, {:polled, parked.answer})
          state

        nil ->
          state
      end

    ref = make_ref()
    Clock.schedule(state.clock, self(), {:poll_max, runtime_id, ref}, state.wait)
    entry = %{from: from, client: client, offer: offer, answer: answer, ref: ref}
    put_in(state.parked[runtime_id], entry)
  end

  # A held poll is answered as soon as there is a lease for it.
  defp serve_parked(state) do
    budget = budget(state)

    Enum.reduce(state.parked, state, fn {runtime_id, parked}, state ->
      case grant_offer(state, parked.client, parked.offer, budget) do
        {[], state} ->
          state

        {leases, state} ->
          GenServer.reply(parked.from, {:polled, %{parked.answer | leases: leases}})
          %{state | parked: Map.delete(state.parked, runtime_id)}
      end
    end)
  end

  ## Grants

  # The profiles of one poll share the Runtime's slots: each profile's count is the free
  # slots it may take, and the poll's slots are the largest of those counts (the Runtime
  # offers every profile its total), never their sum. Tasks are granted oldest first among
  # the profiles that still have a slot, until the poll's slots are taken.
  # Each grant reads and writes Facts; none is started once `budget` (monotonic ms) passed.
  defp grant_offer(state, client, offer, budget) do
    slots = offer |> Map.values() |> Enum.max(fn -> 0 end)
    grant_slots(state, client, offer, slots, [], budget)
  end

  defp grant_slots(state, _client, _offer, 0, leases, _budget), do: {leases, state}

  defp grant_slots(state, client, offer, slots, leases, budget) do
    open = for {profile, free} <- offer, free > 0, into: MapSet.new(), do: profile

    case grant_one(state, client, open, budget) do
      {nil, state} ->
        {leases, state}

      {{profile, lease}, state} ->
        offer = Map.update!(offer, profile, &(&1 - 1))
        grant_slots(state, client, offer, slots - 1, leases ++ [lease], budget)
    end
  end

  # Half of poll_max: what a poll may spend on its grants, so it answers within poll_max.
  defp budget(state), do: System.monotonic_time(:millisecond) + div(state.poll_max * 1000, 2)

  defp grant_one(state, client, profiles, budget) do
    # A task Dispatch holds a lease of is not read again for a grant (IS-Atlas-110: on a
    # slow Facts each read takes up to 6 s). An expired lease holds its task until it is
    # lost; a live one until another writer changed its task fact (a hint: it may have
    # ended without a result, so the fact decides), or the sweep found it ended and dropped
    # it (the hint may be lost).
    held =
      for {_, l} <- state.leases,
          l.state == :expired or not MapSet.member?(state.touched, l.task_key),
          into: MapSet.new(),
          do: l.task_key

    state.ready
    |> Map.values()
    |> Enum.filter(
      &(MapSet.member?(profiles, &1.intent["work"]["profile"]) and
          not MapSet.member?(held, &1.key))
    )
    |> Enum.sort_by(&{&1.intent["created_at"], &1.key})
    |> Enum.reduce_while({nil, state}, fn entry, {nil, state} ->
      if System.monotonic_time(:millisecond) >= budget do
        {:halt, {nil, state}}
      else
        with {:free, state} <- refresh(state, entry.key),
             {:ok, wire, state} <- grant(state, entry, client) do
          {:halt, {{entry.intent["work"]["profile"], wire}, state}}
        else
          {:held, state} -> {:cont, {nil, state}}
          :skip -> {:cont, {nil, state}}
        end
      end
    end)
  end

  # A task another writer changed while Dispatch holds a lease of it: its fact, read once,
  # says whether that lease is over (`:free`, the lease dropped) or still holds it.
  defp refresh(state, task_key) do
    ids = for {id, l} <- state.leases, l.task_key == task_key, do: id

    cond do
      ids == [] ->
        {:free, state}

      not MapSet.member?(state.touched, task_key) ->
        {:held, state}

      true ->
        case Leases.read(task_key) do
          {:ok, fact} ->
            state = %{state | touched: MapSet.delete(state.touched, task_key)}

            if Leases.value(fact, "lease_id") in ids and
                 Leases.value(fact, "lease_state") in @live,
               do: {:held, state},
               else: {:free, %{state | leases: Map.drop(state.leases, ids)}}

          {:error, _} ->
            {:held, state}
        end
    end
  end

  defp grant(state, %{subject: {kind, key}} = entry, {runtime_id, holder}) do
    with {:supervised, ^holder, _run} <- Supervision.of(state.runner, kind, key),
         {:granted, lease_id, values} <-
           Leases.update(entry.key, &lease(&1, entry, runtime_id, holder, state)),
         :ok <- still_supervised(state, entry, holder, lease_id) do
      lease = %{
        lease_id: lease_id,
        task_key: entry.key,
        runtime: runtime_id,
        holder: holder,
        subject: entry.subject,
        granted_at: now(state),
        expires_at: DateTime.add(now(state), state.ttl, :second),
        state: :offered,
        cancel: false
      }

      wire = %{
        lease_id: lease_id,
        expires_at: values["expires_at"],
        work: Translate.offered_work(entry.intent)
      }

      superseded = for {id, l} <- state.leases, l.task_key == entry.key, do: id
      leases = state.leases |> Map.drop(superseded) |> Map.put(lease_id, lease)
      {:ok, wire, %{state | leases: leases}}
    else
      _ -> :skip
    end
  end

  # The lease, as a fenced change of the task fact; nil when the task is not to be leased.
  defp lease(fact, entry, runtime_id, holder, state) do
    if grantable?(fact, holder) do
      attempt = (Leases.value(fact, "attempt") || 0) + 1
      lease_id = Leases.new_id(entry.key, attempt)
      now = now(state)

      values = %{
        "lease_id" => lease_id,
        "runtime" => runtime_id,
        "granted_at" => DateTime.to_iso8601(now),
        "expires_at" => DateTime.to_iso8601(DateTime.add(now, state.ttl, :second)),
        "attempt" => attempt,
        "lease_state" => "offered",
        "lease_end_cause" => nil,
        "input" => Translate.lease_input(entry.intent),
        "base_id" => entry.intent["work"]["input"]["base"]["base_id"],
        "base_snapshot" => entry.intent["base_snapshot"]
      }

      {:write, values, %{@done_for => [holder]}, {:granted, lease_id, values}}
    else
      {:reply, :skip}
    end
  end

  # A task with no lease, or whose last one was lost or ended without a result. "Without a
  # result" is decided from the ending (`Translate.no_result?/1`), never from a cancel
  # request alone: an ended(completed) after cancel_requested is not offered again.
  defp grantable?(nil, _holder), do: false

  defp grantable?(fact, _holder) do
    # The Engine cancelled it (F2-P, `cancel/3`): never leased again, whatever the ready
    # set still says.
    if Leases.value(fact, "state") == "cancelled" do
      false
    else
      case Leases.value(fact, "lease_state") do
        nil -> Leases.value(fact, "lease_id") == nil
        "lost" -> true
        "done" -> Translate.no_result?(fact["values"])
        _ -> false
      end
    end
  end

  # After the write: a hand-over that landed meanwhile loses the lease before it is offered.
  defp still_supervised(state, %{subject: {kind, key}} = entry, holder, lease_id) do
    case Supervision.of(state.runner, kind, key) do
      {:supervised, ^holder, _} ->
        :ok

      _changed ->
        end_lease(state, entry.key, lease_id, ["offered"], "lost", "supervision")
        :lost
    end
  end

  ## Sweep

  # One sweep at a time, in `Sweep`. `from` (a `sweep/1` caller, or a list of them) is
  # answered once a sweep that began after its call ran: during one, the next is queued.
  defp start_sweep(%{sweep: nil} = state, from) do
    ref = make_ref()

    Sweep.run(state.sweeper, %{
      ref: ref,
      now: now(state),
      deadline: state.deadline,
      grace: state.grace,
      runner: state.runner,
      leases: state.leases,
      booted: state.booted
    })

    %{state | sweep: %{ref: ref, waiters: List.wrap(from), again: []}}
  end

  defp start_sweep(state, nil), do: state

  defp start_sweep(%{sweep: sweep} = state, from),
    do: %{state | sweep: %{sweep | again: sweep.again ++ List.wrap(from)}}

  # Whether lease `id`'s renewed expiry has passed now: a poll may have renewed it since
  # the sweep read it.
  defp due?(state, id) do
    case state.leases[id] do
      %{state: s, expires_at: at} when s != :expired -> DateTime.compare(now(state), at) != :lt
      _ -> false
    end
  end

  # What the sweep found or fenced, on the lease Dispatch holds now.
  defp learn(state, id, :drop), do: drop(state, id)

  defp learn(state, id, what) do
    case {state.leases[id], what} do
      {nil, _} -> state
      {_, :expired} -> put_in(state.leases[id].state, :expired)
      {_, :cancel} -> put_in(state.leases[id].cancel, true)
      {%{state: :offered}, :live} -> put_in(state.leases[id].state, :live)
      _ -> state
    end
  end

  # Fence-writes `lease_state` (and its cause) on lease `id` while it is in one of `from`:
  # `:ended` once stored, `:gone` when the lease is not in one of them, `:unavailable`.
  # A stored fence (`to` expired or lost) is cast to Delivery, which ends the lease's
  # attempt (F10); `cancel_requested` fences nothing, so it is not.
  defp end_lease(state, task_key, id, from, to, cause) do
    decide = fn fact ->
      if Leases.value(fact, "lease_id") == id and Leases.value(fact, "lease_state") in from,
        do: {:write, %{"lease_state" => to, "lease_end_cause" => cause}, %{}, :ended},
        else: {:reply, :gone}
    end

    case Leases.update(task_key, decide) do
      :ended ->
        if to in ~w(expired lost),
          do: AtlasFlow.Delivery.lease_fenced(task_key, id, cause, state.delivery)

        :ended

      :gone ->
        :gone

      _ ->
        :unavailable
    end
  end

  defp drop(state, id), do: %{state | leases: Map.delete(state.leases, id)}

  ## Ready set and boot

  defp resync_ready(%{runner: %{config: nil}} = state), do: state

  defp resync_ready(%{runner: %{config: config}} = state) do
    case AtlasFlow.Talk.read(config["kind"], %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        ready =
          for fact <- facts,
              {:ok, run} <- [Store.decode(config, fact)],
              run["status"] == "active",
              intent = run["pending"]["task"],
              Translate.intent?(intent),
              into: %{} do
            {intent["key"],
             %{
               key: intent["key"],
               intent: intent,
               subject: {run["subject_kind"], run["subject_key"]}
             }}
          end

        leases =
          Map.new(state.leases, fn {id, l} ->
            {id, %{l | subject: l.subject || (ready[l.task_key] && ready[l.task_key].subject)}}
          end)

        %{state | ready: ready, leases: leases}

      other ->
        Logger.warning("flow dispatch could not read the runs: #{inspect(other)}")
        state
    end
  end

  # Every live lease on a task fact counts as renewed now (§5.3 item 5); read once, at boot,
  # and again by each sweep while Facts did not answer it.
  defp boot_leases(state) do
    case Leases.all() do
      {:ok, facts} ->
        take_leases(state, facts)

      {:error, why} ->
        Logger.warning("flow dispatch could not read the leases: #{inspect(why)}")
        state
    end
  end

  defp take_leases(state, facts) do
    now = now(state)

    leases =
      for fact <- facts,
          id = Leases.value(fact, "lease_id"),
          is_binary(id),
          lease_state = Leases.value(fact, "lease_state"),
          lease_state in ["expired" | @live],
          into: %{} do
        {id,
         %{
           lease_id: id,
           task_key: fact["key"],
           runtime: Leases.value(fact, "runtime"),
           holder: List.first(Leases.links(fact, @done_for)),
           subject: state.ready[fact["key"]] && state.ready[fact["key"]].subject,
           granted_at: parse(Leases.value(fact, "granted_at")) || now,
           expires_at:
             if(lease_state == "expired",
               do: now,
               else: DateTime.add(now, state.ttl, :second)
             ),
           state:
             case lease_state do
               "offered" -> :offered
               "expired" -> :expired
               _ -> :live
             end,
           cancel: lease_state == "cancel_requested"
         }}
      end

    %{state | leases: Map.merge(leases, state.leases), booted: true}
  end

  defp parse(%DateTime{} = at), do: at

  defp parse(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp parse(_), do: nil

  defp every(state, key, message) do
    case state[key] do
      ms when is_integer(ms) and ms > 0 -> Clock.schedule(state.clock, self(), message, ms)
      _ -> nil
    end
  end

  defp now(state), do: Clock.now(state.clock)
end
