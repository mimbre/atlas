defmodule AtlasE2E.Pull.Hub do
  @moduledoc """
  The pull-e2e's one event stream: every observation the bench waits on is published here
  as it happens, stamped with a sequence number and the bench's monotonic receive time.

  Sources: `:wire` (the edge's tap, `AtlasE2E.Pull.Edge`), `:stub` (the agents' FIFO
  events), `:rt` (`atlas-runtime events --follow`), `:console` (tmux control mode) and
  `:port` (a reader Port's exit). The history is kept, so a wait that starts after its event
  still finds it (`find/2` from a mark); subscribers get `{:pull_event, event}` for each new
  one, which is what wakes `AtlasE2E.Pull.Await` (`AtlasTestAwait`'s `{:subscribe, fun}`).
  With `log:` each event is also appended to `<log>/<source>.jsonl` (the artifacts).
  """
  use GenServer

  @type event :: %{n: pos_integer(), at: integer(), source: atom(), data: map()}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  @doc "Publish `data` from `source`; returns the stamped event."
  def publish(source, data, hub \\ __MODULE__), do: GenServer.call(hub, {:publish, source, data})

  @doc "Subscribe the calling process: `{:pull_event, event}` for every later event."
  def subscribe(hub \\ __MODULE__), do: GenServer.call(hub, {:subscribe, self()})

  @doc "A mark: the last sequence number and the bench's monotonic time (ms) now."
  def mark(hub \\ __MODULE__), do: GenServer.call(hub, :mark)

  @doc "Every event after the mark (or sequence number) `since`, oldest first, that `match` accepts."
  def select(since, match, hub \\ __MODULE__),
    do: GenServer.call(hub, {:select, seq(since), match}, :infinity)

  @doc "The first event after `since` that `match` accepts, or nil."
  def find(since, match, hub \\ __MODULE__), do: since |> select(match, hub) |> List.first()

  @doc "The last `n` events, oldest first (for a failure's report)."
  def last(n, hub \\ __MODULE__), do: GenServer.call(hub, {:last, n})

  def now, do: System.monotonic_time(:millisecond)

  defp seq(%{n: n}), do: n
  defp seq(n) when is_integer(n), do: n

  @impl true
  def init(opts) do
    if log = opts[:log], do: File.mkdir_p!(log)
    {:ok, %{n: 0, events: [], subscribers: %{}, log: opts[:log], clock: opts[:clock] || (&now/0)}}
  end

  @impl true
  def handle_call({:publish, source, data}, _from, state) do
    event = %{n: state.n + 1, at: state.clock.(), source: source, data: data}
    if state.log, do: append(state.log, event)
    for pid <- Map.keys(state.subscribers), do: send(pid, {:pull_event, event})
    {:reply, event, %{state | n: event.n, events: [event | state.events]}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subscribers =
      if Map.has_key?(state.subscribers, pid),
        do: state.subscribers,
        else: Map.put(state.subscribers, pid, Process.monitor(pid))

    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call(:mark, _from, state), do: {:reply, %{n: state.n, at: state.clock.()}, state}

  def handle_call({:select, since, match}, _from, state) do
    found =
      state.events
      |> Enum.take_while(&(&1.n > since))
      |> Enum.reverse()
      |> Enum.filter(fn event ->
        try do
          match.(event)
        rescue
          _ -> false
        end
      end)

    {:reply, found, state}
  end

  def handle_call({:last, n}, _from, state),
    do: {:reply, state.events |> Enum.take(n) |> Enum.reverse(), state}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

  defp append(dir, event) do
    line = JSON.encode!(%{n: event.n, at: event.at, data: jsonable(event.data)})
    File.write!(Path.join(dir, "#{event.source}.jsonl"), line <> "\n", [:append])
  end

  @doc false
  def jsonable(%{} = map) when not is_struct(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)

  def jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)

  def jsonable(value) when is_atom(value) and value not in [nil, true, false],
    do: to_string(value)

  def jsonable(value) when is_binary(value),
    do: if(String.valid?(value), do: value, else: Base.encode64(value))

  def jsonable(value) when is_number(value) or is_boolean(value) or is_nil(value), do: value
  def jsonable(value), do: inspect(value)
end
