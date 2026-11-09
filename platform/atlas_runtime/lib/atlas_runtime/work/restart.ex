defmodule AtlasRuntime.Work.Restart do
  @moduledoc """
  Attempts after a restart (design §6 step 2), and the heartbeat probe that settles a turn
  whose end was never confirmed (I1, G9).

  The Service's own `RestartReconciliation` has already run when the work core boots: a
  turn whose process is provably gone is `failed` with `recorded_state`, and one whose
  process may still exist is left as recorded (`unknown`). Then, per current attempt:

  | Attempt | Its turn | Becomes |
  |---|---|---|
  | `buffered` | — | stays, and starts normally |
  | live, turn still owned by the Service (only the core restarted) | running | stays |
  | live | ended (before or during the restart) | its end, as `AtlasRuntime.Work.Turns.outcome/2` maps it |
  | `starting`/`running` | `unknown`, or none | `interrupted` with its `resume_point` |
  | `cancelling` | `unknown`, or none | `cancelled`, or `failed: time_limit` for a time-limit cancel |

  `quiescent` is false when the turn is `unknown` (its process may still exist) and true
  otherwise. **The probe** re-checks such a turn on every heartbeat with the Service's own
  process check (`RestartReconciliation.process_state/2`, the `classify` of its
  `process.json` leader); it only reads. When the process is provably gone the attempt
  becomes quiescent. A human `release` of the slot does the same.
  """

  alias AtlasRuntime.Work.{Queue, Turns}

  @doc "What becomes of an attempt at boot: `:keep` or `{:end, outcome}` (see `Turns.outcome/2`)."
  def classify(attempt, turn, owned?) do
    cond do
      not Queue.live?(attempt) ->
        :keep

      owned? ->
        :keep

      turn && not Turns.live?(turn) ->
        {:end, Turns.outcome(turn, attempt)}

      true ->
        {kind, reason} =
          case attempt do
            %{state: :cancelling, cancel_reason: :time_limit} ->
              {:failed, "time_limit"}

            %{state: :cancelling, cancel_reason: why} ->
              {:cancelled, Atom.to_string(why || :cancel)}

            _ ->
              {:interrupted, nil}
          end

        {:end,
         %{kind: kind, reason: reason, native_outcome: nil, quiescent: is_nil(turn), answer: nil}}
    end
  end

  @doc """
  Whether a turn's process is provably gone: `probe.(pid, launched)` on its `process.json`,
  as `RestartReconciliation.process_state/2` answers. Without that evidence nothing is
  proven, and only `release` frees the slot.
  """
  def gone?(dir, turn_id, probe) do
    path = Path.join([dir, "turns", turn_id, "process.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"pid" => pid}} when is_integer(pid) and pid > 1 <- JSON.decode(bytes),
         {:ok, %File.Stat{mtime: launched}} <- File.stat(path, time: :posix),
         {:gone, _why} <- probe.(pid, launched) do
      true
    else
      _ -> false
    end
  end
end
