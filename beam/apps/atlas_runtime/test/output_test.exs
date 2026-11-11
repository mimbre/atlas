defmodule AtlasRuntime.OutputTest do
  use ExUnit.Case, async: true
  alias AtlasRuntime.Output

  @execution %{
    "worker" => %{"environment" => "private", "machine" => "box", "worker" => "worker-a"},
    "turn" => "turn-a",
    "attempt" => "attempt-a"
  }

  defp store(opts \\ []) do
    test = self()
    clock = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

    defaults = [
      name: nil,
      clock: fn -> Agent.get(clock, & &1) end,
      timer: fn pid, message, delay ->
        send(test, {:scheduled, pid, message, delay})
        make_ref()
      end
    ]

    server = start_supervised!({Output, Keyword.merge(defaults, opts)}, id: make_ref())
    assert_receive {:scheduled, ^server, :cleanup, _}
    {server, clock}
  end

  defp advance(clock, milliseconds), do: Agent.update(clock, &(&1 + milliseconds))
  defp text(value), do: %{"kind" => "text", "text" => value}
  defp execution(turn), do: Map.put(@execution, "turn", turn)

  defp owner do
    pid = spawn(fn -> owner_loop() end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp owner_loop do
    receive do
      {:run, from, ref, fun} ->
        send(from, {ref, fun.()})
        owner_loop()
    end
  end

  defp as_owner(pid, fun) do
    ref = make_ref()
    send(pid, {:run, self(), ref, fun})
    assert_receive {^ref, result}
    result
  end

  defp cleanup(server) do
    send(server, :cleanup)
    assert_receive {:scheduled, ^server, :cleanup, _}
    :sys.get_state(server)
  end

  defp replace_cursor(token, fun) do
    token
    |> Base.url_decode64!(padding: false)
    |> JSON.decode!()
    |> fun.()
    |> JSON.encode!()
    |> Base.url_encode64(padding: false)
  end

  test "snapshot cursor replays retained output and later appends without a race" do
    {server, _} = store()
    assert :ok = Output.open(@execution, self(), server)
    assert :ok = Output.append(@execution, text("before"), server)
    assert {:ok, snapshot} = Output.snapshot(@execution, nil, server)
    assert snapshot["stream"]["watermark"] == 1
    assert snapshot["stream"]["first_sequence"] == 1
    refute snapshot["stream"]["ended"]
    assert snapshot["stream"]["execution"] == @execution
    assert :ok = Output.append(@execution, text("after"), server)
    assert {:ok, batch} = Output.read(@execution, snapshot["cursor"], server)
    assert Enum.map(batch["events"], & &1["text"]) == ["before", "after"]
    assert Enum.map(batch["events"], & &1["sequence"]) == [1, 2]
    assert batch["stream"]["watermark"] == 2
    refute batch["more"]
    assert {:ok, empty} = Output.read(@execution, batch["cursor"], server)
    assert empty["events"] == []
    assert empty["cursor"] == batch["cursor"]
  end

  test "independent cursors never consume each other's output or mutate the ring" do
    {server, _} = store()
    :ok = Output.open(@execution, self(), server)
    {:ok, first} = Output.snapshot(@execution, nil, server)
    :ok = Output.append(@execution, text("one"), server)
    {:ok, viewer_a} = Output.read(@execution, first["cursor"], server)
    :ok = Output.append(@execution, text("two"), server)
    state = :sys.get_state(server)
    {:ok, next_a} = Output.read(@execution, viewer_a["cursor"], server)
    {:ok, viewer_b} = Output.read(@execution, first["cursor"], server)
    assert Enum.map(next_a["events"], & &1["text"]) == ["two"]
    assert Enum.map(viewer_b["events"], & &1["text"]) == ["one", "two"]
    assert :sys.get_state(server) == state
  end

  test "every execution identity dimension scopes the cursor" do
    {server, _} = store()
    :ok = Output.open(@execution, self(), server)
    {:ok, snapshot} = Output.snapshot(@execution, nil, server)

    for path <- [
          ["worker", "environment"],
          ["worker", "machine"],
          ["worker", "worker"],
          ["turn"],
          ["attempt"]
        ] do
      different = put_in(@execution, path, "different")
      :ok = Output.open(different, self(), server)
      assert {:error, "invalid_cursor"} = Output.read(different, snapshot["cursor"], server)
      assert {:error, "invalid_cursor"} = Output.snapshot(different, snapshot["cursor"], server)
    end
  end

  test "invalid identities, malformed cursors and future sequences are rejected" do
    {server, _} = store()

    for invalid <- [
          nil,
          %{},
          Map.delete(@execution, "attempt"),
          Map.put(@execution, "attempt", ""),
          Map.put(@execution, "attempt", 1),
          Map.put(@execution, "private", "secret"),
          put_in(@execution, ["worker", "machine"], <<255>>)
        ] do
      assert {:error, "invalid_execution"} = Output.open(invalid, self(), server)
      assert {:error, "invalid_execution"} = Output.snapshot(invalid, nil, server)
    end

    :ok = Output.open(@execution, self(), server)
    {:ok, snapshot} = Output.snapshot(@execution, nil, server)

    future =
      replace_cursor(snapshot["cursor"], fn [version, scope, epoch, _] ->
        [version, scope, epoch, 1]
      end)

    negative =
      replace_cursor(snapshot["cursor"], fn [version, scope, epoch, _] ->
        [version, scope, epoch, -1]
      end)

    bad_epoch =
      replace_cursor(snapshot["cursor"], fn [version, scope, _, sequence] ->
        [version, scope, "bad", sequence]
      end)

    for invalid <- [
          "",
          "not a cursor",
          String.duplicate("a", 513),
          %{},
          1,
          Base.url_encode64("{}", padding: false),
          future,
          negative,
          bad_epoch
        ] do
      assert {:error, "invalid_cursor"} = Output.read(@execution, invalid, server)
    end
  end

  test "open is idempotent for one owner and mutations cannot be made by viewers" do
    {server, _} = store()
    other = owner()
    assert {:error, "invalid_owner"} = Output.open(@execution, :not_a_pid, server)
    assert :ok = Output.open(@execution, self(), server)
    {:ok, before} = Output.snapshot(@execution, nil, server)
    assert :ok = Output.open(@execution, self(), server)
    assert {:ok, ^before} = Output.snapshot(@execution, nil, server)
    assert {:error, "owner_conflict"} = Output.open(@execution, other, server)

    assert {:error, "not_owner"} =
             as_owner(other, fn -> Output.append(@execution, text("no"), server) end)

    assert {:error, "not_owner"} = as_owner(other, fn -> Output.finish(@execution, server) end)
    assert :ok = Output.append(@execution, text("yes"), server)
    assert :ok = Output.finish(@execution, server)
    assert :ok = Output.finish(@execution, server)
    assert :ok = Output.open(@execution, self(), server)
    assert {:error, "output_ended"} = Output.append(@execution, text("late"), server)
    assert {:error, "owner_conflict"} = Output.open(@execution, other, server)
    {:ok, replay} = Output.read(@execution, before["cursor"], server)
    assert replay["stream"]["ended"]
    assert Enum.map(replay["events"], & &1["text"]) == ["yes"]
  end

  test "event count retention reports the exact lost prefix and resets snapshot cursor" do
    {server, _} = store(max_events: 2)
    :ok = Output.open(@execution, self(), server)
    {:ok, initial} = Output.snapshot(@execution, nil, server)
    for n <- 1..4, do: assert(:ok == Output.append(@execution, text("#{n}"), server))
    {:ok, snapshot} = Output.snapshot(@execution, initial["cursor"], server)

    assert snapshot["reset"] == %{
             "reason" => "retention_gap",
             "from_sequence" => 1,
             "to_sequence" => 2
           }

    assert snapshot["stream"]["first_sequence"] == 3
    assert snapshot["stream"]["watermark"] == 4
    {:ok, newcomer} = Output.snapshot(@execution, nil, server)
    assert newcomer["reset"] == snapshot["reset"]
    {:ok, newcomer_replay} = Output.read(@execution, newcomer["cursor"], server)
    assert Enum.map(newcomer_replay["events"], & &1["sequence"]) == [3, 4]
    {:ok, replay} = Output.read(@execution, initial["cursor"], server)
    assert replay["reset"] == snapshot["reset"]
    assert Enum.map(replay["events"], & &1["sequence"]) == [3, 4]
    {:ok, fresh} = Output.read(@execution, snapshot["cursor"], server)
    refute Map.has_key?(fresh, "reset")
    assert fresh["events"] == replay["events"]
  end

  test "encoded event bytes bound retention including array framing" do
    {server, _} = store(max_bytes: 260, max_event_bytes: 128)
    :ok = Output.open(@execution, self(), server)
    {:ok, initial} = Output.snapshot(@execution, nil, server)

    for _ <- 1..5,
        do: assert(:ok == Output.append(@execution, text(String.duplicate("x", 70)), server))

    {:ok, replay} = Output.read(@execution, initial["cursor"], server)
    assert byte_size(JSON.encode!(replay["events"])) <= 260
    assert length(replay["events"]) == 2
    assert replay["reset"]["to_sequence"] == 3
    [ring] = Map.values(:sys.get_state(server).rings)
    assert ring.bytes == byte_size(JSON.encode!(replay["events"]))
  end

  test "event age expires prefixes even on live streams without extending age on reads" do
    {server, clock} = store(max_age_ms: 100)
    :ok = Output.open(@execution, self(), server)
    {:ok, initial} = Output.snapshot(@execution, nil, server)
    :ok = Output.append(@execution, text("old"), server)
    advance(clock, 60)
    :ok = Output.append(@execution, text("new"), server)
    advance(clock, 40)
    {:ok, replay} = Output.read(@execution, initial["cursor"], server)
    assert Enum.map(replay["events"], & &1["text"]) == ["new"]

    assert replay["reset"] == %{
             "reason" => "retention_gap",
             "from_sequence" => 1,
             "to_sequence" => 1
           }

    advance(clock, 60)
    state = cleanup(server)
    [ring] = Map.values(state.rings)
    assert ring.count == 0
    assert ring.bytes == 2
    {:ok, empty} = Output.read(@execution, initial["cursor"], server)
    assert empty["events"] == []
    assert empty["reset"]["to_sequence"] == 2
    assert empty["stream"]["first_sequence"] == 3
    refute empty["stream"]["ended"]
    refute empty["more"]
  end

  test "batches are byte bounded and can drain without loss" do
    {server, _} = store(max_event_bytes: 256, max_reply_bytes: 512)
    :ok = Output.open(@execution, self(), server)
    {:ok, initial} = Output.snapshot(@execution, nil, server)

    for n <- 1..10,
        do:
          assert(
            :ok == Output.append(@execution, text("#{n}:" <> String.duplicate("x", 150)), server)
          )

    {events, batches} = drain(server, initial["cursor"], [], [])
    assert Enum.map(events, & &1["sequence"]) == Enum.to_list(1..10)
    assert length(batches) > 1
    assert Enum.all?(batches, &(byte_size(JSON.encode!(&1["events"])) <= 512))
    assert Enum.all?(Enum.drop(batches, -1), & &1["more"])
    refute List.last(batches)["more"]
  end

  defp drain(server, cursor, events, batches) do
    {:ok, batch} = Output.read(@execution, cursor, server)
    events = events ++ batch["events"]
    batches = batches ++ [batch]
    if batch["more"], do: drain(server, batch["cursor"], events, batches), else: {events, batches}
  end

  test "UTF-8 and JSON escaping survive chunk boundaries under the production event limit" do
    {server, _} = store()
    :ok = Output.open(@execution, self(), server)
    original = String.duplicate("a🦉é\"\\\n\t", 4500)
    :ok = Output.append(@execution, text(original), server)
    {events, batches} = drain(server, nil, [], [])
    assert length(events) > 1
    assert Enum.map_join(events, & &1["text"]) == original

    assert Enum.all?(
             events,
             &(String.valid?(&1["text"]) and byte_size(JSON.encode!(&1)) <= 16_384)
           )

    assert Enum.all?(batches, &(byte_size(JSON.encode!(&1["events"])) <= 65_536))
  end

  test "a multibyte codepoint fitting exactly is not split or rejected" do
    limit = byte_size(JSON.encode!(%{"kind" => "text", "text" => "🦉", "sequence" => 1}))
    {server, _} = store(max_event_bytes: limit)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.append(@execution, text("🦉🦉"), server)
    {:ok, replay} = Output.read(@execution, nil, server)
    assert Enum.map(replay["events"], & &1["text"]) == ["🦉", "🦉"]
  end

  test "retained chunks do not pin a discarded large producer binary" do
    {server, _} = store(max_events: 1)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.append(@execution, text(String.duplicate("x", 100_000)), server)
    {:ok, replay} = Output.read(@execution, nil, server)
    [event] = replay["events"]
    assert :binary.referenced_byte_size(event["text"]) == byte_size(event["text"])
    assert byte_size(JSON.encode!(event)) <= 16_384
  end

  test "closed safe event fields reject raw input, reasoning and extra metadata" do
    {server, _} = store()
    :ok = Output.open(@execution, self(), server)

    for event <- [
          Map.put(text("safe"), "reasoning", "secret"),
          Map.put(text("safe"), "raw", %{}),
          Map.put(text("safe"), "sequence", 1),
          %{"kind" => "reasoning", "text" => "secret"},
          %{"kind" => "text", "text" => <<255>>},
          %{kind: "text", text: "no"},
          %{"kind" => "tool", "tool_name" => "Read", "status" => "started", "input" => %{}},
          %{"kind" => "tool", "tool_name" => "", "status" => "started"},
          %{"kind" => "tool", "tool_name" => "Read", "status" => String.duplicate("x", 16_384)}
        ] do
      assert {:error, "invalid_event"} = Output.append(@execution, event, server)
    end

    assert :ok = Output.append(@execution, %{"kind" => "activity", "text" => "working"}, server)

    assert :ok =
             Output.append(
               @execution,
               %{"kind" => "tool", "tool_name" => "Read", "status" => "started"},
               server
             )

    {:ok, replay} = Output.read(@execution, nil, server)
    assert Enum.map(replay["events"], & &1["sequence"]) == [1, 2]
    assert Enum.map(replay["events"], & &1["kind"]) == ["activity", "tool"]
  end

  test "owner exit retains output and periodic cleanup expires it without readers" do
    {server, clock} = store(max_age_ms: 100)
    producer = owner()
    monitor = Process.monitor(producer)
    :ok = Output.open(@execution, producer, server)
    :ok = as_owner(producer, fn -> Output.append(@execution, text("retained"), server) end)
    Process.exit(producer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^producer, :killed}
    assert_ended(server, 100)
    {:ok, retained} = Output.read(@execution, nil, server)
    assert Enum.map(retained["events"], & &1["text"]) == ["retained"]
    assert :sys.get_state(server).monitors == %{}
    advance(clock, 100)
    state = cleanup(server)
    assert state.rings == %{}
    assert :queue.is_empty(state.cleanup)
    assert {:error, "output_unavailable"} = Output.snapshot(@execution, nil, server)
    assert {:error, "output_unavailable"} = Output.read(@execution, retained["cursor"], server)
    assert {:error, "output_unavailable"} = Output.append(@execution, text("no ring"), server)
  end

  defp assert_ended(server, attempts) do
    {:ok, snapshot} = Output.snapshot(@execution, nil, server)

    if snapshot["stream"]["ended"] do
      :ok
    else
      assert attempts > 0

      receive do
      after
        1 -> assert_ended(server, attempts - 1)
      end
    end
  end

  test "expiry is enforced before cleanup and reopening resets old cursors" do
    {server, clock} = store(max_age_ms: 100)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.append(@execution, text("old epoch"), server)
    {:ok, old} = Output.read(@execution, nil, server)
    :ok = Output.finish(@execution, server)
    advance(clock, 99)
    assert {:ok, _} = Output.snapshot(@execution, nil, server)
    assert :ok = Output.finish(@execution, server)
    advance(clock, 1)
    assert {:error, "output_unavailable"} = Output.read(@execution, old["cursor"], server)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.append(@execution, text("new epoch"), server)
    {:ok, current} = Output.read(@execution, old["cursor"], server)
    assert current["reset"] == %{"reason" => "epoch_changed"}
    assert current["stream"]["epoch"] != old["stream"]["epoch"]
    assert Enum.map(current["events"], & &1["sequence"]) == [1]
    assert Enum.map(current["events"], & &1["text"]) == ["new epoch"]
    assert :queue.len(:sys.get_state(server).cleanup) == 1
  end

  test "a store restart cannot silently accept an old cursor" do
    {before, _} = store()
    :ok = Output.open(@execution, self(), before)
    :ok = Output.append(@execution, text("gone"), before)
    {:ok, old} = Output.read(@execution, nil, before)
    GenServer.stop(before)
    {after_restart, _} = store()
    assert {:error, "output_unavailable"} = Output.read(@execution, old["cursor"], after_restart)
    :ok = Output.open(@execution, self(), after_restart)
    {:ok, fresh} = Output.snapshot(@execution, old["cursor"], after_restart)
    assert fresh["reset"] == %{"reason" => "epoch_changed"}
    assert fresh["stream"]["watermark"] == 0
  end

  test "stream cap evicts closed first, then oldest producer, never oldest viewer" do
    {server, clock} = store(max_streams: 2)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.append(@execution, text("oldest live"), server)
    advance(clock, 1)
    second = execution("second")
    :ok = Output.open(second, self(), server)
    :ok = Output.finish(second, server)
    advance(clock, 1)
    third = execution("third")
    :ok = Output.open(third, self(), server)
    assert {:error, "output_unavailable"} = Output.snapshot(second, nil, server)
    {:ok, oldest} = Output.snapshot(@execution, nil, server)
    advance(clock, 1)
    :ok = Output.open(execution("fourth"), self(), server)
    assert {:error, "output_unavailable"} = Output.snapshot(@execution, nil, server)
    state = :sys.get_state(server)
    assert map_size(state.rings) == 2
    assert map_size(state.monitors) == 2
    assert :queue.len(state.cleanup) == 2
    {:monitors, monitors} = Process.info(server, :monitors)
    assert length(monitors) == 2
    advance(clock, 1)
    :ok = Output.open(@execution, self(), server)
    {:ok, fresh} = Output.read(@execution, oldest["cursor"], server)
    assert fresh["reset"] == %{"reason" => "epoch_changed"}
  end

  test "aggregate byte cap evicts whole oldest rings and clears their monitors" do
    {server, clock} = store(max_bytes: 200, max_event_bytes: 128, max_total_bytes: 240)

    for n <- 1..3 do
      advance(clock, 1)
      current = execution("#{n}")
      :ok = Output.open(current, self(), server)
      :ok = Output.append(current, text(String.duplicate("x", 70)), server)
    end

    assert {:error, "output_unavailable"} = Output.snapshot(execution("1"), nil, server)
    assert {:ok, _} = Output.snapshot(execution("2"), nil, server)
    assert {:ok, _} = Output.snapshot(execution("3"), nil, server)
    state = :sys.get_state(server)
    assert Enum.sum(Enum.map(state.rings, fn {_, ring} -> ring.bytes end)) <= 240
    assert map_size(state.rings) == 2
    assert map_size(state.monitors) == 2
    assert :queue.len(state.cleanup) == 2
  end

  test "same-clock eviction uses producer order and appends refresh that order" do
    {server, _} = store(max_streams: 2)
    :ok = Output.open(@execution, self(), server)
    :ok = Output.open(execution("second"), self(), server)
    :ok = Output.append(@execution, text("newly produced"), server)
    :ok = Output.open(execution("third"), self(), server)
    assert {:ok, _} = Output.snapshot(@execution, nil, server)
    assert {:ok, _} = Output.snapshot(execution("third"), nil, server)
    assert {:error, "output_unavailable"} = Output.snapshot(execution("second"), nil, server)
  end

  test "cleanup is periodic and bounded across ended streams" do
    {server, clock} = store(max_age_ms: 100, cleanup_batch_size: 1, cleanup_interval_ms: 25)

    for n <- 1..3 do
      current = execution("#{n}")
      :ok = Output.open(current, self(), server)
      :ok = Output.finish(current, server)
    end

    advance(clock, 100)
    assert map_size(cleanup(server).rings) == 2
    assert map_size(cleanup(server).rings) == 1
    assert cleanup(server).rings == %{}
    assert cleanup(server).rings == %{}
  end
end
