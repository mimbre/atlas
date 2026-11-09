defmodule AtlasRuntime.Work.Prune do
  @moduledoc """
  Retention of finished work (design §4: 30 days). A work whose every attempt is settled
  (terminal and quiescent) and whose current attempt ended longer ago than the retention is
  pruned: its index entry becomes a tombstone (`pruned`, with the final result kind) and is
  written first, then its record is deleted (I7). Turns and history stay.

  A pruned work without a client key gets a tombstone too, keyed by its `work_id`
  (`AtlasRuntime.Work.Store`), so `get_work` answers `pruned` for every pruned work.
  """

  alias AtlasRuntime.Work.Queue

  @default_retention 30 * 24 * 3600

  def default_retention, do: @default_retention

  @doc "The work IDs due for pruning at `now` with `retention` seconds."
  def due(works, now, retention) do
    for {id, record} <- works,
        Enum.all?(record.attempts, &Queue.settled?/1),
        ended = Queue.current(record).timestamps.ended_at,
        ended && DateTime.diff(now, ended, :millisecond) >= retention * 1000,
        do: id
  end
end
