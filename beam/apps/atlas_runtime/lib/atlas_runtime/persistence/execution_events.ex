defmodule AtlasRuntime.ExecutionEvents do
  @moduledoc "Bounded, durable execution snapshots; completion does not imply task verification."

  @retention 256
  @max_bytes 4 * 1024 * 1024
  @max_sequence 9_223_372_036_854_775_807
  @filename "execution-events.json"
  @question_kinds ~w(question_available answer_accepted answer_delivered answer_processed question_invalidated)
  @peer_question_kinds ~w(peer_question_routed peer_reply_bound)

  def append_question(dir, store, transition) do
    duplicate =
      Enum.find(store["events"], fn event ->
        event["kind"] in @question_kinds and event["turn_id"] == transition["turn_id"] and
          event["question_id"] == transition["question_id"] and
          event["revision"] == transition["revision"]
      end)

    if duplicate do
      unless Map.delete(duplicate, "sequence") == transition,
        do: raise(ArgumentError, "conflicting question event revision")

      store
    else
      event = Map.put(transition, "sequence", store["sequence"] + 1)

      unless transition["kind"] in @question_kinds and valid_event?(event),
        do: raise(ArgumentError, "invalid question event")

      store
      |> Map.put("sequence", event["sequence"])
      |> Map.put("events", Enum.take(store["events"] ++ [event], -@retention))
      |> then(&persist(dir, &1))
    end
  end

  def append_peer_question(dir, store, transition) do
    event = Map.put(transition, "sequence", store["sequence"] + 1)

    unless transition["kind"] in @peer_question_kinds and valid_event?(event),
      do: raise(ArgumentError, "invalid peer question event")

    duplicate =
      Enum.find(store["events"], fn previous ->
        previous["kind"] in @peer_question_kinds and previous["turn_id"] == transition["turn_id"] and
          previous["question_id"] == transition["question_id"] and
          previous["revision"] == transition["revision"]
      end)

    if duplicate do
      unless Map.delete(duplicate, "sequence") == transition,
        do: raise(ArgumentError, "conflicting peer question event revision")

      store
    else
      store
      |> Map.put("sequence", event["sequence"])
      |> Map.put("events", Enum.take(store["events"] ++ [event], -@retention))
      |> then(&persist(dir, &1))
    end
  end

  def append_handoff(dir, store, record) do
    transition = %{
      "kind" => "handoff_submitted",
      "turn_id" => record["turn_id"],
      "worker_id" => record["worker_id"],
      "record_ref" => record["record_ref"],
      "timestamp" => record["submitted_at"]
    }

    duplicate =
      Enum.find(store["events"], fn previous ->
        previous["kind"] == "handoff_submitted" and previous["turn_id"] == record["turn_id"]
      end)

    if duplicate do
      unless Map.delete(duplicate, "sequence") == transition,
        do: raise(ArgumentError, "conflicting handoff event")

      store
    else
      event = Map.put(transition, "sequence", store["sequence"] + 1)
      unless valid_event?(event), do: raise(ArgumentError, "invalid handoff event")

      store
      |> Map.put("sequence", event["sequence"])
      |> Map.put("events", Enum.take(store["events"] ++ [event], -@retention))
      |> then(&persist(dir, &1))
    end
  end

  def open(dir) do
    path = Path.join(dir, @filename)

    case File.stat(path) do
      {:error, :enoent} ->
        store = %{
          "version" => 1,
          "epoch" => Base.encode16(:crypto.strong_rand_bytes(16), case: :lower),
          "recording_started_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "sequence" => 0,
          "events" => []
        }

        persist(dir, store)

      {:ok, %{size: size}} when size <= @max_bytes ->
        case JSON.decode(File.read!(path)) do
          {:ok, store} -> validate!(store)
          {:error, _} -> invalid_store!()
        end

      {:ok, _} ->
        invalid_store!()

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read execution event journal", path: path
    end
  end

  def append(dir, store, run) do
    kind =
      case run.state do
        "running" -> "execution_accepted"
        "finished" -> "execution_finished"
        "failed" -> "execution_failed"
        "stopped" -> "execution_stopped"
        "killed" -> "execution_killed"
        _ -> raise ArgumentError, "unsupported execution event state"
      end

    event = %{
      "sequence" => store["sequence"] + 1,
      "kind" => kind,
      "turn_id" => run.id,
      "worker_id" => run.worker_id,
      "backend" => run.backend,
      "session_id" => Map.get(run, :session_id),
      "model" => Map.get(run, :model),
      "timestamp" => if(kind == "execution_accepted", do: run.started_at, else: run.ended_at)
    }

    event =
      if kind == "execution_accepted" do
        operation =
          if get_in(run, [:selection, "reason"]) == "continuation", do: "continue", else: "start"

        Map.put(event, "operation", operation)
      else
        event
      end

    unless valid_event?(event), do: raise(ArgumentError, "invalid execution event snapshot")

    store
    |> Map.put("sequence", event["sequence"])
    |> Map.put("events", Enum.take(store["events"] ++ [event], -@retention))
    |> then(&persist(dir, &1))
  end

  def query(store, cursor, limit) do
    unless is_integer(limit) and limit in 1..100,
      do: raise(ArgumentError, "execution event limit must be an integer between 1 and 100")

    earliest = store["sequence"] - length(store["events"])
    sequence = if is_nil(cursor), do: earliest, else: parse_cursor!(store, cursor, earliest)
    remaining = Enum.drop_while(store["events"], &(&1["sequence"] <= sequence))
    events = Enum.take(remaining, limit)

    next_cursor =
      case List.last(events) do
        nil -> cursor || cursor(store, earliest)
        event -> cursor(store, event["sequence"])
      end

    %{
      "events" => events,
      "next_cursor" => next_cursor,
      "has_more" => length(remaining) > limit,
      "earliest_cursor" => cursor(store, earliest),
      "retention_gap" => is_nil(cursor) and earliest > 0,
      "recording_started_at" => store["recording_started_at"]
    }
  end

  @doc "The cursor after the newest recorded event."
  def head(store), do: cursor(store, store["sequence"])

  @doc """
  A runtime.read/1 page after `cursor`. Lost events are an explicit `reset` followed by the
  earliest retained events, as in public output: `retention_gap` with inclusive
  `from_sequence`/`to_sequence` (also for a first read once events were dropped), or
  `epoch_changed` for a cursor of a replaced journal, whose lost interval is unknown.
  A malformed or future cursor is `{:error, "invalid_cursor"}`.
  """
  def read(store, cursor, limit) do
    earliest = store["sequence"] - length(store["events"])

    case if(is_nil(cursor), do: {:ok, earliest}, else: locate(store, cursor, earliest)) do
      {:ok, sequence} ->
        reset = if is_nil(cursor) and earliest > 0, do: gap(1, earliest)
        {:ok, page(store, sequence, limit, reset)}

      {:error, :stale, sequence} ->
        {:ok, page(store, earliest, limit, gap(sequence + 1, earliest))}

      {:error, :other_stream} ->
        {:ok, page(store, earliest, limit, %{"reason" => "epoch_changed"})}

      {:error, _} ->
        {:error, "invalid_cursor"}
    end
  end

  defp gap(from, to),
    do: %{"reason" => "retention_gap", "from_sequence" => from, "to_sequence" => to}

  defp page(store, sequence, limit, reset) do
    remaining = Enum.drop_while(store["events"], &(&1["sequence"] <= sequence))
    events = Enum.take(remaining, limit)
    last = if events == [], do: sequence, else: List.last(events)["sequence"]

    page = %{
      "events" => events,
      "cursor" => cursor(store, last),
      "more" => length(remaining) > limit,
      "recording_started_at" => store["recording_started_at"]
    }

    if reset, do: Map.put(page, "reset", reset), else: page
  end

  defp parse_cursor!(store, value, earliest) do
    case locate(store, value, earliest) do
      {:ok, sequence} ->
        sequence

      {:error, :other_stream} ->
        raise ArgumentError, "execution event cursor belongs to a different stream"

      {:error, :future} ->
        raise ArgumentError, "execution event cursor is in the future"

      {:error, :stale, _sequence} ->
        raise ArgumentError,
              "stale execution event cursor; earliest usable cursor: #{cursor(store, earliest)}"

      {:error, :malformed} ->
        raise ArgumentError, "malformed execution event cursor"
    end
  end

  defp locate(store, value, earliest) do
    parsed =
      if is_binary(value) and byte_size(value) <= 52 do
        Regex.run(~r/\A([0-9a-f]{32}):(0|[1-9][0-9]{0,18})\z/, value, capture: :all_but_first)
      end

    case parsed do
      [epoch, number] ->
        sequence = String.to_integer(number)

        cond do
          epoch != store["epoch"] -> {:error, :other_stream}
          sequence > store["sequence"] -> {:error, :future}
          sequence < earliest -> {:error, :stale, sequence}
          true -> {:ok, sequence}
        end

      _ ->
        {:error, :malformed}
    end
  end

  defp cursor(store, sequence), do: store["epoch"] <> ":" <> Integer.to_string(sequence)

  defp persist(dir, store) do
    encoded = JSON.encode!(store)
    if byte_size(encoded) > @max_bytes, do: invalid_store!()
    File.mkdir_p!(dir)
    path = Path.join(dir, @filename)
    File.write!(path <> ".tmp", encoded)
    File.rename!(path <> ".tmp", path)
    store
  end

  defp validate!(
         %{
           "version" => 1,
           "epoch" => epoch,
           "recording_started_at" => started_at,
           "sequence" => sequence,
           "events" => events
         } = store
       ) do
    valid =
      map_size(store) == 5 and is_binary(epoch) and
        Regex.match?(~r/\A[0-9a-f]{32}\z/, epoch) and timestamp?(started_at) and
        is_integer(sequence) and sequence >= 0 and sequence <= @max_sequence and
        is_list(events) and length(events) == min(sequence, @retention)

    unless valid, do: invalid_store!()

    events
    |> Enum.with_index(sequence - length(events) + 1)
    |> Enum.each(fn {event, expected} ->
      unless valid_event?(event) and event["sequence"] == expected, do: invalid_store!()
    end)

    handoffs = Enum.filter(events, &(&1["kind"] == "handoff_submitted"))

    unless length(Enum.uniq_by(handoffs, & &1["turn_id"])) == length(handoffs),
      do: invalid_store!()

    peers = Enum.filter(events, &(&1["kind"] in @peer_question_kinds))

    unless length(Enum.uniq_by(peers, &{&1["turn_id"], &1["question_id"], &1["revision"]})) ==
             length(peers),
           do: invalid_store!()

    store
  end

  defp validate!(_), do: invalid_store!()

  defp valid_event?(
         %{
           "kind" => "handoff_submitted",
           "record_ref" => reference,
           "turn_id" => turn,
           "worker_id" => worker,
           "sequence" => sequence,
           "timestamp" => timestamp
         } = event
       ) do
    map_size(event) == 6 and is_integer(sequence) and sequence > 0 and
      sequence <= @max_sequence and is_binary(turn) and
      Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, turn) and is_binary(worker) and
      Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, worker) and
      reference == Path.join(["turns", turn, "handoff.json"]) and timestamp?(timestamp)
  end

  defp valid_event?(
         %{
           "kind" => kind,
           "question_id" => question,
           "revision" => revision,
           "record_ref" => reference,
           "turn_id" => turn,
           "worker_id" => worker,
           "peer_worker_id" => peer,
           "peer_source_turn_id" => source,
           "response_turn_id" => response,
           "sequence" => sequence,
           "timestamp" => timestamp
         } = event
       )
       when kind in @peer_question_kinds do
    map_size(event) == 11 and is_integer(revision) and is_integer(sequence) and sequence > 0 and
      sequence <= @max_sequence and is_binary(question) and
      Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, question) and
      is_binary(turn) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, turn) and
      is_binary(worker) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, worker) and
      is_binary(peer) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, peer) and peer != worker and
      is_binary(source) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, source) and source != turn and
      reference == Path.join(["turns", turn, "peer-questions", question <> ".json"]) and
      timestamp?(timestamp) and
      ((kind == "peer_question_routed" and revision == 1 and is_nil(response)) or
         (kind == "peer_reply_bound" and revision == 2 and is_binary(response) and
            Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, response) and response not in [turn, source]))
  end

  defp valid_event?(
         %{
           "kind" => kind,
           "question_id" => question,
           "revision" => revision,
           "record_ref" => reference,
           "turn_id" => turn,
           "worker_id" => worker,
           "sequence" => sequence,
           "timestamp" => timestamp
         } = event
       )
       when kind in @question_kinds do
    map_size(event) == 8 and is_integer(sequence) and sequence > 0 and
      sequence <= @max_sequence and is_integer(revision) and revision in 1..5 and
      is_binary(question) and Regex.match?(~r/\Aquestion-[0-9a-f]{1,64}\z/, question) and
      is_binary(turn) and Regex.match?(~r/\Aturn-[0-9a-f]{16}\z/, turn) and
      is_binary(worker) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, worker) and
      reference == Path.join(["turns", turn, "questions", question <> ".json"]) and
      timestamp?(timestamp)
  end

  defp valid_event?(
         %{
           "sequence" => sequence,
           "kind" => kind,
           "turn_id" => turn,
           "backend" => backend,
           "session_id" => session,
           "model" => model,
           "timestamp" => timestamp
         } = event
       ) do
    worker_fields = if Map.has_key?(event, "worker_id"), do: 1, else: 0

    worker_valid =
      worker_fields == 0 or
        (is_binary(event["worker_id"]) and
           Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, event["worker_id"]))

    shape =
      case kind do
        "execution_accepted" ->
          map_size(event) == 8 + worker_fields and event["operation"] in ["start", "continue"]

        terminal
        when terminal in [
               "execution_finished",
               "execution_failed",
               "execution_stopped",
               "execution_killed"
             ] ->
          map_size(event) == 7 + worker_fields

        _ ->
          false
      end

    shape and worker_valid and is_integer(sequence) and sequence > 0 and sequence <= @max_sequence and
      text?(turn, 128) and text?(backend, 64) and nullable_text?(session, 1024) and
      nullable_text?(model, 256) and timestamp?(timestamp)
  end

  defp valid_event?(_), do: false
  defp nullable_text?(nil, _), do: true
  defp nullable_text?(value, max), do: text?(value, max)

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp timestamp?(value) do
    text?(value, 64) and match?({:ok, _, _}, DateTime.from_iso8601(value))
  end

  defp invalid_store!, do: raise(ArgumentError, "invalid or oversized execution event journal")
end
