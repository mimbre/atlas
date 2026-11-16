defmodule AtlasRuntime.ClaudeProtocolProbe do
  @moduledoc """
  Offline source-derived protocol probe, compiled only in test.
  No executable selection, live adapter, Facts writes or native capability claims.
  One pending immutable input; observations are bounded booleans, never receipts.
  """
  alias AtlasRuntime.Agent.Input
  @version "2.1.280"
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @gaps ~w(native_durable_admission_lookup native_restart_dedup native_durable_consumption_lookup)

  def new(version, identity, session, uuid) do
    with true <- version == @version,
         :ok <- Input.validate_identity(identity),
         true <- uuid?(session) and uuid?(uuid) do
      {:ok,
       %{
         identity: identity,
         session: session,
         uuid: uuid,
         request: nil,
         partial: "",
         closed: false,
         error: nil,
         echo: false,
         correlated: false,
         result: false,
         activity: false
       }}
    else
      _ -> {:error, :unsupported_profile}
    end
  end

  # Source: SDK 0.3.280 SDKUserMessage and Query.streamInput/verbatimPrompts.
  # This proves the codec's literal bytes, not native handling or admission.
  def input(%{closed: false, error: nil, request: nil} = state, request) do
    with :ok <- Input.validate(request),
         true <- Map.drop(request, ["body", "mode"]) == state.identity do
      frame = %{
        "type" => "user",
        "message" => %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => request["body"]}]
        },
        "parent_tool_use_id" => nil,
        "uuid" => state.uuid,
        "session_id" => state.session,
        "client_composed" => true
      }

      line = JSON.encode!(frame) <> "\n"

      if byte_size(line) <= 32_768,
        do: {:ok, line, %{state | request: request}},
        else: {:error, :frame_too_large, state}
    else
      _ -> {:error, :invalid_input, state}
    end
  end

  def input(%{request: request} = state, request), do: {:error, :uncertain, state}
  def input(state, _), do: {:error, :conflict, state}

  def feed(%{closed: false, error: nil} = state, chunk) when is_binary(chunk) do
    if byte_size(state.partial) + byte_size(chunk) > 65_536 do
      fail(state, :frame_too_large)
    else
      parts = :binary.split(state.partial <> chunk, "\n", [:global])
      {lines, [partial]} = Enum.split(parts, -1)
      Enum.reduce(lines, %{state | partial: partial}, &line/2)
    end
  end

  def feed(state, _), do: state

  def eof(state) do
    state = if state.partial == "", do: state, else: fail(state, :truncated_frame)
    %{state | closed: true, partial: ""}
  end

  def verdict(state) do
    %{
      "guidance" => "unsupported",
      "durable_admission" => "unproven",
      "durable_consumption" => "unproven",
      "gaps" => @gaps,
      "error" => state.error && Atom.to_string(state.error),
      "observations" => %{
        "transport_echo" => state.echo,
        "source_derived_uuid_correlation" => state.correlated,
        "result" => state.result,
        "activity" => state.activity
      }
    }
  end

  # No recovery/retry path can reinterpret an ephemeral observation as native lookup.
  def recover(_identity), do: {:error, :unsupported}

  defp line(_, %{error: error} = state) when error != nil, do: state
  defp line(_, %{request: nil} = state), do: fail(state, :no_pending_input)

  defp line(line, state) do
    case JSON.decode(line) do
      {:ok, %{"type" => "control_request"}} ->
        fail(state, :control_not_permitted)

      {:ok, %{"session_id" => session}} when session != state.session ->
        fail(state, :wrong_session)

      {:ok,
       %{
         "type" => "user",
         "isReplay" => true,
         "uuid" => uuid,
         "session_id" => session,
         "parent_tool_use_id" => nil,
         "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => body}]}
       }}
      when uuid == state.uuid and session == state.session ->
        if state.request != nil and body == state.request["body"],
          do: %{state | echo: true},
          else: fail(state, :conflict)

      {:ok, %{"type" => type} = event} when type in ["assistant", "result"] ->
        if event["session_id"] != state.session do
          fail(state, :wrong_session)
        else
          correlation(event, state)
        end

      {:ok, %{"type" => "stream_event", "session_id" => session, "event" => event}}
      when session == state.session and is_map(event) ->
        %{state | activity: true}

      _ ->
        fail(state, :invalid_frame)
    end
  end

  defp correlation(%{"parent_tool_use_id" => parent}, state) when parent != nil, do: state

  defp correlation(event, state) do
    scalar = event["user_message_uuid"]

    ids =
      case Map.fetch(event, "user_message_uuids") do
        {:ok, ids} -> ids
        :error -> List.wrap(scalar)
      end

    if is_list(ids) and length(ids) <= 64 and Enum.all?(ids, &uuid?/1) and
         (scalar == nil or (uuid?(scalar) and scalar in ids)) do
      %{
        state
        | correlated: state.correlated or state.uuid in ids,
          result: state.result or event["type"] == "result",
          activity: true
      }
    else
      fail(state, :invalid_correlation)
    end
  end

  defp uuid?(value),
    do: is_binary(value) and byte_size(value) == 36 and Regex.match?(@uuid, value)

  defp fail(state, reason), do: %{state | error: reason, partial: ""}
end
