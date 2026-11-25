defmodule AtlasFlow.Dispatch.Sweep do
  @moduledoc """
  Dispatch's sweep, off the poll's path (IS-Atlas-110). A process of its own, started and
  linked by `AtlasFlow.Dispatch`, attached to the Bus as `flow/dispatch/sweep`: it does
  the sweep's reads (each task fact, each subject's supervision, and the leases while
  Dispatch could not read them at boot), which take up to 6 s each when Facts is slow,
  so Dispatch answers polls meanwhile.

  It never writes. Facts takes `task` writes only from Flow's own senders
  (`flow/dispatch`, `flow/delivery`, `flow/landing`), so each fence is a call to Dispatch
  with the fact it read (`{:fence, …}`); Dispatch writes it as a fenced change of that
  fact, one at a time between polls. Dispatch refuses an expiry fence of a lease a poll
  renewed after this sweep began, so a lease still renewed is never fenced. A refused
  write (the fact changed since its read) is read and decided again, at most 3 times, as
  `AtlasFlow.WorkSource.Leases.update/3` does.

  A live lease `ended` with its result still `incomplete` is cast to Delivery
  (`AtlasFlow.Delivery.result_pending/3`), which completes it once its blobs are all held
  (IS-Atlas-112).

  What the sweep learns without a write (a lease gone, accepted in time, or cancel
  requested already) it casts to Dispatch, in order, and `{:swept, ref}` once done.
  """
  use GenServer

  require Logger

  alias AtlasFlow.Supervision
  alias AtlasFlow.WorkSource.Leases

  @endpoint "flow/dispatch/sweep"
  @live ~w(offered accepted started ended cancel_requested)
  @tries 3

  def start_link(dispatch), do: GenServer.start_link(__MODULE__, dispatch)

  @doc """
  Sweeps `job` (`ref`, `now`, `deadline`, `grace`, `runner`, `leases`, `booted`, `delivery`); Dispatch
  gets `{:swept, ref}` once done.
  """
  def run(sweep, job), do: GenServer.cast(sweep, {:sweep, job})

  @impl true
  def init(dispatch) do
    :ok = attach(20)
    {:ok, %{dispatch: dispatch}}
  end

  # A Dispatch restarted at once may start its sweep before the one it replaced is gone.
  defp attach(0), do: AtlasBus.attach(@endpoint)

  defp attach(tries) do
    case AtlasBus.attach(@endpoint) do
      {:error, :taken} ->
        Process.sleep(50)
        attach(tries - 1)

      other ->
        other
    end
  end

  @impl true
  def handle_cast({:sweep, job}, s) do
    job = Map.put(job, :dispatch, s.dispatch)
    leases = if job.booted, do: job.leases, else: boot(job)

    leases
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(%{}, fn {id, lease}, seen -> sweep_lease(job, seen, id, lease) end)

    send(s.dispatch, {:swept, job.ref})
    {:noreply, s}
  end

  # The leases, read again while Dispatch could not read them at boot (`Dispatch` takes
  # them in, and answers what it holds then).
  defp boot(job) do
    case Leases.all() do
      {:ok, facts} ->
        GenServer.call(job.dispatch, {:sweep_boot, facts}, :infinity)

      {:error, why} ->
        Logger.warning("flow dispatch could not read the leases: #{inspect(why)}")
        job.leases
    end
  end

  defp sweep_lease(job, seen, id, lease) do
    now = job.now

    cond do
      lease.state == :offered and DateTime.diff(now, lease.granted_at, :second) > job.deadline ->
        case Leases.read(lease.task_key) do
          {:ok, fact} ->
            cond do
              Leases.value(fact, "lease_id") == id and
                  Leases.value(fact, "lease_state") == "offered" ->
                # Accepted meanwhile (`:gone`) or Facts unavailable: the next sweep reads it again.
                end_lease(job, lease.task_key, id, ["offered"], "lost", "late_accept", :drop)
                seen

              # Accepted in time (Delivery's): look again as a live lease.
              Leases.value(fact, "lease_id") == id ->
                learnt(job, id, :live)
                sweep_lease(job, seen, id, %{lease | state: :live})

              true ->
                learnt(job, id, :drop)
                seen
            end

          {:error, _} ->
            seen
        end

      lease.state == :expired and DateTime.diff(now, lease.expires_at, :second) >= job.grace ->
        case end_lease(job, lease.task_key, id, ["expired"], "lost", "expired", :drop) do
          :gone -> learnt(job, id, :drop)
          _ -> :ok
        end

        seen

      lease.state != :expired and DateTime.compare(now, lease.expires_at) != :lt ->
        case end_lease(job, lease.task_key, id, @live, "expired", "expired", :expired) do
          :gone -> learnt(job, id, :drop)
          _ -> :ok
        end

        seen

      lease.state != :expired ->
        case Leases.read(lease.task_key) do
          {:ok, fact} -> current(job, seen, id, lease, fact)
          {:error, _} -> seen
        end

      true ->
        seen
    end
  end

  # A lease not due, on its task fact as read now.
  defp current(job, seen, id, lease, fact) do
    pending_result(job, id, fact)

    cond do
      # Ended (Delivery's), lost, or another lease took the task: Dispatch holds it no
      # more, so its task may be granted again.
      Leases.value(fact, "lease_id") != id or Leases.value(fact, "lease_state") not in @live ->
        learnt(job, id, :drop)
        seen

      # The Engine cancelled its task (`Dispatch.cancel/3`): its stored task fact says so.
      lease.cancel != true and Leases.value(fact, "state") == "cancelled" ->
        cancel_lease(job, id, lease, "answer")
        seen

      # Running when Flow booted (an update or an outage, D-0102): its work is stopped and
      # the task offered again on a fresh attempt. An `ended` one stands.
      lease.restart and lease.cancel != true and
          Leases.value(fact, "lease_state") in ~w(offered accepted started) ->
        cancel_lease(job, id, lease, "restart")
        seen

      lease.subject != nil ->
        {answer, seen} = supervision(job, seen, lease.subject)
        supervise(job, id, lease, answer)
        seen

      true ->
        seen
    end
  end

  # One read of a subject's supervision per sweep.
  defp supervision(job, seen, {kind, key} = subject) do
    case seen do
      %{^subject => answer} -> {answer, seen}
      _ -> Supervision.of(job.runner, kind, key) |> then(&{&1, Map.put(seen, subject, &1)})
    end
  end

  defp supervise(_job, _id, %{holder: holder}, {:supervised, holder, _}), do: :ok
  defp supervise(_job, _id, _lease, :unavailable), do: :ok
  defp supervise(job, id, lease, _changed), do: cancel_lease(job, id, lease, "supervision")

  # The graceful cancel (§3.7): an offered lease is lost; an accepted or started one is
  # cancel_requested, named in its holder's next poll; an ended one stands.
  defp cancel_lease(job, id, lease, cause) do
    with :gone <- end_lease(job, lease.task_key, id, ["offered"], "lost", cause, :drop),
         :gone <-
           end_lease(
             job,
             lease.task_key,
             id,
             ["accepted", "started"],
             "cancel_requested",
             cause,
             :cancel
           ) do
      cancelled_already(job, id, lease)
    end
  end

  defp cancelled_already(job, id, lease) do
    case Leases.read(lease.task_key) do
      {:ok, fact} ->
        cond do
          Leases.value(fact, "lease_id") != id -> learnt(job, id, :drop)
          Leases.value(fact, "lease_state") == "cancel_requested" -> learnt(job, id, :cancel)
          true -> :ok
        end

      _ ->
        :ok
    end
  end

  # Lease `id` in one of `from` on its task fact is fenced to `to` (with `cause`) by
  # Dispatch: `:ended` once stored (Dispatch applied `apply`), `:gone` when the lease is
  # not in one of them, `:renewed` when Dispatch declined an expiry, `:unavailable`.
  defp end_lease(job, task_key, id, from, to, cause, apply, tries \\ @tries)

  defp end_lease(_job, _task_key, _id, _from, _to, _cause, _apply, 0), do: :unavailable

  defp end_lease(job, task_key, id, from, to, cause, apply, tries) do
    with {:ok, fact} <- Leases.read(task_key) do
      if Leases.value(fact, "lease_id") == id and Leases.value(fact, "lease_state") in from do
        case GenServer.call(job.dispatch, {:fence, id, fact, to, cause, apply}, :infinity) do
          :refused -> end_lease(job, task_key, id, from, to, cause, apply, tries - 1)
          answer -> answer
        end
      else
        :gone
      end
    else
      _ -> :unavailable
    end
  end

  # Ended with its result still incomplete: Delivery completes it when its blobs are all
  # held, as a completion write Facts missed leaves it (IS-Atlas-112). A cast, as fences are.
  defp pending_result(job, id, fact) do
    if Leases.value(fact, "lease_id") == id and Leases.value(fact, "lease_state") == "ended" and
         Leases.value(fact, "result_state") == "incomplete",
       do: AtlasFlow.Delivery.result_pending(fact["key"], id, job.delivery)
  end

  defp learnt(job, id, what), do: GenServer.cast(job.dispatch, {:swept, id, what})
end
