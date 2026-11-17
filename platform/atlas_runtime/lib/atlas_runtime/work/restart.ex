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
  | `running` while `checking` (s5a-plan B21) | ended | `completed` with `check.interrupted: true` (`interrupted_check/2`); never checked again |

  **Checking (design §5, §6 step 2; B21).** The agent's result and its frozen result were
  committed before the check started, so the attempt ends `completed`, never `interrupted`,
  whatever happened to the check (its frozen record is kept, B9). Its `quiescent` is false
  while a recorded `check_pgid` may live: the old helper lost its stdin and stops the group
  itself. The probe settles it once that group is provably gone (`AtlasRuntime.Work.Check.gone?/2`),
  and only then is the check's scratch removed (`remove_check_scratch/3`, B24). Without a
  recorded group nothing was reported started, and it is quiescent at once, as a `preparing`
  attempt without a `prepare_pid`.

  `quiescent` of a `preparing` attempt is false while its preparer's helper may still write
  the folder (`prepare_pid` recorded) and true without one; the probe settles it once that
  process is provably gone (`prepare_gone?/2`), as for an `unknown` turn.

  **Frozen records (s5a-plan B9).** Before any attempt ends at boot, `orphans/2` deletes every
  frozen record whose attempt was never committed `completed` (nor is `checking`): a crash
  between the frozen write and the commit. It was never public. That attempt then ends
  `interrupted` (`unfrozen/1`), retryable, never `completed` without a frozen result.

  `quiescent` is false when the turn is `unknown` (its process may still exist) and true
  otherwise. **The probe** re-checks such a turn on every heartbeat with the Service's own
  process check (`RestartReconciliation.classify/5` of its `process.json` leader); it only
  reads. When the process is provably gone the attempt becomes quiescent. A human `release`
  of the slot does the same. The same check, from one `ps` listing per heartbeat
  (`processes/0`), is the heartbeat's `alive` (§3.6).
  """

  alias AtlasRuntime.Execution.RestartReconciliation
  alias AtlasRuntime.Work.{Check, FrozenStore, Queue, Turns}

  @doc """
  What becomes of an attempt at boot: `:keep`, `:checking` (its check is interrupted,
  `interrupted_check/2`) or `{:end, outcome}` (see `Turns.outcome/2`).
  """
  def classify(attempt, turn, owned?) do
    cond do
      not Queue.live?(attempt) ->
        :keep

      Map.get(attempt, :checking) == true ->
        :checking

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
  Deletes the frozen records no committed `completed` (or `checking`) attempt names (B9) and
  returns their `{work_id, attempt}` as a set.
  """
  def orphans(dir, works), do: dir |> FrozenStore.orphans(works) |> MapSet.new()

  @doc """
  The end of an attempt whose frozen record was an orphan: a completed end becomes
  `interrupted` (its frozen result is gone), any other end is kept.
  """
  def unfrozen(%{kind: :completed} = outcome), do: %{outcome | kind: :interrupted, reason: nil}
  def unfrozen(outcome), do: outcome

  @doc """
  The check result of a `checking` attempt a restart interrupted (B21): `interrupted: true`,
  nothing else known (no exit status, signal or error, and no output), the time since
  `check_started_at` as its duration, and `quiescent` only when no check group was recorded.
  """
  def interrupted_check(attempt, now) do
    started = attempt.timestamps.check_started_at

    %{
      exit_status: nil,
      signal: nil,
      error: nil,
      timed_out: false,
      cancelled: false,
      interrupted: true,
      duration_ms: if(started, do: max(DateTime.diff(now, started, :millisecond), 0), else: 0),
      output: %{tail: "", complete: false},
      pgid: attempt.check_pgid,
      quiescent: is_nil(attempt.check_pgid)
    }
  end

  @doc "Whether a checking attempt's group provably exists: `:alive` only on that evidence."
  def check_alive?(%{check_pgid: pgid} = attempt, probe) when is_integer(pgid) and pgid > 1 do
    started =
      case attempt.timestamps.check_started_at do
        %DateTime{} = at -> DateTime.to_unix(at)
        nil -> System.os_time(:second)
      end

    probe.(pgid, started) == :alive
  end

  def check_alive?(_attempt, _probe), do: false

  @doc """
  Removes the scratch of attempt `n`'s check (`<home>/scratch/check-<work_id>.<n>`, B24),
  restoring the write bits of its directories first (symlinks are never followed). Called only
  once the check's group is provably gone.
  """
  def remove_check_scratch(home, work_id, n) do
    remove(Check.scratch(home, work_id, n))
  end

  defp remove(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        File.chmod(path, 0o700)

        case File.ls(path) do
          {:ok, names} -> for name <- names, do: remove(Path.join(path, name))
          _ -> :ok
        end

        File.rmdir(path)

      {:ok, _} ->
        File.rm(path)

      {:error, _} ->
        :ok
    end

    :ok
  end

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
