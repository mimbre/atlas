defmodule AtlasRuntime.ExecutionEventsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntime.ExecutionEvents

  @started "2026-11-07T10:00:00Z"
  @ended "2026-11-07T10:01:00Z"

  setup %{tmp_dir: dir} do
    %{dir: dir, path: Path.join(dir, "execution-events.json")}
  end

  @moduletag :tmp_dir

  defp run(id, state \\ "running") do
    %{
      id: "turn-#{id}",
      worker_id: "default",
      backend: "codex",
      model: nil,
      session_id: nil,
      state: state,
      started_at: @started,
      ended_at: @ended,
      selection: %{"reason" => "default"},
      assignment: "private assignment",
      result: "private output",
      error: "private error",
      folder: "/private/artifacts"
    }
  end

  defp cursor_at(reply, sequence) do
    [epoch, _] = String.split(reply["earliest_cursor"], ":")
    epoch <> ":" <> Integer.to_string(sequence)
  end

  defp handoff do
    %{
      "worker_id" => "alpha",
      "turn_id" => "turn-0000000000000001",
      "record_ref" => "turns/turn-0000000000000001/handoff.json",
      "submitted_at" => @ended,
      "handoff" => %{"result" => "Private declaration"},
      "provenance" => "coordinator_submitted_declaration"
    }
  end

  test "handoff events deduplicate exact attribution and replay without declaration contents", %{
    dir: dir
  } do
    initial = ExecutionEvents.open(dir)
    cursor = ExecutionEvents.query(initial, nil, 100)["next_cursor"]
    store = ExecutionEvents.append_handoff(dir, initial, handoff())
    assert ExecutionEvents.append_handoff(dir, store, handoff()) == store
    assert ExecutionEvents.open(dir) == store
    assert [event] = ExecutionEvents.query(store, cursor, 100)["events"]

    assert event == %{
             "sequence" => 1,
             "kind" => "handoff_submitted",
             "timestamp" => @ended,
             "turn_id" => "turn-0000000000000001",
             "worker_id" => "alpha",
             "record_ref" => "turns/turn-0000000000000001/handoff.json"
           }

    for {key, value} <- [{"worker_id", "beta"}, {"submitted_at", @started}] do
      assert_raise ArgumentError, ~r/conflicting handoff event/, fn ->
        ExecutionEvents.append_handoff(dir, store, Map.put(handoff(), key, value))
      end
    end

    assert ExecutionEvents.open(dir) == store
  end

  test "handoff event attribution and references reject malformed input before persistence", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.open(dir)
    before = File.read!(path)

    for {key, value} <- [
          {"worker_id", nil},
          {"worker_id", "Upper"},
          {"worker_id", "../alpha"},
          {"worker_id", String.duplicate("a", 65)},
          {"turn_id", "turn-1"},
          {"turn_id", "../turn-0000000000000001"},
          {"turn_id", nil},
          {"record_ref", "turns/turn-0000000000000002/handoff.json"},
          {"record_ref", "/turns/turn-0000000000000001/handoff.json"},
          {"record_ref", "turns/turn-0000000000000001/../handoff.json"},
          {"record_ref", nil},
          {"submitted_at", "yesterday"},
          {"submitted_at", nil},
          {"submitted_at", String.duplicate("x", 65)}
        ] do
      assert_raise ArgumentError, ~r/invalid handoff event/, fn ->
        ExecutionEvents.append_handoff(dir, store, Map.put(handoff(), key, value))
      end

      assert File.read!(path) == before
    end
  end

  test "reloading rejects extra handoff fields and duplicate turn publication", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.append_handoff(dir, ExecutionEvents.open(dir), handoff())
    [event] = store["events"]

    malformed = [
      %{store | "events" => [Map.put(event, "handoff", %{})]},
      %{store | "events" => [Map.put(event, "worker_id", "../alpha")]},
      %{store | "events" => [Map.put(event, "record_ref", "turns/other/handoff.json")]},
      %{store | "sequence" => 2, "events" => [event, %{event | "sequence" => 2}]}
    ]

    for invalid <- malformed do
      bytes = JSON.encode!(invalid)
      File.write!(path, bytes)
      assert_raise ArgumentError, ~r/execution event journal/, fn -> ExecutionEvents.open(dir) end
      assert File.read!(path) == bytes
    end
  end

  test "handoff publication shares bounded retention and cursor semantics", %{dir: dir} do
    initial = ExecutionEvents.open(dir)
    cursor = ExecutionEvents.query(initial, nil, 100)["next_cursor"]

    store =
      Enum.reduce(1..257, initial, fn number, store ->
        turn =
          "turn-" <>
            (number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(16, "0"))

        record = %{handoff() | "turn_id" => turn, "record_ref" => "turns/#{turn}/handoff.json"}
        ExecutionEvents.append_handoff(dir, store, record)
      end)

    assert length(store["events"]) == 256
    assert ExecutionEvents.open(dir) == store

    assert_raise ArgumentError, ~r/stale execution event cursor/, fn ->
      ExecutionEvents.query(store, cursor, 100)
    end

    page = ExecutionEvents.query(store, nil, 100)
    assert page["retention_gap"]
    assert Enum.map(page["events"], & &1["sequence"]) == Enum.to_list(2..101)
    assert ExecutionEvents.query(store, page["earliest_cursor"], 100)["events"] == page["events"]
  end

  test "opening creates a persistent empty checkpoint without historical synthesis", %{dir: dir} do
    File.mkdir_p!(Path.join(dir, "turns/old-turn"))
    File.write!(Path.join(dir, "turns/old-turn/turn.json"), JSON.encode!(run("old", "finished")))
    store = ExecutionEvents.open(dir)
    reply = ExecutionEvents.query(store, nil, 50)

    assert reply["events"] == []
    assert reply["next_cursor"] == reply["earliest_cursor"]
    assert reply["next_cursor"] =~ ~r/\A[0-9a-f]{32}:0\z/
    assert {:ok, _, _} = DateTime.from_iso8601(reply["recording_started_at"])
    refute reply["has_more"]
    refute reply["retention_gap"]
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 50) == reply
    assert ExecutionEvents.query(store, reply["next_cursor"], 50) == reply
  end

  test "snapshots preserve acceptance, terminal kinds and native identity across reopening", %{
    dir: dir
  } do
    first = run(1)
    finished = %{first | state: "finished", model: "native-model", session_id: "native-session"}

    continuation = %{
      run(2)
      | selection: %{"reason" => "continuation"},
        session_id: "native-session"
    }

    store =
      Enum.reduce(
        [first, finished, continuation, run(2, "failed"), run(3, "stopped")],
        ExecutionEvents.open(dir),
        fn snapshot, store -> ExecutionEvents.append(dir, store, snapshot) end
      )

    reply = ExecutionEvents.query(store, nil, 100)
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 100) == reply
    assert Enum.map(reply["events"], & &1["sequence"]) == [1, 2, 3, 4, 5]

    assert Enum.map(reply["events"], & &1["kind"]) == [
             "execution_accepted",
             "execution_finished",
             "execution_accepted",
             "execution_failed",
             "execution_stopped"
           ]

    [accepted, completed, continued, failed, stopped] = reply["events"]

    assert accepted == %{
             "sequence" => 1,
             "kind" => "execution_accepted",
             "turn_id" => "turn-1",
             "worker_id" => "default",
             "backend" => "codex",
             "model" => nil,
             "session_id" => nil,
             "timestamp" => @started,
             "operation" => "start"
           }

    assert completed == %{
             "sequence" => 2,
             "kind" => "execution_finished",
             "turn_id" => "turn-1",
             "worker_id" => "default",
             "backend" => "codex",
             "model" => "native-model",
             "session_id" => "native-session",
             "timestamp" => @ended
           }

    assert continued["operation"] == "continue"
    assert continued["timestamp"] == @started
    assert continued["session_id"] == "native-session"
    assert failed["timestamp"] == @ended
    assert stopped["timestamp"] == @ended

    for event <- reply["events"],
        field <- ["assignment", "result", "error", "folder", "verified"] do
      refute Map.has_key?(event, field)
    end
  end

  test "pages replay stable prefixes, extend short pages and never skip unreturned events", %{
    dir: dir
  } do
    store = ExecutionEvents.open(dir)
    checkpoint = ExecutionEvents.query(store, nil, 1)["next_cursor"]

    store =
      Enum.reduce(1..3, store, fn id, store -> ExecutionEvents.append(dir, store, run(id)) end)

    first = ExecutionEvents.query(store, checkpoint, 2)

    assert Enum.map(first["events"], & &1["sequence"]) == [1, 2]
    assert first["next_cursor"] == cursor_at(first, 2)
    assert first["has_more"]
    assert ExecutionEvents.query(store, checkpoint, 2) == first

    second = ExecutionEvents.query(store, first["next_cursor"], 2)
    assert Enum.map(second["events"], & &1["sequence"]) == [3]
    refute second["has_more"]

    empty = ExecutionEvents.query(store, second["next_cursor"], 2)
    assert empty["events"] == []
    assert empty["next_cursor"] == second["next_cursor"]
    refute empty["has_more"]

    store = ExecutionEvents.append(dir, store, run(4))
    assert ExecutionEvents.query(store, checkpoint, 2) == first
    extended = ExecutionEvents.query(store, first["next_cursor"], 2)
    assert Enum.map(extended["events"], & &1["sequence"]) == [3, 4]
    assert hd(extended["events"]) == hd(second["events"])
    assert extended["next_cursor"] == cursor_at(first, 4)
    refute extended["has_more"]

    assert ExecutionEvents.query(store, second["next_cursor"], 2)["events"] == [
             List.last(extended["events"])
           ]
  end

  test "query rejects invalid limits and malformed, foreign or future cursors", %{dir: dir} do
    store = ExecutionEvents.open(dir)
    empty = ExecutionEvents.query(store, nil, 100)
    [epoch, _] = String.split(empty["earliest_cursor"], ":")

    for limit <- [0, -1, 101, 1.0, "1", nil, true] do
      assert_raise ArgumentError, ~r/limit.*between 1 and 100/, fn ->
        ExecutionEvents.query(store, nil, limit)
      end
    end

    for cursor <- [
          "",
          "garbage",
          "epoch:0",
          epoch <> ":-1",
          epoch <> ":01",
          epoch <> ":+1",
          epoch <> ":0:1",
          epoch <> ":" <> String.duplicate("9", 100),
          0,
          %{}
        ] do
      assert_raise ArgumentError, ~r/malformed.*cursor/, fn ->
        ExecutionEvents.query(store, cursor, 1)
      end
    end

    foreign = ExecutionEvents.open(Path.join(dir, "foreign"))
    foreign_cursor = ExecutionEvents.query(foreign, nil, 1)["next_cursor"]

    assert_raise ArgumentError, ~r/different stream/, fn ->
      ExecutionEvents.query(store, foreign_cursor, 1)
    end

    assert_raise ArgumentError, ~r/future/, fn ->
      ExecutionEvents.query(store, cursor_at(empty, 1), 1)
    end
  end

  test "retention keeps 256 events, reports gaps and rejects stale checkpoints", %{
    dir: dir,
    path: path
  } do
    initial = ExecutionEvents.open(dir)
    checkpoint = ExecutionEvents.query(initial, nil, 1)["next_cursor"]

    store =
      Enum.reduce(1..260, initial, fn id, store -> ExecutionEvents.append(dir, store, run(id)) end)

    first = ExecutionEvents.query(store, nil, 100)

    assert first["retention_gap"]
    assert first["has_more"]
    assert first["earliest_cursor"] == cursor_at(first, 4)
    assert Enum.map(first["events"], & &1["sequence"]) == Enum.to_list(5..104)
    assert first["next_cursor"] == cursor_at(first, 104)
    assert ExecutionEvents.query(ExecutionEvents.open(dir), nil, 100) == first

    explicit = ExecutionEvents.query(store, first["earliest_cursor"], 100)
    assert explicit["events"] == first["events"]
    refute explicit["retention_gap"]

    second = ExecutionEvents.query(store, first["next_cursor"], 100)
    third = ExecutionEvents.query(store, second["next_cursor"], 100)

    assert Enum.map(first["events"] ++ second["events"] ++ third["events"], & &1["sequence"]) ==
             Enum.to_list(5..260)

    refute third["has_more"]
    assert third["next_cursor"] == cursor_at(first, 260)
    assert File.stat!(path).size < 4 * 1024 * 1024

    for stale <- [checkpoint, cursor_at(first, 3)] do
      error = assert_raise ArgumentError, fn -> ExecutionEvents.query(store, stale, 100) end

      assert error.message ==
               "stale execution event cursor; earliest usable cursor: #{first["earliest_cursor"]}"
    end
  end

  test "corrupt or oversized journals fail closed without changing persisted bytes", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.append(dir, ExecutionEvents.open(dir), run(1))
    [event] = store["events"]

    corrupt = [
      "not JSON",
      "null",
      JSON.encode!(Map.put(store, "version", 2)),
      JSON.encode!(Map.put(store, "epoch", "bad")),
      JSON.encode!(Map.put(store, "recording_started_at", "yesterday")),
      JSON.encode!(Map.put(store, "sequence", -1)),
      JSON.encode!(Map.put(store, "events", [])),
      JSON.encode!(Map.put(store, "events", [%{event | "sequence" => 2}])),
      JSON.encode!(Map.put(store, "events", [%{event | "kind" => "task_verified"}])),
      JSON.encode!(Map.put(store, "events", [%{event | "operation" => "retry"}])),
      JSON.encode!(Map.put(store, "events", [Map.put(event, "result", "private")])),
      JSON.encode!(Map.put(store, "events", [%{event | "model" => String.duplicate("x", 257)}])),
      JSON.encode!(Map.put(store, "unexpected", true)),
      String.duplicate(" ", 4 * 1024 * 1024 + 1)
    ]

    for bytes <- corrupt do
      File.write!(path, bytes)
      assert_raise ArgumentError, ~r/execution event journal/, fn -> ExecutionEvents.open(dir) end
      assert File.read!(path) == bytes
    end
  end

  test "upgraded journals preserve unattributed history and interleaved worker checkpoints", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.append(dir, ExecutionEvents.open(dir), run(1))
    legacy = %{store | "events" => Enum.map(store["events"], &Map.delete(&1, "worker_id"))}
    File.write!(path, JSON.encode!(legacy))
    reopened = ExecutionEvents.open(dir)
    checkpoint = ExecutionEvents.query(reopened, nil, 100)["next_cursor"]

    store =
      Enum.reduce(
        [{"server", "running"}, {"console", "running"}, {"server", "stopped"}],
        reopened,
        fn {worker, state}, acc ->
          ExecutionEvents.append(dir, acc, %{run(worker, state) | worker_id: worker})
        end
      )

    assert hd(store["events"]) == hd(legacy["events"])
    page = ExecutionEvents.query(ExecutionEvents.open(dir), checkpoint, 2)

    assert Enum.map(page["events"], &{&1["worker_id"], &1["kind"]}) ==
             [{"server", "execution_accepted"}, {"console", "execution_accepted"}]

    assert page["has_more"]
    last = ExecutionEvents.query(store, page["next_cursor"], 2)

    assert Enum.map(last["events"], &{&1["worker_id"], &1["kind"]}) ==
             [{"server", "execution_stopped"}]

    refute last["has_more"]
  end

  test "maximum escaped identity fields keep a full page below the socket response cap", %{
    dir: dir
  } do
    largest = %{
      run(1)
      | id: String.duplicate("\u0000", 128),
        backend: String.duplicate("\u0000", 64),
        model: String.duplicate("\u0000", 256),
        worker_id: String.duplicate("w", 64),
        session_id: String.duplicate("\u0000", 1024)
    }

    store =
      Enum.reduce(1..100, ExecutionEvents.open(dir), fn _, store ->
        ExecutionEvents.append(dir, store, largest)
      end)

    response = ExecutionEvents.query(store, nil, 100)
    assert length(response["events"]) == 100
    assert byte_size(JSON.encode!(response)) + 1 < 1_048_576
  end

  test "invalid snapshots cannot change the journal", %{dir: dir, path: path} do
    store = ExecutionEvents.open(dir)
    bytes = File.read!(path)

    for snapshot <- [
          %{run(1) | worker_id: "../server"},
          %{run(1) | worker_id: String.duplicate("w", 65)},
          %{run(1) | worker_id: nil},
          %{run(1) | id: String.duplicate("x", 129)},
          %{run(1) | backend: String.duplicate("x", 65)},
          %{run(1) | model: String.duplicate("x", 257)},
          %{run(1) | session_id: String.duplicate("x", 1025)},
          %{run(1) | started_at: "not a timestamp"},
          %{run(1) | state: "idle"}
        ] do
      assert_raise ArgumentError, fn -> ExecutionEvents.append(dir, store, snapshot) end
      assert File.read!(path) == bytes
    end
  end

  test "question references interleave with execution events and deduplicate exact revisions", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.append(dir, ExecutionEvents.open(dir), run(1))
    checkpoint = ExecutionEvents.query(store, nil, 100)["next_cursor"]

    transition = %{
      "kind" => "question_available",
      "worker_id" => "alpha",
      "turn_id" => "turn-0000000000000001",
      "question_id" => "question-ab12",
      "record_ref" => "turns/turn-0000000000000001/questions/question-ab12.json",
      "revision" => 1,
      "timestamp" => @started
    }

    store = ExecutionEvents.append_question(dir, store, transition)
    assert ExecutionEvents.append_question(dir, store, transition) == store
    bytes = File.read!(path)

    assert_raise ArgumentError, ~r/conflicting/, fn ->
      ExecutionEvents.append_question(dir, store, %{transition | "kind" => "answer_accepted"})
    end

    assert File.read!(path) == bytes

    store =
      ExecutionEvents.append_question(dir, store, %{
        transition
        | "kind" => "answer_accepted",
          "revision" => 2
      })

    store = ExecutionEvents.append(dir, store, run(1, "finished"))
    reply = ExecutionEvents.query(ExecutionEvents.open(dir), checkpoint, 100)

    assert Enum.map(reply["events"], & &1["kind"]) ==
             ["question_available", "answer_accepted", "execution_finished"]

    assert Enum.map(reply["events"], & &1["sequence"]) == [2, 3, 4]
    assert ExecutionEvents.query(store, checkpoint, 100) == reply

    for invalid <- [
          Map.put(transition, "questions", []),
          %{transition | "question_id" => "../question"},
          %{transition | "revision" => 6},
          %{transition | "worker_id" => "../worker"},
          %{transition | "record_ref" => "/unrelated"}
        ] do
      assert_raise ArgumentError, fn -> ExecutionEvents.append_question(dir, store, invalid) end
    end
  end

  defp peer_transition do
    %{
      "kind" => "peer_question_routed",
      "worker_id" => "alpha",
      "turn_id" => "turn-0000000000000001",
      "question_id" => "question-ab12",
      "peer_worker_id" => "beta",
      "peer_source_turn_id" => "turn-0000000000000002",
      "response_turn_id" => nil,
      "revision" => 1,
      "timestamp" => @started,
      "record_ref" => "turns/turn-0000000000000001/peer-questions/question-ab12.json"
    }
  end

  test "peer and native question revisions use distinct namespaces in either append order", %{
    dir: dir
  } do
    peer = peer_transition()

    question =
      peer
      |> Map.drop(~w(peer_worker_id peer_source_turn_id response_turn_id))
      |> Map.merge(%{
        "kind" => "question_available",
        "record_ref" => "turns/turn-0000000000000001/questions/question-ab12.json"
      })

    for order <- [:peer_first, :question_first] do
      folder = Path.join(dir, Atom.to_string(order))
      store = ExecutionEvents.open(folder)
      cursor = ExecutionEvents.query(store, nil, 100)["next_cursor"]

      store =
        if order == :peer_first do
          store = ExecutionEvents.append_peer_question(folder, store, peer)
          ExecutionEvents.append_question(folder, store, question)
        else
          store = ExecutionEvents.append_question(folder, store, question)
          ExecutionEvents.append_peer_question(folder, store, peer)
        end

      assert ExecutionEvents.append_question(folder, store, question) == store
      assert ExecutionEvents.append_peer_question(folder, store, peer) == store

      bound = %{
        peer
        | "kind" => "peer_reply_bound",
          "revision" => 2,
          "response_turn_id" => "turn-0000000000000003",
          "timestamp" => @ended
      }

      store = ExecutionEvents.append_peer_question(folder, store, bound)
      assert ExecutionEvents.append_peer_question(folder, store, bound) == store
      assert ExecutionEvents.open(folder) == store
      assert [first, second, last] = ExecutionEvents.query(store, cursor, 100)["events"]

      assert Enum.sort([first["kind"], second["kind"]]) == [
               "peer_question_routed",
               "question_available"
             ]

      assert Map.delete(last, "sequence") == bound
      assert last["sequence"] == 3
      assert map_size(last) == 11

      assert_raise ArgumentError, ~r/conflicting peer question/, fn ->
        ExecutionEvents.append_peer_question(
          folder,
          store,
          Map.put(peer, "peer_worker_id", "gamma")
        )
      end
    end
  end

  test "peer event shape, revisions and references reject malformed inputs", %{
    dir: dir,
    path: path
  } do
    store = ExecutionEvents.open(dir)
    before = File.read!(path)
    peer = peer_transition()

    for invalid <- [
          Map.put(peer, "answer", "private"),
          Map.put(peer, "question_id", "question-"),
          Map.put(peer, "worker_id", "../alpha"),
          Map.put(peer, "peer_worker_id", "alpha"),
          Map.put(peer, "peer_worker_id", String.duplicate("a", 65)),
          Map.put(peer, "peer_source_turn_id", peer["turn_id"]),
          Map.put(peer, "peer_source_turn_id", "../outside"),
          Map.put(peer, "revision", 2),
          Map.put(peer, "record_ref", "turns/turn-0000000000000001/questions/question-ab12.json"),
          Map.put(peer, "response_turn_id", "turn-0000000000000003"),
          Map.put(peer, "timestamp", "bad"),
          Map.merge(peer, %{"kind" => "peer_reply_bound", "revision" => 2}),
          Map.merge(peer, %{
            "kind" => "peer_reply_bound",
            "revision" => 2,
            "response_turn_id" => peer["peer_source_turn_id"]
          }),
          Map.merge(peer, %{
            "kind" => "peer_reply_bound",
            "revision" => 2,
            "response_turn_id" => peer["turn_id"]
          })
        ] do
      assert_raise ArgumentError, ~r/invalid peer question event/, fn ->
        ExecutionEvents.append_peer_question(dir, store, invalid)
      end

      assert File.read!(path) == before
    end

    assert_raise ArgumentError, fn -> ExecutionEvents.append_question(dir, store, peer) end
  end

  test "peer event reload rejects duplicate revisions and corrupt attributed replay", %{
    dir: dir,
    path: path
  } do
    store =
      ExecutionEvents.append_peer_question(dir, ExecutionEvents.open(dir), peer_transition())

    [event] = store["events"]

    for invalid <- [
          %{store | "events" => [Map.put(event, "answer", "private")]},
          %{store | "events" => [Map.put(event, "peer_worker_id", event["worker_id"])]},
          %{store | "events" => [Map.put(event, "response_turn_id", "turn-0000000000000003")]},
          %{store | "sequence" => 2, "events" => [event, %{event | "sequence" => 2}]},
          %{
            store
            | "sequence" => 2,
              "events" => [event, %{event | "sequence" => 2, "peer_worker_id" => "gamma"}]
          }
        ] do
      bytes = JSON.encode!(invalid)
      File.write!(path, bytes)
      assert_raise ArgumentError, ~r/execution event journal/, fn -> ExecutionEvents.open(dir) end
      assert File.read!(path) == bytes
    end
  end
end
