defmodule AtlasRuntime.QuestionRecords do
  @moduledoc "Per-question admission and evidence with a bounded execution-event outbox."
  alias AtlasRuntime.ExecutionEvents
  alias AtlasRuntime.Interactions.NativeQuestion

  defmodule StorageError do
    defexception [:message]
  end

  @max_bytes 131_072
  @kinds ~w(question_available answer_accepted answer_delivered answer_processed question_invalidated)

  def reference(turn, question), do: Path.join(["turns", turn, "questions", question <> ".json"])

  def load(dir, turn, question) do
    storage(fn ->
      path = Path.join(dir, reference(turn, question))
      case File.stat(path) do
        {:error, :enoent} -> nil
        {:ok, %{size: size}} when size <= @max_bytes ->
          record = path |> File.read!() |> JSON.decode!() |> validate!()
          unless record["turn_id"] == turn and record["question_id"] == question,
            do: raise("Question record ownership does not match its path")
          record
        {:ok, _} -> raise("Oversized question record")
        {:error, reason} -> raise File.Error, reason: reason, action: "read question record", path: path
      end
    end)
  end

  def create(dir, events, run, question) do
    storage(fn ->
      if load(dir, run.id, question.id), do: raise("Question ID already recorded")
      now = timestamp()
      record = %{
        "version" => 1, "worker_id" => run.worker_id, "turn_id" => run.id,
        "question_id" => question.id, "record_ref" => reference(run.id, question.id),
        "original_input" => %{"questions" => question.questions},
        "correlation" => question.correlation, "admission" => "pending", "answers" => nil,
        "transport" => "not_attempted", "processing" => "not_observed", "outcome" => "pending",
        "active" => true, "invalidation_reason" => nil, "created_at" => now, "updated_at" => now,
        "revision" => 0, "published_revision" => 0, "transitions" => []
      }
      transition(dir, events, record, "question_available")
    end)
  end

  def admit(dir, events, record, answers) do
    record = Map.merge(record, %{"admission" => "accepted", "answers" => answers,
      "transport" => "unknown", "processing" => "unknown", "outcome" => "unknown"})
    transition(dir, events, record, "answer_accepted")
  end

  def delivered(dir, events, %{"admission" => "accepted", "transport" => "unknown"} = record) do
    transition(dir, events, Map.put(record, "transport", "delivered"), "answer_delivered")
  end
  def delivered(_dir, events, record), do: {record, events}

  def processed(dir, events, %{"admission" => "accepted", "processing" => processing} = record)
      when processing != "processed" do
    {record, events} = delivered(dir, events, record)
    record = Map.merge(record, %{"processing" => "processed", "outcome" => "processed", "active" => false})
    transition(dir, events, record, "answer_processed")
  end
  def processed(_dir, events, record), do: {record, events}

  def invalidate(dir, events, %{"active" => true} = record, reason) do
    outcome = if record["admission"] == "pending", do: "invalidated", else: record["outcome"]
    record = Map.merge(record, %{"active" => false, "outcome" => outcome, "invalidation_reason" => reason})
    transition(dir, events, record, "question_invalidated")
  end
  def invalidate(_dir, events, record, _reason), do: {record, events}

  def recover(dir, events) do
    Enum.reduce(turns(dir), events, fn turn, events ->
      invalidate_turn(dir, events, turn, "runtime_restart")
    end)
  end

  def invalidate_turn(dir, events, turn, reason) do
    Enum.reduce(records(dir, turn), events, fn record, events ->
      {record, events} = flush(dir, events, record)
      {_record, events} = invalidate(dir, events, record, reason)
      events
    end)
  end

  def flush(dir, events, record) do
    storage(fn ->
      Enum.reduce(record["transitions"], {record, events}, fn transition, {record, events} ->
        events = ExecutionEvents.append_question(dir, events, transition)
        revision = transition["revision"]
        record = Map.merge(record, %{"published_revision" => revision,
          "transitions" => Enum.reject(record["transitions"], &(&1["revision"] <= revision))})
        persist(dir, record)
        {record, events}
      end)
    end)
  end

  def evidence(record) do
    status = cond do
      record["processing"] == "processed" -> "processed"
      record["transport"] == "delivered" -> "delivered"
      true -> record["admission"]
    end
    %{worker_id: record["worker_id"], turn_id: record["turn_id"], question_id: record["question_id"],
      status: status, admission: record["admission"], transport: record["transport"],
      processing: record["processing"], outcome: record["outcome"], active: record["active"],
      revision: record["revision"], record_ref: record["record_ref"]}
  end

  def public(record), do: Map.drop(record, ["version", "transitions", "published_revision"])

  defp transition(dir, events, record, kind) do
    storage(fn ->
      revision = record["revision"] + 1
      now = timestamp()
      event = %{"kind" => kind, "turn_id" => record["turn_id"], "worker_id" => record["worker_id"],
        "question_id" => record["question_id"], "revision" => revision,
        "record_ref" => record["record_ref"], "timestamp" => now}
      record = Map.merge(record, %{"revision" => revision, "updated_at" => now,
        "transitions" => record["transitions"] ++ [event]})
      persist(dir, record)
      flush(dir, events, record)
    end)
  end

  defp persist(dir, record) do
    validate!(record)
    encoded = JSON.encode!(record)
    if byte_size(encoded) > @max_bytes, do: raise("Oversized question record")
    path = Path.join(dir, record["record_ref"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path <> ".tmp", encoded)
    File.rename!(path <> ".tmp", path)
    record
  end

  defp turns(dir) do
    entries(Path.join(dir, "turns")) |> Enum.filter(&Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, &1)) |> Enum.sort()
  end

  defp records(dir, turn) do
    entries(Path.join([dir, "turns", turn, "questions"]))
    |> Enum.sort()
    |> Enum.reject(&String.ends_with?(&1, ".tmp"))
    |> Enum.map(fn name ->
      unless Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\.json\z/, name),
        do: raise(StorageError, message: "Invalid question record filename")
      load(dir, turn, String.replace_suffix(name, ".json", "")) ||
        raise(StorageError, message: "Question record disappeared")
    end)
  end

  defp entries(path) do
    storage(fn ->
      case File.ls(path) do
        {:ok, names} -> names
        {:error, :enoent} -> []
        {:error, reason} -> raise File.Error, reason: reason, action: "read question records", path: path
      end
    end)
  end

  defp validate!(record) do
    valid = is_map(record) and map_size(record) == 19 and record["version"] == 1 and
      text_match?(record["worker_id"], ~r/\A[a-z][a-z0-9_-]{0,63}\z/) and
      text_match?(record["turn_id"], ~r/\Aturn-[0-9a-f]{16}\z/) and
      text_match?(record["question_id"], ~r/\Aquestion-[0-9a-f]{1,64}\z/) and
      record["record_ref"] == reference(record["turn_id"], record["question_id"]) and
      is_map(record["original_input"]) and map_size(record["original_input"]) == 1 and
      valid_questions?(record["original_input"]["questions"]) and valid_correlation?(record["correlation"]) and
      record["admission"] in ["pending", "accepted"] and
      record["transport"] in ["not_attempted", "unknown", "delivered"] and
      record["processing"] in ["not_observed", "unknown", "processed"] and
      record["outcome"] in ["pending", "unknown", "processed", "invalidated"] and
      is_boolean(record["active"]) and
      (is_nil(record["invalidation_reason"]) or record["invalidation_reason"] in
        ["runtime_restart", "stopped", "killed", "finished", "failed"]) and
      timestamp?(record["created_at"]) and timestamp?(record["updated_at"]) and
      is_integer(record["revision"]) and record["revision"] in 1..5 and
      is_integer(record["published_revision"]) and record["published_revision"] in 0..record["revision"] and
      is_list(record["transitions"]) and
      length(record["transitions"]) == record["revision"] - record["published_revision"]
    unless valid, do: raise("Invalid question record")
    questions = record["original_input"]["questions"]
    case record["admission"] do
      "pending" ->
        unless is_nil(record["answers"]) and record["transport"] == "not_attempted" and
          record["processing"] == "not_observed" and
          record["outcome"] == if(record["active"], do: "pending", else: "invalidated"),
          do: raise("Invalid pending question record")
      "accepted" ->
        unless NativeQuestion.validate_answers(%{questions: questions}, record["answers"]) == :ok and
          record["transport"] in ["unknown", "delivered"] and record["processing"] in ["unknown", "processed"] and
          record["outcome"] in ["unknown", "processed"], do: raise("Invalid accepted question record")
    end
    processed = record["processing"] == "processed"
    if processed != (record["outcome"] == "processed") or
         (processed and (record["transport"] != "delivered" or record["active"])),
      do: raise("Invalid processed question record")
    if (record["active"] and not is_nil(record["invalidation_reason"])) or
         (not record["active"] and not processed and is_nil(record["invalidation_reason"])),
      do: raise("Invalid question invalidation state")
    Enum.with_index(record["transitions"], record["published_revision"] + 1)
    |> Enum.each(fn {event, revision} ->
      unless is_map(event) and map_size(event) == 7 and event["kind"] in @kinds and
        event["revision"] == revision and timestamp?(event["timestamp"]) and
        Enum.all?(["worker_id", "turn_id", "question_id", "record_ref"], &(event[&1] == record[&1])),
        do: raise("Invalid question transition outbox")
    end)
    record
  end

  defp valid_questions?(questions) when is_list(questions) and length(questions) in 1..4 do
    Enum.all?(questions, &(is_map(&1) and is_binary(&1["question"]))) and
      NativeQuestion.validate_answers(%{questions: questions}, Map.new(questions, &{&1["question"], "valid"})) == :ok
  end
  defp valid_questions?(_), do: false

  defp valid_correlation?(correlation) when is_map(correlation) do
    Enum.sort(Map.keys(correlation)) == ~w(model native_pid request_id session_id tool_use_id) and
      Enum.all?(~w(model request_id session_id tool_use_id), fn key ->
        is_binary(correlation[key]) and byte_size(correlation[key]) in 1..1024
      end) and is_integer(correlation["native_pid"]) and correlation["native_pid"] > 0
  end
  defp valid_correlation?(_), do: false
  defp text_match?(value, regex), do: is_binary(value) and Regex.match?(regex, value)
  defp timestamp, do: DateTime.to_iso8601(DateTime.utc_now())
  defp timestamp?(value), do: is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp storage(fun) do
    fun.()
  rescue
    error in StorageError -> reraise error, __STACKTRACE__
    error -> raise StorageError, message: "Question storage failed: #{Exception.message(error)}"
  end
end
