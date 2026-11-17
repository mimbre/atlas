defmodule AtlasRuntime.Work.Queue do
  @moduledoc """
  The work queue's rules, as functions of the work records (design §2, §3.2, §3.7, §5):
  slots, the buffer, capacity, the start gate (I1) and the retry and cancel tables. The
  work core (`AtlasRuntime.Work.Server`) applies them, persists, and only then answers.

  **Slots and buffer.** The slots are the policy's (`AtlasRuntime.Policy.slots/1`, F1). A
  slot is busy while it holds an attempt that is not both terminal and quiescent (F2): a
  turn whose end is not confirmed keeps its slot until the probe or `release`. Accepted
  attempts wait `buffered`; each takes a free slot when the start gate opens. There is room
  for one more attempt while `free slots + buffer size - buffered attempts > 0`; the buffer
  reports as used the buffered attempts that no free slot could take.

  **Start gate (I1).** A buffered attempt starts only when every earlier attempt of its
  work is terminal and quiescent, a slot is free (its own slot when the request names one
  or it resumes a turn, which runs on that turn's slot), and its profile is available.

  **Leases (M2 plan C3).** A leased attempt is `held` (the private `lease_hold`) until its
  source recorded the accept: it waits `buffered` but is never startable, and it takes no
  slot of its own. `offer/4` counts it, with the other waiting attempts and the outstanding
  reservations, against the free slots, so no source is offered a slot that is already
  promised. `promised/2` is what the sources were promised and do not run yet (the
  outstanding reservations and the held attempts): an attempt that came in without a lease
  starts only into a slot beyond it (`unpromised/4`), and a leased attempt is tried first
  (`startable/1`), so a lease is never buffered behind a direct submit.
  """

  @terminal [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]
  @live [:starting, :running, :cancelling]

  def terminal, do: @terminal
  def terminal?(%{state: state}), do: state in @terminal
  def live?(%{state: state}), do: state in @live

  @doc "Ended and nothing of it left: it no longer holds a slot or blocks the next attempt."
  def settled?(attempt), do: terminal?(attempt) and attempt.quiescent

  @doc "The current (last) attempt of a work."
  def current(record), do: List.last(record.attempts)

  @doc "Whether an attempt holds its slot."
  def holds_slot?(attempt), do: attempt.state != :buffered and not settled?(attempt)

  @doc "The slots held by any attempt."
  def busy(works) do
    for {_id, record} <- works,
        attempt <- record.attempts,
        attempt.slot && holds_slot?(attempt),
        into: MapSet.new(),
        do: attempt.slot
  end

  @doc "Buffered attempts as `{work_id, attempt}`, oldest acceptance first."
  def buffered(works) do
    waiting =
      for {id, record} <- works,
          attempt = current(record),
          attempt.state == :buffered,
          do: {id, attempt}

    Enum.sort_by(waiting, fn {id, attempt} ->
      at = attempt.timestamps.accepted_at || attempt.timestamps.received_at
      {DateTime.to_unix(at, :microsecond), id}
    end)
  end

  @doc "Whether an attempt waits for its source's recorded accept (C3)."
  def held?(attempt), do: attempt.lease_hold == true

  @doc "Whether a work is a work source's (it came in by a lease)."
  def leased?(record), do: AtlasRuntime.Sources.Rights.source?(record.client)

  @doc """
  The buffered attempts that may start: none that is held; the leased ones first, each
  group in `buffered/1`'s order.
  """
  def startable(works) do
    works
    |> buffered()
    |> Enum.reject(fn {_id, a} -> held?(a) end)
    |> Enum.sort_by(fn {id, _a} -> if leased?(works[id]), do: 0, else: 1 end)
  end

  @doc """
  The slots promised to the work sources and not taken yet: the outstanding reservations
  (`%{name => slots}`) plus the held attempts.
  """
  def promised(works, reservations) do
    held = works |> buffered() |> Enum.count(fn {_id, a} -> held?(a) end)
    Enum.sum(Map.values(reservations)) + held
  end

  @doc """
  The free slots (neither busy nor `blocked`) beyond what `promised/2` keeps for the
  sources; negative when more is promised than is free.
  """
  def unpromised(works, slots, blocked, reservations) do
    busy = busy(works)
    free = Enum.count(slots, &(not (MapSet.member?(busy, &1) or MapSet.member?(blocked, &1))))
    free - promised(works, reservations)
  end

  @doc """
  The offer to the work sources (decision §5.5, strict priority with caps): `%{name =>
  slots}`. `sources` are the sources polling right now (Main's O2: the caller passes no
  other), as `%{name, priority, max_slots}` (priority 1 first). `reservations` are the slots
  offered to other open polls and not yet given back, `%{name => slots}`.

  The slots to offer are the free ones minus every waiting attempt (a held lease
  included) and every outstanding reservation; they never go negative. In priority order
  each source gets up to its `max_slots` minus what it holds (its unsettled attempts) and
  its own reservation, and the next source gets what is left.
  """
  def offer(works, slots, sources, reservations) do
    busy = works |> busy() |> Enum.count(&(&1 in slots))
    waiting = length(buffered(works))
    reserved = reservations |> Map.values() |> Enum.sum()
    free = max(length(slots) - busy - waiting - reserved, 0)

    {offer, _left} =
      sources
      |> Enum.sort_by(& &1.priority)
      |> Enum.map_reduce(free, fn %{name: name, max_slots: max}, left ->
        cap = max - holds(works, name) - Map.get(reservations, name, 0)
        n = cap |> max(0) |> min(left)
        {{name, n}, left - n}
      end)

    Map.new(offer)
  end

  # A source's unsettled attempts: what it holds of its max_slots.
  defp holds(works, name) do
    client = AtlasRuntime.Sources.Rights.client_id(name)

    for {_id, %{client: ^client} = record} <- works,
        attempt <- record.attempts,
        not settled?(attempt),
        reduce: 0,
        do: (n -> n + 1)
  end

  @doc """
  Slot and buffer counts: `%{slots: {total, busy, free}, buffer: {size, used, free},
  available}`, where `available` is the number of attempts that can still be accepted.
  """
  def counts(works, slots, buffer_size) do
    busy = works |> busy() |> Enum.count(&(&1 in slots))
    free = max(length(slots) - busy, 0)
    waiting = length(buffered(works))
    used = min(max(waiting - free, 0), buffer_size)

    %{
      slots: %{total: length(slots), busy: busy, free: free},
      buffer: %{size: buffer_size, used: used, free: buffer_size - used},
      available: free + buffer_size - waiting
    }
  end

  @doc "The slot the attempt may start on now, or nil (`fixed` is its own slot, if any)."
  def slot(slots, busy, blocked, fixed) do
    if fixed,
      do: if(MapSet.member?(busy, fixed) or MapSet.member?(blocked, fixed), do: nil, else: fixed),
      else: Enum.find(slots, &(not (MapSet.member?(busy, &1) or MapSet.member?(blocked, &1))))
  end

  @doc "Whether every attempt before the current one is settled (I1)."
  def previous_settled?(record),
    do: record.attempts |> Enum.drop(-1) |> Enum.all?(&settled?/1)

  @doc """
  What `retry` does with the current attempt (§3.2): `:replace` (buffered: it is cancelled
  never started and the new attempt takes its buffer place, no capacity check),
  `:supersede` (live: a capacity check, then it is cancelled `superseded` unless already
  cancelling), or `:after` (terminal: a capacity check).
  """
  def retry_rule(attempt) do
    cond do
      attempt.state == :buffered -> :replace
      attempt.state == :cancelling -> :after_cancel
      live?(attempt) -> :supersede
      true -> :after
    end
  end

  @doc """
  What `cancel` does with the current attempt (§3.7): `:never_started` (buffered),
  `:request` (starting or running), `{:escalate, stage}` (cancelling: a `force` raises
  the stage to `forced`) or `:ended` (terminal).
  """
  def cancel_rule(attempt) do
    cond do
      attempt.state == :buffered -> :never_started
      attempt.state == :cancelling -> {:escalate, attempt.cancel_stage}
      live?(attempt) -> :request
      true -> :ended
    end
  end
end
