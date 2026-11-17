defmodule AtlasRuntime.Sources.Local.Work do
  @moduledoc """
  The work contract's implementation behind `AtlasRuntime.Boundary.Work` (M2 plan A6, the
  CLI cut-over): every work command of the CLI (`backend.sock`) goes to the built-in local
  work source (`AtlasRuntime.Sources.Local`), and the executor (`AtlasRuntime.Work`) is
  reached only as the local source reaches it, under the local source's client
  (`AtlasRuntime.Sources.Rights.client("local")`).

  - `submit` adds the work to the local source's queue (`Local.add/3`: checked against the
    policy at once, the client key the source's, I3/I7). The source's puller leases it to
    the executor, which keeps the local work id as its record's (Main's A6 Q1), so one id
    names the work from start to end.
  - `get_work`, `find_work` and `list_work` show a local work as the executor records it
    once leased, with the adder as its client and the adder's client key; before that (and
    after the executor pruned it) as the source holds it: `buffered` while queued, its
    result kind once ended there.
  - `cancel` ends a queued work at the source at once (`ended`, `cancelled`); a leased one
    is cancelled at the source (through the next poll) and gets the executor's cancel
    stages at once.
  - `retry` (Main's round 2) queues an ended local work again at the source, for its next
    attempt under the same work id, after the policy checked its request again (as `add`
    does). Its next lease adds that attempt to the executor's record, and it counts against
    the `local` entry's `max_slots`. A queued work has nothing to retry (`invalid`), a
    leased one has not ended (`conflict`). Until it is leased again, the work shows that
    attempt `buffered`.
  - `turn_output`, `capacity`, `subscribe`, `get_frozen` and `get_frozen_blob` read from or
    act on the executor: a local work's under the local source's client, after the caller's
    visibility of that work was checked here.

  Visibility and ownership are the work contract's: a client sees its own local work, or
  every one with `read_all`; only the adder cancels or retries it here. Every other client
  gets the executor's own answer for the record, which is the local source's client's: so
  the local source's puller and `Upload` (that client) read and cancel it, and nobody else
  does.

  **Until A7 (Main's Deviation 2).** While no local source runs (a test that starts only the
  executor), `submit` is the executor's direct submit, and every other capability the
  executor's own answer. The service always starts the local source (a policy without
  `sources` has `local`, Main's A6 Q2). Removing the direct path is A7's.
  """
  use AtlasRuntime.Boundary.Work.Implementation

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.LocalSource.{QueueKeyEntry, QueuedWork}
  alias AtlasRuntime.Sources.{Local, Rights}
  alias AtlasRuntime.Work, as: Executor

  @impl true
  def submit(client, input) do
    if Local.running?() do
      case Local.add(client, input) do
        {:added, id} -> %B.Outcome.Accepted{work: view!(id)}
        {:existing, id} -> %B.Outcome.Existing{work: view!(id)}
        {:conflict, id} -> refused(:conflict, "client key #{input.client_key} names work #{id}")
        {:refused, :not_accepting, _detail} -> Executor.at_capacity(:not_accepting)
        {:refused, reason, detail} -> refused(reason, detail)
        :not_running -> Executor.at_capacity(:not_accepting)
      end
    else
      Executor.submit(client, input)
    end
  end

  @impl true
  def get_work(client, %{work_id: id} = input) do
    case local(client, id) do
      {:ok, work} -> %B.Outcome.Found{work: view(work)}
      {:pruned, entry} -> pruned(entry)
      :none -> Executor.get_work(client, input)
    end
  end

  @impl true
  def find_work({client_id, _rights} = client, %{client_key: key} = input) do
    case Local.find(client_id, key) do
      {:ok, work} -> %B.Outcome.Found{work: view(work)}
      {:pruned, entry} -> pruned(entry)
      _ -> Executor.find_work(client, input)
    end
  end

  @impl true
  def list_work(client, input) do
    %B.Outcome.Works{works: works, sequence: sequence} = Executor.list_work(client, input)

    locals =
      case Local.running?() && Local.queue() do
        [_ | _] = queue ->
          for w <- queue, visible?(client, w.client), into: %{}, do: {w.work_id, w}

        _ ->
          %{}
      end

    listed = MapSet.new(works, & &1.work_id)

    works =
      Enum.map(
        works,
        &if(l = locals[&1.work_id], do: &1 |> as_local(l) |> next_attempt(l), else: &1)
      )

    rest =
      for {id, l} <- Enum.sort_by(locals, fn {_id, l} -> {l.priority, l.position} end),
          not MapSet.member?(listed, id),
          work = view(l),
          listed?(work, input),
          do: work

    %B.Outcome.Works{works: works ++ rest, sequence: sequence}
  end

  @impl true
  def cancel(client, %{work_id: id} = input) do
    case owned(client, id) do
      {:ok, %QueuedWork{state: :queued} = work} ->
        case Local.cancel(id) do
          {:ended, ended} -> %B.Outcome.Ended{work: queued(ended)}
          _ -> cancel_leased(work, input)
        end

      {:ok, work} ->
        _ = Local.cancel(id)
        cancel_leased(work, input)

      {:pruned, _entry} ->
        Executor.cancel(Rights.client("local"), input)

      :none ->
        Executor.cancel(client, input)
    end
  end

  @impl true
  def retry(client, %{work_id: id} = input) do
    case owned(client, id) do
      {:ok, work} ->
        with :ok <- Executor.check_request(client, Local.to_request(work)),
             {kind, queued} when kind in [:queued, :pending] <-
               Local.retry(id, input.resume == true, ended_here?(id)) do
          %B.Outcome.Accepted{work: view(queued)}
        else
          {:refused, :not_accepting, _detail} -> Executor.at_capacity(:not_accepting)
          {:refused, reason, detail} -> refused(reason, detail)
          _not_found -> %B.Outcome.NotFound{}
        end

      {:pruned, entry} ->
        refused(:invalid, "work #{entry.work_id} was pruned; its request is gone")

      :none ->
        Executor.retry(client, input)
    end
  end

  @impl true
  def capacity(client), do: Executor.capacity(client)

  @impl true
  def turn_output(client, input), do: Executor.turn_output(client, input)

  @impl true
  def subscribe(client, input), do: Executor.subscribe(client, input)

  @impl true
  def get_frozen(client, %{work_id: id} = input) do
    case local(client, id) do
      :none -> Executor.get_frozen(client, input)
      _local -> Executor.get_frozen(Rights.client("local"), input)
    end
  end

  @impl true
  def get_frozen_blob(client, %{work_id: id} = input) do
    case local(client, id) do
      :none -> Executor.get_frozen_blob(client, input)
      _local -> Executor.get_frozen_blob(Rights.client("local"), input)
    end
  end

  ## Local works

  # What the local source holds of `work_id`, for its adder or a client with read_all:
  # `{:ok, queued_work}` or `{:pruned, tombstone}`. `:none` otherwise (not a local work, no
  # local source runs, or another client): the executor's own answer then decides, under its
  # own visibility, so the local source's client (its puller, `Upload`) reads and cancels
  # the record it holds, and any other client sees nothing of another's work.
  defp local(client, work_id) do
    case Local.get(work_id) do
      {:ok, %QueuedWork{} = work} ->
        if visible?(client, work.client), do: {:ok, work}, else: :none

      {:pruned, entry} ->
        if visible?(client, entry.client), do: {:pruned, entry}, else: :none

      _ ->
        :none
    end
  end

  # As `local/2`, for a change: the adder's own local work; `:none` leaves every other case
  # to the executor's rules (only the record's owner, the local source's client, may).
  defp owned({client_id, _rights}, work_id) do
    case Local.get(work_id) do
      {:ok, %QueuedWork{client: ^client_id}} = ok -> ok
      {:pruned, %QueueKeyEntry{client: ^client_id}} = pruned -> pruned
      _ -> :none
    end
  end

  defp visible?({client_id, rights}, owner), do: client_id == owner or :read_all in rights

  # Whether the executor's current attempt of a local work has ended (its `ended` may still
  # be on its way to the source).
  defp ended_here?(work_id) do
    case Executor.get_work(Rights.client("local"), %B.GetWorkInput{work_id: work_id}) do
      %B.Outcome.Found{work: %B.Work{attempts: [_ | _] = attempts}} ->
        List.last(attempts).state in AtlasRuntime.Work.Queue.terminal()

      _ ->
        false
    end
  end

  defp cancel_leased(work, input) do
    case Executor.cancel(Rights.client("local"), input) do
      # Leased, not yet accepted by the executor: its lease is cancelled at the source.
      %B.Outcome.NotFound{} -> %B.Outcome.Cancelling{stage: :requested, work: queued(work)}
      outcome -> overlay(outcome, work)
    end
  end

  # The work of the local work `id` right after it was added.
  defp view!(id) do
    {:ok, work} = Local.get(id)
    view(work)
  end

  # A local work: the executor's record once leased, shown as the adder's; otherwise as the
  # source holds it.
  defp view(%QueuedWork{} = local) do
    case Executor.get_work(Rights.client("local"), %B.GetWorkInput{work_id: local.work_id}) do
      %B.Outcome.Found{work: work} -> work |> as_local(local) |> next_attempt(local)
      _ -> queued(local)
    end
  end

  # A retried work queued again at the source (Main's round 2): its next attempt waits there,
  # `buffered`, until its lease adds it to the executor's record.
  defp next_attempt(%B.Work{attempts: attempts} = work, %QueuedWork{} = local)
       when local.state == :queued or local.retry != nil do
    n = if local.state == :queued, do: local.attempt || 1, else: (local.attempt || 1) + 1

    if n > length(attempts) do
      attempt = %B.Attempt{
        attempt: n,
        state: :buffered,
        timestamps: %B.AttemptTimestamps{received_at: local.added_at},
        quiescent: false
      }

      %{work | state: :buffered, attempts: attempts ++ [attempt]}
    else
      work
    end
  end

  defp next_attempt(work, _local), do: work

  defp pruned(%QueueKeyEntry{} = entry) do
    case Executor.get_work(Rights.client("local"), %B.GetWorkInput{work_id: entry.work_id}) do
      %B.Outcome.Found{work: work} -> %B.Outcome.Found{work: as_local(work, entry)}
      _ -> %B.Outcome.Pruned{work_id: entry.work_id, kind: entry.final_kind}
    end
  end

  # The executor's record of a local work, with the adder as client and its client key.
  defp as_local(%B.Work{} = work, %{client: client, client_key: key}),
    do: %{work | client: client, client_key: key, request: %{work.request | client_key: key}}

  defp overlay(%{work: %B.Work{} = work} = outcome, %QueuedWork{} = local),
    do: %{outcome | work: as_local(work, local)}

  defp overlay(outcome, _local), do: outcome

  # A local work the executor has no record of: queued (or leased, not yet accepted) is
  # `buffered`; ended at the source, its result kind.
  defp queued(%QueuedWork{} = local) do
    {state, ended_at} =
      case local do
        %{state: :ended, result: %{kind: kind, ended_at: at}} -> {kind, at}
        _ -> {:buffered, nil}
      end

    attempt = %B.Attempt{
      attempt: 1,
      state: state,
      timestamps: %B.AttemptTimestamps{received_at: local.added_at, ended_at: ended_at},
      quiescent: state != :buffered
    }

    %B.Work{
      work_id: local.work_id,
      client: local.client,
      client_key: local.client_key,
      idempotency_key: local.work_id,
      revision: 0,
      sequence: 0,
      request: %{Local.to_request(local) | client_key: local.client_key},
      state: state,
      attempts: [attempt]
    }
  end

  defp listed?(work, input) do
    (is_nil(input.state) or work.state == input.state) and
      (is_nil(input.changed_since) or work.sequence > input.changed_since)
  end

  defp refused(reason, detail), do: %B.Outcome.Refused{reason: reason, detail: detail}
end
