defmodule AtlasFlow.Delivery do
  @moduledoc """
  The work source's reports and results (plan m3 §3.1, §3.3, §3.4, §3.5): a process of its
  own, attached to the Bus as `flow/delivery`. It shares nothing with Dispatch but Facts
  (Flow plan decision 11); it never grants, renews or expires a lease.

  **Fence (§3.2).** A report or `put_blob` is answered `lease_lost` when the task fact's
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

  **Results (§3.4).** An `ended` with a change set stores its manifest (`AtlasFlow.Results`),
  pins it for the task and answers the referenced blobs the store lacks (`missing`). The
  result is `complete` only when every referenced blob is held and every root's `csf_`
  fingerprint computes again (`atlas_changeset`, on the change set's own `base`); otherwise
  `invalid`. The manifest keeps that `base` as the report declared it (Main's ruling,
  option A): the Runtime's id of the baseline it imported, which is not the lease's
  `base_id` and cannot be derived from it. A change set without a `base` is
  `rejected(invalid)` (work_source 0.2.0), and nothing is stored. Past a cap it is
  `too_large`. Recording `complete` pins the manifest again (a no-op unless a restart
  dropped the pin; rev 4, R2). A completion write Facts misses (a deploy, a throttled
  core) leaves the result `incomplete` and the lease live: the next report (a replayed
  `ended`), `put_done` or Dispatch's sweep (`result_pending/3`, a cast) decides it again
  from the task fact and completes it, before the lease expires (IS-Atlas-112). The pin goes on `invalid`, `too_large`, an `ended` without a
  result, and the `accepted` of a later attempt.

  **Fenced attempts (F10).** Dispatch fences a lease (`expired`, `lost`) on the task fact
  and notifies Delivery with a cast (`lease_fenced/4`), never a call, so a busy Delivery
  never holds a grant up. Delivery then ends that lease's running `task_attempt` `lost`,
  with the fence's cause (`Records.lost/6`); a terminal record, another lease's, or none
  is left as it is. A notice lost to a crash is made up at `init`: before Delivery serves
  anything (and so before the Listener, started after it, lets a poll reach Dispatch), it
  ends the attempt of every task fact whose lease is `expired` or `lost`, with no
  `ended_at`. A Facts failure there is logged and Delivery starts all the same; the next
  notice on that lease, or the next start, ends it. Delivery stays the only attempt writer.

  **The run.** On complete, refused, invalid or too large, `{:reconcile, kind, key}` is cast
  to the Engine for the run that holds the task (Delivery never writes a run).

  Options of `start_link/1`: `name`, `model`, `clock`, `accept_deadline` (30 s), `engine`
  (default `AtlasFlow.Engine`), `results` and `bases` (their servers).
  """
  use GenServer

  require Logger

  alias AtlasFlow.{Bases, Results, Talk}
  alias AtlasFlow.Runs.{Clock, Store}
  alias AtlasFlow.Runtime.Records
  alias AtlasFlow.WorkSource.{Leases, Translate}

  @endpoint "flow/delivery"

  ## Interface

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
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
  Where a blob a lease may read comes from: `{:base, snapshot_id}` (Code, through Bases),
  `:result` (the result store), or `:not_found` (a fenced lease, another Runtime, a name
  the lease's input does not name).
  """
  def blob_scope(client, lease_id, sha256, server \\ __MODULE__),
    do: GenServer.call(server, {:scope, client, lease_id, sha256}, :infinity)

  @doc """
  The checks of a `put_blob` before a byte is read, in this order: fence (`:lease_lost`, or
  `:unavailable` when Facts does not answer), reference (`:not_referenced`), then
  `{:ok, room}` (the bytes the lease may still store).
  """
  def put_check(client, lease_id, sha256, server \\ __MODULE__),
    do: GenServer.call(server, {:put_check, client, lease_id, sha256}, :infinity)

  @doc "The fence again, once the bytes were read and before they are kept: `:ok`, `:lease_lost` or `:unavailable`."
  def refence(client, lease_id, server \\ __MODULE__),
    do: GenServer.call(server, {:refence, client, lease_id}, :infinity)

  @doc "A `put_blob` of the lease ended `outcome`: the result is completed or held too large."
  def put_done(client, lease_id, outcome, server \\ __MODULE__),
    do: GenServer.call(server, {:put_done, client, lease_id, outcome}, :infinity)

  @doc """
  Dispatch's sweep read lease `lease_id` of `task_key` live, `ended` with its result still
  `incomplete`: Delivery completes it when every referenced blob is held (a completion
  write Facts missed, IS-Atlas-112). A cast: the sweep never waits on Delivery.
  """
  def result_pending(task_key, lease_id, server \\ __MODULE__),
    do: GenServer.cast(server, {:result_pending, task_key, lease_id})

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
       results: Keyword.get(opts, :results, Results),
       bases: Keyword.get(opts, :bases, Bases)
     }}
  end

  @impl true
  def handle_cast({:lease_fenced, task_key, lease_id, cause}, state) do
    with {:ok, _, n} <- Leases.parse(lease_id),
         do: end_attempt(task_key, n, lease_id, cause, now(state))

    {:noreply, state}
  end

  def handle_cast({:result_pending, task_key, lease_id}, state) do
    decide = fn fact ->
      lease = %{id: lease_id, task_key: task_key, runtime: Leases.value(fact, "runtime")}
      completion(fact, lease, state)
    end

    with {:error, why} <- Leases.update(task_key, decide),
         do: Logger.warning("flow delivery could not complete #{lease_id}: #{inspect(why)}")

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

  def handle_call({:scope, {runtime_id, _}, lease_id, sha}, _from, state) do
    {:reply, scope(state, runtime_id, lease_id, sha), state}
  end

  def handle_call({:put_check, {runtime_id, _}, lease_id, sha}, _from, state) do
    reply =
      with {:ok, task_key, _} <- lease(lease_id),
           {:ok, fact} <- current(task_key, lease_id, runtime_id),
           {:ok, manifest} <- referenced(state, fact, sha) do
        {:ok, Results.room(lease_bytes(state, manifest, sha), state.results)}
      end

    {:reply, reply, state}
  end

  def handle_call({:refence, {runtime_id, _}, lease_id}, _from, state) do
    reply =
      with {:ok, task_key, _} <- lease(lease_id),
           {:ok, _fact} <- current(task_key, lease_id, runtime_id),
           do: :ok

    {:reply, reply, state}
  end

  def handle_call({:put_done, {runtime_id, _}, lease_id, outcome}, _from, state) do
    with {:ok, task_key, _} <- lease(lease_id) do
      lease = %{id: lease_id, task_key: task_key, runtime: runtime_id}

      written =
        case outcome do
          :stored -> Leases.update(task_key, &completion(&1, lease, state))
          :too_large -> Leases.update(task_key, &too_large(&1, lease, state))
          _ -> :ok
        end

      # Not stored: the result stays incomplete until the next report, put_done or sweep
      # completes it (IS-Atlas-112).
      with {:error, why} <- written,
           do: Logger.warning("flow delivery could not settle #{lease_id}: #{inspect(why)}")
    end

    {:reply, :ok, state}
  end

  ## Reports

  defp report_input(input) do
    input = Translate.normal(input)

    with %{"lease_id" => lease_id, "revision" => revision, "report" => report} <- input,
         true <- is_binary(lease_id) and is_integer(revision) and revision in 1..2_147_483_647,
         state when state != nil <- Translate.state(report),
         true <- Translate.base_declared?(report) do
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
        # The same report again: a result whose completion Facts missed completes now.
        revision == last and last > 0 and digest == Leases.value(fact, "lease_report") ->
          case completion(fact, lease, state, {:recorded, %{missing: []}}) do
            {:write, _, _, _} = write -> write
            {:reply, _} -> {:reply, {:recorded, %{missing: missing(state, fact)}}}
          end

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

  # The lease keeps a supervision cancel request until its work ends.
  defp live_state(fact, to) do
    if Leases.value(fact, "lease_state") == "cancel_requested", do: "cancel_requested", else: to
  end

  defp record(fact, lease, _report, "accepted", state) do
    if late?(fact, state) do
      {:reply, :lease_lost}
    else
      # A later attempt's accepted supersedes the earlier attempt's result.
      later? = lease.attempt > 1 and Leases.value(fact, "result_manifest") != nil

      values =
        if later?,
          do: %{"lease_state" => "accepted", "result_state" => nil, "result_manifest" => nil},
          else: %{"lease_state" => "accepted"}

      {:write, values, %{},
       fn ->
         if lease.attempt > 1, do: Results.unpin(lease.task_key, now(state), state.results)
         {:recorded, %{missing: []}}
       end}
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
        # No result: the work is offered again as a fresh attempt (Q8).
        values =
          Map.merge(result, %{
            "lease_state" => "done",
            "lease_end_cause" => cause,
            "result_state" => nil,
            "result_manifest" => nil
          })

        {:write, values, %{},
         fn ->
           attempt_record(lease, report, state)
           Results.unpin(lease.task_key, now(state), state.results)
           {:recorded, %{missing: []}}
         end}
    end
  end

  defp ended_with_result(fact, lease, report, result, state) do
    if Translate.change_set?(report) do
      manifest = Translate.manifest(report)

      case Results.put_manifest(manifest, state.results) do
        {:ok, sha} ->
          missing = absent(state, Translate.references(manifest))

          result_state =
            if missing == [],
              do: verdict(manifest, result["result_fingerprints"]),
              else: "incomplete"

          lease_state = if missing == [], do: "done", else: "ended"

          values =
            Map.merge(result, %{
              "lease_state" => lease_state,
              "lease_end_cause" => nil,
              "result_manifest" => sha,
              "result_state" => result_state
            })

          {:write, values, %{},
           fn ->
             attempt_record(lease, report, state)
             Results.pin(lease.task_key, sha, state.results)
             settled(state, lease.task_key, result_state)
             {:recorded, %{missing: missing}}
           end}

        :too_large ->
          values =
            Map.merge(result, %{
              "lease_state" => "done",
              "lease_end_cause" => nil,
              "result_manifest" => nil,
              "result_state" => "too_large"
            })

          {:write, values, %{},
           fn ->
             attempt_record(lease, report, state)
             settled(state, lease.task_key, "too_large")
             {:recorded, %{missing: []}}
           end}
      end
    else
      # A subject's result went to Code over Git (`input.result_ref`): the task names its ref.
      values =
        Map.merge(result, %{
          "lease_state" => "done",
          "lease_end_cause" => nil,
          "result_manifest" => nil,
          "result_state" => nil,
          "result_ref" => Translate.input_result_ref(Leases.value(fact, "input"))
        })

      {:write, values, %{},
       fn ->
         attempt_record(lease, report, state)
         reconcile(state, lease.task_key)
         {:recorded, %{missing: []}}
       end}
    end
  end

  # complete pins again (rev 4, R2); invalid and too_large free the room; each reaches the run.
  defp settled(_state, _task_key, "incomplete"), do: :ok

  defp settled(state, task_key, "complete") do
    with {:ok, fact} <- Leases.read(task_key),
         sha when is_binary(sha) <- Leases.value(fact, "result_manifest"),
         do: Results.pin(task_key, sha, state.results)

    reconcile(state, task_key)
  end

  defp settled(state, task_key, _invalid_or_too_large) do
    Results.unpin(task_key, now(state), state.results)
    reconcile(state, task_key)
  end

  defp late?(fact, state) do
    case DateTime.from_iso8601(Leases.value(fact, "granted_at") || "") do
      {:ok, granted, _} -> DateTime.diff(now(state), granted, :second) > state.deadline
      _ -> false
    end
  end

  # The referenced blobs the store does not hold yet, for an ended still incomplete.
  defp missing(state, fact) do
    with "incomplete" <- Leases.value(fact, "result_state"),
         {:ok, manifest} <-
           Results.manifest_by_sha(Leases.value(fact, "result_manifest"), state.results) do
      absent(state, Translate.references(manifest))
    else
      _ -> []
    end
  end

  defp absent(state, shas),
    do: Enum.filter(shas, &(Results.blob(&1, state.results) == :not_found))

  # `fingerprints`: the roots' reported csf_ (`result_fingerprints`, JSON); the stored
  # manifest is the plain change set (`Translate.manifest/1`).
  defp verdict(manifest, fingerprints),
    do: if(Translate.fingerprints_hold?(manifest, fingerprints), do: "complete", else: "invalid")

  ## Blobs

  defp current(task_key, lease_id, runtime_id) do
    case Leases.read(task_key) do
      {:ok, fact} ->
        if Leases.fenced?(fact, lease_id, runtime_id), do: :lease_lost, else: {:ok, fact}

      {:error, _} ->
        :unavailable
    end
  end

  # A blob is referenced by the lease's recorded ended manifest only.
  defp referenced(state, fact, sha) do
    with true <- Leases.value(fact, "lease_state") in ["ended", "done"],
         manifest_sha when is_binary(manifest_sha) <- Leases.value(fact, "result_manifest"),
         {:ok, manifest} <- Results.manifest_by_sha(manifest_sha, state.results),
         true <- sha in Translate.references(manifest) do
      {:ok, manifest}
    else
      _ -> :not_referenced
    end
  end

  # The bytes the lease's result already holds (its referenced blobs in the store), this
  # blob not counted: the result cap is per lease, not per blob.
  defp lease_bytes(state, manifest, sha) do
    for %{"entries" => entries} <- manifest["roots"],
        %{"op" => "write", "sha256" => other, "size" => size} <- entries,
        other != sha,
        uniq: true do
      {other, size}
    end
    |> Enum.filter(fn {other, _} -> Results.blob(other, state.results) != :not_found end)
    |> Enum.map(&elem(&1, 1))
    |> Enum.sum()
  end

  defp scope(state, runtime_id, lease_id, sha) do
    with {:ok, task_key, _} <- lease(lease_id),
         {:ok, fact} <- current(task_key, lease_id, runtime_id) do
      input = Leases.value(fact, "input")

      cond do
        sha in base_names(state, Translate.input_manifest(input)) ->
          {:base, Leases.value(fact, "base_snapshot")}

        sha in change_set_names(state, input) ->
          :result

        true ->
          :not_found
      end
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

  # A change set as input (F2): its manifest and the blobs its write entries name.
  defp change_set_names(state, input) do
    with {:ok, %{"change_set" => %{"manifest" => sha}}} <- JSON.decode(input || ""),
         {:ok, manifest} <- Results.manifest_by_sha(sha, state.results) do
      [sha | Translate.references(manifest)]
    else
      _ -> []
    end
  end

  ## Completion

  # An ended result still incomplete is completed (or found invalid) once every blob it
  # references is held: from a put_done, a replayed ended report, or the sweep's notice.
  defp completion(fact, lease, state, reply \\ :ok) do
    with false <- Leases.fenced?(fact, lease.id, lease.runtime),
         "incomplete" <- Leases.value(fact, "result_state"),
         {:ok, manifest} <-
           Results.manifest_by_sha(Leases.value(fact, "result_manifest"), state.results),
         [] <- absent(state, Translate.references(manifest)) do
      result_state = verdict(manifest, Leases.value(fact, "result_fingerprints"))

      {:write, %{"lease_state" => "done", "result_state" => result_state}, %{},
       fn ->
         settled(state, lease.task_key, result_state)
         reply
       end}
    else
      _ -> {:reply, reply}
    end
  end

  defp too_large(fact, lease, state) do
    if not Leases.fenced?(fact, lease.id, lease.runtime) and
         Leases.value(fact, "result_state") == "incomplete" do
      {:write, %{"lease_state" => "done", "result_state" => "too_large"}, %{},
       fn -> settled(state, lease.task_key, "too_large") end}
    else
      {:reply, :ok}
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
