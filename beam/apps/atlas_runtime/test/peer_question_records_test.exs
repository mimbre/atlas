defmodule AtlasRuntime.PeerQuestionRecordsTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.{ExecutionEvents, PeerQuestionRecords}
  @moduletag :tmp_dir
  @sender "turn-0000000000000001"
  @source "turn-0000000000000002"
  @response "turn-0000000000000003"
  @question "question-ab12"

  setup %{tmp_dir: dir} do
    question = %{
      "worker_id" => "alpha",
      "turn_id" => @sender,
      "question_id" => @question,
      "record_ref" => "turns/#{@sender}/questions/#{@question}.json",
      "original_input" => %{"questions" => [%{"question" => "Private question"}]}
    }

    source = %{"worker_id" => "beta", "turn_id" => @source, "result" => "Private source output"}
    response = %{"worker_id" => "beta", "turn_id" => @response, "result" => "Private answer"}

    %{
      dir: dir,
      question: question,
      source: source,
      response: response,
      events: ExecutionEvents.open(dir)
    }
  end

  defp create(c), do: PeerQuestionRecords.create(c.dir, c.events, c.question, c.source)
  defp load(c), do: PeerQuestionRecords.load(c.dir, @sender, @question)

  defp save(c, record),
    do: File.write!(Path.join(c.dir, record["record_ref"]), JSON.encode!(record))

  defp transition(store), do: store["events"] |> List.last() |> Map.delete("sequence")

  test "reference-only records preserve original routing evidence after immutable binding", c do
    {record, events} = create(c)
    original = PeerQuestionRecords.public(record)

    assert Enum.sort(Map.keys(original)) ==
             ~w(bound_at created_at peer_source_turn_id peer_worker_id provenance question_id question_ref record_ref response_turn_id revision turn_id worker_id)

    assert original["question_ref"] == c.question["record_ref"]
    assert original["provenance"] == "coordinator_routed_declaration"
    assert original["revision"] == 1
    assert original["response_turn_id"] == nil
    assert original["bound_at"] == nil
    assert record["published_revision"] == 1
    assert record["transitions"] == []
    assert PeerQuestionRecords.create(c.dir, events, c.question, c.source) == {record, events}
    {bound, events} = PeerQuestionRecords.bind(c.dir, events, record, c.response)
    assert PeerQuestionRecords.routed(bound) == original
    assert bound["revision"] == 2
    assert bound["published_revision"] == 2
    assert bound["response_turn_id"] == @response
    assert {:ok, _, _} = DateTime.from_iso8601(bound["bound_at"])
    assert load(c) == bound
    assert PeerQuestionRecords.bind(c.dir, events, record, c.response) == {bound, events}
    assert PeerQuestionRecords.create(c.dir, events, c.question, c.source) == {bound, events}
    assert PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir)) == events
    refute JSON.encode!(bound) =~ "Private"
    assert byte_size(JSON.encode!(bound)) <= 16_384

    assert Enum.map(events["events"], & &1["kind"]) == [
             "peer_question_routed",
             "peer_reply_bound"
           ]

    assert Enum.all?(events["events"], &(map_size(&1) == 11))
  end

  test "replacement routes and replies cannot change the original record", c do
    {record, events} = create(c)
    path = Path.join(c.dir, record["record_ref"])
    before = File.read!(path)

    for {question, source} <- [
          {Map.put(c.question, "worker_id", "other"), c.source},
          {c.question, Map.put(c.source, "worker_id", "other")},
          {c.question, Map.put(c.source, "turn_id", @response)}
        ] do
      assert_raise ArgumentError, ~r/Conflicting/, fn ->
        PeerQuestionRecords.create(c.dir, events, question, source)
      end

      assert File.read!(path) == before
    end

    for response <- [
          Map.put(c.response, "worker_id", "other"),
          Map.put(c.response, "turn_id", @source),
          Map.put(c.response, "turn_id", @sender)
        ] do
      assert_raise ArgumentError, fn ->
        PeerQuestionRecords.bind(c.dir, events, record, response)
      end

      assert File.read!(path) == before
    end

    {bound, events} = PeerQuestionRecords.bind(c.dir, events, record, c.response)
    before = File.read!(path)

    assert_raise ArgumentError, ~r/Conflicting peer reply/, fn ->
      PeerQuestionRecords.bind(
        c.dir,
        events,
        bound,
        Map.put(c.response, "turn_id", "turn-0000000000000004")
      )
    end

    assert File.read!(path) == before
  end

  test "identifiers, ownership and reference paths reject malformed caller input", c do
    assert load(c) == nil

    for {key, value} <- [
          {"worker_id", "Upper"},
          {"worker_id", String.duplicate("a", 65)},
          {"worker_id", "../alpha"},
          {"turn_id", "turn-a"},
          {"turn_id", "../outside"},
          {"question_id", "question-"},
          {"question_id", "question-" <> String.duplicate("a", 65)},
          {"record_ref", "turns/#{@source}/questions/#{@question}.json"},
          {"record_ref", "/outside"}
        ] do
      assert_raise ArgumentError, fn ->
        PeerQuestionRecords.create(c.dir, c.events, Map.put(c.question, key, value), c.source)
      end
    end

    for {key, value} <- [
          {"worker_id", "alpha"},
          {"worker_id", nil},
          {"turn_id", @sender},
          {"turn_id", "../outside"}
        ] do
      assert_raise ArgumentError, fn ->
        PeerQuestionRecords.create(c.dir, c.events, c.question, Map.put(c.source, key, value))
      end
    end

    assert_raise ArgumentError, fn -> PeerQuestionRecords.load(c.dir, @sender, "../outside") end
    assert load(c) == nil
  end

  test "maximum identifier sizes remain bounded without copying payloads", c do
    question = %{
      c.question
      | "worker_id" => String.duplicate("a", 64),
        "question_id" => "question-" <> String.duplicate("f", 64)
    }

    question =
      Map.put(
        question,
        "record_ref",
        "turns/#{@sender}/questions/#{question["question_id"]}.json"
      )

    source = %{
      c.source
      | "worker_id" => String.duplicate("b", 64),
        "result" => String.duplicate("x", 20_000)
    }

    {record, _} = PeerQuestionRecords.create(c.dir, c.events, question, source)
    assert byte_size(JSON.encode!(record)) < 16_384
    assert PeerQuestionRecords.load(c.dir, @sender, question["question_id"]) == record
  end

  for revision <- [1, 2], window <- [:before_journal, :before_checkpoint] do
    test "revision #{revision} recovery #{window} publishes exactly once", c do
      journal = Path.join(c.dir, "execution-events.json")
      initial_bytes = File.read!(journal)
      {routed, routed_events} = create(c)
      routed_bytes = File.read!(journal)

      {record, events, before, published} =
        if unquote(revision) == 1 do
          {routed, routed_events, initial_bytes, 0}
        else
          {bound, bound_events} =
            PeerQuestionRecords.bind(c.dir, routed_events, routed, c.response)

          {bound, bound_events, routed_bytes, 1}
        end

      save(c, %{record | "published_revision" => published, "transitions" => [transition(events)]})

      if unquote(window) == :before_journal, do: File.write!(journal, before)
      recovered = PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir))
      assert recovered == events
      assert load(c) == record
      assert PeerQuestionRecords.recover(c.dir, recovered) == recovered
      assert length(recovered["events"]) == unquote(revision)
    end
  end

  test "two pending transitions recover in order and preserve routed response null", c do
    initial = File.read!(Path.join(c.dir, "execution-events.json"))
    {routed, events} = create(c)
    {bound, events} = PeerQuestionRecords.bind(c.dir, events, routed, c.response)
    transitions = Enum.map(events["events"], &Map.delete(&1, "sequence"))
    save(c, %{bound | "published_revision" => 0, "transitions" => transitions})
    File.write!(Path.join(c.dir, "execution-events.json"), initial)
    assert PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir)) == events
    assert hd(events["events"])["response_turn_id"] == nil
    assert load(c) == bound
  end

  test "revision order survives a backwards wall-clock correction", c do
    {routed, events} = create(c)
    {bound, events} = PeerQuestionRecords.bind(c.dir, events, routed, c.response)
    bound = Map.put(bound, "bound_at", "2000-01-01T00:00:00Z")

    events =
      Map.update!(events, "events", fn entries ->
        Enum.map(entries, fn event ->
          if event["revision"] == 2,
            do: Map.put(event, "timestamp", bound["bound_at"]),
            else: event
        end)
      end)

    save(c, bound)
    File.write!(Path.join(c.dir, "execution-events.json"), JSON.encode!(events))
    assert load(c) == bound
    assert PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir)) == events
    assert PeerQuestionRecords.routed(bound) == PeerQuestionRecords.public(routed)
  end

  test "pruned checkpointed events never republish on recovery or exact repeats", c do
    {routed, events} = create(c)
    {bound, events} = PeerQuestionRecords.bind(c.dir, events, routed, c.response)
    cursor = ExecutionEvents.query(events, nil, 100)["next_cursor"]

    events =
      Enum.reduce(1..257, events, fn number, store ->
        run = %{
          id:
            "turn-" <>
              (number
               |> Integer.to_string(16)
               |> String.downcase()
               |> String.pad_leading(16, "0")),
          worker_id: "alpha",
          state: "running",
          backend: "claude",
          started_at: "2026-11-07T10:00:00Z"
        }

        ExecutionEvents.append(c.dir, store, run)
      end)

    assert length(events["events"]) == 256
    assert Enum.all?(events["events"], &(&1["kind"] == "execution_accepted"))
    assert_raise ArgumentError, ~r/stale/, fn -> ExecutionEvents.query(events, cursor, 100) end
    assert PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir)) == events
    assert PeerQuestionRecords.create(c.dir, events, c.question, c.source) == {bound, events}
    assert PeerQuestionRecords.bind(c.dir, events, routed, c.response) == {bound, events}
  end

  test "corrupt metadata, outbox and oversized records fail closed", c do
    {record, events} = create(c)
    event = transition(events)

    corrupt = [
      Map.put(record, "payload", "private"),
      Map.put(record, "version", 2),
      Map.put(record, "worker_id", "../outside"),
      Map.put(record, "peer_worker_id", "alpha"),
      Map.put(record, "question_ref", "/outside"),
      Map.put(record, "record_ref", "/outside"),
      Map.put(record, "provenance", "authenticated"),
      Map.put(record, "response_turn_id", @response),
      Map.put(record, "bound_at", record["created_at"]),
      Map.put(record, "created_at", "invalid"),
      Map.put(record, "revision", 3),
      Map.put(record, "published_revision", 2),
      Map.put(record, "transitions", [event]),
      Map.merge(record, %{
        "published_revision" => 0,
        "transitions" => [Map.put(event, "peer_worker_id", "other")]
      }),
      Map.merge(record, %{
        "published_revision" => 0,
        "transitions" => [Map.put(event, "timestamp", "2026-01-01T00:00:00Z")]
      }),
      Map.merge(record, %{
        "revision" => 2,
        "published_revision" => 2,
        "response_turn_id" => @source,
        "bound_at" => record["created_at"]
      })
    ]

    path = Path.join(c.dir, record["record_ref"])

    for bytes <-
          Enum.map(corrupt, &JSON.encode!/1) ++ ["{", "null", String.duplicate(" ", 16_385)] do
      File.write!(path, bytes)
      assert_raise PeerQuestionRecords.StorageError, fn -> load(c) end

      assert_raise PeerQuestionRecords.StorageError, fn ->
        PeerQuestionRecords.recover(c.dir, events)
      end

      assert File.read!(path) == bytes
    end
  end

  test "missing nullable fields cannot hide behind unknown metadata", c do
    {record, events} = create(c)

    for key <- ["response_turn_id", "bound_at"] do
      save(c, record |> Map.delete(key) |> Map.put("unexpected", nil))
      assert_raise PeerQuestionRecords.StorageError, fn -> load(c) end

      assert_raise PeerQuestionRecords.StorageError, fn ->
        PeerQuestionRecords.recover(c.dir, events)
      end
    end
  end

  for revision <- [1, 2] do
    test "revision #{revision} publication failure retains recoverable durable intent", c do
      {record, events} =
        if unquote(revision) == 1, do: {nil, c.events}, else: create(c)

      temporary_journal = Path.join(c.dir, "execution-events.json.tmp")
      File.mkdir!(temporary_journal)

      assert_raise PeerQuestionRecords.StorageError, fn ->
        if unquote(revision) == 1 do
          create(c)
        else
          PeerQuestionRecords.bind(c.dir, events, record, c.response)
        end
      end

      pending = load(c)
      assert pending["revision"] == unquote(revision)
      assert pending["published_revision"] == unquote(revision) - 1
      assert length(pending["transitions"]) == 1
      File.rmdir!(temporary_journal)
      recovered = PeerQuestionRecords.recover(c.dir, ExecutionEvents.open(c.dir))
      assert recovered["sequence"] == unquote(revision)
      published = load(c)
      assert published["published_revision"] == unquote(revision)
      assert published["transitions"] == []
      assert PeerQuestionRecords.recover(c.dir, recovered) == recovered
    end
  end

  test "copied valid records cannot change path ownership", c do
    {record, _} = create(c)
    other = "question-ff"

    File.write!(
      Path.join(c.dir, PeerQuestionRecords.reference(@sender, other)),
      JSON.encode!(record)
    )

    assert_raise PeerQuestionRecords.StorageError, ~r/ownership/, fn ->
      PeerQuestionRecords.load(c.dir, @sender, other)
    end
  end

  test "retained checkpoint evidence rejects conflicting attribution", c do
    {record, events} = create(c)

    for key <- ["worker_id", "peer_worker_id"] do
      save(c, Map.put(record, key, "other"))

      assert_raise PeerQuestionRecords.StorageError, ~r/Conflicting retained/, fn ->
        PeerQuestionRecords.recover(c.dir, events)
      end
    end
  end

  test "recovery filters non-turn directories but rejects unexpected peer record names", c do
    File.mkdir_p!(Path.join(c.dir, "turns/not-a-turn/peer-questions"))
    File.write!(Path.join(c.dir, "turns/not-a-turn/peer-questions/bad.json"), "{")
    {record, events} = create(c)
    folder = Path.dirname(Path.join(c.dir, record["record_ref"]))
    File.write!(Path.join(folder, "unfinished.tmp"), "{")
    assert PeerQuestionRecords.recover(c.dir, events) == events
    File.write!(Path.join(folder, "bad.json"), "{")

    assert_raise PeerQuestionRecords.StorageError, ~r/filename/, fn ->
      PeerQuestionRecords.recover(c.dir, events)
    end
  end

  test "record and temporary file links cannot redirect reads or writes", c do
    {record, events} = create(c)
    path = Path.join(c.dir, record["record_ref"])
    outside = Path.join(c.dir, "outside.json")
    bytes = File.read!(path)
    File.write!(outside, bytes)
    File.rm!(path)
    File.ln_s!(outside, path)
    assert_raise PeerQuestionRecords.StorageError, fn -> load(c) end
    File.rm!(path)
    File.ln!(outside, path)
    assert_raise PeerQuestionRecords.StorageError, fn -> load(c) end
    File.rm!(path)
    File.write!(path, bytes)

    for link <- [:symlink, :hardlink] do
      temp = path <> ".tmp"
      if link == :symlink, do: File.ln_s!(outside, temp), else: File.ln!(outside, temp)

      assert_raise PeerQuestionRecords.StorageError, fn ->
        PeerQuestionRecords.bind(c.dir, events, record, c.response)
      end

      assert File.read!(outside) == bytes
      assert File.read!(path) == bytes
      File.rm!(temp)
    end
  end

  test "symlinked peer directories refuse new records and recovery", c do
    outside = Path.join(c.dir, "outside")
    File.mkdir_p!(outside)
    turn = Path.join([c.dir, "turns", @sender])
    File.mkdir_p!(turn)
    File.ln_s!(outside, Path.join(turn, "peer-questions"))
    assert_raise PeerQuestionRecords.StorageError, fn -> create(c) end

    assert_raise PeerQuestionRecords.StorageError, fn ->
      PeerQuestionRecords.recover(c.dir, c.events)
    end

    assert File.ls!(outside) == []
  end
end
