defmodule AtlasFlow.Delivery do
  @moduledoc """
  The work source's reports and results (plan m3 §3.1, §3.3, §3.4, §3.5): a process of its
  own, attached to the Bus as `flow/delivery`. It shares nothing with Dispatch but Facts
  (Flow plan decision 11); it never grants, renews or expires a lease.

  **Fence (§3.2).** A report is answered `lease_lost` when the task fact's
  `lease_id` is not the request's, its `runtime` is not the caller's, or its `lease_state`
  is `expired` or `lost` (Dispatch's sweep writes those). Delivery never reads when a lease
  expires: every write it makes is a fenced change carrying `lease_state` (§2.3), so a
  sweep write in between refuses it, and Delivery reads again and answers `lease_lost`.

  **Facts unavailable.** When Facts does not answer the read, or the fenced write is still
  refused or unanswered after three tries (a deploy that restarts rela, a throttled core),
  the answer is `:unavailable`, never `lease_lost`: nothing says the lease is lost, and a
  Runtime that hears `lease_lost` cancels the work or drops its finished result. The
  router answers it 503, which a Runtime takes as unreachable and sends again; each report
  is idempotent (2026-11-24: a rela restart made three leases look lost).

  **Reports.** Revision 1 is the first report of a lease, then +1 each; the same revision
  with the same report (its digest is `lease_report`) is recorded again; any other is a
  `conflict`. The order is `accepted | refused` → `started` → `ended`, or `accepted` →
  `ended`. An `accepted` more than 30 s after the lease's `granted_at` is `lease_lost`
  (Dispatch's sweep then loses the lease). Each report updates the task fact (§3.3,
  §3.5) and, from `refused`/`started`/`ended` on, the lease's `task_attempt`
  (`AtlasFlow.Runtime.Records`).

  **Results (§3.4).** A result travels over Git only (IS-Atlas-100): a writable task's
  Runtime pushed its result commit to the lease's `result_ref` in Code before it reports
  `ended`, so the `ended` is recorded in one write, the task naming that ref
  (`result_ref`), and never asks for a blob (`missing` is always empty). A change set an
  older Runtime still reports is not read. A read-only task brings back its answer only.

  **Fenced attempts (F10).** Dispatch fences a lease (`expired`, `lost`) on the task fact
  and notifies Delivery with a cast (`lease_fenced/4`), never a call, so a busy Delivery
  never holds a grant up. Delivery then ends that lease's running `task_attempt` `lost`,
  with the fence's cause (`Records.lost/6`); a terminal record, another lease's, or none
  is left as it is. A notice lost to a crash is made up at `init`: before Delivery serves
  anything (and so before the Listener, started after it, lets a poll reach Dispatch), it
  ends the attempt of every task fact whose lease is `expired` or `lost`, with no
  `ended_at`. A Facts failure there is logged and Delivery starts all the same; the next
  notice on that lease, or the next start, ends it. Delivery stays the only attempt writer.

  **The run.** On an ended result, a refusal or a lease fenced at its expiry (a silent
  turn), `{:reconcile, kind, key}` is cast to the Engine for the run that holds the task;
  on each stored write of a Runtime's upgrade, for that upgrade's run (Delivery never
  writes a run).

  Options of `start_link/1`: `name`, `model`, `clock`, `accept_deadline` (30 s), `engine`
  (default `AtlasFlow.Engine`) and `bases` (its server).
  """
  use GenServer

  require Logger

  alias AtlasFlow.{Bases, Talk}
  alias AtlasFlow.Runs.{Clock, Store}
  alias AtlasFlow.Runtime.Records
  alias AtlasFlow.WorkSource.{Configuration, Leases, Translate, Upgrade}

  @endpoint "flow/delivery"

  ## Interface

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  The configuration step of a poll of `client` (`AtlasFlow.WorkSource.Configuration.poll/3`):
  records what the poll says on the Runtime's machinery fact, then `{:serve, document}` or
  `:none`. Never fails a poll: a Delivery that does not answer in time is `:none`.
  """
  def configuration(client, input, server \\ __MODULE__) do
    GenServer.call(server, {:configuration, client, input}, 10_000)
  catch
    :exit, _ -> :none
  end

  @doc """
  The upgrade step of a poll of `client` (`AtlasFlow.WorkSource.Upgrade.poll/3`, IS-Atlas-26):
  moves the Runtime's upgrade on, then `{:serve, order}` or `:none`. Never fails a poll: a
  Delivery that does not answer in time is `:none`.
  """
  def upgrade(client, input, server \\ __MODULE__) do
    GenServer.call(server, {:upgrade, client, input}, 10_000)
  catch
    :exit, _ -> :none
  end

  @doc """
  Dispatch fenced lease `lease_id` of `task_key` with `cause` (its `lease_end_cause`): its
  running attempt is ended `lost`. A cast: Dispatch never waits on Delivery.
  """
  def lease_fenced(task_key, lease_id, cause, server \\ __MODULE__),
    do: GenServer.cast(server, {:lease_fenced, task_key, lease_id, cause})

  @doc "A report (`report_input`) from `client` (`{runtime_id, holder}`)."
  def report(client, input, server \\ __MODULE__),
    do: GenServer.call(server, {:report, client, input}, :infinity)

  @doc """
  Where a blob a lease may read comes from: `{:base, snapshot_id}` (Code, through Bases), or
  `:not_found` (a fenced lease, another Runtime, a name the lease's base does not name).
  """
  def blob_scope(client, lease_id, sha256, server \\ __MODULE__),
    do: GenServer.call(server, {:scope, client, lease_id, sha256}, :infinity)

  ## Server

  @impl true
  def init(opts) do
    conf = Application.get_env(:atlas_flow, :work_source, [])
    model = Keyword.get_lazy(opts, :model, &AtlasFlow.Model.configured!/0)
    :ok = AtlasBus.attach(@endpoint)
    :ok = repair()

    {:ok,
     %{
       runner:
         AtlasFlow.Model.load(
           model,
           AtlasFlow.Model.environment(),
           Keyword.get(opts, :actors, AtlasBus.Actors.configured())
         ),
       clock: opts[:clock],
       deadline: Keyword.get(opts, :accept_deadline, Keyword.get(conf, :accept_deadline, 30)),
       engine: Keyword.get(opts, :engine, AtlasFlow.Engine),
       bases: Keyword.get(opts, :bases, Bases)
     }}
  end

  @impl true
  def handle_cast({:lease_fenced, task_key, lease_id, cause}, state) do
    with {:ok, _, n} <- Leases.parse(lease_id),
         do: end_attempt(task_key, n, lease_id, cause, now(state))

    # A lease run out unrenewed is a silent turn (`Translate.empty/1`): it decides the run's
    # next step as a result does (counted and offered again, or the task ends), so its run
    # is reconciled now, not on its next round. Any other fence brings the run nothing.
    if cause == "expired", do: reconcile(state, task_key)
    {:noreply, state}
  end

  @impl true
  def handle_call({:report, {runtime_id, _holder}, input}, _from, state) do
    reply =
      with {:ok, lease_id, revision, report} <- report_input(input),
           {:ok, task_key, attempt} <- lease(lease_id) do
        lease = %{id: lease_id, task_key: task_key, attempt: attempt, runtime: runtime_id}

        case Leases.update(task_key, &decide(&1, lease, revision, report, state)) do
          {:error, _} -> :unavailable
          answer -> answer
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:configuration, {runtime_id, _holder}, input}, _from, state) do
    {:reply, Configuration.poll(runtime_id, input), state}
  end

  def handle_call({:upgrade, {runtime_id, _holder}, input}, _from, state) do
    stored = &GenServer.cast(state.engine, {:reconcile, Upgrade.kind(), &1})
    {:reply, Upgrade.poll(runtime_id, input, "flow", stored), state}
  end

  def handle_call({:scope, {runtime_id, _}, lease_id, sha}, _from, state) do
    {:reply, scope(state, runtime_id, lease_id, sha), state}
  end

  ## Reports

  defp report_input(input) do
    input = Translate.normal(input)

    with %{"lease_id" => lease_id, "revision" => revision, "report" => report} <- input,
         true <- is_binary(lease_id) and is_integer(revision) and revision in 1..2_147_483_647,
         state when state != nil <- Translate.state(report) do
      {:ok, lease_id, revision, report}
    else
      _ -> {:rejected, :invalid}
    end
  end

  defp lease(lease_id) do
    case Leases.parse(lease_id) do
      {:ok, _, _} = ok -> ok
      :error -> :lease_lost
    end
  end

  defp decide(fact, lease, revision, report, state) do
    if Leases.fenced?(fact, lease.id, lease.runtime) do
      {:reply, :lease_lost}
    else
      held = Leases.value(fact, "lease_state")
      last = if held == "offered", do: 0, else: Leases.value(fact, "lease_revision") || 0
      digest = Translate.digest(report)
      next = Translate.state(report)

      cond do
        # The same report again: recorded again, nothing more.
        revision == last and last > 0 and digest == Leases.value(fact, "lease_report") ->
          {:reply, {:recorded, %{missing: []}}}

        revision == last + 1 and follows?(previous(fact, held, last), next) ->
          record(fact, lease, report, next, state)
          |> fenced(%{"lease_revision" => revision, "lease_report" => digest})

        true ->
          {:reply, {:rejected, :conflict}}
      end
    end
  end

  defp fenced({:write, values, links, reply}, more),
    do: {:write, Map.merge(values, more), links, reply}

  defp fenced(other, _more), do: other

  # The state the last recorded report left the lease in (a cancel request hides it).
  defp previous(_fact, "offered", _last), do: nil

  defp previous(fact, "done", _last),
    do: if(Leases.value(fact, "result_kind") == "refused", do: "refused", else: "ended")

  defp previous(_fact, "cancel_requested", 1), do: "accepted"
  defp previous(_fact, "cancel_requested", _last), do: "started"
  defp previous(_fact, held, _last), do: held

  defp follows?(nil, next), do: next in ["accepted", "refused"]
  defp follows?("accepted", next), do: next in ["started", "ended"]
  defp follows?("started", next), do: next == "ended"
  defp follows?(_, _), do: false

  # The lease keeps a cancel request (supervision, restart) until its work ends.
  defp live_state(fact, to) do
    if Leases.value(fact, "lease_state") == "cancel_requested", do: "cancel_requested", else: to
  end

  defp record(fact, _lease, _report, "accepted", state) do
    if late?(fact, state) do
      {:reply, :lease_lost}
    else
      {:write, %{"lease_state" => "accepted"}, %{}, fn -> {:recorded, %{missing: []}} end}
    end
  end

  defp record(_fact, lease, report, "refused", state) do
    values = %{"lease_state" => "done", "result_kind" => "refused", "reason" => report["reason"]}

    {:write, values, %{},
     fn ->
       attempt_record(lease, report, state)
       reconcile(state, lease.task_key)
       {:recorded, %{missing: []}}
     end}
  end

  defp record(fact, lease, report, "started", state) do
    {:write, %{"lease_state" => live_state(fact, "started")}, %{},
     fn ->
       attempt_record(lease, report, state)
       {:recorded, %{missing: []}}
     end}
  end

  defp record(fact, lease, report, "ended", state) do
    cancel_cause =
      if Leases.value(fact, "lease_state") == "cancel_requested",
        do: Leases.value(fact, "lease_end_cause")

    result = Translate.ended_values(report)

    # Result-less is decided from the ending (§3.5): a cancel request does not discard a
    # result that arrives after it. A result clears the request's `lease_end_cause`, so the
    # fact, `Translate.outcome/2` and Dispatch's grant agree that the ending stands.
    case Translate.result_less(report, cancel_cause) do
      nil ->
        ended_with_result(fact, lease, report, result, state)

      cause ->
        # No result (returned, any interruption, a check cut short, a supervision or
        # restart cancel): the same step is offered again as a fresh attempt (Q8, D-0102).
        values = Map.merge(result, %{"lease_state" => "done", "lease_end_cause" => cause})

        {:write, values, %{},
         fn ->
           attempt_record(lease, report, state)
           {:recorded, %{missing: []}}
         end}
    end
  end

  # A writable task's result went to Code over Git (`input.result_ref`): the task names its
  # ref. A read-only task's has none.
  defp ended_with_result(fact, lease, report, result, state) do
    values =
      Map.merge(result, %{
        "lease_state" => "done",
        "lease_end_cause" => nil,
        "result_ref" => Translate.input_result_ref(Leases.value(fact, "input"))
      })

    {:write, values, %{},
     fn ->
       attempt_record(lease, report, state)
       reconcile(state, lease.task_key)
       {:recorded, %{missing: []}}
     end}
  end

  defp late?(fact, state) do
    case DateTime.from_iso8601(Leases.value(fact, "granted_at") || "") do
      {:ok, granted, _} -> DateTime.diff(now(state), granted, :second) > state.deadline
      _ -> false
    end
  end

  ## Blobs

  defp current(task_key, lease_id, runtime_id) do
    case Leases.read(task_key) do
      {:ok, fact} ->
        if Leases.fenced?(fact, lease_id, runtime_id), do: :lease_lost, else: {:ok, fact}

      {:error, _} ->
        :unavailable
    end
  end

  defp scope(state, runtime_id, lease_id, sha) do
    with {:ok, task_key, _} <- lease(lease_id),
         {:ok, fact} <- current(task_key, lease_id, runtime_id) do
      input = Leases.value(fact, "input")

      if sha in base_names(state, Translate.input_manifest(input)),
        do: {:base, Leases.value(fact, "base_snapshot")},
        else: :not_found
    else
      _ -> :not_found
    end
  end

  defp base_names(_state, nil), do: []

  defp base_names(state, manifest) do
    case Bases.names(manifest, state.bases) do
      {:ok, names} -> MapSet.to_list(names)
      :not_found -> []
    end
  end

  ## Records and the run

  defp attempt_record(lease, report, state) do
    case Records.record(
           lease.task_key,
           lease.attempt,
           lease.id,
           report,
           ran_on(state, lease.runtime)
         ) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        Logger.warning("flow delivery could not record #{lease.id}: #{inspect(why)}")
    end
  end

  # Dispatch's fence ended the lease: its running attempt ends lost (F10). `at` is nil from
  # the repair at init, which cannot tell when the lease ended.
  defp end_attempt(task_key, n, lease_id, cause, at) do
    case Records.lost(task_key, n, lease_id, cause, at) do
      {:ok, _} ->
        :ok

      {:error, why} ->
        Logger.warning("flow delivery could not record #{lease_id}: #{inspect(why)}")
    end
  end

  # The fence notices a crash lost, made up before Delivery serves: every fenced lease's
  # attempt. Never fails the start: a Facts failure is logged.
  defp repair do
    case Leases.all() do
      {:ok, facts} ->
        for fact <- facts,
            Leases.value(fact, "lease_state") in ~w(expired lost),
            lease_id = Leases.value(fact, "lease_id"),
            cause = Leases.value(fact, "lease_end_cause"),
            is_binary(cause),
            {:ok, _, n} <- [Leases.parse(lease_id)],
            do: end_attempt(fact["key"], n, lease_id, cause, nil)

        :ok

      {:error, why} ->
        Logger.warning("flow delivery could not repair attempts: #{inspect(why)}")
        :ok
    end
  end

  # The machinery fact the Runtime's id names, when there is one (Q7).
  defp ran_on(%{runner: runner}, runtime_id) do
    kinds = get_in(runner.relations || %{}, ["ran_on", "to"]) || []

    Enum.find_value(kinds, fn kind ->
      case Talk.read(kind, %{"key" => runtime_id, "plain" => true}) do
        %{"fact" => %{}} -> runtime_id
        _ -> nil
      end
    end)
  end

  # The run that holds the task: its subject is reconciled by the Engine.
  defp reconcile(%{runner: %{config: config}} = state, task_key) when is_map(config) do
    case Talk.read(config["kind"], %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        subjects =
          for fact <- facts,
              {:ok, run} <- [Store.decode(config, fact)],
              (run["pending"]["task"] || %{})["key"] == task_key,
              uniq: true,
              do: {run["subject_kind"], run["subject_key"]}

        for {kind, key} <- subjects, do: GenServer.cast(state.engine, {:reconcile, kind, key})

        :ok

      other ->
        Logger.warning("flow delivery could not read the runs: #{inspect(other)}")
    end
  end

  defp reconcile(_state, _task_key), do: :ok

  defp now(state), do: Clock.now(state.clock)
end
