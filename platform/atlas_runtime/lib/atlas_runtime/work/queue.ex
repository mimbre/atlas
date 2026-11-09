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
