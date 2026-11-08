defmodule AtlasRuntime.NativeQuestionTest do
  use ExUnit.Case, async: false
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Interactions.NativeQuestion
  alias AtlasRuntime.{BackendPolicy, ExecutionEvents, Service}
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    workspace = Path.join(dir, "workspace")
    File.mkdir_p!(bin)
    File.mkdir_p!(workspace)
    executable = Path.join(bin, "claude")
    AtlasRuntime.FakeNative.install!(executable, "question")
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)
    %{executable: executable, workspace: workspace,
      state: %{dir: dir, policy: BackendPolicy.empty(), events: ExecutionEvents.open(dir), workers: %{}, stopping: false}}
  end

  defp launch(context, changes \\ %{}) do
    settings = Map.merge(%{"backend" => "claude", "command" => context.executable,
                          "workspace" => context.workspace, "goal" => "Choose", "questions_enabled" => true}, changes)
    Native.start(%{key: "question-turn"}, agent: settings, turns_dir: Path.join(context.tmp_dir, "turns"))
  end

  defp cleanup(pid), do: on_exit(fn -> if Process.alive?(pid), do: Native.stop(pid) end)

  defp assert_source(question, workspace) do
    source = workspace |> Path.join("question-source.json") |> File.read!() |> JSON.decode!()
    assistant = source["assistant"]
    control = source["control_request"]
    tool = hd(assistant["message"]["content"])
    assert question.correlation == %{
      "session_id" => assistant["session_id"], "model" => assistant["message"]["model"],
      "tool_use_id" => tool["id"], "request_id" => control["request_id"],
      "native_pid" => source["native_pid"]
    }
    assert question.correlation["tool_use_id"] == control["request"]["tool_use_id"]
    assert %{"questions" => question.questions} == tool["input"]
    assert tool["input"] == control["request"]["input"]
    assert to_string(question.correlation["native_pid"]) == File.read!(Path.join(workspace, "native.pid"))
  end

  defp assert_one_answer(workspace, answers) do
    [response] =
      workspace
      |> Path.join("received-answers.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert response["response"]["response"]["updatedInput"]["answers"] == answers
  end

  test "delivery acknowledges stdin, processing requires native tool_result, duplicate never writes", context do
    {:ok, pid} = launch(context)
    cleanup(pid)
    ref = Process.monitor(pid)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    assert question.questions |> hd() |> Map.fetch!("question") == "Choose?"
    assert_source(question, context.workspace)
    assert {:error, :no_matching_pending_question} = Native.answer(pid, "question-dead", %{"Choose?" => "A"})
    assert {:error, :invalid_answers} = Native.answer(pid, question.id, %{"Choose?" => " "})
    assert {:ok, %{question_id: id, status: "delivered"}} = Native.answer(pid, question.id, %{"Choose?" => "fresh answer"})
    assert id == question.id
    assert_receive {:agent, ^pid, {:answer, %{question_id: ^id, status: "delivered"}}}
    refute_receive {:agent, ^pid, {:answer, %{status: "processed"}}}, 30
    assert {:error, :no_matching_pending_question} = Native.answer(pid, id, %{"Choose?" => "duplicate"})
    assert {:error, :no_matching_pending_question} = Native.answer(pid, id, %{"Choose?" => "fresh answer"})
    File.write!(Path.join(context.workspace, "process-answer"), "")
    assert_receive {:agent, ^pid, {:answer, %{question_id: ^id, status: "processed"}}}, 5_000
    assert_receive {:agent, ^pid, {:ended, "done"}}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:error, _} = Native.answer(pid, id, %{"Choose?" => "late"})
    assert_one_answer(context.workspace, %{"Choose?" => "fresh answer"})
    response = Path.join(context.workspace, "received-answer.json") |> File.read!() |> JSON.decode!()
    assert response["response"]["response"]["updatedInput"]["answers"] == %{"Choose?" => "fresh answer"}
    refute Map.has_key?(response["response"]["response"], "updatedPermissions")
  end

  test "pending stop and native loss refuse late answers", context do
    {:ok, pid} = launch(context)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    assert :ok = Native.stop(pid)
    assert {:error, _} = Native.answer(pid, question.id, %{"Choose?" => "late"})
    refute File.exists?(Path.join(context.workspace, "received-answer.json"))

    {:ok, pid} = launch(context)
    assert_receive {:agent, ^pid, {:question, question}}, 5_000
    ref = Process.monitor(pid)
    native_pid = context.workspace |> Path.join("native.pid") |> File.read!()
    assert {_, 0} = System.cmd("kill", ["-KILL", native_pid])
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
    assert {:error, _} = Native.answer(pid, question.id, %{"Choose?" => "late"})
  end

  test "waiting answer callers are cancelled on stop and termination", _context do
    for terminal <- [:stop, :terminate] do
      tag = make_ref()
      timer = Process.send_after(self(), :unused_timeout, 60_000)
      question = %{NativeQuestion.new(true) | pending: %{id: "question-ab"},
                   waiter: {"question-ab", {self(), tag}, timer}}
      state = %{port: nil, question: question, stopping: nil}
      case terminal do
        :stop ->
          assert {:noreply, %{question: %{pending: nil, waiter: nil}}} =
                   Native.handle_call(:stop, {self(), make_ref()}, state)
        :terminate -> Native.terminate(:lost, state)
      end
      assert_receive {^tag, {:error, :native_question_cancelled}}
    end
    assert {:error, :invalid_answer} = Native.answer(nil, "question-ab", %{})
    assert {:error, :invalid_answer} = Native.answer(self(), nil, %{})
  end

  test "runner acknowledgements stay correlated and rejection never becomes delivery", _context do
    port = make_ref()
    tag = make_ref()
    timer = Process.send_after(self(), :unused_timeout, 60_000)
    question = %{id: "question-ab", questions: [%{"question" => "Choose?"}]}
    pending = %{NativeQuestion.new(true) | pending: question,
                waiter: {question.id, {self(), tag}, timer}}
    state = %{port: port, owner: self(), partial: "", question: pending, stopping: nil}
    event = fn type, id, extra ->
      record = Map.merge(%{"type" => type, "question_id" => id}, extra)
      {port, {:data, {:eol, JSON.encode!(record)}}}
    end
    assert {:noreply, ^state} =
             Native.handle_info(event.("runtime.answer_processed", question.id, %{}), state)
    assert {:noreply, ^state} =
             Native.handle_info(event.("runtime.answer_delivered", "question-dead", %{}), state)
    assert {:noreply, rejected} =
             Native.handle_info(event.("runtime.answer_rejected", question.id, %{"error" => "refused"}), state)
    assert_receive {^tag, {:error, "refused"}}
    assert rejected.question.pending == question
    assert rejected.question.waiter == nil
    assert rejected.question.last_answer == nil
    refute_received {:agent, _, {:answer, _}}
    assert {:stop, :answer_delivery_timeout, %{question: %{pending: nil, waiter: nil}}} =
             Native.handle_info({:answer_timeout, question.id}, state)
    assert_receive {^tag, {:error, :native_question_cancelled}}
  end

  test "answer bounds use UTF-8 bytes and the complete encoded object", _context do
    questions = Enum.map(1..4, &%{"question" => "Question #{&1}?"})
    question = %{questions: questions}
    assert :ok = NativeQuestion.validate_answers(question, Map.new(questions, &{&1["question"], "yes"}))
    assert {:error, :invalid_answers} = NativeQuestion.validate_answers(question, Map.new(questions, &{&1["question"], String.duplicate("x", 4096)}))
    assert {:error, :invalid_answers} = NativeQuestion.validate_answers(%{questions: [%{"question" => "Q?"}]}, %{"Q?" => String.duplicate("é", 2049)})
    assert {:error, :invalid_answers} = NativeQuestion.validate_answers(%{questions: [%{"question" => "Q?"}]}, %{"Q?" => <<255>>})
  end

  defp call(state, request) do
    {:reply, {reply, false}, next} = Service.handle_call(request, {self(), make_ref()}, state)
    refute Map.has_key?(reply, :command_error), inspect(reply)
    {reply, next}
  end

  defp await_run(state, predicate) do
    if predicate.(state.workers["alpha"].run) do
      state
    else
      receive do
        message ->
          {:noreply, next} = Service.handle_info(message, state)
          await_run(next, predicate)
      after
        5_000 -> flunk("Missing native lifecycle evidence")
      end
    end
  end

  test "service carries capability through saved continuation and exposes only delivery evidence", context do
    request = %{"command" => "start", "worker_id" => "alpha", "backend" => "claude",
                "cwd" => context.workspace, "assignment" => "Choose", "questions_enabled" => true}
    {run, state} = call(context.state, request)
    cleanup(state.workers["alpha"].agent)
    assert run.questions_enabled
    state = await_run(state, & &1.pending_question)
    pending = state.workers["alpha"].run.pending_question
    assert_source(pending, context.workspace)
    query = %{"command" => "question", "worker_id" => "alpha", "turn_id" => run.id,
              "question_id" => pending.id}
    {record, state} = call(state, query)
    assert record["correlation"] == pending.correlation
    assert record["original_input"] == %{"questions" => pending.questions}
    answer = %{"command" => "answer", "worker_id" => "alpha", "turn_id" => run.id,
               "question_id" => pending.id, "answers" => %{"Choose?" => "fresh"}}
    {evidence, state} = call(state, answer)
    assert evidence.status == "delivered"
    assert state.workers["alpha"].run.pending_question == nil
    assert state.workers["alpha"].run.last_answer.status == "delivered"
    assert evidence.admission == "accepted"
    {duplicate, state} = call(state, answer)
    assert duplicate == evidence
    {record, state} = call(state, query)
    assert record["answers"] == answer["answers"]
    assert record["transport"] == "delivered"
    assert record["processing"] != "processed"
    File.write!(Path.join(context.workspace, "process-answer"), "")
    state = await_run(state, &(&1.state == "finished"))
    original = state.workers["alpha"].run
    assert original.last_answer.status == "processed"
    {processed, state} = call(state, answer)
    assert processed.status == "processed"
    {historical, _} = call(%{state | workers: %{}}, query)
    assert historical["correlation"] == pending.correlation
    assert historical["original_input"] == %{"questions" => pending.questions}
    assert historical["processing"] == "processed"
    {restarted_duplicate, _} = call(%{state | workers: %{}}, answer)
    assert restarted_duplicate == processed
    assert_one_answer(context.workspace, answer["answers"])
    {continued, state} = call(state, %{"command" => "continue", "worker_id" => "alpha", "turn_id" => run.id, "assignment" => "Choose again"})
    cleanup(state.workers["alpha"].agent)
    assert continued.questions_enabled
    assert continued.source_turn_id == run.id
    assert JSON.decode!(File.read!(Path.join(continued.artifacts, "turn.json")))["source_turn_id"] == run.id
    assert continued.session_id == original.session_id
    assert continued.requested_model == original.model
    assert continued.cwd == original.cwd
    assert continued.sandbox == original.sandbox
    assert continued.pending_question == nil
    assert continued.last_answer == nil
    state = await_run(state, & &1.pending_question)
    next_pending = state.workers["alpha"].run.pending_question
    assert_source(next_pending, context.workspace)
    assert next_pending.id != pending.id
    assert next_pending.correlation["session_id"] == pending.correlation["session_id"]
    assert next_pending.correlation["model"] == pending.correlation["model"]
    assert next_pending.correlation["native_pid"] != pending.correlation["native_pid"]
    {old_duplicate, state} = call(state, answer)
    assert old_duplicate == processed
    assert state.workers["alpha"].run.pending_question == next_pending
    {stopped, _} = call(state, %{"command" => "stop", "worker_id" => "alpha"})
    assert stopped.pending_question == nil
  end

  test "default and legacy continuation keep questions disabled", context do
    request = %{"command" => "start", "worker_id" => "alpha", "backend" => "claude",
                "cwd" => context.workspace, "assignment" => "Read"}
    {run, state} = call(context.state, request)
    cleanup(state.workers["alpha"].agent)
    refute run.questions_enabled
    state = await_run(state, &(&1.state == "finished"))
    saved = state.workers["alpha"].run
    path = Path.join(saved.artifacts, "turn.json")
    File.write!(path, saved |> Map.delete(:questions_enabled) |> JSON.encode!())
    restarted = %{state | workers: %{}}
    {continued, state} = call(restarted, %{"command" => "continue", "turn_id" => run.id, "assignment" => "Read again"})
    cleanup(state.workers["alpha"].agent)
    refute continued.questions_enabled
    assert continued.source_turn_id == run.id
    state = await_run(state, &(&1.state == "finished"))
    assert state.workers["alpha"].run.pending_question == nil
  end
end
