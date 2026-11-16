defmodule AtlasFlow.Runtime.Link do
  @moduledoc """
  Flow's link to one machinery: it follows the Runtime's event stream (`GET /v1/events`,
  Runtime design §3.6, §8.4) and tells Flow's engine what changed (plan 2026-11-17 §3.4,
  §3.5 obligations 1 and 5). One runs per configured machinery (`children/1`).

  It sends the engine (`notify:`, default `AtlasFlow.Engine`):

  - `{:work_changed, work}`: a work snapshot, as `AtlasFlow.Runtime.Client` returns it,
    read with `get_work` on each `work` event and from `list_work` on a reconcile. A
    notification is a signal only (D9); the engine applies snapshots by `revision`, so a
    repeat does no harm;
  - `{:capacity, capacity}`: Flow's word for the Runtime's capacity, sent on its
    `capacity_available` event and on every heartbeat (which also carries it).

  The change sequence is kept in memory only (plan §9.7):

  - **First connect** (no sequence yet): it subscribes from now and then reads
    `list_work` once, so nothing that changed before the stream opened is missed, and
    takes the sequence from it.
  - **Reconnect:** with `Last-Event-ID` = the last sequence it handled; the Runtime replays
    what it missed. A `work` event is counted as handled only once its snapshot was sent, so
    one that could not be read is replayed after the next reconnect.
  - **`reset`** (its position is outside the Runtime's window, or the Runtime restarted):
    `list_work(changed_since: last sequence)`, each work sent, then the sequence moves on.
  - **Lost stream** (closed, a transport error, no data for `idle_ms`, a refused open, or a
    read after the open that fails): it reconnects with exponential backoff
    (`backoff: {first_ms, max_ms}`). The delay starts again at `first_ms` only once the
    stream has carried an event the link handled; an open alone is not health, so a stream
    that opens and then fails (a `list_work` or `get_work` that stays unreadable, a proxy that
    answers 200 and closes) still backs off. Unreachable is never lost: the link only waits,
    and decides nothing about work.

  Options: `machinery:` (required, an `AtlasFlow.Runtime.Config`), `notify:`, `client:` (an
  `AtlasFlow.Runtime.Client`, default `AtlasFlow.Runtime.Client.Http`), `backoff:` (default
  `{1_000, 30_000}`), `idle_ms:` (default 45 000: three missed heartbeats) and `name:`.
  """
  use GenServer

  require Logger

  alias AtlasFlow.Runtime.Client.Http
  alias AtlasFlow.Runtime.Config

  @backoff {1_000, 30_000}
  @idle_ms 45_000

  @doc "One child per configured machinery (none when none is configured); `opts` are added."
  @spec children(keyword()) :: [Supervisor.child_spec()]
  def children(opts \\ []) do
    for {name, machinery} <- Config.all(),
        do:
          Supervisor.child_spec({__MODULE__, Keyword.put(opts, :machinery, machinery)},
            id: {__MODULE__, name}
          )
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc """
  What the link knows: `connected`, `sequence` (the last change it handled), `reconciles`
  (how often it read `list_work`, at a first connect or a `reset`), `resets`, `connects`
  and `last_seen` (when the stream last carried data).
  """
  def info(link), do: GenServer.call(link, :info)

  @impl true
  def init(opts) do
    %Config{} = machinery = Keyword.fetch!(opts, :machinery)
    {first, max} = Keyword.get(opts, :backoff, @backoff)

    state = %{
      machinery: machinery,
      notify: Keyword.get(opts, :notify, AtlasFlow.Engine),
      client: Keyword.get(opts, :client, Http),
      backoff: {first, max},
      delay: first,
      idle_ms: Keyword.get(opts, :idle_ms, @idle_ms),
      idle: nil,
      response: nil,
      buffer: "",
      sequence: nil,
      connected: false,
      connects: 0,
      reconciles: 0,
      resets: 0,
      last_seen: nil
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_call(:info, _from, state),
    do:
      {:reply,
       Map.take(state, [:connected, :sequence, :reconciles, :resets, :connects, :last_seen]),
       state}

  @impl true
  def handle_info(:connect, state) do
    case Http.events(state.machinery, state.sequence) do
      {:ok, response} ->
        state = %{state | response: response, buffer: "", connected: true}
        state = %{state | connects: state.connects + 1} |> idle()

        if state.sequence do
          {:noreply, state}
        else
          case reconcile(state, nil) do
            {:ok, state} -> {:noreply, state}
            :error -> {:noreply, lost(state, :reconcile)}
          end
        end

      other ->
        {:noreply, lost(state, other)}
    end
  end

  def handle_info(:idle, state), do: {:noreply, lost(state, :idle)}

  def handle_info(message, %{response: response} = state) when response != nil do
    case Req.parse_message(response, message) do
      {:ok, parts} ->
        case Enum.reduce_while(parts, state, &part/2) do
          {:lost, state, reason} -> {:noreply, lost(state, reason)}
          state -> {:noreply, state}
        end

      {:error, reason} ->
        {:noreply, lost(state, reason)}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{response: response}) do
    if response, do: Http.close(response)
    :ok
  end

  ## The stream

  defp part({:data, data}, state) do
    state = %{state | last_seen: DateTime.utc_now()} |> idle()
    {frames, rest} = frames(state.buffer <> data)

    case Enum.reduce_while(frames, %{state | buffer: rest}, &frame/2) do
      {:lost, _state, _reason} = lost -> {:halt, lost}
      state -> {:cont, state}
    end
  end

  defp part(:done, state), do: {:halt, {:lost, state, :closed}}
  defp part(_trailers, state), do: {:cont, state}

  # Each frame ends with a blank line (`\n\n`; `\r\n` is accepted too).
  defp frames(buffer) do
    parts = buffer |> String.replace("\r\n", "\n") |> String.split("\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    {Enum.map(complete, &parse/1), rest}
  end

  defp parse(text) do
    text
    |> String.split("\n")
    |> Enum.reduce(%{event: "message", id: nil, data: []}, fn line, frame ->
      case String.split(line, ":", parts: 2) do
        ["event", value] -> %{frame | event: String.trim_leading(value, " ")}
        ["id", value] -> %{frame | id: String.trim_leading(value, " ")}
        ["data", value] -> %{frame | data: [String.trim_leading(value, " ") | frame.data]}
        _comment_or_other -> frame
      end
    end)
    |> then(fn frame -> %{frame | data: frame.data |> Enum.reverse() |> Enum.join("\n")} end)
  end

  defp frame(frame, state) do
    case event(frame.event, decode(frame.data), state) do
      {:ok, state} -> {:cont, state |> advance(frame.id) |> healthy()}
      # Not handled: the sequence stays before it, so the reconnect replays it.
      :error -> {:halt, {:lost, state, {:event, frame.event}}}
    end
  end

  defp event("work", %{"work_id" => work_id}, state) do
    case state.client.get_work(state.machinery, work_id) do
      {:found, work} ->
        tell(state, {:work_changed, work})
        {:ok, state}

      # Pruned or never seen: there is nothing to apply.
      {:pruned, _id, _kind} ->
        {:ok, state}

      :not_found ->
        {:ok, state}

      _unreachable_or_refused ->
        :error
    end
  end

  defp event(type, %{"capacity" => capacity}, state) when type in ["capacity", "heartbeat"] do
    tell(state, {:capacity, capacity})
    {:ok, state}
  end

  defp event("reset", data, state) do
    current = if is_map(data), do: data["current_sequence"]

    case reconcile(state, state.sequence) do
      {:ok, state} ->
        {:ok, %{state | resets: state.resets + 1} |> advance(current)}

      :error ->
        :error
    end
  end

  defp event(type, _data, state) do
    Logger.debug("#{inspect(__MODULE__)} #{state.machinery.name}: event #{type} passed over")
    {:ok, state}
  end

  # Re-read what changed after `since` (nil: everything Flow has there), and send each.
  defp reconcile(state, since) do
    case state.client.list_work(state.machinery, since) do
      {:works, works, sequence} ->
        Enum.each(works, &tell(state, {:work_changed, &1}))
        {:ok, %{state | reconciles: state.reconciles + 1} |> advance(sequence)}

      other ->
        Logger.info(
          "#{inspect(__MODULE__)} #{state.machinery.name}: list_work: #{inspect(other)}"
        )

        :error
    end
  end

  # The sequence only moves forward.
  defp advance(state, nil), do: state

  defp advance(state, id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> advance(state, n)
      _ -> state
    end
  end

  defp advance(%{sequence: current} = state, n) when is_integer(n) do
    if current == nil or n > current, do: %{state | sequence: n}, else: state
  end

  defp advance(state, _other), do: state

  ## Losing and regaining the stream

  defp lost(state, reason) do
    if state.response, do: Http.close(state.response)
    if state.idle, do: Process.cancel_timer(state.idle)

    if state.connected or state.delay == elem(state.backoff, 0),
      do:
        Logger.info(
          "#{inspect(__MODULE__)} #{state.machinery.name}: stream lost (#{inspect(reason)}); " <>
            "reconnecting in #{state.delay} ms"
        )

    Process.send_after(self(), :connect, state.delay)
    {_first, max} = state.backoff

    %{
      state
      | response: nil,
        buffer: "",
        idle: nil,
        connected: false,
        delay: min(state.delay * 2, max)
    }
  end

  # The stream opened or carried data: the idle timeout starts again. This alone says
  # nothing about health, so the backoff is left as it is (see `healthy/1`).
  defp idle(state) do
    if state.idle, do: Process.cancel_timer(state.idle)
    %{state | idle: Process.send_after(self(), :idle, state.idle_ms)}
  end

  # An event was handled: the stream is healthy, so the next loss starts the backoff again.
  defp healthy(%{backoff: {first, _max}} = state), do: %{state | delay: first}

  defp tell(%{notify: notify}, message) when is_pid(notify), do: send(notify, message)

  defp tell(%{notify: notify}, message) do
    case GenServer.whereis(notify) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end

  defp decode(""), do: nil

  defp decode(data) do
    case JSON.decode(data) do
      {:ok, value} -> value
      {:error, _} -> nil
    end
  end
end
