defmodule AtlasTui.WorkerOutputTest do
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Wire.Control.Workers.Protocol, as: Wire
  alias AtlasTui.{Blocks, WorkerOutput}

  @execution %{
    "worker" => %{"environment" => "test", "machine" => "machine-a", "worker" => "worker-a"},
    "turn" => "turn-a",
    "attempt" => "attempt-a"
  }

  test "connect inspects the exact target and only explicit output availability subscribes" do
    {state, [inspect]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    assert inspect["op"] == "worker_inspect"
    assert inspect["execution"] == @execution
    assert state.status == :inspecting
    assert {^state, []} = WorkerOutput.connect(state)
    assert {^state, []} = WorkerOutput.next(state)

    {state, [subscribe]} = WorkerOutput.receive(state, inspect_reply(inspect, view()))
    assert subscribe["op"] == "worker_output_subscribe"
    assert subscribe["execution"] == @execution
    refute Map.has_key?(subscribe, "cursor")
    assert state.status == :subscribing
    assert map_size(state.pending) == 1
    assert {^state, []} = WorkerOutput.next(state)

    {state, []} = WorkerOutput.receive(state, subscribe_reply(subscribe, stream(2)))
    assert state.view == view()
    assert state.stream == stream(2)
    assert state.subscription == "subscription-a"
    assert state.cursor == "opaque-before-replay"
    assert state.last_sequence == 0
    assert state.more
    refute state.replay_complete
    assert state.pending == %{}
    assert state.events == []
  end

  test "independent viewers never share pending requests, subscription tokens or accepted cursors" do
    {first, [request_a]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {second, [request_b]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    refute request_a["id"] == request_b["id"]
    reply = inspect_reply(request_a, view())
    assert {^second, []} = WorkerOutput.receive(second, reply)
    {first, [subscribe_a]} = WorkerOutput.receive(first, reply)
    {second, [subscribe_b]} = WorkerOutput.receive(second, inspect_reply(request_b, view()))
    {first, []} = WorkerOutput.receive(first, subscribe_reply(subscribe_a, stream(1)))

    {second, []} =
      WorkerOutput.receive(
        second,
        subscribe_reply(subscribe_b, stream(1), subscription: "subscription-b")
      )

    {first, [next_a]} = WorkerOutput.next(first)
    {second, [next_b]} = WorkerOutput.next(second)
    reply = batch_reply(next_a, [event(1)], "first-cursor", stream(1))
    assert {^second, []} = WorkerOutput.receive(second, reply)
    {first, []} = WorkerOutput.receive(first, reply)
    assert first.cursor == "first-cursor"
    assert second.cursor == "opaque-before-replay"
    assert next_b["subscription"] == "subscription-b"
    assert second.events == []
  end

  test "missing exact attempts or machine identities refuse output without fabricated targets" do
    for execution <- [
          nil,
          %{},
          Map.delete(@execution, "attempt"),
          put_in(@execution, ["worker", "machine"], "")
        ] do
      state = WorkerOutput.new(execution)
      assert {^state, []} = WorkerOutput.connect(state)
      assert state.subscription == nil
      assert state.cursor == nil
      assert text(state) =~ "Exact execution unavailable"
    end
  end

  test "output support and guidance availability are independent" do
    for {output, expected} <- [
          {nil, :unsupported},
          {%{"available" => false, "replay" => false, "reason" => "adapter unsupported"},
           :unavailable}
        ] do
      {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
      view = put_in(view(), ["guidance", "available"], true)
      view = if output, do: Map.put(view, "output", output), else: Map.delete(view, "output")
      {state, []} = WorkerOutput.receive(state, inspect_reply(request, view))
      assert state.status == expected
      assert state.view["guidance"]["available"]
      assert state.stream == nil
      assert state.cursor == nil
      assert state.subscription == nil
      assert text(state) =~ "guidance"
    end

    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [_subscribe]} = WorkerOutput.receive(state, inspect_reply(request, view()))
    refute state.view["guidance"]["available"]
    assert state.status == :subscribing
  end

  test "the initial opaque cursor precedes the first replay event and receive never polls" do
    state = subscribed(watermark: 2)
    {state, [first]} = WorkerOutput.next(state)
    assert first["cursor"] == "opaque-before-replay"
    assert first["op"] == "worker_output_next"
    assert map_size(state.pending) == 1
    assert {^state, []} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(first, [event(1)], "cursor-1", stream(2), more: true)
      )

    assert sequences(state) == [1]
    assert state.last_sequence == 1
    assert state.more
    refute state.replay_complete
    assert state.pending == %{}
    {state, [second]} = WorkerOutput.next(state)
    assert second["cursor"] == "cursor-1"

    {state, []} =
      WorkerOutput.receive(state, batch_reply(second, [event(2)], "cursor-2", stream(2)))

    assert sequences(state) == [1, 2]
    assert state.replay_complete
    refute state.more
    refute Map.has_key?(state, :history_position)
  end

  test "ordered duplicates are discarded but an out-of-order batch is rejected atomically" do
    state = accepted_one()
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(1), event(2), event(2)], "cursor-2", stream(2))
      )

    assert sequences(state) == [1, 2]
    {pending, [request]} = WorkerOutput.next(state)

    {rejected, []} =
      WorkerOutput.receive(
        pending,
        batch_reply(request, [event(3), event(2)], "not-accepted", stream(3))
      )

    assert rejected.status == :gap
    assert rejected.events == state.events
    assert rejected.cursor == "cursor-2"
    assert rejected.last_sequence == 2
    assert text(rejected) =~ "Out-of-order"
    {retry, [request]} = WorkerOutput.next(rejected)
    assert request["cursor"] == "cursor-2"

    {retry, []} =
      WorkerOutput.receive(retry, batch_reply(request, [event(3)], "cursor-3", stream(3)))

    assert sequences(retry) == [1, 2, 3]
    assert retry.status == :ready
  end

  test "conflicting duplicate payloads do not advance the accepted cursor" do
    state = accepted_one()
    {pending, [request]} = WorkerOutput.next(state)
    conflict = %{event(1) | "text" => "different"}

    {rejected, []} =
      WorkerOutput.receive(pending, batch_reply(request, [conflict], "cursor-1", stream(1)))

    assert rejected.status == :error
    assert rejected.events == state.events
    assert rejected.cursor == state.cursor
    assert text(rejected) =~ "Conflicting duplicate"
  end

  test "a sequence gap preserves the entire frontier and explicit retention reset shows inclusive loss" do
    state = accepted_one()
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(state, batch_reply(request, [event(3)], "bad-frontier", stream(3)))

    assert state.status == :gap
    assert sequences(state) == [1]
    assert state.cursor == "cursor-1"
    assert text(state) =~ "expected 2, received 3"

    {state, [request]} = WorkerOutput.next(state)
    reset = %{"reason" => "retention_gap", "from_sequence" => 2, "to_sequence" => 3}

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(4)], "cursor-4", stream(4, first: 4),
          reset: reset,
          view: view()
        )
      )

    assert sequences(state) == [1, 4]
    assert state.cursor == "cursor-4"
    assert state.status == :ready
    assert text(state) =~ "lost inclusive sequences 2–3"
    refute current?(state, 1)
    assert current?(state, 4)
    assert missing_lines(state) == 1
  end

  test "epoch changes require a reset and unknown loss stays explicitly unknown" do
    state = accepted_one()
    {pending, [request]} = WorkerOutput.next(state)
    changed = stream(1, epoch: "epoch-b")

    {rejected, []} =
      WorkerOutput.receive(pending, batch_reply(request, [event(1)], "new-epoch", changed))

    assert rejected.cursor == "cursor-1"
    assert rejected.stream["epoch"] == "epoch-a"
    assert text(rejected) =~ "Unknown epoch change"

    reset = %{"reason" => "epoch_changed"}
    fresh_view = %{view() | "confirmed_at" => "2026-11-06T12:01:00Z"}

    {state, []} =
      WorkerOutput.receive(
        pending,
        batch_reply(request, [event(1)], "new-epoch", changed, reset: reset, view: fresh_view)
      )

    assert state.stream["epoch"] == "epoch-b"
    assert length(state.events) == 2
    assert state.view == fresh_view
    assert state.cursor == "new-epoch"
    assert text(state) =~ "lost interval unknown"
    assert text(state) =~ "Earlier retained output is non-current/discontinuous"
    assert hd(state.events).segment != List.last(state.events).segment
  end

  test "a reset without a refreshed exact view or truthful interval never commits" do
    state = accepted_one()
    reset = %{"reason" => "retention_gap", "from_sequence" => 2, "to_sequence" => 3}

    invalid = [
      [reset: reset],
      [reset: reset, view: view(put_in(@execution, ["attempt"], "foreign"))],
      [reset: %{"reason" => "retention_gap"}, view: view()],
      [reset: %{"reason" => "retention_gap", "from_sequence" => 2}, view: view()],
      [
        reset: %{"reason" => "retention_gap", "from_sequence" => 3, "to_sequence" => 2},
        view: view()
      ],
      [
        reset: %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 3},
        view: view()
      ],
      [reset: %{"reason" => ""}, view: view()]
    ]

    for opts <- invalid do
      {pending, [request]} = WorkerOutput.next(state)

      {rejected, []} =
        WorkerOutput.receive(
          pending,
          batch_reply(request, [event(4)], "bad-reset", stream(4, first: 4), opts)
        )

      assert rejected.status == :error
      assert rejected.cursor == "cursor-1"
      assert rejected.events == state.events
      assert rejected.stream == state.stream
    end
  end

  test "no cursor replays the retained prefix only with an explicit truncated-prefix marker" do
    {state, [inspect]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [subscribe]} = WorkerOutput.receive(state, inspect_reply(inspect, view()))
    refute Map.has_key?(subscribe, "cursor")
    retained = stream(8, first: 7)
    {rejected, []} = WorkerOutput.receive(state, subscribe_reply(subscribe, retained))
    assert rejected.status == :error
    assert rejected.cursor == nil
    assert text(rejected) =~ "prefix is missing"
    reset = %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => 6}
    {state, []} = WorkerOutput.receive(state, subscribe_reply(subscribe, retained, reset: reset))
    assert state.last_sequence == 6
    assert state.events == []
    assert text(state) =~ "lost inclusive sequences 1–6"
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(7), event(8)], "cursor-8", retained)
      )

    assert sequences(state) == [7, 8]
    assert state.replay_complete
  end

  test "an explicit epoch reset cannot invent a known interval from the lost epoch" do
    state = accepted_one()
    {pending, [request]} = WorkerOutput.next(state)
    reset = %{"reason" => "epoch_changed", "from_sequence" => 1, "to_sequence" => 3}

    reply =
      batch_reply(request, [event(4)], "new-epoch", stream(4, first: 4, epoch: "epoch-b"),
        reset: reset,
        view: view()
      )

    {rejected, []} = WorkerOutput.receive(pending, reply)
    assert rejected.status == :error
    assert rejected.cursor == state.cursor
    assert rejected.events == state.events
    assert rejected.stream == state.stream
  end

  test "replay watermark stays captured while live watermark advances and ended is not worker completion" do
    state = subscribed(watermark: 2)
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(1)], "cursor-1", stream(4), more: true)
      )

    assert state.replay_watermark == 2
    refute state.replay_complete
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(2)], "cursor-2", stream(4, ended: true), more: true)
      )

    assert state.replay_complete
    assert state.ended
    assert state.status == :ready
    assert state.more
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(
        state,
        batch_reply(request, [event(3), event(4)], "cursor-4", stream(4, ended: true))
      )

    assert state.status == :ended
    refute state.more
    assert {^state, []} = WorkerOutput.next(state)
    assert state.view["state"] == "running"
    assert state.view["outcome"] == nil
    assert text(state) =~ "worker lifecycle remains independent"
    # The worker's state is the page's, not repeated by its output.
    refute Enum.any?(all_fields(state), &(&1.value == state.view["state"]))
  end

  test "an already-ended retained subscription replays before becoming drained" do
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, view()))
    ended = stream(1, ended: true)
    {state, []} = WorkerOutput.receive(state, subscribe_reply(request, ended))
    assert state.ended
    assert state.more
    assert state.status == :ready
    {state, [request]} = WorkerOutput.next(state)
    {state, []} = WorkerOutput.receive(state, batch_reply(request, [event(1)], "cursor-1", ended))
    assert state.status == :ended
    assert {^state, []} = WorkerOutput.next(state)
    assert state.view["state"] == "running"
  end

  test "idle empty batches are valid observations with no automatic polling" do
    state = subscribed()
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(state, batch_reply(request, [], "opaque-before-replay", stream(0)))

    assert state.status == :ready
    assert state.events == []
    assert state.pending == %{}
    refute state.more
    refute state.ended
    assert state.error == nil
    assert {_, [_one_request]} = WorkerOutput.next(state)
  end

  test "disconnect preserves accepted cursor and events, invalidates pending, and reinspects before resume" do
    state = accepted_one()
    {pending, [interrupted]} = WorkerOutput.next(state)
    disconnected = WorkerOutput.disconnect(pending)
    assert disconnected.status == :detached
    assert disconnected.cursor == "cursor-1"
    assert disconnected.events == state.events
    assert disconnected.pending == %{}
    assert disconnected.subscription == nil
    refute disconnected.view_current
    refute current?(disconnected, 1)
    late = batch_reply(interrupted, [event(2)], "late-cursor", stream(2))
    assert {^disconnected, []} = WorkerOutput.receive(disconnected, late)
    {state, [inspect]} = WorkerOutput.connect(disconnected)
    assert inspect["execution"] == @execution
    {state, [subscribe]} = WorkerOutput.receive(state, inspect_reply(inspect, view()))
    assert subscribe["cursor"] == "cursor-1"
    assert subscribe["execution"] == @execution

    {state, []} =
      WorkerOutput.receive(
        state,
        subscribe_reply(subscribe, stream(2), cursor: "cursor-1", subscription: "resumed")
      )

    assert state.last_sequence == 1
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(state, batch_reply(request, [event(2)], "cursor-2", stream(2)))

    assert sequences(state) == [1, 2]
    refute current?(state, 1)
    assert current?(state, 2)
    # A disconnect alone loses nothing: the replay resumed from the accepted cursor.
    assert missing_lines(state) == 0
  end

  test "correlation, typed version and exact identities are checked before any acceptance" do
    state = subscribed(watermark: 1)
    {pending, [request]} = WorkerOutput.next(state)
    reply = batch_reply(request, [event(1)], "cursor-1", stream(1))
    assert {^pending, []} = WorkerOutput.receive(pending, %{reply | "id" => "foreign"})

    assert {^pending, []} =
             WorkerOutput.receive(pending, %{reply | "op" => "worker_inspect_result"})

    for malformed <- [
          %{reply | "version" => "99"},
          %{reply | "channel" => "runtime"},
          Map.delete(reply, "cursor")
        ] do
      {rejected, []} = WorkerOutput.receive(pending, malformed)
      assert rejected.status == :error
      assert rejected.events == []
      assert rejected.cursor == "opaque-before-replay"
    end

    executions =
      [put_in(@execution, ["turn"], "other"), put_in(@execution, ["attempt"], "other")] ++
        Enum.map(~w(environment machine worker), &put_in(@execution, ["worker", &1], "other"))

    for execution <- executions do
      foreign_stream = %{stream(1) | "execution" => execution}

      {rejected, []} =
        WorkerOutput.receive(
          pending,
          batch_reply(request, [event(1)], "foreign-cursor", foreign_stream)
        )

      assert rejected.events == []
      assert rejected.stream == state.stream
      assert rejected.cursor == state.cursor
      assert text(rejected) =~ "exact execution/attempt"
    end
  end

  test "foreign inspect and subscribe views cannot retarget an output viewer" do
    foreign = view(put_in(@execution, ["attempt"], "successor-attempt"))
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {rejected, []} = WorkerOutput.receive(state, inspect_reply(request, foreign))
    assert rejected.status == :error
    assert rejected.execution == @execution
    assert rejected.view == nil
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, view()))

    {rejected, []} =
      WorkerOutput.receive(state, subscribe_reply(request, stream(0), view: foreign))

    assert rejected.subscription == nil
    assert rejected.cursor == nil
    assert rejected.execution == @execution
  end

  test "malformed wrong-scope and future opaque cursors remain honest server errors, not local decoding" do
    state = accepted_one()

    for reason <- ["malformed cursor", "cursor belongs to another attempt", "future cursor"] do
      {pending, [request]} = WorkerOutput.next(state)

      reply =
        Wire.reply(:worker_output_next, :error,
          id: request["id"],
          error: %{
            code: "invalid_cursor",
            message: reason,
            retryable: false
          }
        )

      {rejected, []} = WorkerOutput.receive(pending, reply)
      assert rejected.error["code"] == "invalid_cursor"
      assert rejected.error["message"] == reason
      assert rejected.cursor == state.cursor
      assert rejected.events == state.events
      assert rejected.execution == @execution
      assert {^rejected, []} = WorkerOutput.next(rejected)
      assert text(rejected) =~ reason
    end
  end

  test "unavailable ring errors require a reset and refreshed view without a fabricated stream" do
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, view()))

    props = %{
      id: request["id"],
      error: %{code: "output_unavailable", message: "retained ring lost", retryable: true}
    }

    {rejected, []} =
      WorkerOutput.receive(state, Wire.reply(:worker_output_subscribe, :error, props))

    assert rejected.error["code"] == "invalid_output"
    props = Map.merge(props, %{view: view(), reset: %{reason: "output_unavailable"}})
    {state, []} = WorkerOutput.receive(state, Wire.reply(:worker_output_subscribe, :error, props))
    assert state.status == :unavailable
    assert state.error["code"] == "output_unavailable"
    assert state.view == view()
    assert state.stream == nil
    assert state.cursor == nil
    assert state.subscription == nil
    assert text(state) =~ "lost interval unknown"
  end

  test "unsupported operation errors preserve guidance and never authorize invented output" do
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    available = put_in(view(), ["guidance", "available"], true)
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, available))

    reply =
      Wire.reply(:worker_output_subscribe, :error,
        id: request["id"],
        error: %{
          code: "unsupported",
          message: "output adapter unsupported",
          retryable: false
        }
      )

    {state, []} = WorkerOutput.receive(state, reply)
    assert state.status == :unsupported
    assert state.view["guidance"]["available"]
    assert state.stream == nil
    assert state.cursor == nil
    assert text(state) =~ "output adapter unsupported"
  end

  test "forbidden output errors never accept an accompanying disclosed view" do
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, view()))
    disclosed = %{view() | "confirmed_at" => "disclosed-later"}

    reply =
      Wire.reply(:worker_output_subscribe, :error,
        id: request["id"],
        error: %{code: "forbidden", message: "denied", retryable: false},
        view: disclosed
      )

    {state, []} = WorkerOutput.receive(state, reply)
    assert state.status == :error
    assert state.view == view()
    assert state.cursor == nil
    assert state.subscription == nil
    assert text(state) =~ "Forbidden output response"
    refute text(state) =~ "disclosed-later"
  end

  test "false cursor progress, false drain, future events and foreign subscriptions are rejected" do
    state = subscribed(watermark: 1)
    {pending, [request]} = WorkerOutput.next(state)

    replies = [
      batch_reply(request, [], "changed-without-events", stream(1)),
      batch_reply(request, [event(1)], "opaque-before-replay", stream(1)),
      batch_reply(request, [event(2)], "future", stream(1)),
      batch_reply(request, [event(1)], "cursor-1", stream(2)),
      batch_reply(request, [event(1)], "cursor-1", stream(1), subscription: "foreign"),
      batch_reply(request, [event(1)], "", stream(1)),
      batch_reply(request, [], "opaque-before-replay", stream(1), more: true)
    ]

    for reply <- replies do
      {rejected, []} = WorkerOutput.receive(pending, reply)
      assert rejected.status in [:error, :gap]
      assert rejected.cursor == state.cursor
      assert rejected.events == []
    end
  end

  test "safe literal Unicode text, activity and tool projections render only ordinary actionless items" do
    literal = "  λ雪 👩🏽‍💻\n\n<text>\t\"quoted\"  \n"

    events = [
      event(1, literal),
      %{"sequence" => 2, "kind" => "activity", "text" => "活動 雪"},
      %{"sequence" => 3, "kind" => "tool", "tool_name" => "read_雪", "status" => "finished"}
    ]

    state = subscribed(watermark: 3)
    {state, [request]} = WorkerOutput.next(state)
    {state, []} = WorkerOutput.receive(state, batch_reply(request, events, "cursor-3", stream(3)))
    # What the worker said leads the conversation; what it did is a detail.
    assert [%{label: "", value: ^literal}] = conversation(state).fields
    details = Enum.flat_map(WorkerOutput.details(state), fn {_, block} -> block.fields end)
    assert Enum.any?(details, &(&1.value == "活動 雪"))
    assert Enum.any?(details, &(&1.value =~ "read_雪" and &1.value =~ "finished"))
    refute Enum.any?(conversation(state).fields, &(&1.value == "活動 雪"))

    assert Enum.all?(output_blocks(state), fn {id, block} ->
             is_binary(id) and match?(%Blocks.Item{}, block) and block.actions == nil
           end)

    for unsafe <- [
          %{"sequence" => 1, "kind" => "reasoning", "text" => "secret"},
          %{
            "sequence" => 1,
            "kind" => "tool",
            "tool_name" => "read",
            "status" => "running",
            "text" => "secret input"
          }
        ] do
      pending = subscribed(watermark: 1)
      {pending, [request]} = WorkerOutput.next(pending)

      {rejected, []} =
        WorkerOutput.receive(pending, batch_reply(request, [unsafe], "unsafe", stream(1)))

      assert rejected.events == []
      refute text(rejected) =~ "secret"
    end
  end

  test "retained Unicode bytes, event count and uncertainty notes remain bounded with truthful local loss" do
    small = subscribed(watermark: 1000)
    {small, [request]} = WorkerOutput.next(small)

    {small, []} =
      WorkerOutput.receive(
        small,
        batch_reply(request, Enum.map(1..1000, &event/1), "cursor-1000", stream(1000))
      )

    {small, [request]} = WorkerOutput.next(small)

    {small, []} =
      WorkerOutput.receive(
        small,
        batch_reply(request, [event(1001)], "cursor-1001", stream(1001))
      )

    assert length(small.events) <= 1000
    assert small.local_dropped > 0
    assert small.cursor == "cursor-1001"
    assert text(small) =~ "Local retention"
    assert text(small) =~ "not a complete contiguous transcript"
    # The conversation says once, plainly, that earlier output is missing.
    assert missing_lines(small) == 1

    literal = String.duplicate("雪👩🏽‍💻", 700)
    large = subscribed(watermark: 30)

    large =
      Enum.reduce(1..30, large, fn sequence, state ->
        {state, [request]} = WorkerOutput.next(state)

        {state, []} =
          WorkerOutput.receive(
            state,
            batch_reply(request, [event(sequence, literal)], "cursor-#{sequence}", stream(30),
              more: sequence < 30
            )
          )

        state
      end)

    assert large.local_dropped > 0
    assert large.retained_bytes <= 256 * 1024
    assert Enum.reduce(large.events, 0, &(:erlang.external_size(&1) + &2)) == large.retained_bytes

    assert Enum.all?(
             large.events,
             &(String.valid?(&1.event["text"]) and &1.event["text"] == literal)
           )

    assert large.last_sequence == 30
    assert large.cursor == "cursor-30"
    disconnected = Enum.reduce(1..40, large, fn _, state -> WorkerOutput.disconnect(state) end)
    assert length(disconnected.notes) <= 16

    assert disconnected.retained_bytes + Enum.reduce(disconnected.notes, 0, &(byte_size(&1) + &2)) <=
             256 * 1024
  end

  defp subscribed(opts \\ []) do
    {state, [request]} = WorkerOutput.new(@execution) |> WorkerOutput.connect()
    {state, [request]} = WorkerOutput.receive(state, inspect_reply(request, view()))

    {state, []} =
      WorkerOutput.receive(
        state,
        subscribe_reply(request, stream(Keyword.get(opts, :watermark, 0)))
      )

    state
  end

  defp accepted_one do
    state = subscribed(watermark: 1)
    {state, [request]} = WorkerOutput.next(state)

    {state, []} =
      WorkerOutput.receive(state, batch_reply(request, [event(1)], "cursor-1", stream(1)))

    state
  end

  defp inspect_reply(request, view),
    do: Wire.reply(:worker_inspect, :result, id: request["id"], view: view)

  defp subscribe_reply(request, stream, opts \\ []) do
    props = %{
      id: request["id"],
      subscription: "subscription-a",
      view: view(),
      stream: stream,
      cursor: "opaque-before-replay"
    }

    Wire.reply(:worker_output_subscribe, :result, Map.merge(props, Map.new(opts)))
  end

  defp batch_reply(request, events, cursor, stream, opts \\ []) do
    props = %{
      id: request["id"],
      subscription: request["subscription"],
      events: events,
      cursor: cursor,
      stream: stream,
      more: false
    }

    Wire.reply(:worker_output_next, :result, Map.merge(props, Map.new(opts)))
  end

  defp stream(watermark, opts \\ []) do
    %{
      "execution" => @execution,
      "epoch" => Keyword.get(opts, :epoch, "epoch-a"),
      "first_sequence" => Keyword.get(opts, :first, 1),
      "watermark" => watermark,
      "ended" => Keyword.get(opts, :ended, false)
    }
  end

  defp event(sequence, text \\ "literal output"),
    do: %{"sequence" => sequence, "kind" => "text", "text" => text}

  defp view(execution \\ @execution) do
    %{
      "execution" => execution,
      "state" => "running",
      "confirmed_at" => "2026-11-06T12:00:00Z",
      "guidance" => %{"available" => false, "reason" => "guidance unsupported"},
      "output" => %{"available" => true, "replay" => true},
      "descriptor" => %{
        "harness" => "test-harness",
        "harness_version" => "1",
        "configured_model" => "configured",
        "capability_version" => "1",
        "queued_input" => false,
        "durable_accept_query" => false,
        "consumption_evidence" => false
      }
    }
  end

  defp sequences(state), do: Enum.map(state.events, & &1.event["sequence"])

  # Whether the retained event `sequence` belongs to the current subscription segment.
  defp current?(state, sequence) do
    entry = Enum.find(state.events, &(&1.event["sequence"] == sequence))
    state.current and entry.segment == state.segment
  end

  defp output_blocks(state),
    do: WorkerOutput.conversation(state, nil) ++ WorkerOutput.details(state)

  defp conversation(state) do
    [{"worker-output", block}] = WorkerOutput.conversation(state, nil)
    block
  end

  # The conversation's lines that are not what the worker said, less the one that counts
  # the earlier messages (there are more than the latest five): the lines that say earlier
  # output is missing.
  defp missing_lines(state) do
    said = for %{event: %{"kind" => "text", "text" => t}} <- state.events, do: t
    known = MapSet.new(said)

    lines =
      conversation(state).fields
      |> Enum.reject(&(&1.value == "" or MapSet.member?(known, &1.value)))
      |> length()

    if length(said) > 5, do: lines - 1, else: lines
  end

  defp all_fields(state),
    do: Enum.flat_map(output_blocks(state), fn {_, block} -> block.fields end)

  defp text(state),
    do:
      output_blocks(state)
      |> Enum.map_join("\n", fn {_, block} ->
        block.title <> "\n" <> Enum.map_join(block.fields, "\n", &(&1.label <> ": " <> &1.value))
      end)
end
