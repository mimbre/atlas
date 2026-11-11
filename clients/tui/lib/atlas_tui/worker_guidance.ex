defmodule AtlasTui.WorkerGuidance do
  @moduledoc """
  Session-local, exact-execution guidance drafts and durable acceptance recovery.

  `values` retains literal partial form values. Once a request is emitted,
  `attempted` fixes its guidance payload, including its client key; callers must
  lock that payload rather than interpret a draft edit as a new submission.
  Only `:retryable`, reached by a negative query, permits an explicit identical
  retry. An explicit submit with an unresolved attempt queries its original key;
  another submit while querying is coalesced. Neither reconnect nor a query
  result resubmits guidance.

  `interaction` proves durable acceptance only, not delivery or consumption.
  Errors preserve the wire's code, message and retryable flag; that flag alone
  never authorizes a submit retry. Request IDs follow the shared client protocol
  convention and are invalidated on reconnect. Nothing is persisted here.
  """
  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire

  def new(execution, values) when is_map(values) do
    %{
      execution: Wire.model(:runtime_execution, execution),
      values: values,
      attempted: nil,
      pending: %{},
      status: :draft,
      error: nil,
      interaction: nil
    }
  end

  def update(state, values) when is_map(values),
    do: %{state | values: Map.merge(state.values, values)}

  def submit(state, values) do
    state = update(state, values)

    cond do
      is_nil(state.attempted) ->
        send_submission(state, state.values)

      state.status == :retryable and state.values == state.attempted ->
        send_submission(state, state.attempted)

      state.status == :retryable ->
        {%{
           state
           | error:
               local_error(
                 "immutable_payload",
                 "Retry requires the identical attempted body, cause and client key"
               )
         }, []}

      state.status in [:submitting, :unknown, :error] ->
        reconnect(state)

      true ->
        {state, []}
    end
  end

  def reconnect(%{attempted: nil} = state), do: {state, []}
  def reconnect(%{status: :accepted} = state), do: {state, []}

  def reconnect(state) do
    id = request_id()

    request =
      Wire.request(:worker_query, %{
        "id" => id,
        "execution" => state.execution,
        "client_key" => state.attempted["client_key"]
      })

    {%{state | pending: %{id => :worker_query}, status: :querying, error: nil}, [request]}
  end

  def receive(state, %{"id" => id} = message) do
    case state.pending[id] do
      name when name in [:worker_submit, :worker_query] ->
        case Wire.decode_reply(name, message) do
          {:ok, kind, reply} ->
            accept_reply(%{state | pending: Map.delete(state.pending, id)}, name, kind, reply)

          {:invalid, _reason} ->
            if message["op"] in [
                 Atom.to_string(name) <> "_result",
                 Atom.to_string(name) <> "_error"
               ] do
              invalid_reply(
                %{state | pending: Map.delete(state.pending, id)},
                "Malformed correlated response; acceptance remains unknown"
              )
            else
              {state, []}
            end
        end

      _ ->
        {state, []}
    end
  end

  def receive(state, _message), do: {state, []}

  defp send_submission(state, guidance) do
    id = request_id()

    request =
      Wire.request(:worker_submit, %{
        "id" => id,
        "execution" => state.execution,
        "guidance" => guidance
      })

    {%{
       state
       | attempted: request["guidance"],
         pending: %{id => :worker_submit},
         status: :submitting,
         error: nil
     }, [request]}
  rescue
    error in ArgumentError ->
      {%{state | status: :error, error: local_error("invalid_request", Exception.message(error))},
       []}
  end

  # Control rejects invalid_guidance before admission or durable lookup/write.
  defp accept_reply(state, :worker_submit, :error, %{
         "error" => %{"code" => "invalid_guidance"} = error
       }),
       do: {%{state | attempted: nil, status: :draft, error: error}, []}

  defp accept_reply(state, name, :error, %{"error" => error}) do
    status =
      if name == :worker_query or error["code"] == "outcome_unknown",
        do: :unknown,
        else: :error

    {%{state | status: status, error: error}, []}
  end

  defp accept_reply(state, :worker_submit, :result, %{"interaction" => interaction}),
    do: accept_interaction(state, interaction)

  defp accept_reply(state, :worker_query, :result, %{"found" => true} = reply),
    do: accept_interaction(state, reply["interaction"])

  defp accept_reply(state, :worker_query, :result, %{"found" => false} = reply) do
    if is_nil(reply["interaction"]) do
      {%{state | status: :retryable, error: nil}, []}
    else
      invalid_reply(state, "A negative query included an interaction")
    end
  end

  defp accept_interaction(state, interaction) when is_map(interaction) do
    execution = state.execution
    worker = execution["worker"]

    # The contract exposes no machine on an interaction. That part of the
    # execution binding is owned by Control and the correlated exact-target
    # request; never treat the opaque interaction execution key as a machine.
    matches =
      interaction["environment"] == worker["environment"] and
        interaction["worker"] == worker["worker"] and
        interaction["turn"] == execution["turn"] and
        interaction["attempt"] == execution["attempt"] and
        interaction["mode"] == "queued_guidance" and
        Enum.all?(state.attempted, fn {key, value} -> interaction[key] == value end)

    if matches do
      {%{state | status: :accepted, error: nil, interaction: interaction}, []}
    else
      invalid_reply(state, "Interaction does not match the exact attempted guidance")
    end
  end

  defp accept_interaction(state, _interaction),
    do: invalid_reply(state, "A successful query did not include an interaction")

  defp invalid_reply(state, message),
    do: {%{state | status: :unknown, error: local_error("invalid_reply", message)}, []}

  defp local_error(code, message),
    do: %{"code" => code, "message" => message, "retryable" => false}

  defp request_id, do: Integer.to_string(System.unique_integer([:positive]))
end
