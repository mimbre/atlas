defmodule AtlasRuntime.Interactions.Commands do
  alias AtlasRuntime.Agent.Native
  alias AtlasRuntime.Interactions.NativeQuestion
  alias AtlasRuntime.{QuestionRecords, PeerQuestionRecords}
  alias AtlasRuntime.Persistence.History
  import AtlasRuntime.Execution.Identity, only: [valid_id?: 1, valid_worker_id?: 1]

  def execute(%{"command" => "peer-question"} = request, dir, events, workers) do
    question_selectors!(request, [])

    record =
      owned_peer_question!(dir, request) || raise("No peer question recorded for this question")

    {PeerQuestionRecords.public(record), events, workers}
  end

  def execute(%{"command" => "route-peer-question"} = request, dir, events, workers) do
    question_selectors!(request, ["peer_worker_id", "peer_source_turn_id"])
    if not valid_worker_id?(request["peer_worker_id"]), do: raise("Invalid peer worker ID")
    if not valid_id?(request["peer_source_turn_id"]), do: raise("Invalid peer source turn ID")

    if request["peer_worker_id"] == request["worker_id"],
      do: raise("Peer must differ from sender")

    case owned_peer_question!(dir, request) do
      nil ->
        question = live_peer_question!(dir, workers, request)

        source =
          finished_peer_turn!(dir, request["peer_source_turn_id"], request["peer_worker_id"])

        {record, events} = PeerQuestionRecords.create(dir, events, question, source)
        {PeerQuestionRecords.routed(record), events, workers}

      record ->
        if record["peer_worker_id"] != request["peer_worker_id"] or
             record["peer_source_turn_id"] != request["peer_source_turn_id"],
           do: raise("Conflicting peer question route")

        {PeerQuestionRecords.routed(record), events, workers}
    end
  end

  def execute(%{"command" => "bind-peer-reply"} = request, dir, events, workers) do
    question_selectors!(request, ["response_turn_id"])
    if not valid_id?(request["response_turn_id"]), do: raise("Invalid response turn ID")

    record =
      owned_peer_question!(dir, request) || raise("No peer question recorded for this question")

    case record["response_turn_id"] do
      nil ->
        live_peer_question!(dir, workers, request)
        response = peer_response_turn!(dir, record, request["response_turn_id"])
        {record, events} = PeerQuestionRecords.bind(dir, events, record, response)
        {PeerQuestionRecords.public(record), events, workers}

      response_turn_id ->
        if response_turn_id != request["response_turn_id"],
          do: raise("Conflicting peer reply binding")

        {PeerQuestionRecords.public(record), events, workers}
    end
  end

  def execute(%{"command" => "question"} = request, dir, events, workers) do
    question_selectors!(request, [])
    record = owned_question!(dir, request)
    {QuestionRecords.public(record), events, workers}
  end

  def execute(%{"command" => "answer"} = request, dir, events, workers) do
    question_selectors!(request, ["answers"])
    record = owned_question!(dir, request)

    if record["admission"] == "accepted" do
      if record["answers"] != request["answers"],
        do: raise("Conflicting answer: question already admitted")

      {QuestionRecords.evidence(record), events, workers}
    else
      worker = workers[request["worker_id"]] || raise("Unknown worker: #{request["worker_id"]}")

      if not record["active"] or not is_pid(worker.agent) or
           worker.run.state != "running" or worker.run.id != request["turn_id"],
         do: raise("Answer requires the current active worker turn")

      if worker.run[:questions_enabled] != true or worker.run[:backend] != "claude",
        do: raise("Questions are not enabled for this turn")

      question = worker.run[:pending_question]

      if is_nil(question) or question.id != request["question_id"],
        do: raise("No matching pending question")

      if NativeQuestion.validate_answers(
           %{questions: record["original_input"]["questions"]},
           request["answers"]
         ) != :ok,
         do: raise("Invalid answers for the pending question")

      # Admission and its journal checkpoint must precede the only native send.
      {record, events} = QuestionRecords.admit(dir, events, record, request["answers"])

      {record, events} =
        case send_answer(worker.agent, request["question_id"], request["answers"]) do
          {:ok, %{status: "delivered"}} -> QuestionRecords.delivered(dir, events, record)
          _ -> {record, events}
        end

      evidence = QuestionRecords.evidence(record)
      run = Map.merge(worker.run, %{pending_question: nil, last_answer: evidence})
      {evidence, events, Map.put(workers, request["worker_id"], %{worker | run: run})}
    end
  end

  def observe(
        {:question, question},
        %{state: "running", backend: "claude", questions_enabled: true} = run,
        _worker_id,
        dir,
        events
      ) do
    if is_nil(run[:pending_question]) do
      {record, events} = QuestionRecords.create(dir, events, run, question)

      question =
        Map.merge(question, %{record_ref: record["record_ref"], revision: record["revision"]})

      {Map.put(run, :pending_question, question), events}
    else
      {run, events}
    end
  end

  def observe({:answer, %{question_id: question_id, status: status}}, run, worker_id, dir, events)
      when status in ["delivered", "processed"] do
    record = QuestionRecords.load(dir, run.id, question_id)

    if record && record["worker_id"] == worker_id && record["admission"] == "accepted" do
      {record, events} =
        if status == "processed",
          do: QuestionRecords.processed(dir, events, record),
          else: QuestionRecords.delivered(dir, events, record)

      evidence = QuestionRecords.evidence(record)
      pending = run[:pending_question]
      pending = if pending && pending.id == question_id, do: nil, else: pending
      last = run[:last_answer]
      last = if is_nil(last) or last.question_id == question_id, do: evidence, else: last
      {Map.merge(run, %{pending_question: pending, last_answer: last}), events}
    else
      {run, events}
    end
  end

  def observe(_, run, _worker_id, _dir, events), do: {run, events}

  defp question_selectors!(request, extra) do
    fields = ["command", "worker_id", "turn_id", "question_id"] ++ extra

    if Enum.sort(Map.keys(request)) != Enum.sort(fields),
      do: raise("#{request["command"]} requires exactly #{Enum.join(tl(fields), ", ")}")

    if not valid_worker_id?(request["worker_id"]), do: raise("Invalid worker ID")
    if not valid_id?(request["turn_id"]), do: raise("Invalid turn ID")

    if not is_binary(request["question_id"]) or
         not Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, request["question_id"]),
       do: raise("Invalid question ID")
  end

  defp owned_question!(dir, request) do
    record =
      QuestionRecords.load(dir, request["turn_id"], request["question_id"]) ||
        raise("Question record unavailable; no matching recorded question")

    if record["worker_id"] != request["worker_id"],
      do: raise("Question belongs to worker #{record["worker_id"]}, not #{request["worker_id"]}")

    record
  end

  defp owned_peer_question!(dir, request) do
    record = PeerQuestionRecords.load(dir, request["turn_id"], request["question_id"])

    if record && record["worker_id"] != request["worker_id"],
      do:
        raise(
          "Peer question belongs to worker #{record["worker_id"]}, not #{request["worker_id"]}"
        )

    record
  end

  defp live_peer_question!(dir, workers, request) do
    record = owned_question!(dir, request)
    worker = workers[request["worker_id"]] || raise("Unknown worker: #{request["worker_id"]}")

    if not record["active"] or record["admission"] != "pending" or
         not is_pid(worker.agent) or not Process.alive?(worker.agent) or
         worker.run.state != "running" or worker.run[:worker_id] != request["worker_id"] or
         worker.run[:id] != request["turn_id"],
       do: raise("Peer question requires the current active worker turn")

    if worker.run[:questions_enabled] != true or worker.run[:backend] != "claude",
      do: raise("Questions are not enabled for this turn")

    question = worker.run[:pending_question]

    if is_nil(question) or question.id != request["question_id"] or
         question.correlation != record["correlation"] or
         %{"questions" => question.questions} != record["original_input"],
       do: raise("No matching pending native question")

    record
  end

  defp finished_peer_turn!(dir, turn, worker_id) do
    run = History.owned_saved_turn!(dir, turn, worker_id)
    if run["state"] != "finished", do: raise("Peer turn must be successfully finished")

    if not is_binary(run["session_id"]) or String.trim(run["session_id"]) == "",
      do: raise("Peer turn has no confirmed native session")

    Map.put(run, "turn_id", turn)
  end

  defp peer_response_turn!(dir, record, response_turn_id) do
    if response_turn_id in [record["turn_id"], record["peer_source_turn_id"]],
      do: raise("Peer response must differ from sender and source turns")

    source = finished_peer_turn!(dir, record["peer_source_turn_id"], record["peer_worker_id"])
    response = finished_peer_turn!(dir, response_turn_id, record["peer_worker_id"])

    if not is_map(response["selection"]) or response["selection"]["reason"] != "continuation" or
         response["source_turn_id"] != record["peer_source_turn_id"],
       do: raise("Peer response must be an exact saved continuation of the peer source turn")

    if Enum.any?(
         ~w(backend session_id cwd sandbox permissions repository model),
         &(response[&1] != source[&1])
       ),
       do: raise("Peer response changed the saved source execution identity")

    response
  end

  defp send_answer(agent, question_id, answers) do
    Native.answer(agent, question_id, answers)
  rescue
    _ -> {:error, :delivery_unknown}
  catch
    :exit, _ -> {:error, :delivery_unknown}
  end
end
