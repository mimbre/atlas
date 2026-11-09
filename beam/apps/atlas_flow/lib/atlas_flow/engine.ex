defmodule AtlasFlow.Engine do
  @moduledoc """
  Flow's engine: keeps one process (`AtlasFlow.Item`) running for every open fact that a
  flow definition runs on.

  - At boot, and on its own timer, it reads the description and every fact of each kind a
    definition runs on, and starts a process for each fact that has none. A process stops
    by itself once its fact is done; reading again starts it when the fact opens again.
  - It listens to every kind. A hint pokes the processes of the fact it is about and of
    every fact above it (through its parent links, read plainly from Facts), so those look
    again at once; one that has no process yet gets one. A hint about a delete pokes them
    all, since what was above it can no longer be read, and so does a new fact of a kind a
    flow assigns to (an owner that did not exist yet). A hint of Flow's own write is
    passed over: Flow writes only what no state depends on (Facts checks that). A lost
    hint only waits for the timer (nobody depends on a hint).

  It reaches Facts only over the Bus, as the endpoint `flow`.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasFlow.{Definition, Item, Talk}

  # How far up a hint looks for facts whose state it may change.
  @depth 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Read Facts and start what is missing, now (for tests)."
  def round(server), do: GenServer.call(server, :round, 30_000)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach("flow")
    send(self(), :round)

    {:ok,
     %{
       every: Keyword.get(opts, :every, 60_000),
       kinds: [],
       owners: [],
       description: %{},
       listening: MapSet.new(),
       timer: nil
     }}
  end

  @impl true
  def handle_call(:round, _from, state), do: {:reply, :ok, look_all(state)}

  @impl true
  def handle_info(:round, state), do: {:noreply, look_all(state)}

  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind}, content}, state) do
    # A delete: what was above it can no longer be read. A new owner (a fact of a kind a
    # flow assigns to): a fact whose owner waited for it can have it now.
    all? = content["op"] == "delete" or (content["op"] == "create" and kind in state.owners)

    case content do
      # Its own write changes nothing any state depends on.
      %{"by" => "flow"} ->
        :ok

      _ when all? ->
        for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasFlow.Supervisor),
            is_pid(pid),
            do: Item.poke(pid, state.description)

      %{"key" => key} when is_binary(key) ->
        for {kind, key} <- up(state.description, kind, key, @depth),
            kind in state.kinds,
            pid = ensure(kind, key, state),
            is_pid(pid),
            do: Item.poke(pid, state.description)

      _ ->
        :ok
    end

    {:noreply, state}
  end

  # A failure Control asks about or causes (test only; IS-Atlas-23): answered at once.
  def handle_info({:atlas_bus, %Envelope{class: "fault"} = envelope, content}, state) do
    answer =
      case content do
        %{"do" => "offer", "key" => key} ->
          %{"offers" => AtlasFlow.Faults.offers(key)}

        %{"do" => "run", "fault" => fault, "key" => key} ->
          case AtlasFlow.Faults.run(fault, key) do
            {:ok, done} -> %{"done" => done}
            {:error, why} -> %{"refused" => why}
          end

        _ ->
          %{"refused" => "Flow does not know that failure."}
      end

    AtlasBus.send(Envelope.reply(envelope, "answer"), answer)
    {:noreply, state}
  end

  # Answers that came after their wait, and anything else.
  def handle_info(_message, state), do: {:noreply, state}

  defp look_all(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state =
      case Talk.read("_description", %{}) do
        %{"description" => description} ->
          report(description)
          kinds = Definition.kinds(description)

          # Listen to every kind: what hangs under a fact can change its state.
          listening =
            Enum.reduce(Map.keys(description["entities"] || %{}), state.listening, fn kind, acc ->
              :ok = AtlasBus.listen(kind)
              MapSet.put(acc, kind)
            end)

          for kind <- kinds, {_name, flow} = Definition.for_kind(description, kind) do
            case Talk.read(kind, %{}) do
              %{"facts" => facts} ->
                for fact <- facts,
                    open?(description, kind, flow, fact),
                    do: ensure(kind, fact["key"], state)

              other ->
                Logger.warning("flow could not list #{kind}: #{inspect(other)}")
            end
          end

          %{
            state
            | kinds: kinds,
              owners: Definition.owner_kinds(description),
              description: description,
              listening: listening
          }

        other ->
          Logger.warning("flow has no description yet: #{inspect(other)}")
          state
      end

    %{state | timer: Process.send_after(self(), :round, state.every)}
  end

  # The fact and every fact above it, through the parent relations the description marks.
  defp up(_description, _kind, _key, 0), do: []

  defp up(description, kind, key, depth) do
    parents =
      case Talk.read(kind, %{"key" => key, "plain" => true}) do
        %{"fact" => %{"links" => links} = fact} ->
          parents =
            for {relation, %{"parent" => true, "from" => from, "to" => [to]}} <-
                  description["relations"] || %{},
                kind in from,
                parent <- links[relation] || [],
                do: {to, parent}

          n = get_in(description, ["runtime", "turn"]) || %{}

          ended =
            if kind == n["kind"] and fact["values"][n["state"]] != n["running"] do
              for to <- get_in(description, ["relations", n["on"], "to"]) || [],
                  item <- links[n["on"]] || [],
                  do: {to, item}
            else
              []
            end

          # Component changes wake open work, but do not reopen a completed fact's
          # stopped process (including historical owners left for a migration).
          components =
            for {relation, %{"component" => %{}, "to" => to, "from" => from}} <-
                  description["relations"] || %{},
                kind in to,
                from_kind <- from,
                %{"facts" => facts} <- [
                  Talk.read(from_kind, %{"linked" => %{relation => key}})
                ],
                item <- facts,
                component_open?(description, from_kind, item),
                do: {from_kind, item["key"]}

          # An association a flow reads (`empty`): the fact it points at may wait for it.
          anchors =
            for {_name, flow} <- Definition.flows(description),
                to <- flow["kinds"] || [],
                relation <- Definition.pointing(description, flow, to),
                kind in (get_in(description, ["relations", relation, "from"]) || []),
                anchor <- links[relation] || [],
                uniq: true,
                do: {to, anchor}

          Enum.uniq(parents ++ ended ++ components ++ anchors)

        _ ->
          []
      end

    [{kind, key} | Enum.flat_map(parents, fn {k, p} -> up(description, k, p, depth - 1) end)]
  end

  defp component_open?(description, kind, fact) do
    case Definition.for_kind(description, kind) do
      {_name, flow} -> open?(description, kind, flow, fact)
      nil -> true
    end
  end

  # A fact that is done by itself alone (what hangs under it can only reopen work its own
  # facts already say is open) needs no process. Nothing is taken to point at it through the
  # associations its flow reads (`empty`): its process reads them and stops when done.
  defp open?(description, kind, flow, fact) do
    {current, _} =
      Definition.state_of(flow, fact, [], [], Definition.pointing(description, flow, kind))

    current["done"] != true
  end

  # A fact's process, started when it has none. It finds out itself whether it is open.
  # The Registry forgets a stopped process only a moment after it stopped, so the one it
  # names may be gone: a fact that reopens right after it was done gets a new process then,
  # and does not wait for the next round (IS-Atlas-86). Starting one under the same name
  # works while the Registry still names the stopped one.
  defp ensure(kind, key, state) do
    case Registry.lookup(AtlasFlow.Items, {kind, key}) do
      [{pid, _}] -> if Process.alive?(pid), do: pid, else: start(kind, key, state)
      [] -> start(kind, key, state)
    end
  end

  defp start(kind, key, state) do
    spec = {Item, {kind, key, every: state.every}}

    case DynamicSupervisor.start_child(AtlasFlow.Supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      other -> Logger.warning("flow could not start #{key}: #{inspect(other)}")
    end
  end

  # A definition Facts refused is not run; say why once per round.
  defp report(description) do
    for {name, problems} <- description["flow_problems"] || %{}, problems != [] do
      Logger.error("flow #{name} is not run: #{Enum.join(problems, "; ")}")
    end
  end
end
