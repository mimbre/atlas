defmodule AtlasTui.WorkerOutput do
  @moduledoc """
  Demand-driven, exact-execution ephemeral output, independent of durable history.

  Only an inspected output capability permits subscription. Replies never poll;
  the caller requests each next batch after accepting the previous one. A gap
  keeps the accepted cursor and permits an explicit `next/1` replay attempt.
  Disconnect invalidates the viewer subscription, not the worker. Its owner
  closes the isolated Control connection (or unsubscribes before closing it).
  Cursors remain opaque and are never interpreted as Facts history positions.
  """
  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.Blocks

  @max_events 1000
  @max_bytes 224 * 1024
  @max_notes 16
  @max_note_bytes 1024
  # The conversation shows the latest messages, each cut at a bound; the rest are details.
  @latest 5
  @message_bytes 8 * 1024
  @latest_activity 50

  defstruct execution: nil,
            valid: false,
            status: :detached,
            pending: %{},
            subscription: nil,
            cursor: nil,
            stream: nil,
            view: nil,
            view_current: false,
            more: false,
            ended: false,
            replay_watermark: nil,
            replay_complete: false,
            last_sequence: nil,
            events: [],
            retained_bytes: 0,
            local_dropped: 0,
            notes: [],
            # A reset said events were lost: some earlier output is missing.
            missing: false,
            error: nil,
            current: false,
            segment: 0,
            retries: 0

  def new(execution) do
    execution = normalize(execution)
    valid = exact_execution?(execution)
    state = %__MODULE__{execution: execution, valid: valid}

    if valid,
      do: state,
      else:
        note(%{state | status: :unavailable}, "Exact execution unavailable; no output requested.")
  end

  def connect(%{valid: false} = state), do: {state, []}
  def connect(%{pending: pending} = state) when map_size(pending) > 0, do: {state, []}

  def connect(state) do
    cond do
      # Control reported the output temporarily unavailable: start over from the
      # accepted cursor through a fresh inspect, as an explicit reconnect would.
      retryable?(state) ->
        connect(%{disconnect(state) | retries: state.retries + 1})

      not is_nil(state.subscription) ->
        {state, []}

      true ->
        request(
          %{state | error: nil, view_current: false},
          :worker_inspect,
          %{execution: state.execution},
          :inspecting
        )
    end
  end

  def next(%{pending: pending} = state) when map_size(pending) > 0, do: {state, []}

  def next(%{status: status, subscription: subscription} = state)
      when status in [:ready, :gap] and is_binary(subscription) do
    request(
      state,
      :worker_output_next,
      %{subscription: subscription, cursor: state.cursor},
      :reading
    )
  end

  def next(state), do: {state, []}

  @doc """
  Whether unavailability is transient: a retryable `output_unavailable` error, or
  an inspect reporting `output_unavailable`, while the worker still runs or the
  stream has not been observed ended. Expired, unsupported and other reasons are final.
  """
  def retryable?(%{status: :unavailable, view: view} = state) when is_map(view) do
    transient =
      case state.error do
        nil -> get_in(view, ["output", "reason"]) == "output_unavailable"
        error -> error["code"] == "output_unavailable" and error["retryable"] == true
      end

    transient and (view["state"] == "running" or not state.ended)
  end

  def retryable?(_state), do: false

  def disconnect(state) do
    state = %{
      state
      | pending: %{},
        subscription: nil,
        status: :detached,
        current: false,
        view_current: false,
        segment: state.segment + 1
    }

    note(
      state,
      "Disconnected: retained output is non-current; continuity must be re-established for this exact execution."
    )
  end

  def receive(state, %{"id" => id, "op" => op} = message) do
    case state.pending[id] do
      nil ->
        {state, []}

      operation ->
        name = Atom.to_string(operation)

        if op in [name <> "_result", name <> "_error"] do
          state = %{state | pending: %{}}

          case Wire.decode_reply(operation, message) do
            {:ok, :result, reply} -> accept(state, operation, reply)
            {:ok, :error, reply} -> accept_error(state, reply)
            {:invalid, reason} -> reject(state, "Invalid typed output reply: #{reason}")
          end
        else
          {state, []}
        end
    end
  end

  def receive(state, _message), do: {state, []}

  @doc """
  What the worker said, for the conversation: Control's `placeholder` block (its title, and
  its fields while nothing was said) filled with the latest #{@latest} text messages, newest
  last, each cut at #{@message_bytes} bytes. One line says when earlier output is missing
  (a reset that lost events, or this viewer's own bounded retention), and one how many
  earlier messages are in the details.
  """
  def conversation(state, placeholder) do
    texts = texts(state)
    {earlier, latest} = Enum.split(texts, max(length(texts) - @latest, 0))

    lines =
      if(missing?(state), do: [bare("Some earlier output is missing.")], else: []) ++
        if(earlier == [],
          do: [],
          else: [bare("#{count(length(earlier), "earlier message")} under Details.")]
        )

    title = (placeholder && placeholder.title) || "Worker messages"

    fields =
      cond do
        latest != [] ->
          lines ++ (latest |> Enum.map(&bare(cut(&1))) |> Enum.intersperse(bare("")))

        lines != [] ->
          lines

        placeholder ->
          Enum.map(placeholder.fields, &{&1.label, &1.value})

        true ->
          []
      end

    [item("worker-output", title, fields)]
  end

  @doc """
  The output's own state, for the details: the stream's status, its notes (resets,
  disconnects, refusals), what the worker did besides speaking (the latest
  #{@latest_activity} activity and tool events) and its earlier messages.
  """
  def details(state) do
    fields =
      [
        {"Status", Atom.to_string(state.status)},
        {"Execution", execution_text(state.execution)},
        {"Freshness",
         if(state.current,
           do: "Current subscription observation",
           else: "Non-current retained output"
         )},
        {"Scope",
         "Ephemeral output only; not guidance delivery, durable history, or worker completion"},
        {"Producer",
         if(state.ended,
           do: "Ended; worker lifecycle remains independent",
           else: "Not observed ended"
         )},
        {"Replay", replay_text(state)},
        {"More", to_string(state.more)}
      ] ++ error_fields(state) ++ retention_fields(state)

    others = for entry <- state.events, entry.event["kind"] != "text", do: entry.event
    {older, shown} = Enum.split(others, max(length(others) - @latest_activity, 0))

    activity =
      if(older == [], do: [], else: [bare("#{count(length(older), "earlier event")} not shown")]) ++
        Enum.flat_map(shown, &event_fields/1)

    {earlier, _latest} = Enum.split(texts(state), max(length(texts(state)) - @latest, 0))

    [item("worker-output-status", "Output stream", fields)] ++
      Enum.with_index(state.notes, fn text, index ->
        item("worker-output-note:#{index}", "Output note", [{"Note", text}])
      end) ++
      if(activity == [], do: [], else: [item("worker-output-activity", "Activity", activity)]) ++
      if earlier == [],
        do: [],
        else: [
          item(
            "worker-output-earlier",
            "Earlier messages",
            earlier |> Enum.map(&bare(cut(&1))) |> Enum.intersperse(bare(""))
          )
        ]
  end

  defp texts(state),
    do: for(%{event: %{"kind" => "text", "text" => text}} <- state.events, do: text)

  defp missing?(state), do: state.missing or state.local_dropped > 0
  defp bare(text), do: {"", text}

  defp cut(text) when byte_size(text) <= @message_bytes, do: text
  defp cut(text), do: prefix(text, @message_bytes) <> " …"

  defp count(n, noun), do: "#{n} #{noun}#{if n == 1, do: "", else: "s"}"

  defp request(state, operation, props, status) do
    id = "worker-output-#{System.unique_integer([:positive, :monotonic])}"
    wire = Wire.request(operation, Map.put(props, :id, id))
    {%{state | pending: %{id => operation}, status: status}, [wire]}
  end

  defp accept(state, :worker_inspect, %{"view" => view}) do
    if exact_view?(state, view) do
      state = %{state | view: view, view_current: true}

      case view["output"] do
        %{"available" => true} ->
          request(
            state,
            :worker_output_subscribe,
            %{execution: state.execution, cursor: state.cursor},
            :subscribing
          )

        %{"available" => false} = capability ->
          {note(
             %{state | status: :unavailable, current: false},
             "Output unavailable: #{capability["reason"] || "no reason supplied"}. Guidance availability is independent."
           ), []}

        _ ->
          {note(
             %{state | status: :unsupported, current: false},
             "Output capability is unsupported or not established; guidance availability does not imply output support."
           ), []}
      end
    else
      reject(state, "Inspect view does not match the exact execution/attempt.")
    end
  end

  defp accept(state, :worker_output_subscribe, reply) do
    with :ok <- validate_stream(state, reply["stream"], reply["reset"]),
         :ok <- validate_reset(state, reply),
         true <- exact_view?(state, reply["view"]),
         true <- token?(reply["subscription"]) and token?(reply["cursor"]) do
      state = establish(state, reply)

      state = %{
        state
        | subscription: reply["subscription"],
          cursor: reply["cursor"],
          view: reply["view"],
          view_current: true,
          current: true,
          error: nil,
          replay_watermark: reply["stream"]["watermark"],
          retries: 0
      }

      state = %{state | more: state.last_sequence < state.stream["watermark"]}
      {observed(state), []}
    else
      {:error, reason} ->
        reject(state, reason)

      false ->
        reject(
          state,
          "Subscribe requires an exact view and nonempty subscription/cursor; nothing was accepted."
        )
    end
  end

  defp accept(state, :worker_output_next, reply) do
    with true <- reply["subscription"] == state.subscription,
         :ok <- validate_stream(state, reply["stream"], reply["reset"]),
         :ok <- validate_reset(state, reply),
         true <- is_nil(reply["view"]) or exact_view?(state, reply["view"]),
         true <- token?(reply["cursor"]),
         candidate = establish(state, reply),
         {:ok, events, last_sequence} <- validate_events(candidate, reply["events"]),
         :ok <- validate_frontier(state, reply, events, last_sequence) do
      state = candidate

      entries =
        Enum.map(events, &%{epoch: state.stream["epoch"], segment: state.segment, event: &1})

      state =
        retain(
          %{
            state
            | last_sequence: last_sequence,
              cursor: reply["cursor"],
              more: reply["more"],
              current: true,
              error: nil
          },
          entries
        )

      state =
        if reply["view"], do: %{state | view: reply["view"], view_current: true}, else: state

      {observed(state), []}
    else
      {:gap, reason} ->
        reject(state, reason, :gap)

      {:error, reason} ->
        reject(state, reason)

      false ->
        reject(
          state,
          "Output batch subscription, cursor or view does not match the exact request."
        )
    end
  end

  defp accept_error(state, reply) do
    error = reply["error"]
    view = reply["view"]
    reset = reply["reset"]

    cond do
      error["code"] == "forbidden" and (not is_nil(view) or not is_nil(reset)) ->
        reject(state, "Forbidden output response disclosed a view or reset.")

      not is_nil(view) and not exact_view?(state, view) ->
        reject(state, "Output error view does not match the exact execution/attempt.")

      error["code"] == "output_unavailable" and
          (not exact_view?(state, view) or not is_map(reset) or
             reset["reason"] != "output_unavailable") ->
        reject(
          state,
          "Output unavailable requires an explicit reset and refreshed exact view; no stream was fabricated."
        )

      not is_nil(reset) and (not exact_view?(state, view) or not reset_shape?(reset)) ->
        reject(
          state,
          "Output error reset requires an explicit reason, valid interval and refreshed exact view."
        )

      true ->
        status =
          case error["code"] do
            "output_unavailable" -> :unavailable
            "unsupported" -> :unsupported
            "unsupported_output" -> :unsupported
            _ -> :error
          end

        state = %{state | status: status, error: error, current: false}
        state = if view, do: %{state | view: view, view_current: true}, else: state
        state = if reset, do: discontinuity(state, reset), else: state
        {state, []}
    end
  end

  defp validate_stream(state, stream, reset) do
    cond do
      not is_map(stream) or stream["execution"] != state.execution ->
        {:error, "Output stream does not match the exact execution/attempt."}

      not token?(stream["epoch"]) or not is_integer(stream["first_sequence"]) or
        stream["first_sequence"] < 1 or not is_integer(stream["watermark"]) or
          stream["watermark"] < stream["first_sequence"] - 1 ->
        {:error, "Invalid output epoch or replay watermark."}

      state.stream && is_nil(reset) && state.stream["epoch"] != stream["epoch"] ->
        {:error, "Unknown epoch change without an explicit reset; accepted cursor retained."}

      state.stream && is_nil(reset) &&
          (stream["watermark"] < state.stream["watermark"] or
             (state.ended and not stream["ended"])) ->
        {:error, "Output stream regressed without an explicit reset."}

      true ->
        :ok
    end
  end

  defp validate_reset(state, reply) do
    case reply["reset"] do
      nil ->
        if is_nil(state.cursor) and reply["stream"]["first_sequence"] > 1,
          do: {:error, "Retained replay prefix is missing without an explicit reset."},
          else: :ok

      reset ->
        stream = reply["stream"]
        same_epoch = not is_nil(state.stream) and state.stream["epoch"] == stream["epoch"]
        expected = if same_epoch and state.last_sequence, do: state.last_sequence + 1, else: 1

        cond do
          not exact_view?(state, reply["view"]) ->
            {:error, "Output reset is missing a refreshed exact view."}

          not reset_shape?(reset) ->
            {:error,
             "Output reset requires a reason and either both inclusive loss bounds or neither."}

          state.stream && not same_epoch && is_integer(reset["to_sequence"]) ->
            {:error,
             "An epoch change cannot establish a known loss interval for the previous epoch."}

          is_integer(reset["to_sequence"]) and
              (reset["to_sequence"] != stream["first_sequence"] - 1 or
                 reset["from_sequence"] != expected) ->
            {:error, "Output reset interval does not describe the missing replay prefix."}

          true ->
            :ok
        end
    end
  end

  defp reset_shape?(reset) when is_map(reset) do
    from = reset["from_sequence"]
    to = reset["to_sequence"]

    bounds =
      (is_nil(from) and is_nil(to) and reset["reason"] != "retention_gap") or
        (is_integer(from) and is_integer(to) and from >= 1 and to >= from and
           reset["reason"] not in ["epoch_changed", "output_unavailable"])

    token?(reset["reason"]) and bounds
  end

  defp reset_shape?(_), do: false

  defp establish(state, reply) do
    stream = reply["stream"]
    reset = reply["reset"]
    state = if reset, do: discontinuity(state, reset), else: state

    last =
      if not is_nil(reset) or is_nil(state.last_sequence),
        do: stream["first_sequence"] - 1,
        else: state.last_sequence

    watermark = if reset, do: stream["watermark"], else: state.replay_watermark

    %{
      state
      | stream: stream,
        ended: stream["ended"],
        last_sequence: last,
        replay_watermark: watermark
    }
  end

  defp discontinuity(state, reset) do
    interval =
      if is_integer(reset["from_sequence"]),
        do: "lost inclusive sequences #{reset["from_sequence"]}–#{reset["to_sequence"]}",
        else: "lost interval unknown"

    note(
      %{state | segment: state.segment + 1, current: false, missing: true},
      "Reset #{reset["reason"]}: #{interval}. Earlier retained output is non-current/discontinuous."
    )
  end

  defp validate_events(state, events) do
    known = Map.new(state.events, &{{&1.epoch, &1.event["sequence"]}, &1.event})

    if length(events) <= @max_events do
      Enum.reduce_while(events, {:ok, [], state.last_sequence, nil, known}, fn event,
                                                                               {:ok, accepted,
                                                                                last, previous,
                                                                                seen} ->
        sequence = event["sequence"]
        known_event = seen[{state.stream["epoch"], sequence}]

        cond do
          not safe_event?(event) or sequence > state.stream["watermark"] ->
            {:halt,
             {:error, "Invalid safe event projection or event beyond the stream watermark."}}

          previous && sequence < previous ->
            {:halt,
             {:gap,
              "Out-of-order output batch; entire batch rejected, accepted cursor retained for replay."}}

          known_event && known_event != event ->
            {:halt, {:error, "Conflicting duplicate output event; accepted cursor retained."}}

          sequence <= last ->
            {:cont, {:ok, accepted, last, sequence, seen}}

          sequence != last + 1 ->
            {:halt,
             {:gap,
              "Sequence gap: expected #{last + 1}, received #{sequence}; entire batch rejected. Replay from the accepted cursor or reconnect for an explicit reset."}}

          true ->
            {:cont,
             {:ok, [event | accepted], sequence, sequence,
              Map.put(seen, {state.stream["epoch"], sequence}, event)}}
        end
      end)
      |> case do
        {:ok, accepted, last, _previous, _seen} -> {:ok, Enum.reverse(accepted), last}
        error -> error
      end
    else
      {:error, "Output batch exceeds the bounded client event budget; accepted cursor retained."}
    end
  end

  defp safe_event?(%{"sequence" => sequence, "kind" => kind} = event)
       when is_integer(sequence) and sequence > 0 do
    fields =
      case kind do
        kind when kind in ["text", "activity"] -> ~w(sequence kind text)
        "tool" -> ~w(sequence kind tool_name status)
        _ -> []
      end

    fields != [] and Map.keys(event) -- fields == [] and
      Enum.all?(fields -- ~w(sequence kind), &literal?(event[&1])) and
      :erlang.external_size(event) <= @max_bytes
  end

  defp safe_event?(_), do: false

  defp validate_frontier(state, reply, events, last) do
    cond do
      not reply["more"] and last < reply["stream"]["watermark"] ->
        {:gap, "Output batch claims drained before its watermark; accepted cursor retained."}

      reply["more"] and events == [] and is_nil(reply["reset"]) ->
        {:gap, "Output batch claims more without progress; accepted cursor retained."}

      is_nil(reply["reset"]) and events != [] and reply["cursor"] == state.cursor ->
        {:error, "Output cursor did not advance with newly accepted events."}

      is_nil(reply["reset"]) and events == [] and reply["cursor"] != state.cursor ->
        {:error, "Output cursor changed without new events or an explicit reset."}

      true ->
        :ok
    end
  end

  defp observed(state) do
    drained = state.ended and not state.more

    %{
      state
      | status: if(drained, do: :ended, else: :ready),
        replay_complete: state.last_sequence >= state.replay_watermark
    }
  end

  defp retain(state, entries) do
    known = MapSet.new(state.events, &{&1.epoch, &1.event["sequence"]})
    entries = Enum.reject(entries, &MapSet.member?(known, {&1.epoch, &1.event["sequence"]}))
    events = state.events ++ entries
    bytes = state.retained_bytes + Enum.reduce(entries, 0, &(:erlang.external_size(&1) + &2))
    {events, bytes, dropped} = trim(events, bytes, length(events), 0)
    %{state | events: events, retained_bytes: bytes, local_dropped: state.local_dropped + dropped}
  end

  defp trim([event | rest], bytes, count, dropped) when bytes > @max_bytes or count > @max_events,
    do: trim(rest, bytes - :erlang.external_size(event), count - 1, dropped + 1)

  defp trim(events, bytes, _count, dropped), do: {events, bytes, dropped}

  defp reject(state, reason, status \\ :error),
    do:
      {note(
         %{
           state
           | status: status,
             current: false,
             error: %{"code" => "invalid_output", "message" => reason, "retryable" => false}
         },
         reason
       ), []}

  defp note(state, text) do
    text = prefix(text, @max_note_bytes)
    %{state | notes: Enum.take(Enum.uniq([text | state.notes]), @max_notes)}
  end

  defp prefix(text, limit) when byte_size(text) <= limit, do: text

  defp prefix(text, limit) do
    part = binary_part(text, 0, limit)
    if String.valid?(part), do: :binary.copy(part), else: prefix(text, limit - 1)
  end

  defp normalize(execution) do
    Wire.model(:runtime_execution, execution)
  rescue
    ArgumentError -> nil
  end

  defp exact_execution?(%{"worker" => worker, "turn" => turn, "attempt" => attempt}),
    do:
      Enum.all?(
        [worker["environment"], worker["machine"], worker["worker"], turn, attempt],
        &token?/1
      )

  defp exact_execution?(_), do: false
  defp exact_view?(state, view), do: is_map(view) and view["execution"] == state.execution
  defp literal?(value), do: is_binary(value) and String.valid?(value)
  defp token?(value), do: literal?(value) and byte_size(value) > 0 and byte_size(value) <= 4096

  defp execution_text(nil), do: "Unavailable"

  defp execution_text(execution) do
    worker = execution["worker"]

    Enum.join(
      [
        worker["environment"],
        worker["machine"],
        worker["worker"],
        execution["turn"],
        execution["attempt"]
      ],
      " / "
    )
  end

  defp replay_text(%{replay_watermark: nil}), do: "Not established"

  defp replay_text(state),
    do:
      "Snapshot watermark #{state.replay_watermark}; " <>
        if(state.replay_complete, do: "replayed", else: "replay pending")

  defp error_fields(%{error: nil}), do: []

  defp error_fields(state),
    do: [
      {"Error",
       "#{state.error["code"]}: #{state.error["message"]} (retryable: #{state.error["retryable"]})"}
    ]

  defp retention_fields(%{local_dropped: 0}), do: []

  defp retention_fields(state),
    do: [
      {"Local retention",
       "#{state.local_dropped} earlier events evicted by this viewer's bounded retention; displayed text is not a complete contiguous transcript. Runtime cursor is unchanged by local eviction."}
    ]

  defp event_fields(%{"kind" => "activity", "text" => text}), do: [{"activity", text}]

  defp event_fields(%{"kind" => "tool"} = event),
    do: [{"tool", "#{event["tool_name"]} #{event["status"]}"}]

  defp item(id, title, fields) do
    {id,
     Blocks.decode(%{
       "type" => "item",
       "props" => %{
         "title" => title,
         "fields" =>
           Enum.map(fields, fn {label, value} -> %{"label" => label, "value" => value} end)
       }
     })}
  end
end
