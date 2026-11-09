defmodule AtlasRuntime.Execution.RestartReconciliation do
  @moduledoc """
  Service-start reconciliation of turn records a previous service left non-terminal.

  A starting service owns no execution: it has no port, so no host, for any saved turn.
  A record still `running`, `stopping` or `killing` is ended only when its process is
  provably gone: the leader PID in its `process.json` runs no process and leads no
  surviving process group, or that PID now belongs to a process that started at another
  time than the recorded launch. The turn then becomes `failed` with the reason, its
  previous state in `recorded_state`, and one `execution_failed` event carrying
  `interruption: "service_restart"`, which no ordinary failure has; every other field is kept. A turn whose process may still run, or whose evidence is missing or
  unreadable, stays as recorded (reads show it `unknown`). Nothing is ever signalled.
  """

  require Logger

  alias AtlasRuntime.{ExecutionEvents, QuestionRecords}
  import AtlasRuntime.Execution.Identity

  @terminal ["finished", "failed", "stopped", "killed"]
  # The launch is `process.json`'s write time, right after the host started the leader;
  # `ps` reports elapsed time in whole seconds.
  @tolerance 5

  @doc """
  Ends every provably interrupted turn under `dir` and returns the event journal.
  `probe.(pid, recorded_start)` answers `{:gone, why}`, `:alive` or `:unknown`, where
  `recorded_start` is the launch in Unix seconds; only `{:gone, why}` ends a turn.
  """
  def reconcile(dir, events, probe \\ &process_state/2, now \\ DateTime.utc_now()) do
    root = Path.join(dir, "turns")

    case File.ls(root) do
      {:ok, entries} -> entries |> Enum.filter(&valid_id?/1) |> Enum.sort()
      {:error, _} -> []
    end
    |> Enum.reduce(events, fn id, events ->
      folder = Path.join(root, id)

      with {:ok, run} <- unfinished(folder, id),
           {:ok, pid, started} <- launch(folder),
           {:gone, why} <- probe.(pid, started) do
        interrupt(dir, events, folder, run, pid, why, now)
      else
        :terminal ->
          events

        other ->
          Logger.warning("runtime: #{id} left as recorded after restart: #{inspect(other)}")
          events
      end
    end)
  end

  defp unfinished(folder, id) do
    with {:ok, bytes} <- File.read(Path.join(folder, "turn.json")),
         {:ok, %{"id" => ^id} = run} <- JSON.decode(bytes) do
      run = Map.put_new(run, "worker_id", "default")

      cond do
        run["state"] in @terminal -> :terminal
        not valid_worker_id?(run["worker_id"]) -> {:invalid, :worker_id}
        true -> {:ok, run}
      end
    else
      {:error, reason} -> {:unreadable, reason}
      _ -> {:invalid, :turn_record}
    end
  end

  defp launch(folder) do
    path = Path.join(folder, "process.json")

    with {:ok, bytes} <- File.read(path),
         {:ok, %{"pid" => pid}} when is_integer(pid) and pid > 1 <- JSON.decode(bytes),
         {:ok, %File.Stat{mtime: started}} <- File.stat(path, time: :posix) do
      {:ok, pid, started}
    else
      {:error, reason} -> {:no_process_evidence, reason}
      _ -> {:no_process_evidence, :invalid}
    end
  end

  defp interrupt(dir, events, folder, run, pid, why, now) do
    ended_at = DateTime.to_iso8601(now)

    run =
      Map.merge(run, %{
        "state" => "failed",
        "recorded_state" => run["state"],
        "pending_question" => nil,
        "error" =>
          "interrupted: the Runtime service restarted while the turn ran; " <>
            "its process (pid #{pid}) is gone: #{why}",
        "ended_at" => ended_at
      })

    run =
      if is_map(run["termination"]),
        do: put_in(run, ["termination", "error"], run["error"]),
        else: run

    events = QuestionRecords.invalidate_turn(dir, events, run["id"], "failed")
    path = Path.join(folder, "turn.json")
    File.write!(path <> ".tmp", JSON.encode!(run))
    File.rename!(path <> ".tmp", path)

    ExecutionEvents.append(dir, events, %{
      state: "failed",
      id: run["id"],
      worker_id: run["worker_id"],
      backend: Map.get(run, "backend", "codex"),
      session_id: run["session_id"],
      model: run["model"],
      ended_at: ended_at,
      interruption: "service_restart"
    })
  end

  @doc """
  The default probe: one `ps` listing of every process. A listing that does not show this
  BEAM and PID 1 (a denied or unusual `ps`) proves nothing.
  """
  def process_state(pid, recorded_start) do
    with executable when is_binary(executable) <- System.find_executable("ps"),
         {listing, 0} <-
           System.cmd(executable, ["-A", "-o", "pid=,pgid=,etime="],
             env: [{"LC_ALL", "C"}],
             stderr_to_stdout: true
           ) do
      classify(listing, String.to_integer(System.pid()), pid, recorded_start, now())
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp now, do: System.os_time(:second)

  @doc false
  # Decides from a `ps -A -o pid=,pgid=,etime=` listing; `own` must appear in it, as PID 1.
  def classify(listing, own, pid, recorded_start, now) do
    table = table(listing)

    cond do
      not (Map.has_key?(table, own) and Map.has_key?(table, 1)) ->
        :unknown

      leader = table[pid] ->
        started = now - elem(leader, 1)

        if abs(started - recorded_start) <= @tolerance,
          do: :alive,
          else:
            {:gone,
             "pid #{pid} now belongs to a process started #{started - recorded_start} s " <>
               "from the recorded launch"}

      # Descendants keep the group while its leader is gone; a PID is not reused meanwhile.
      Enum.any?(table, fn {_, {group, _}} -> group == pid end) ->
        :alive

      true ->
        {:gone, "pid #{pid} runs no process and leads no process group"}
    end
  end

  defp table(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.reduce_while(%{}, fn line, table ->
      with [pid, group, elapsed] <- String.split(line),
           {pid, ""} <- Integer.parse(pid),
           {group, ""} <- Integer.parse(group),
           {:ok, seconds} <- elapsed(elapsed) do
        {:cont, Map.put(table, pid, {group, seconds})}
      else
        # An unreadable line could be the recorded process: prove nothing.
        _ -> {:halt, %{}}
      end
    end)
  end

  # ps etime: [[dd-]hh:]mm:ss
  defp elapsed(text) do
    {days, clock} =
      case String.split(text, "-") do
        [days, clock] -> {Integer.parse(days), clock}
        [clock] -> {{0, ""}, clock}
        _ -> {:error, ""}
      end

    parts = clock |> String.split(":") |> Enum.map(&Integer.parse/1)

    with {days, ""} <- days,
         true <- length(parts) in 2..3 and Enum.all?(parts, &match?({_, ""}, &1)) do
      [seconds, minutes, hours | _] =
        parts |> Enum.map(&elem(&1, 0)) |> Enum.reverse() |> Kernel.++([0])

      {:ok, ((days * 24 + hours) * 60 + minutes) * 60 + seconds}
    else
      _ -> :error
    end
  end
end
