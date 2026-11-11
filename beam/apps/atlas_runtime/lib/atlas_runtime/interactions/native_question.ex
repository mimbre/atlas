defmodule AtlasRuntime.Interactions.NativeQuestion do
  @moduledoc "Pending native questions, bounded answers and delivery evidence."

  def new(enabled), do: %{enabled: enabled, pending: nil, waiter: nil, last_answer: nil}

  def validate_answers(%{questions: questions}, answers)
      when is_list(questions) and is_map(answers) do
    keys = Enum.map(questions, & &1["question"])

    if length(keys) in 1..4 and map_size(answers) == length(keys) and
         Enum.sort(Map.keys(answers)) == Enum.sort(keys) and
         Enum.all?(answers, fn {key, value} -> bounded_text?(key) and bounded_text?(value) end) and
         byte_size(JSON.encode!(answers)) <= 16_384,
       do: :ok,
       else: {:error, :invalid_answers}
  rescue
    _ -> {:error, :invalid_answers}
  end

  def validate_answers(_, _), do: {:error, :invalid_answers}

  defp bounded_text?(text),
    do:
      is_binary(text) and byte_size(text) <= 4_096 and String.valid?(text) and
        String.trim(text) != ""

  def prepare_answer(%{enabled: true, pending: %{id: id} = question, waiter: nil}, id, answers),
    do: validate_answers(question, answers)

  def prepare_answer(_, _, _), do: {:error, :no_matching_pending_question}

  def await_delivery(state, id, from) do
    timer = Process.send_after(self(), {:answer_timeout, id}, 5_000)
    %{state | waiter: {id, from, timer}}
  end

  def clear(state) do
    if state.waiter do
      {_, from, timer} = state.waiter
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :native_question_cancelled})
    end

    %{state | pending: nil, waiter: nil}
  end

  def consume(
        %{
          "type" => "runtime.question",
          "question" => %{"id" => id, "questions" => questions, "correlation" => correlation}
        },
        %{enabled: true, pending: nil, waiter: nil} = state,
        owner
      )
      when is_binary(id) and is_list(questions) and is_map(correlation) do
    question = %{id: id, questions: questions, correlation: correlation}
    send(owner, {:agent, self(), {:question, question}})
    %{state | pending: question}
  end

  def consume(
        %{"type" => "runtime.answer_delivered", "question_id" => id},
        %{waiter: {id, from, timer}, pending: %{id: id}} = state,
        owner
      ) do
    Process.cancel_timer(timer)
    evidence = %{question_id: id, status: "delivered"}
    GenServer.reply(from, {:ok, evidence})
    send(owner, {:agent, self(), {:answer, evidence}})
    %{state | waiter: nil, pending: nil, last_answer: evidence}
  end

  def consume(
        %{"type" => "runtime.answer_processed", "question_id" => id},
        %{last_answer: %{question_id: id, status: "delivered"}} = state,
        owner
      ) do
    evidence = %{question_id: id, status: "processed"}
    send(owner, {:agent, self(), {:answer, evidence}})
    %{state | last_answer: evidence}
  end

  def consume(
        %{"type" => "runtime.answer_rejected", "question_id" => id, "error" => error},
        %{waiter: {id, from, timer}} = state,
        _owner
      ) do
    Process.cancel_timer(timer)
    GenServer.reply(from, {:error, error})
    %{state | waiter: nil}
  end

  def consume(_, state, _owner), do: state
end
