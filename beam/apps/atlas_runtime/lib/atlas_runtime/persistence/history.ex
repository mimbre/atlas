defmodule AtlasRuntime.Persistence.History do
  alias AtlasRuntime.{ExecutionEvents, HandoffRecords, PeerQuestionRecords, QuestionRecords}
  import AtlasRuntime.Execution.Identity

  def recover(dir) do
    events = HandoffRecords.recover(dir, ExecutionEvents.open(dir))
    events = PeerQuestionRecords.recover(dir, events)
    QuestionRecords.recover(dir, events)
  end

  def list(dir, workers) do
    root = Path.join(dir, "turns")

    entries =
      case File.ls(root) do
        {:ok, entries} -> entries
        {:error, :enoent} -> []
        {:error, reason} -> raise("Cannot read turn history: #{inspect(reason)}")
      end

    turns =
      entries
      |> Enum.filter(&valid_id?/1)
      |> Enum.filter(&File.dir?(Path.join(root, &1)))
      |> Enum.map(&historical(&1, dir, workers))
      |> Enum.sort_by(&{&1["started_at"] || "", &1["id"]}, :desc)

    %{turns: turns}
  end

  def owned_saved_turn!(dir, turn, worker_id) do
    path = Path.join([dir, "turns", turn, "turn.json"])

    run =
      case File.read(path) do
        {:ok, bytes} ->
          JSON.decode!(bytes)

        {:error, :enoent} ->
          raise("Unknown saved turn: #{turn}")

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read saved turn", path: path
      end

    if not is_map(run) or run["id"] != turn or not valid_worker_id?(run["worker_id"]),
      do: raise("Invalid saved execution identity")

    if run["worker_id"] != worker_id,
      do: raise("Turn belongs to worker #{run["worker_id"]}, not #{worker_id}")

    run
  end

  def historical(id, dir, workers) do
    if not valid_id?(id), do: raise("Invalid turn ID")
    folder = Path.join([dir, "turns", id])
    if not File.dir?(folder), do: raise("Unknown turn: #{id}")

    current =
      Enum.find_value(workers, fn {_worker_id, worker} ->
        if worker.run[:id] == id, do: worker.run
      end)

    if current do
      # Normalize keys to match persisted JSON without interning user input.
      string_keys(current)
    else
      run =
        case File.read(Path.join(folder, "turn.json")) do
          {:ok, bytes} -> JSON.decode!(bytes)
          {:error, :enoent} -> %{"state" => "unknown"}
          {:error, reason} -> raise("Cannot read turn #{id}: #{inspect(reason)}")
        end

      run = Map.put_new(run, "worker_id", "default")
      run = run |> Map.put_new("questions_enabled", false) |> Map.put("pending_question", nil)
      if not valid_worker_id?(run["worker_id"]), do: raise("Invalid saved worker ID")

      run =
        case run["last_answer"] do
          %{"question_id" => question_id, "record_ref" => _} ->
            if not is_binary(question_id) or
                 not Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, question_id),
               do:
                 raise(QuestionRecords.StorageError, message: "Invalid saved question reference")

            record =
              QuestionRecords.load(dir, id, question_id) ||
                raise(QuestionRecords.StorageError, message: "Saved question record is missing")

            if record["worker_id"] != run["worker_id"],
              do: raise(QuestionRecords.StorageError, message: "Saved question ownership changed")

            Map.put(run, "last_answer", string_keys(QuestionRecords.evidence(record)))

          _ ->
            run
        end

      # A service that is gone owns nothing: its unfinished turns are unknown, not still active.
      run =
        if run["state"] in ["running", "stopping", "killing"],
          do: Map.merge(run, %{"state" => "unknown", "recorded_state" => run["state"]}),
          else: run

      Map.merge(run, %{"id" => id, "artifacts" => folder})
    end
  end

  def checkpoint(dir, events, previous, workers) do
    Enum.reduce(Enum.sort(workers), {events, workers}, fn {id, worker}, {events, workers} ->
      old = Map.get(previous, id, %{run: %{worker_id: id, state: "idle"}}).run

      {worker, events, workers} =
        if worker.run[:id] && worker.run.state in ["stopped", "killed", "finished", "failed"] &&
             {worker.run[:id], worker.run.state} != {old[:id], old.state} do
          events = QuestionRecords.invalidate_turn(dir, events, worker.run.id, worker.run.state)

          worker =
            case worker.run[:last_answer] do
              %{question_id: question_id} ->
                record = QuestionRecords.load(dir, worker.run.id, question_id)

                if record,
                  do: %{
                    worker
                    | run: Map.put(worker.run, :last_answer, QuestionRecords.evidence(record))
                  },
                  else: worker

              _ ->
                worker
            end

          {worker, events, Map.put(workers, id, worker)}
        else
          {worker, events, workers}
        end

      if worker.run != old, do: persist(worker.run)

      # Stopping and killing are persisted in turn.json only; no transition event.
      events =
        if {worker.run[:id], worker.run.state} != {old[:id], old.state} and
             worker.run.state not in ["stopping", "killing"],
          do: ExecutionEvents.append(dir, events, worker.run),
          else: events

      {events, workers}
    end)
  end

  def persist(run) do
    path = Path.join(run.artifacts, "turn.json")
    File.write!(path <> ".tmp", JSON.encode!(run))
    File.rename!(path <> ".tmp", path)
  end

  @doc """
  The worker's admission latch, written before a stop or kill is signalled and kept across
  restarts until an explicit release; nil when absent. Unreadable latches fail closed.
  """
  def latch(dir, worker_id) do
    path = latch_path(dir, worker_id)

    case File.read(path) do
      {:ok, bytes} ->
        case JSON.decode(bytes) do
          {:ok, %{"worker_id" => ^worker_id, "turn_id" => turn, "latched_at" => at} = latch}
          when map_size(latch) == 3 and is_binary(turn) and is_binary(at) ->
            latch

          _ ->
            raise("Invalid admission latch for worker #{worker_id}")
        end

      {:error, :enoent} ->
        nil

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read admission latch", path: path
    end
  end

  @doc "Latches the worker for `turn`, keeping an existing latch unchanged."
  def latch!(dir, worker_id, turn, at) do
    if latch = latch(dir, worker_id) do
      latch
    else
      path = latch_path(dir, worker_id)
      latch = %{"worker_id" => worker_id, "turn_id" => turn, "latched_at" => at}
      File.mkdir_p!(Path.dirname(path))
      File.write!(path <> ".tmp", JSON.encode!(latch))
      File.rename!(path <> ".tmp", path)
      latch
    end
  end

  def release_latch!(dir, worker_id), do: File.rm!(latch_path(dir, worker_id))

  defp latch_path(dir, worker_id), do: Path.join([dir, "workers", worker_id, "admission-latch.json"])

  @doc "A late Server report on a saved turn: kept only for its exact attempt."
  def server_report(dir, turn, attempt, report) do
    path = Path.join([dir, "turns", turn, "turn.json"])

    with true <- valid_id?(turn),
         {:ok, bytes} <- File.read(path),
         {:ok, %{"id" => ^turn, "server" => %{"attempt" => ^attempt} = server} = run} <- JSON.decode(bytes) do
      File.write!(path <> ".tmp", JSON.encode!(Map.put(run, "server", Map.put(server, "report", report))))
      File.rename!(path <> ".tmp", path)
    end

    :ok
  end

  def output(nil), do: %{answer: nil, recent_events: ""}

  def output(folder) do
    answer =
      case File.read(Path.join(folder, "answer.txt")) do
        {:ok, text} -> text
        {:error, :enoent} -> nil
        {:error, reason} -> raise("Cannot read turn answer: #{inspect(reason)}")
      end

    %{answer: answer, recent_events: recent(Path.join(folder, "stream.jsonl"))}
  end

  # Bounded diagnostic tail; full native output remains in the artifact file.
  defp recent(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          {:ok, size} = :file.position(file, :eof)
          offset = max(0, size - 65_536)
          {:ok, _} = :file.position(file, offset)

          case :file.read(file, 65_536) do
            {:ok, bytes} ->
              lines = String.split(bytes, "\n")
              lines = if offset > 0, do: tl(lines), else: lines
              Enum.join(lines, "\n")

            _ ->
              ""
          end
        after
          File.close(file)
        end

      _ ->
        ""
    end
  end
end
