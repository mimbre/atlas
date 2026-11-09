defmodule AtlasRuntime.QuestionRecordsTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.{ExecutionEvents, QuestionRecords}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    run = %{id: "turn-0000000000000001", worker_id: "alpha"}

    question = %{
      id: "question-ab12",
      questions: [%{"question" => "Choose?"}],
      correlation: %{
        "session_id" => "00000000-0000-4000-8000-000000000001",
        "model" => "claude-sonnet-4-6",
        "tool_use_id" => "tool-use-1",
        "request_id" => "request-1",
        "native_pid" => 12345
      }
    }

    {record, events} = QuestionRecords.create(dir, ExecutionEvents.open(dir), run, question)
    %{dir: dir, run: run, question: question, record: record, events: events}
  end

  defp save(dir, record),
    do: File.write!(Path.join(dir, record["record_ref"]), JSON.encode!(record))

  defp events(store), do: ExecutionEvents.query(store, nil, 100)["events"]
  defp load(context), do: QuestionRecords.load(context.dir, context.run.id, context.question.id)

  test "records retain original input, ownership, correlation and only bounded transition references",
       context do
    %{dir: dir, record: record, events: store, question: question} = context
    assert record["original_input"] == %{"questions" => question.questions}
    assert record["correlation"] == question.correlation
    assert record["published_revision"] == 1
    assert record["transitions"] == []
    {record, store} = QuestionRecords.admit(dir, store, record, %{"Choose?" => "yes"})
    {record, store} = QuestionRecords.delivered(dir, store, record)
    {record, store} = QuestionRecords.processed(dir, store, record)
    assert record == load(context)
    assert record["revision"] == 4
    assert record["published_revision"] == 4
    assert record["transitions"] == []
    assert record["processing"] == "processed"
    assert record["active"] == false

    assert Enum.map(events(store), & &1["kind"]) ==
             ["question_available", "answer_accepted", "answer_delivered", "answer_processed"]

    for event <- events(store) do
      assert Enum.sort(Map.keys(event)) ==
               ~w(kind question_id record_ref revision sequence timestamp turn_id worker_id)
    end

    assert QuestionRecords.recover(dir, ExecutionEvents.open(dir)) == store
    assert load(context) == record
  end

  test "admission without transport survives restart, never inventing consumption", context do
    %{dir: dir, record: record, events: store} = context
    {record, store} = QuestionRecords.admit(dir, store, record, %{"Choose?" => "yes"})
    assert record["transport"] == "unknown"
    assert record["processing"] == "unknown"
    store = QuestionRecords.recover(dir, store)
    recovered = load(context)
    assert recovered["active"] == false
    assert recovered["invalidation_reason"] == "runtime_restart"
    assert recovered["answers"] == record["answers"]
    assert recovered["admission"] == "accepted"
    assert recovered["transport"] == "unknown"
    assert recovered["processing"] == "unknown"
    assert recovered["outcome"] == "unknown"
    assert List.last(events(store))["kind"] == "question_invalidated"
    assert QuestionRecords.recover(dir, store) == store
  end

  test "record-before-journal crash flushes missing transition once", context do
    %{dir: dir, record: record, events: before} = context
    journal = Path.join(dir, "execution-events.json")
    bytes = File.read!(journal)
    {record, after_admission} = QuestionRecords.admit(dir, before, record, %{"Choose?" => "yes"})
    transition = List.last(events(after_admission)) |> Map.delete("sequence")
    save(dir, %{record | "published_revision" => 1, "transitions" => [transition]})
    File.write!(journal, bytes)

    recovered = QuestionRecords.recover(dir, ExecutionEvents.open(dir))

    assert Enum.map(events(recovered), & &1["kind"]) ==
             ["question_available", "answer_accepted", "question_invalidated"]

    assert load(context)["transitions"] == []
    assert QuestionRecords.recover(dir, recovered) == recovered
    assert load(context)["published_revision"] == 3
  end

  test "journal-before-checkpoint crash deduplicates question revision", context do
    %{dir: dir, record: record, events: store} = context
    {record, store} = QuestionRecords.admit(dir, store, record, %{"Choose?" => "yes"})
    transition = List.last(events(store)) |> Map.delete("sequence")
    save(dir, %{record | "published_revision" => 1, "transitions" => [transition]})

    recovered = QuestionRecords.recover(dir, ExecutionEvents.open(dir))

    assert Enum.map(events(recovered), & &1["kind"]) ==
             ["question_available", "answer_accepted", "question_invalidated"]

    assert length(Enum.filter(events(recovered), &(&1["kind"] == "answer_accepted"))) == 1
    assert load(context)["transitions"] == []
    assert QuestionRecords.recover(dir, recovered) == recovered
  end

  test "checkpointed pruned transitions never republish and retention remains 256", context do
    %{dir: dir, record: record, events: store} = context
    {record, store} = QuestionRecords.invalidate(dir, store, record, "stopped")

    store =
      Enum.reduce(1..270, store, fn number, store ->
        run = %{
          id: "turn-" <> String.pad_leading(Integer.to_string(number, 16), 16, "0"),
          worker_id: "alpha",
          state: "running",
          backend: "claude",
          session_id: nil,
          model: nil,
          started_at: "2026-11-07T10:00:00Z"
        }

        ExecutionEvents.append(dir, store, run)
      end)

    assert length(store["events"]) == 256
    assert Enum.all?(store["events"], &(&1["kind"] == "execution_accepted"))
    assert ExecutionEvents.query(store, nil, 100)["retention_gap"]
    assert QuestionRecords.recover(dir, ExecutionEvents.open(dir)) == store
    assert load(context) == record
  end

  test "corrupt records fail closed instead of dropping admission", context do
    %{dir: dir, record: record} = context

    for bad <- [
          Map.put(record, "answers", %{"Choose?" => "unadmitted"}),
          Map.put(record, "processing", "processed"),
          Map.put(record, "active", false),
          Map.put(record, "outcome", "invalidated"),
          Map.put(record, "invalidation_reason", "stopped"),
          Map.merge(record, %{"active" => false, "invalidation_reason" => "stopped"}),
          Map.put(record, "published_revision", 2),
          Map.put(record, "correlation", %{}),
          Map.put(record, "worker_id", "../outside")
        ] do
      save(dir, bad)
      assert_raise QuestionRecords.StorageError, fn -> load(context) end

      assert_raise QuestionRecords.StorageError, fn ->
        QuestionRecords.recover(dir, ExecutionEvents.open(dir))
      end
    end

    save(dir, record)
    File.write!(Path.join(dir, record["record_ref"]), "{")
    assert_raise QuestionRecords.StorageError, fn -> load(context) end
  end

  test "accepted corruption cannot invent processing or contradictory invalidation", context do
    %{dir: dir, record: record, events: store} = context
    {accepted, store} = QuestionRecords.admit(dir, store, record, %{"Choose?" => "yes"})
    {delivered, store} = QuestionRecords.delivered(dir, store, accepted)
    {processed, _store} = QuestionRecords.processed(dir, store, delivered)

    for bad <- [
          Map.put(accepted, "outcome", "processed"),
          Map.put(delivered, "outcome", "processed"),
          Map.put(processed, "outcome", "unknown"),
          Map.put(processed, "processing", "unknown"),
          Map.put(processed, "transport", "unknown"),
          Map.put(processed, "active", true),
          Map.put(accepted, "active", false),
          Map.put(accepted, "invalidation_reason", "stopped")
        ] do
      save(dir, bad)
      assert_raise QuestionRecords.StorageError, fn -> load(context) end

      assert_raise QuestionRecords.StorageError, fn ->
        QuestionRecords.recover(dir, ExecutionEvents.open(dir))
      end
    end
  end
end
