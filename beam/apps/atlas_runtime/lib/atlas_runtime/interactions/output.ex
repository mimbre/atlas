defmodule AtlasRuntime.Output do
  @moduledoc """
  Runtime-owned, ephemeral replay of public producer output, independent of viewers.

  Events have only `kind` and `text`, or `kind`, `tool_name`, and `status`.
  Text is split on UTF-8 boundaries into encoded events of at most 16 KiB.
  Sequence numbers start at one; cursors identify the last consumed sequence.
  Snapshot's initial cursor precedes the oldest retained event, not its watermark.
  `ended` means producer closure only, never authoritative worker completion.

  A missing/expired ring returns `output_unavailable`. Retention gaps and replacement
  epochs return a `reset` with `reason`; retention gaps include inclusive
  `from_sequence`/`to_sequence`. An epoch change's lost interval is unknown.
  Readers neither extend retention nor change execution/lease state.

  Options: `name` (default this module, nil for an unnamed server), `max_events`
  (1000), `max_bytes` (1 MiB, including JSON array framing), `max_age_ms` (15 min),
  `max_event_bytes` (16 KiB), `max_reply_bytes` (64 KiB), `cleanup_interval_ms`
  (1000), and `cleanup_batch_size` (64 rings). Aggregate limits are `max_streams`
  (64) and `max_total_bytes` (16 MiB). These internal test limits may only be lowered.
  Aggregate pressure evicts closed streams first, then least-recently-produced
  live streams. Reads do not refresh this age. Eviction also removes monitors.
  `clock` is a zero-arity monotonic millisecond function; `timer` accepts
  `(pid, message, delay_ms)`, like `Process.send_after/3`. Tests may inject both
  and deliver `:cleanup` explicitly. Ended rings expire `max_age_ms` after closure.
  """
  use GenServer

  @limits [
    max_events: 1000,
    max_bytes: 1_048_576,
    max_age_ms: 900_000,
    max_event_bytes: 16_384,
    max_reply_bytes: 65_536,
    max_streams: 64,
    max_total_bytes: 16_777_216
  ]
  @cursor_bytes 512

  def start_link(opts \\ []) do
    server_opts =
      if opts[:name] == nil and Keyword.has_key?(opts, :name),
        do: [],
        else: [name: opts[:name] || __MODULE__]

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def open(execution, owner_pid, server \\ __MODULE__),
    do: GenServer.call(server, {:open, execution, owner_pid})

  def append(execution, event, server \\ __MODULE__),
    do: GenServer.call(server, {:append, execution, event})

  def finish(execution, server \\ __MODULE__),
    do: GenServer.call(server, {:finish, execution})

  def snapshot(execution, cursor \\ nil, server \\ __MODULE__),
    do: GenServer.call(server, {:snapshot, execution, cursor})

  def read(execution, cursor, server \\ __MODULE__),
    do: GenServer.call(server, {:read, execution, cursor})

  @impl true
  def init(opts) do
    limits = Map.new(@limits, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)
    interval = Keyword.get(opts, :cleanup_interval_ms, 1000)
    batch = Keyword.get(opts, :cleanup_batch_size, 64)

    valid =
      Enum.all?(@limits, fn {key, maximum} ->
        is_integer(limits[key]) and limits[key] > 0 and limits[key] <= maximum
      end) and is_integer(interval) and interval > 0 and is_integer(batch) and batch > 0 and
        limits.max_event_bytes + 2 <= limits.max_reply_bytes and
        limits.max_event_bytes + 2 <= limits.max_bytes and
        limits.max_bytes <= limits.max_total_bytes

    if valid do
      state =
        Map.merge(limits, %{
          rings: %{},
          monitors: %{},
          cleanup: :queue.new(),
          order: 0,
          cleanup_interval_ms: interval,
          cleanup_batch_size: batch,
          clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
          timer: Keyword.get(opts, :timer, &Process.send_after/3)
        })

      schedule(state)
      {:ok, state}
    else
      {:stop, :invalid_options}
    end
  end

  @impl true
  def handle_call({:open, execution, owner}, _from, state) do
    with {:ok, key} <- identity(execution),
         true <- is_pid(owner) and node(owner) == node() and Process.alive?(owner) do
      now = state.clock.()
      existing = Map.get(state.rings, key)

      cond do
        existing != nil and not expired?(existing, now, state) ->
          result = if existing.owner == owner, do: :ok, else: {:error, "owner_conflict"}
          {:reply, result, state}

        true ->
          state = if existing, do: forget(state, key, existing), else: state
          ref = Process.monitor(owner)

          ring = %{
            execution: execution,
            scope: scope(key),
            epoch: epoch(),
            owner: owner,
            monitor: ref,
            events: :queue.new(),
            count: 0,
            bytes: 2,
            watermark: 0,
            ended_at: nil,
            produced_at: now,
            produced_order: state.order + 1
          }

          state = %{
            state
            | rings: Map.put(state.rings, key, ring),
              monitors: Map.put(state.monitors, ref, key),
              cleanup: :queue.in({key, ring.epoch}, state.cleanup),
              order: state.order + 1
          }

          {:reply, :ok, enforce_limits(state)}
      end
    else
      false -> {:reply, {:error, "invalid_owner"}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:append, execution, event}, {caller, _}, state) do
    now = state.clock.()

    with {:ok, key, ring} <- fetch(execution, now, state),
         :ok <- owner(ring, caller),
         :ok <- active(ring),
         :ok <- valid_event(event),
         {:ok, ring} <- ingest(prune(ring, now, state), event, now, state) do
      ring = %{ring | produced_order: state.order + 1}

      {:reply, :ok,
       enforce_limits(%{state | rings: Map.put(state.rings, key, ring), order: state.order + 1})}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:finish, execution}, {caller, _}, state) do
    now = state.clock.()

    with {:ok, key, ring} <- fetch(execution, now, state),
         :ok <- owner(ring, caller) do
      {ring, state} = close(ring, now, state)
      {:reply, :ok, %{state | rings: Map.put(state.rings, key, ring)}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({operation, execution, cursor}, _from, state)
      when operation in [:snapshot, :read] do
    now = state.clock.()

    result =
      with {:ok, _key, ring} <- fetch(execution, now, state),
           ring = prune(ring, now, state),
           {:ok, sequence, reset} <- position(ring, cursor) do
        result = %{"stream" => stream(ring), "cursor" => cursor(ring, sequence)}
        result = if reset, do: Map.put(result, "reset", reset), else: result

        if operation == :read do
          {events, last} = batch(ring.events, sequence, state.max_reply_bytes, [], 2, sequence)

          {:ok,
           Map.merge(result, %{
             "events" => events,
             "cursor" => cursor(ring, last),
             "more" => last < ring.watermark
           })}
        else
          {:ok, result}
        end
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, key} ->
        ring = Map.fetch!(state.rings, key)
        {ring, state} = close(ring, state.clock.(), state)
        {:noreply, %{state | rings: Map.put(state.rings, key, ring)}}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info(:cleanup, state) do
    state =
      cleanup(state, state.clock.(), min(state.cleanup_batch_size, :queue.len(state.cleanup)))

    schedule(state)
    {:noreply, state}
  end

  defp identity(%{"worker" => worker, "turn" => turn, "attempt" => attempt} = execution)
       when map_size(execution) == 3 and is_map(worker) and map_size(worker) == 3 do
    values = [worker["environment"], worker["machine"], worker["worker"], turn, attempt]

    if Enum.all?(values, &string?/1),
      do: {:ok, List.to_tuple(values)},
      else: {:error, "invalid_execution"}
  end

  defp identity(_), do: {:error, "invalid_execution"}
  defp string?(value), do: is_binary(value) and byte_size(value) > 0 and String.valid?(value)

  defp scope(key),
    do:
      :crypto.hash(:sha256, JSON.encode!(Tuple.to_list(key))) |> Base.url_encode64(padding: false)

  defp epoch, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp fetch(execution, now, state) do
    with {:ok, key} <- identity(execution) do
      case Map.get(state.rings, key) do
        nil ->
          {:error, "output_unavailable"}

        ring ->
          if expired?(ring, now, state),
            do: {:error, "output_unavailable"},
            else: {:ok, key, ring}
      end
    end
  end

  defp expired?(ring, now, state),
    do: ring.ended_at != nil and now - ring.ended_at >= state.max_age_ms

  defp owner(%{owner: caller}, caller), do: :ok
  defp owner(_, _), do: {:error, "not_owner"}
  defp active(%{ended_at: nil}), do: :ok
  defp active(_), do: {:error, "output_ended"}

  defp close(%{ended_at: nil} = ring, now, state) do
    Process.demonitor(ring.monitor, [:flush])

    {%{ring | ended_at: now, monitor: nil},
     %{state | monitors: Map.delete(state.monitors, ring.monitor)}}
  end

  defp close(ring, _now, state), do: {ring, state}

  defp valid_event(%{"kind" => kind, "text" => text} = event)
       when kind in ["text", "activity"] and map_size(event) == 2 and is_binary(text) do
    if String.valid?(text), do: :ok, else: {:error, "invalid_event"}
  end

  defp valid_event(%{"kind" => "tool", "tool_name" => name, "status" => status} = event)
       when map_size(event) == 3 do
    if string?(name) and string?(status), do: :ok, else: {:error, "invalid_event"}
  end

  defp valid_event(_), do: {:error, "invalid_event"}

  defp ingest(ring, %{"text" => text} = event, now, state) do
    event = Map.put(event, "sequence", ring.watermark + 1)
    length = fitting_prefix(text, event, state.max_event_bytes)

    if length == 0 and text != "" do
      {:error, "invalid_event"}
    else
      <<part::binary-size(length), rest::binary>> = text
      event = Map.put(event, "text", part)

      if byte_size(JSON.encode!(event)) <= state.max_event_bytes do
        ring = insert(ring, event, now, state)

        if rest == "",
          do: {:ok, ring},
          else: ingest(ring, Map.delete(Map.put(event, "text", rest), "sequence"), now, state)
      else
        {:error, "invalid_event"}
      end
    end
  end

  defp ingest(ring, event, now, state) do
    event = Map.put(event, "sequence", ring.watermark + 1)

    if byte_size(event["tool_name"]) + byte_size(event["status"]) <= state.max_event_bytes and
         byte_size(JSON.encode!(event)) <= state.max_event_bytes do
      {:ok, insert(ring, event, now, state)}
    else
      {:error, "invalid_event"}
    end
  end

  defp fitting_prefix(text, event, limit),
    do: fitting_prefix(text, event, limit, 0, min(byte_size(text), limit))

  defp fitting_prefix(text, _event, _limit, low, high) when low >= high,
    do: utf8_end(text, low)

  defp fitting_prefix(text, event, limit, low, high) do
    middle = div(low + high + 1, 2)
    finish = utf8_end(text, middle)
    part = binary_part(text, 0, finish)

    if byte_size(JSON.encode!(Map.put(event, "text", part))) <= limit do
      fitting_prefix(text, event, limit, middle, high)
    else
      fitting_prefix(text, event, limit, low, middle - 1)
    end
  end

  defp utf8_end(text, offset) when offset == byte_size(text), do: offset
  defp utf8_end(_text, 0), do: 0

  defp utf8_end(text, offset) do
    if :binary.at(text, offset) in 128..191, do: utf8_end(text, offset - 1), else: offset
  end

  defp insert(ring, event, now, state) do
    # A small sub-binary must not pin an arbitrarily large producer payload.
    event = Map.new(event, fn {key, value} -> {detach(key), detach(value)} end)
    size = byte_size(JSON.encode!(event))

    ring = %{
      ring
      | events: :queue.in({event["sequence"], now, size, event}, ring.events),
        count: ring.count + 1,
        bytes: ring.bytes + size + if(ring.count == 0, do: 0, else: 1),
        watermark: event["sequence"],
        produced_at: now
    }

    prune(ring, now, state)
  end

  defp detach(value) when is_binary(value) do
    if :binary.referenced_byte_size(value) > byte_size(value),
      do: :binary.copy(value),
      else: value
  end

  defp detach(value), do: value

  defp prune(ring, now, state) do
    case :queue.out(ring.events) do
      {{:value, {_sequence, at, size, _event}}, rest} ->
        if ring.count > state.max_events or ring.bytes > state.max_bytes or
             now - at >= state.max_age_ms do
          prune(
            %{
              ring
              | events: rest,
                count: ring.count - 1,
                bytes: ring.bytes - size - if(ring.count > 1, do: 1, else: 0)
            },
            now,
            state
          )
        else
          ring
        end

      {:empty, _} ->
        ring
    end
  end

  defp first(ring) do
    case :queue.peek(ring.events) do
      {:value, {sequence, _, _, _}} -> sequence
      :empty -> ring.watermark + 1
    end
  end

  defp stream(ring),
    do: %{
      "execution" => ring.execution,
      "epoch" => ring.epoch,
      "first_sequence" => first(ring),
      "watermark" => ring.watermark,
      "ended" => ring.ended_at != nil
    }

  defp cursor(ring, sequence),
    do: JSON.encode!([1, ring.scope, ring.epoch, sequence]) |> Base.url_encode64(padding: false)

  defp position(ring, nil) do
    sequence = first(ring) - 1

    reset =
      if sequence > 0,
        do: %{"reason" => "retention_gap", "from_sequence" => 1, "to_sequence" => sequence}

    {:ok, sequence, reset}
  end

  defp position(ring, token) when is_binary(token) and byte_size(token) <= @cursor_bytes do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, [1, scope, epoch, sequence]} <- JSON.decode(json),
         true <-
           scope == ring.scope and is_binary(epoch) and is_integer(sequence) and sequence >= 0,
         {:ok, epoch_bytes} <- Base.url_decode64(epoch, padding: false),
         true <- byte_size(epoch_bytes) == 16 do
      cond do
        epoch != ring.epoch ->
          {:ok, first(ring) - 1, %{"reason" => "epoch_changed"}}

        sequence > ring.watermark ->
          {:error, "invalid_cursor"}

        sequence < first(ring) - 1 ->
          {:ok, first(ring) - 1,
           %{
             "reason" => "retention_gap",
             "from_sequence" => sequence + 1,
             "to_sequence" => first(ring) - 1
           }}

        true ->
          {:ok, sequence, nil}
      end
    else
      _ -> {:error, "invalid_cursor"}
    end
  end

  defp position(_, _), do: {:error, "invalid_cursor"}

  defp batch(queue, after_sequence, limit, events, bytes, last) do
    case :queue.out(queue) do
      {{:value, {sequence, _at, size, event}}, rest} ->
        cond do
          sequence <= after_sequence ->
            batch(rest, after_sequence, limit, events, bytes, last)

          bytes + size + if(events == [], do: 0, else: 1) > limit ->
            {Enum.reverse(events), last}

          true ->
            batch(
              rest,
              after_sequence,
              limit,
              [event | events],
              bytes + size + if(events == [], do: 0, else: 1),
              sequence
            )
        end

      {:empty, _} ->
        {Enum.reverse(events), last}
    end
  end

  defp forget(state, key, ring) do
    if ring.monitor, do: Process.demonitor(ring.monitor, [:flush])

    %{
      state
      | rings: Map.delete(state.rings, key),
        monitors: Map.delete(state.monitors, ring.monitor),
        cleanup: :queue.filter(fn entry -> entry != {key, ring.epoch} end, state.cleanup)
    }
  end

  defp enforce_limits(state) do
    total = Enum.reduce(state.rings, 0, fn {_key, ring}, bytes -> bytes + ring.bytes end)

    if map_size(state.rings) > state.max_streams or total > state.max_total_bytes do
      {key, ring} =
        Enum.min_by(state.rings, fn {_key, ring} ->
          {if(ring.ended_at == nil, do: 1, else: 0), ring.produced_at, ring.produced_order}
        end)

      enforce_limits(forget(state, key, ring))
    else
      state
    end
  end

  defp cleanup(state, _now, 0), do: state

  defp cleanup(state, now, remaining) do
    {{:value, {key, epoch}}, queue} = :queue.out(state.cleanup)
    state = %{state | cleanup: queue}

    state =
      case Map.get(state.rings, key) do
        %{epoch: ^epoch} = ring ->
          if expired?(ring, now, state) do
            forget(state, key, ring)
          else
            %{
              state
              | rings: Map.put(state.rings, key, prune(ring, now, state)),
                cleanup: :queue.in({key, epoch}, state.cleanup)
            }
          end

        _ ->
          state
      end

    cleanup(state, now, remaining - 1)
  end

  defp schedule(state), do: state.timer.(self(), :cleanup, state.cleanup_interval_ms)
end
