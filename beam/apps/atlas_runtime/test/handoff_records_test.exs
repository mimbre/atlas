defmodule AtlasRuntime.HandoffRecordsTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.{ExecutionEvents, HandoffRecords}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    run = %{"worker_id" => "alpha", "turn_id" => "turn-0000000000000001", "repository" => nil}

    declaration = %{
      "kind" => "completion",
      "repository_url" => "https://github.com/Eyra/Atlas.git",
      "branch" => "work/handoff",
      "base_sha" => String.duplicate("a", 40),
      "head_sha" => String.duplicate("b", 40),
      "result" => "Added explicit handoff records.",
      "verification" => ["mix test: passed"],
      "limits" => ["No native authentication"],
      "remaining_processes" => []
    }

    %{dir: dir, run: run, declaration: declaration, events: ExecutionEvents.open(dir)}
  end

  test "stores the exact declaration, fixed provenance and reference-only publication", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)
    public = HandoffRecords.public(record)

    assert Enum.sort(Map.keys(public)) ==
             ~w(handoff provenance record_ref submitted_at turn_id worker_id)

    assert public["handoff"] == declaration
    assert public["worker_id"] == run["worker_id"]
    assert public["turn_id"] == run["turn_id"]
    assert public["record_ref"] == "turns/#{run["turn_id"]}/handoff.json"
    assert public["provenance"] == "coordinator_submitted_declaration"
    assert record["published"]
    assert {:ok, _, _} = DateTime.from_iso8601(public["submitted_at"])
    assert record == HandoffRecords.load(dir, run["turn_id"])
    assert events == ExecutionEvents.open(dir)

    assert events["events"] == [
             %{
               "sequence" => 1,
               "kind" => "handoff_submitted",
               "worker_id" => run["worker_id"],
               "turn_id" => run["turn_id"],
               "record_ref" => public["record_ref"],
               "timestamp" => public["submitted_at"]
             }
           ]

    assert HandoffRecords.recover(dir, ExecutionEvents.open(dir)) == events
    assert HandoffRecords.load(dir, "turn-0000000000000002") == nil
  end

  test "managed identity binds URL, branch and base while preserving original declaration",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    repository = %{
      "url" => "https://github.com/eyra/atlas",
      "branch" => declaration["branch"],
      "base_sha" => declaration["base_sha"]
    }

    managed = Map.put(run, "repository", repository)

    for {field, other} <- [
          {"repository_url", "https://github.com/eyra/other"},
          {"branch", "other"},
          {"base_sha", String.duplicate("c", 40)}
        ] do
      assert_raise ArgumentError, ~r/does not match saved repository/, fn ->
        HandoffRecords.submit(dir, events, managed, Map.put(declaration, field, other))
      end

      assert HandoffRecords.load(dir, run["turn_id"]) == nil
      assert ExecutionEvents.open(dir) == events
    end

    {record, _events} = HandoffRecords.submit(dir, events, managed, declaration)
    assert record["handoff"] == declaration
    assert record["handoff"]["head_sha"] != repository["base_sha"]
  end

  test "partial managed metadata binds only present fields without inferring missing declarations",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    run = Map.put(run, "repository", %{"url" => "https://github.com/eyra/atlas"})

    assert_raise ArgumentError, fn ->
      HandoffRecords.submit(dir, events, run, Map.delete(declaration, "base_sha"))
    end

    {record, _events} = HandoffRecords.submit(dir, events, run, declaration)
    assert record["handoff"] == declaration
  end

  test "PR declarations require a matching positive GitHub pull URL; completion forbids it",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    pr = Map.put(declaration, "kind", "pull_request")
    invalid = [pr, Map.put(declaration, "pr_url", "https://github.com/eyra/atlas/pull/12")]

    invalid =
      invalid ++
        Enum.map(
          [
            nil,
            12,
            "https://github.com/eyra/other/pull/12",
            "https://github.com/other/atlas/pull/12",
            "https://github.com/eyra/atlas/pull/0",
            "https://github.com/eyra/atlas/pull/-1",
            "https://github.com/eyra/atlas/pull/01",
            "https://github.com/eyra/atlas/issues/12",
            "https://github.com/eyra/atlas/pull/12?x=1",
            "https://github.com/eyra/atlas/pull/12#x",
            "https://user@github.com/eyra/atlas/pull/12",
            "https://github.com:443/eyra/atlas/pull/12",
            "http://github.com/eyra/atlas/pull/12",
            "https://github.com/eyra/atlas/pull/12/"
          ],
          &Map.put(pr, "pr_url", &1)
        )

    for bad <- invalid do
      assert_raise ArgumentError, fn -> HandoffRecords.submit(dir, events, run, bad) end
    end

    # URL validation is syntactic; this declaration does not prove PR existence or acceptance.
    pr = Map.put(pr, "pr_url", "https://github.com/EYRA/ATLAS/pull/154")
    {record, _events} = HandoffRecords.submit(dir, events, run, pr)
    assert record["handoff"] == pr
  end

  test "rejects non-GitHub, ambiguous, credentialed and decorated repository URLs", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    for url <- [
          nil,
          1,
          "",
          "https://github.com/eyra",
          "https://github.com/eyra/atlas/",
          "https://github.com/eyra/atlas?x=1",
          "https://github.com/eyra/atlas#x",
          "https://user:secret@github.com/eyra/atlas",
          "https://github.com:443/eyra/atlas",
          "http://github.com/eyra/atlas",
          "https://github.com.evil/eyra/atlas",
          "git@github.com:eyra/atlas.git",
          "https://github.com/eyra/%61tlas",
          "https://github.com/eyra/..",
          "https://github.com/eyra/.git",
          "https://github.com/eyra/atlas\n",
          <<255>>
        ] do
      assert_raise ArgumentError, fn ->
        HandoffRecords.submit(dir, events, run, Map.put(declaration, "repository_url", url))
      end
    end

    assert HandoffRecords.load(dir, run["turn_id"]) == nil
    assert ExecutionEvents.open(dir) == events
  end

  test "requires exact fields, text types, lowercase SHAs and bounded nonblank arrays", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    malformed = [
      nil,
      [],
      "completion",
      %{},
      Map.put(declaration, "trusted", true),
      Map.put(declaration, "provenance", "native"),
      Map.put(declaration, "kind", "accepted")
    ]

    malformed =
      malformed ++
        Enum.flat_map(Map.keys(declaration), fn key ->
          [Map.delete(declaration, key), Map.put(declaration, key, nil)]
        end)

    malformed =
      malformed ++
        Enum.flat_map(~w(branch result), fn key ->
          Enum.map(["", " \n\t", 1, true, [], <<255>>], &Map.put(declaration, key, &1))
        end)

    malformed =
      malformed ++
        Enum.flat_map(~w(base_sha head_sha), fn key ->
          Enum.map(
            [
              String.duplicate("A", 40),
              String.duplicate("g", 40),
              String.duplicate("a", 39),
              String.duplicate("a", 41),
              String.duplicate("a", 63),
              String.duplicate("a", 65),
              String.duplicate("a", 40) <> "\n",
              123,
              <<255>>
            ],
            &Map.put(declaration, key, &1)
          )
        end)

    malformed =
      malformed ++
        Enum.flat_map(~w(verification limits remaining_processes), fn key ->
          Enum.map(
            [
              "passed",
              %{},
              [true],
              [nil],
              [1],
              [[]],
              [""],
              [" \t"],
              [<<255>>],
              [String.duplicate("a", 1025)],
              [String.duplicate("é", 513)],
              List.duplicate("x", 17)
            ],
            &Map.put(declaration, key, &1)
          )
        end)

    for bad <- malformed do
      assert_raise ArgumentError, fn -> HandoffRecords.submit(dir, events, run, bad) end
    end

    assert HandoffRecords.load(dir, run["turn_id"]) == nil
    assert ExecutionEvents.open(dir) == events
  end

  test "byte limits accept exact UTF8 boundaries and both SHA widths", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    boundary =
      Map.merge(declaration, %{
        "branch" => String.duplicate("é", 127) <> "x",
        "result" => String.duplicate("é", 2048),
        "base_sha" => String.duplicate("a", 64),
        "head_sha" => String.duplicate("b", 64),
        "verification" => List.duplicate(String.duplicate("é", 512), 16),
        "limits" => [],
        "remaining_processes" => List.duplicate("process still running", 16)
      })

    for bad <- [
          Map.put(boundary, "branch", String.duplicate("é", 128)),
          Map.put(boundary, "result", String.duplicate("é", 2048) <> "x")
        ] do
      assert_raise ArgumentError, fn -> HandoffRecords.submit(dir, events, run, bad) end
    end

    {record, _events} = HandoffRecords.submit(dir, events, run, boundary)
    assert record["handoff"] == boundary
  end

  test "encoded aggregate limit includes JSON escaping and accepts exactly 32768 bytes",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    declaration =
      Map.merge(declaration, %{
        "verification" => List.duplicate(String.duplicate("x", 1024), 16),
        "limits" => List.duplicate(String.duplicate("x", 1024), 15),
        "remaining_processes" => []
      })

    padding = 32_768 - byte_size(JSON.encode!(declaration))

    declaration =
      Map.put(declaration, "result", declaration["result"] <> String.duplicate("x", padding))

    assert byte_size(JSON.encode!(declaration)) == 32_768

    for bad <- [
          Map.update!(declaration, "result", &(&1 <> "x")),
          Map.put(declaration, "verification", List.duplicate(String.duplicate("\"", 1024), 16))
        ] do
      assert_raise ArgumentError, ~r/Oversized/, fn ->
        HandoffRecords.submit(dir, events, run, bad)
      end
    end

    {record, _events} = HandoffRecords.submit(dir, events, run, declaration)
    assert record["handoff"] == declaration
  end

  test "duplicates retain bytes and timestamp; changed declaration or worker conflicts",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)
    bytes = File.read!(Path.join(dir, record["record_ref"]))
    retry_run = Map.put(run, "repository", %{"base_sha" => String.duplicate("c", 40)})
    assert HandoffRecords.submit(dir, events, retry_run, declaration) == {record, events}
    assert File.read!(Path.join(dir, record["record_ref"])) == bytes

    for changed <- [
          Map.put(declaration, "result", "different"),
          Map.put(declaration, "repository_url", "https://github.com/eyra/atlas")
        ] do
      assert_raise ArgumentError, ~r/Conflicting/, fn ->
        HandoffRecords.submit(dir, events, run, changed)
      end
    end

    assert_raise ArgumentError, ~r/Conflicting/, fn ->
      HandoffRecords.submit(dir, events, Map.put(run, "worker_id", "beta"), declaration)
    end

    assert HandoffRecords.load(dir, run["turn_id"]) == record
    assert ExecutionEvents.open(dir) == events
  end

  test "malformed target identifiers cannot escape record paths", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context

    for turn <- [nil, "../outside", run["turn_id"] <> "/../other", "turn-1"] do
      assert_raise ArgumentError, fn -> HandoffRecords.load(dir, turn) end

      assert_raise ArgumentError, fn ->
        HandoffRecords.submit(dir, events, Map.put(run, "turn_id", turn), declaration)
      end
    end

    for worker <- [nil, "../alpha", "Alpha", "alpha\n"] do
      assert_raise ArgumentError, fn ->
        HandoffRecords.submit(dir, events, Map.put(run, "worker_id", worker), declaration)
      end
    end
  end

  test "record-before-journal crash publishes original timestamp once", context do
    %{dir: dir, run: run, declaration: declaration, events: before} = context
    journal = Path.join(dir, "execution-events.json")
    bytes = File.read!(journal)
    {record, expected} = HandoffRecords.submit(dir, before, run, declaration)
    save(dir, Map.put(record, "published", false))
    File.write!(journal, bytes)
    recovered = HandoffRecords.recover(dir, ExecutionEvents.open(dir))
    assert recovered == expected
    assert HandoffRecords.load(dir, run["turn_id"]) == record
    assert HandoffRecords.recover(dir, ExecutionEvents.open(dir)) == recovered
  end

  test "journal-before-checkpoint crash deduplicates exact turn and kind", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)
    save(dir, Map.put(record, "published", false))
    assert HandoffRecords.recover(dir, ExecutionEvents.open(dir)) == events
    assert HandoffRecords.load(dir, run["turn_id"]) == record
    save(dir, Map.put(record, "published", false))
    assert HandoffRecords.submit(dir, events, run, declaration) == {record, events}
  end

  test "identical declarations on distinct turns retain independent worker attribution",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {first, events} = HandoffRecords.submit(dir, events, run, declaration)
    other = Map.merge(run, %{"worker_id" => "beta", "turn_id" => "turn-0000000000000002"})
    {second, events} = HandoffRecords.submit(dir, events, other, declaration)
    assert first["record_ref"] != second["record_ref"]
    assert first["worker_id"] == "alpha"
    assert second["worker_id"] == "beta"

    assert Enum.map(events["events"], &{&1["turn_id"], &1["worker_id"]}) ==
             [{run["turn_id"], "alpha"}, {other["turn_id"], "beta"}]

    assert HandoffRecords.load(dir, run["turn_id"]) == first
    assert HandoffRecords.load(dir, other["turn_id"]) == second
    assert HandoffRecords.recover(dir, ExecutionEvents.open(dir)) == events
  end

  test "checkpointed records survive pruning without republishing", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)

    events =
      Enum.reduce(1..270, events, fn number, store ->
        execution = %{
          id: "turn-" <> String.pad_leading(Integer.to_string(number, 16), 16, "0"),
          worker_id: "alpha",
          state: "running",
          backend: "claude",
          session_id: nil,
          model: nil,
          started_at: "2026-11-07T10:00:00Z"
        }

        ExecutionEvents.append(dir, store, execution)
      end)

    assert length(events["events"]) == 256
    assert Enum.all?(events["events"], &(&1["kind"] == "execution_accepted"))
    assert ExecutionEvents.query(events, nil, 100)["retention_gap"]
    assert HandoffRecords.recover(dir, ExecutionEvents.open(dir)) == events
    assert HandoffRecords.submit(dir, events, run, declaration) == {record, events}
    assert HandoffRecords.load(dir, run["turn_id"]) == record
  end

  test "corrupt authoritative content and publication checkpoints fail closed", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)

    for bad <- [
          Map.put(record, "version", 2),
          Map.put(record, "published", nil),
          Map.put(record, "published", 1),
          Map.put(record, "trusted", true),
          Map.put(record, "provenance", "native_authenticated"),
          Map.put(record, "submitted_at", "invalid"),
          Map.put(record, "turn_id", "turn-0000000000000002"),
          Map.put(record, "record_ref", "turns/turn-0000000000000002/handoff.json"),
          Map.put(record, "worker_id", "../alpha"),
          Map.put(record, "handoff", %{}),
          Map.put(record, "handoff", Map.put(declaration, "trusted", true))
        ] do
      save(dir, bad, record["record_ref"])
      assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.load(dir, run["turn_id"]) end
      assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.recover(dir, events) end
    end

    for bytes <- ["{", "null", String.duplicate(" ", 65_537)] do
      File.write!(Path.join(dir, record["record_ref"]), bytes)
      assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.load(dir, run["turn_id"]) end
    end
  end

  test "conflicting retained publication cannot checkpoint a substituted record", context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)

    for field <- ["worker_id", "submitted_at"], published <- [false, true] do
      value = if field == "worker_id", do: "beta", else: "2026-01-01T00:00:00Z"
      bad = record |> Map.put(field, value) |> Map.put("published", published)
      save(dir, bad)
      assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.recover(dir, events) end
      assert HandoffRecords.load(dir, run["turn_id"])["published"] == published
    end
  end

  test "symlinked record, turn directory and temporary file cannot redirect persistence",
       context do
    %{dir: dir, run: run, declaration: declaration, events: events} = context
    {record, events} = HandoffRecords.submit(dir, events, run, declaration)
    path = Path.join(dir, record["record_ref"])
    outside = Path.join(dir, "outside.json")
    File.rename!(path, outside)
    File.ln_s!(outside, path)
    assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.load(dir, run["turn_id"]) end
    File.rm!(path)
    File.rename!(outside, path)
    folder = Path.dirname(path)
    moved = Path.join(dir, "outside-turn")
    File.rename!(folder, moved)
    File.ln_s!(moved, folder)
    assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.recover(dir, events) end
    File.rm!(folder)
    File.rename!(moved, folder)
    save(dir, Map.put(record, "published", false))
    File.write!(outside, "untouched")
    File.ln_s!(outside, path <> ".tmp")
    assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.recover(dir, events) end
    assert File.read!(outside) == "untouched"
    File.rm!(path <> ".tmp")
    File.ln!(outside, path <> ".tmp")
    assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.recover(dir, events) end
    assert File.read!(outside) == "untouched"
    File.rm!(path <> ".tmp")
    File.ln!(path, Path.join(dir, "linked-record"))
    assert_raise HandoffRecords.StorageError, fn -> HandoffRecords.load(dir, run["turn_id"]) end
  end

  test "recovery ignores unrelated entries using existing turn enumeration conventions",
       context do
    {record, events} =
      HandoffRecords.submit(context.dir, context.events, context.run, context.declaration)

    File.write!(Path.join(context.dir, "turns/.DS_Store"), "unrelated")
    assert HandoffRecords.recover(context.dir, events) == events
    assert HandoffRecords.load(context.dir, context.run["turn_id"]) == record
  end

  defp save(dir, record, reference \\ nil),
    do: File.write!(Path.join(dir, reference || record["record_ref"]), JSON.encode!(record))
end
