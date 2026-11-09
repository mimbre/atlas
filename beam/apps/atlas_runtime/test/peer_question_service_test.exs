defmodule AtlasRuntime.PeerQuestionServiceTest do
  use ExUnit.Case, async: false

  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.{PeerQuestionRecords, QuestionRecords, Service}

  @moduletag capture_log: true
  @other "turn-0000000000000001"

  setup do
    dir = Path.join("/tmp", "apq-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}")
    bin = Path.join(dir, "bin")
    sender_workspace = Path.join(dir, "sender")
    peer_workspace = Path.join(dir, "peer")
    Enum.each([bin, sender_workspace, peer_workspace], &File.mkdir_p!/1)
    executable = Path.join(bin, "claude")
    AtlasRuntime.FakeNative.install!(executable, "peer")
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    on_exit(fn ->
      System.put_env("PATH", previous_path)
      File.rm_rf!(dir)
    end)

    pid = launch(dir)
    source = start(pid, "beta", peer_workspace, false)
    sender = start(pid, "alpha", sender_workspace, true)
    %{dir: dir, service: pid, source: source, sender: sender,
      sender_workspace: sender_workspace, peer_workspace: peer_workspace}
  end

  defp launch(dir) do
    File.rm(Path.join(dir, "runtime.sock"))
    {:ok, pid} = GenServer.start(Service, dir)
    on_exit(fn -> stop_service(pid) end)
    pid
  end

  defp stop_service(pid) do
    if Process.alive?(pid) do
      agents = for {_id, worker} <- :sys.get_state(pid).workers, is_pid(worker.agent), do: worker.agent
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      Enum.each(agents, &Native.stop/1)
    end
  end

  defp call(pid, request) do
    {reply, false} = GenServer.call(pid, request, 10_000)
    reply
  end

  defp ok(pid, request) do
    reply = call(pid, request)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    reply
  end

  defp await_run(pid, worker, predicate, remaining \\ 500) do
    run = ok(pid, %{"command" => "status", "worker_id" => worker})
    cond do
      predicate.(run) -> run
      remaining == 0 -> flunk("Missing native fixture lifecycle evidence: #{inspect(run)}")
      true ->
        Process.sleep(10)
        await_run(pid, worker, predicate, remaining - 1)
    end
  end

  defp start(pid, worker, cwd, questions) do
    ok(pid, %{"command" => "start", "worker_id" => worker, "cwd" => cwd,
      "assignment" => "Synthetic peer record fixture", "backend" => "claude", "questions_enabled" => questions})
    if questions,
      do: await_run(pid, worker, & &1.pending_question),
      else: await_run(pid, worker, &(&1.state == "finished"))
  end

  defp continuation(context, source \\ nil) do
    source = source || context.source
    run = ok(context.service, %{"command" => "continue", "worker_id" => "beta",
      "turn_id" => source.id, "assignment" => "Synthetic response fixture"})
    assert run.source_turn_id == source.id
    run = await_run(context.service, "beta", &(&1.state == "finished"))
    assert saved(run)["source_turn_id"] == source.id
    run
  end

  defp selector(context, command \\ "peer-question") do
    %{"command" => command, "worker_id" => "alpha", "turn_id" => context.sender.id,
      "question_id" => context.sender.pending_question.id}
  end

  defp route(context) do
    Map.merge(selector(context, "route-peer-question"), %{"peer_worker_id" => "beta",
      "peer_source_turn_id" => context.source.id})
  end

  defp bind(context, response) do
    Map.put(selector(context, "bind-peer-reply"), "response_turn_id", response.id)
  end

  defp saved(run), do: run.artifacts |> Path.join("turn.json") |> File.read!() |> JSON.decode!()
  defp save(run, value), do: File.write!(Path.join(run.artifacts, "turn.json"), JSON.encode!(value))
  defp events(pid) do
    page = ok(pid, %{"command" => "events", "limit" => 100})
    refute page["has_more"]
    page["events"]
  end
  defp peer_events(pid), do: Enum.filter(events(pid), &(&1["kind"] in ["peer_question_routed", "peer_reply_bound"]))

  defp evidence(context) do
    state = :sys.get_state(context.service)
    workers = state.workers
    files = Path.wildcard(Path.join([context.dir, "turns", "*", "turn.json"])) ++
      Path.wildcard(Path.join([context.dir, "turns", "*", "questions", "*.json"])) ++
      Path.wildcard(Path.join([context.dir, "*", "fixture-*.jsonl"]))
    %{workers: workers, files: Map.new(files, &{&1, File.read!(&1)}),
      dispatch_counts: Map.new(Enum.filter(files, &String.ends_with?(&1, ".jsonl")), fn path ->
        {path, path |> File.read!() |> String.split("\n", trim: true) |> length()}
      end)}
  end

  test "route and bind preserve pending native evidence and dispatch nothing even while peer is busy", context do
    response = continuation(context)
    busy = start(context.service, "beta", context.peer_workspace, true)
    refute busy.id in [context.source.id, response.id]
    before = evidence(context)
    assert before.dispatch_counts[Path.join(context.sender_workspace, "fixture-launches.jsonl")] == 1
    assert before.dispatch_counts[Path.join(context.peer_workspace, "fixture-launches.jsonl")] == 3
    assert before.dispatch_counts[Path.join(context.sender_workspace, "fixture-inputs.jsonl")] == 2
    refute File.exists?(Path.join(context.sender_workspace, "fixture-answers.jsonl"))
    routed = ok(context.service, route(context))
    assert routed == %{"worker_id" => "alpha", "turn_id" => context.sender.id,
      "question_id" => context.sender.pending_question.id,
      "question_ref" => context.sender.pending_question.record_ref,
      "peer_worker_id" => "beta", "peer_source_turn_id" => context.source.id,
      "response_turn_id" => nil, "record_ref" => "turns/#{context.sender.id}/peer-questions/#{context.sender.pending_question.id}.json",
      "provenance" => "coordinator_routed_declaration", "created_at" => routed["created_at"],
      "bound_at" => nil, "revision" => 1}
    assert ok(context.service, selector(context)) == routed
    bound = ok(context.service, bind(context, response))
    assert bound["response_turn_id"] == response.id
    assert bound["revision"] == 2
    assert is_binary(bound["bound_at"])
    assert ok(context.service, route(context)) == routed
    assert ok(context.service, bind(context, response)) == bound
    assert ok(context.service, selector(context)) == bound
    assert evidence(context) == before
    assert [%{"kind" => "peer_question_routed", "response_turn_id" => nil, "revision" => 1},
            %{"kind" => "peer_reply_bound", "response_turn_id" => response_id, "revision" => 2}] = peer_events(context.service)
    assert response_id == response.id
    assert Enum.all?(peer_events(context.service), &(map_size(&1) == 11))
    assert Enum.count(events(context.service), &(&1["kind"] == "question_available")) == 2
  end

  test "commands require exact selectors and reject extra payload or authority fields", context do
    requests = [route(context), selector(context), bind(context, %{id: @other})]
    before = evidence(context)
    for request <- requests do
      for field <- Map.keys(request) -- ["command"] do
        assert %{command_error: _} = call(context.service, Map.delete(request, field))
        for value <- [nil, "", "../escape", 7, "UPPERCASE", String.duplicate("a", 65)] do
          assert %{command_error: _} = call(context.service, Map.put(request, field, value))
        end
      end
      for field <- ["question", "answers", "permissions", "request_id", "unknown"] do
        assert %{command_error: _} = call(context.service, Map.put(request, field, "injected"))
      end
    end
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_worker_id", "alpha"))
    assert %{command_error: _} = call(context.service, selector(context))
    assert %{command_error: _} = call(context.service, bind(context, %{id: @other}))
    assert evidence(context) == before
    assert peer_events(context.service) == []
    ok(context.service, route(context))
    for request <- requests do
      assert %{command_error: _} = call(context.service, Map.put(request, "worker_id", "gamma"))
    end
  end

  test "route requires the actual saved peer owner, finished state and confirmed session", context do
    source_path = Path.join(context.source.artifacts, "turn.json")
    source_bytes = File.read!(source_path)
    source = JSON.decode!(source_bytes)
    before = evidence(context)
    invalid = [Map.delete(source, "worker_id"), Map.put(source, "worker_id", "gamma"),
      Map.put(source, "id", @other), Map.put(source, "state", "running"),
      Map.put(source, "state", "failed"), Map.put(source, "state", "stopped"),
      Map.delete(source, "session_id"), Map.put(source, "session_id", " ")]
    for changed <- invalid do
      save(context.source, changed)
      assert %{command_error: _} = call(context.service, route(context))
    end
    File.write!(source_path, source_bytes)
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_source_turn_id", @other))
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_worker_id", "gamma"))
    assert peer_events(context.service) == []
    assert evidence(context) == before
    assert %{"revision" => 1} = ok(context.service, route(context))
  end

  test "bind requires exact saved continuation, not a shared native session or inferred legacy source", context do
    routed = ok(context.service, route(context))
    response = continuation(context)
    wrong_source = continuation(context, response)
    assert response.session_id == wrong_source.session_id
    assert %{command_error: _} = call(context.service, bind(context, wrong_source))
    response_path = Path.join(response.artifacts, "turn.json")
    original_bytes = File.read!(response_path)
    original = JSON.decode!(original_bytes)
    changes = [%{"worker_id" => "gamma"}, %{"id" => @other}, %{"state" => "running"},
      %{"state" => "failed"}, %{"state" => "stopped"}, %{"selection" => %{"reason" => "explicit"}},
      %{"selection" => nil}, %{"source_turn_id" => @other}, %{"session_id" => "other-session"},
      %{"backend" => "codex"}, %{"model" => "different-model"}, %{"cwd" => "/other/workspace"},
      %{"sandbox" => "workspace-write"}, %{"permissions" => %{"profile" => "dedicated-repository"}},
      %{"repository" => %{"url" => "https://example.test/other/repo"}}]
    before = evidence(context)
    for changed <- [Map.delete(original, "source_turn_id"), Map.delete(original, "worker_id")] ++
                    Enum.map(changes, &Map.merge(original, &1)) do
      save(response, changed)
      assert %{command_error: _} = call(context.service, bind(context, response))
      assert ok(context.service, selector(context)) == routed
    end
    File.write!(response_path, original_bytes)
    for invalid <- [context.sender, context.source, %{id: @other}] do
      assert %{command_error: _} = call(context.service, bind(context, invalid))
    end
    assert evidence(context) == before
    assert length(peer_events(context.service)) == 1
    assert %{"revision" => 2} = ok(context.service, bind(context, response))
  end

  test "live gate checks native-derived question evidence and durable admission, not caller fields", context do
    response = continuation(context)
    worker = :sys.get_state(context.service).workers["alpha"]
    question = worker.run.pending_question
    changed = [Map.put(worker, :agent, nil),
      put_in(worker.run.worker_id, "gamma"), put_in(worker.run.id, @other),
      put_in(worker.run.state, "stopped"), put_in(worker.run.questions_enabled, false),
      put_in(worker.run.backend, "codex"), put_in(worker.run.pending_question, nil),
      put_in(worker.run.pending_question.id, "question-dead"),
      put_in(worker.run.pending_question.correlation, Map.put(question.correlation, "request_id", "other-request")),
      put_in(worker.run.pending_question.questions, [])]
    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}
    changed = [Map.put(worker, :agent, dead) | changed]
    for altered <- changed do
      :sys.replace_state(context.service, &put_in(&1.workers["alpha"], altered))
      assert %{command_error: _} = call(context.service, route(context))
    end
    :sys.replace_state(context.service, &put_in(&1.workers["alpha"], worker))
    routed = ok(context.service, route(context))
    for altered <- changed do
      :sys.replace_state(context.service, &put_in(&1.workers["alpha"], altered))
      assert ok(context.service, route(context)) == routed
      assert %{command_error: _} = call(context.service, bind(context, response))
    end
    :sys.replace_state(context.service, &put_in(&1.workers["alpha"], worker))
    question_record = QuestionRecords.load(context.dir, context.sender.id, question.id)
    :sys.replace_state(context.service, fn state ->
      {_record, events} = QuestionRecords.admit(context.dir, state.events, question_record, %{"Choose?" => "A"})
      %{state | events: events}
    end)
    assert %{command_error: _} = call(context.service, bind(context, response))
    assert ok(context.service, route(context)) == routed
    assert length(peer_events(context.service)) == 1
    refute File.exists?(Path.join(context.sender_workspace, "fixture-answers.jsonl"))
  end

  for stale <- [:stopped, :replaced, :restarted, :answered], routed? <- [false, true] do
    test "#{stale} sender refuses a new #{if routed?, do: "binding", else: "route"} but preserves old evidence", context do
      response = continuation(context)
      routed = if unquote(routed?), do: ok(context.service, route(context))
      context = stale_sender(context, unquote(stale))
      before = evidence(context)
      request = if unquote(routed?), do: bind(context, response), else: route(context)
      assert %{command_error: _} = call(context.service, request)
      if routed do
        assert ok(context.service, route(context)) == routed
        assert ok(context.service, selector(context)) == routed
      end
      assert evidence(context) == before
      assert length(peer_events(context.service)) == if(unquote(routed?), do: 1, else: 0)
    end
  end

  defp stale_sender(context, :stopped) do
    assert %{state: "stopping"} =
             ok(context.service, %{"command" => "stop", "worker_id" => "alpha", "turn_id" => context.sender.id})
    await_run(context.service, "alpha", &(&1.state == "stopped"))
    context
  end
  defp stale_sender(context, :replaced) do
    context = stale_sender(context, :stopped)
    assert %{released: %{"turn_id" => _}} = ok(context.service, %{"command" => "release", "worker_id" => "alpha"})
    replacement = start(context.service, "alpha", context.sender_workspace, true)
    refute replacement.id == context.sender.id
    refute replacement.pending_question.id == context.sender.pending_question.id
    context
  end
  defp stale_sender(context, :restarted) do
    stop_service(context.service)
    %{context | service: launch(context.dir)}
  end
  defp stale_sender(context, :answered) do
    File.write!(Path.join(context.sender_workspace, "hold-answer"), "")
    request = Map.put(selector(context, "answer"), "answers", %{"Choose?" => "A"})
    assert %{admission: "accepted"} = ok(context.service, request)
    await_file(Path.join(context.sender_workspace, "fixture-answers.jsonl"))
    context
  end

  defp await_file(path, remaining \\ 500) do
    cond do
      File.exists?(path) -> :ok
      remaining == 0 -> flunk("Missing fixture input evidence: #{path}")
      true ->
        Process.sleep(10)
        await_file(path, remaining - 1)
    end
  end

  test "concurrent duplicates serialize and conflicting routes and replies do not replace accepted evidence", context do
    response = continuation(context)
    alternate = continuation(context)
    before = evidence(context)
    routes = for _ <- 1..12, do: Task.async(fn -> call(context.service, route(context)) end)
    assert [routed] = routes |> Task.await_many() |> Enum.uniq()
    assert routed["revision"] == 1
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_source_turn_id", alternate.id))
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_worker_id", "gamma"))
    replies = for candidate <- [response, alternate] |> List.duplicate(6) |> List.flatten() do
      Task.async(fn -> call(context.service, bind(context, candidate)) end)
    end
    replies = Task.await_many(replies)
    assert [bound] = replies |> Enum.reject(&Map.has_key?(&1, :command_error)) |> Enum.uniq()
    assert Enum.count(replies, &Map.has_key?(&1, :command_error)) == 6
    assert bound["response_turn_id"] in [response.id, alternate.id]
    assert ok(context.service, route(context)) == routed
    assert evidence(context) == before
    assert length(peer_events(context.service)) == 2
  end

  test "concurrent conflicting routes keep one immutable peer source", context do
    alternate = continuation(context)
    before = evidence(context)
    tasks = for source <- [context.source, alternate] |> List.duplicate(6) |> List.flatten() do
      Task.async(fn -> call(context.service, Map.put(route(context), "peer_source_turn_id", source.id)) end)
    end
    replies = Task.await_many(tasks)
    assert [routed] = replies |> Enum.reject(&Map.has_key?(&1, :command_error)) |> Enum.uniq()
    assert Enum.count(replies, &Map.has_key?(&1, :command_error)) == 6
    assert routed["peer_source_turn_id"] in [context.source.id, alternate.id]
    assert ok(context.service, selector(context)) == routed
    assert evidence(context) == before
    assert length(peer_events(context.service)) == 1
  end

  test "bound retries survive answered, replaced and restarted sender without re-reading changed turns", context do
    response = continuation(context)
    routed = ok(context.service, route(context))
    bound = ok(context.service, bind(context, response))
    context = stale_sender(context, :answered)
    assert ok(context.service, bind(context, response)) == bound
    context = stale_sender(context, :replaced)
    assert ok(context.service, bind(context, response)) == bound
    journal = peer_events(context.service)
    context = stale_sender(context, :restarted)
    File.rm!(Path.join(context.source.artifacts, "turn.json"))
    save(response, Map.put(saved(response), "worker_id", "gamma"))
    before = evidence(context)
    assert ok(context.service, route(context)) == routed
    assert ok(context.service, bind(context, response)) == bound
    assert ok(context.service, selector(context)) == bound
    assert %{command_error: _} = call(context.service, bind(context, %{id: @other}))
    assert %{command_error: _} = call(context.service, Map.put(route(context), "peer_source_turn_id", @other))
    assert peer_events(context.service) == journal
    assert evidence(context) == before
  end

  test "restart replays unpublished peer events before question invalidation without cross-kind deduplication", context do
    response = continuation(context)
    journal_path = Path.join(context.dir, "execution-events.json")
    prior_journal = File.read!(journal_path)
    routed = ok(context.service, route(context))
    bound = ok(context.service, bind(context, response))
    expected_events = peer_events(context.service)
    record_path = Path.join(context.dir, bound["record_ref"])
    record = JSON.decode!(File.read!(record_path))
    stop_service(context.service)
    pending = Enum.map(expected_events, &Map.delete(&1, "sequence"))
    File.write!(record_path, JSON.encode!(Map.merge(record, %{"published_revision" => 0, "transitions" => pending})))
    File.write!(journal_path, prior_journal)
    pid = launch(context.dir)
    assert ok(pid, selector(context)) == bound
    assert ok(pid, route(context)) == routed
    assert ok(pid, bind(context, response)) == bound
    assert peer_events(pid) == expected_events
    invalidation = Enum.find(events(pid), &(&1["kind"] == "question_invalidated"))
    assert invalidation["sequence"] > List.last(expected_events)["sequence"]
    assert Enum.any?(events(pid), &(&1["kind"] == "question_available" and &1["revision"] == 1))
    checkpoint = PeerQuestionRecords.load(context.dir, context.sender.id, context.sender.pending_question.id)
    assert checkpoint["published_revision"] == 2
    assert checkpoint["transitions"] == []
    journal = events(pid)
    stop_service(pid)
    File.write!(record_path, JSON.encode!(Map.merge(checkpoint, %{"published_revision" => 1, "transitions" => [List.last(pending)]})))
    restarted = launch(context.dir)
    assert events(restarted) == journal
    assert ok(restarted, selector(context)) == bound
  end

  test "publication storage failures remain fatal after the peer record is written", context do
    state = :sys.get_state(context.service)
    File.mkdir!(Path.join(context.dir, "execution-events.json.tmp"))
    assert_raise PeerQuestionRecords.StorageError, fn ->
      Service.handle_call(route(context), {self(), make_ref()}, state)
    end
    record = PeerQuestionRecords.load(context.dir, context.sender.id, context.sender.pending_question.id)
    assert record["revision"] == 1
    assert record["published_revision"] == 0
    assert length(record["transitions"]) == 1
    File.rmdir!(Path.join(context.dir, "execution-events.json.tmp"))
  end
end
