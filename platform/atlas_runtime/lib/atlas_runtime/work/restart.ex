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
  | `starting` or `cancelling` while `preparing` its folder (B25) | none | as the two rows above; never prepared or started again |

  `quiescent` of a `preparing` attempt is false while its preparer's helper may still write
  the folder (`prepare_pid` recorded) and true without one; the probe settles it once that
  process is provably gone (`prepare_gone?/2`), as for an `unknown` turn.

  `quiescent` is false when the turn is `unknown` (its process may still exist) and true
  otherwise. **The probe** re-checks such a turn on every heartbeat with the Service's own
  process check (`RestartReconciliation.classify/5` of its `process.json` leader); it only
  reads. When the process is provably gone the attempt becomes quiescent. A human `release`
  of the slot does the same. The same check, from one `ps` listing per heartbeat
  (`processes/0`), is the heartbeat's `alive` (§3.6).
  """

  alias AtlasRuntime.Execution.RestartReconciliation
  alias AtlasRuntime.Work.{Queue, Turns}

  @doc "What becomes of an attempt at boot: `:keep` or `{:end, outcome}` (see `Turns.outcome/2`)."
  def classify(attempt, turn, owned?) do
    cond do
      not Queue.live?(attempt) ->
        :keep

      Map.get(attempt, :preparing) == true ->
        {kind, reason} = interrupted(attempt)

        {:end,
         %{
           kind: kind,
           reason: reason,
           native_outcome: nil,
           quiescent: is_nil(attempt.prepare_pid),
           answer: nil
         }}

      owned? ->
        :keep

      turn && not Turns.live?(turn) ->
        {:end, Turns.outcome(turn, attempt)}

      true ->
        {kind, reason} = interrupted(attempt)

        {:end,
         %{kind: kind, reason: reason, native_outcome: nil, quiescent: is_nil(turn), answer: nil}}
    end
  end

  defp interrupted(%{state: :cancelling, cancel_reason: :time_limit}), do: {:failed, "time_limit"}

  defp interrupted(%{state: :cancelling, cancel_reason: why}),
    do: {:cancelled, Atom.to_string(why || :cancel)}

  defp interrupted(_attempt), do: {:interrupted, nil}

  @doc """
  Whether the helper a preparer ran (`attempt.prepare_pid`, B25) is provably gone, by the
  probe's process check against the attempt's `started_at` (the preparer starts the helper
  right after that commit).
  """
  def prepare_gone?(%{prepare_pid: pid, timestamps: %{started_at: %DateTime{} = at}}, probe)
      when is_integer(pid) and pid > 1,
      do: match?({:gone, _why}, probe.(pid, DateTime.to_unix(at)))

  def prepare_gone?(_attempt, _probe), do: false

  @doc """
  Whether a turn's process is provably gone: `probe.(pid, launched)` on its `process.json`,
  as `RestartReconciliation.process_state/2` answers. Without that evidence nothing is
  proven, and only `release` frees the slot.
  """
  def gone?(dir, turn_id, probe), do: match?({:gone, _why}, process(dir, turn_id, probe))

  @doc """
  Whether a turn's process group provably exists: `:alive` only on that evidence. A turn
  not yet launched, or a listing that proves nothing, is not alive.
  """
  def alive?(dir, turn_id, probe), do: process(dir, turn_id, probe) == :alive

  defp process(dir, turn_id, probe) do
    path = Path.join([dir, "turns", turn_id, "process.json"])

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"pid" => pid}} when is_integer(pid) and pid > 1 <- JSON.decode(bytes),
         {:ok, %File.Stat{mtime: launched}} <- File.stat(path, time: :posix) do
      probe.(pid, launched)
    else
      _ -> :unknown
    end
  end

  @doc """
  One `ps` listing, taken now, as a probe `(pid, launched) -> :alive | {:gone, why} |
  :unknown` that classifies against it (`RestartReconciliation.classify/5`). A failed or
  denied `ps` gives a probe that proves nothing.
  """
  def processes do
    with executable when is_binary(executable) <- System.find_executable("ps"),
         {listing, 0} <-
           System.cmd(executable, ["-A", "-o", "pid=,pgid=,etime="],
             env: [{"LC_ALL", "C"}],
             stderr_to_stdout: true
           ) do
      own = String.to_integer(System.pid())
      now = System.os_time(:second)
      &RestartReconciliation.classify(listing, own, &1, &2, now)
    else
      _ -> fn _pid, _launched -> :unknown end
    end
  rescue
    _ -> fn _pid, _launched -> :unknown end
  end
end
