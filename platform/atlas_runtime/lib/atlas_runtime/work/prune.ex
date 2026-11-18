defmodule AtlasRuntime.Work.Prune do
  @moduledoc """
  Retention of finished work (design §4: 30 days). A work whose every attempt is settled
  (terminal and quiescent) and whose current attempt ended longer ago than the retention is
  pruned: its index entry becomes a tombstone (`pruned`, with the final result kind) and is
  written first, then its record is deleted (I7). Turns and history stay.

  A pruned work without a client key gets a tombstone too, keyed by its `work_id`
  (`AtlasRuntime.Work.Store`), so `get_work` answers `pruned` for every pruned work.

  Frozen results (s5a-plan B12) follow their works: after a pass that pruned any work, and
  once at boot, `AtlasRuntime.Work.FrozenStore.prune/3` turns every frozen result that
  neither its own work record nor another existing work's `source` or `based_on` retains
  into a tombstone, and deletes the blobs no retained result names. A frozen result can so
  outlive its work record; `get_frozen` then still answers `frozen`, and visibility comes
  from the key tombstone's client.
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
