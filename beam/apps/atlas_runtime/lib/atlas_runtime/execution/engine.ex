defmodule AtlasRuntime.Engine do
  @moduledoc """
  Runtime's engine, on one machine (architecture v4, sections 3, 9 and 13): it runs the
  turns of the agents this machine runs (`AtlasRuntime.Settings`), for the open facts they
  own. Flow decides who owns what; Runtime only runs turns for owners.

  Every round (and at once on a hint about a fact it runs turns on, or a turn) it reads
  Facts and reconciles, safe to repeat (C2):

  1. A turn Facts has running on this machine with no process here (Runtime restarted, or
     its process died): ended, with why. It keeps nothing Facts does not hold (C1).
  2. A turn whose item is no longer its agent's, or no longer open: ended (W1: only the
     owner works on an item). It may still end by itself for a grace (`leave_grace`, 10 s),
     so the result of an agent that handed its item on itself is kept (IS-Atlas-93).
  3. An open fact owned by one of its agents, without a turn here: a turn is started,
     unless that agent is in a turn already (it then waits behind it, W1), or crashed a
     moment ago (it waits a pause that doubles with each crash in a row), or crashed 3 times
     in 10 minutes on this machine: it then cannot run here, and Runtime says so on the
     agent (`runtime.agent.cannot_run`), until that is no longer so (architecture v4,
     section 10.2). All of it is read from the turns in Facts, nothing is remembered.

  What it reads is the description's: the facts a flow writes on (its `on`, or its kinds),
  owned through the flow's `owner_relation`, open while its `state_field` has a value; and
  the turn's kind and fields (`runtime.turn` in `rela/atlas.json`). It names no kind.

  It reaches Facts only over the Bus, as the endpoint `runtime`.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasRuntime.{Agent, Guidance, Talk, Turn}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Reconcile now (for tests)."
  def round(server), do: GenServer.call(server, :round, 30_000)

  @impl true
  def init(opts) do
    :ok = AtlasBus.attach("runtime@" <> Keyword.fetch!(opts, :machine))
    send(self(), :round)

    {:ok,
     %{
       opts: opts,
       every: Keyword.get(opts, :every, 60_000),
       kinds: MapSet.new(),
       timer: nil,
       soon: false,
       history_key: nil,
       history_cursor: 0
     }}
  end

  @impl true
  def handle_call(:round, _from, state), do: {:reply, :ok, round_now(state)}

  @impl true
  def handle_info(:round, state), do: {:noreply, round_now(%{state | soon: false})}

  # A hint about a fact it runs turns on, or a turn: look again soon (a burst at once). Its
  # own writes change nothing it reads but the turns it already knows.
  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind}, content}, state) do
    cond do
      content["by"] == "runtime" or state.soon or kind not in state.kinds ->
        {:noreply, state}

      true ->
        Process.send_after(self(), :round, 100)
        {:noreply, %{state | soon: true}}
    end
  end

  # A failure Control asks about or causes (test only; IS-Atlas-23): answered at once.
  def handle_info({:atlas_bus, %Envelope{class: "fault"} = envelope, content}, state) do
    answer =
      case content do
        %{"do" => "offer", "key" => key} ->
          %{"offers" => AtlasRuntime.Faults.offers(key, state.opts)}

        %{"do" => "run", "fault" => fault, "key" => key} ->
          case AtlasRuntime.Faults.run(fault, key, state.opts) do
            {:ok, done} -> %{"done" => done}
            {:error, why} -> %{"refused" => why}
          end

        _ ->
          %{"refused" => "Runtime does not know that failure."}
      end

    AtlasBus.send(Envelope.reply(envelope, "answer"), answer)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp round_now(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    state =
      case Talk.read("_description", %{}) do
        %{"description" => description} ->
          reconcile(description, state)

        other ->
          Logger.warning("runtime: description unavailable: #{inspect(other)}")
          state
      end

    %{state | timer: Process.send_after(self(), :round, state.every)}
  end

  defp reconcile(description, state) do
    agents = Keyword.get(state.opts, :agents, %{})

    with %{"kind" => _} = names <- get_in(description, ["runtime", "turn"]),
         true <- agents != %{} do
      names = atomize(names)
      kinds = written(description)

      for {kind, _flow} <- kinds, do: AtlasBus.listen(kind)
      AtlasBus.listen(names.kind)

      # Snapshot local processes, then turns, then ownership. A turn that ends during
      # these reads stays busy for this round. An old ownership reply must not be
      # combined with newer ended-turn/process snapshots to bypass a saved handover.
      local = local()

      with %{"facts" => turns} <- Talk.read(names.kind, %{}),
           {:ok, owned} <- owned(kinds, agents) do
        machine = Keyword.fetch!(state.opts, :machine)

        mine =
          for turn <- turns,
              turn["values"][names.state] == names.running,
              turn["values"][names.machine] == machine,
              do: turn

        # 1. Running in Facts, with no process here.
        orphaned = Enum.reject(mine, &Map.has_key?(local, &1["key"]))

        for turn <- orphaned do
          outcome = names.outcome && turn["values"][names.outcome]

          why =
            if is_binary(outcome) and outcome != "",
              do: "the agent ended its turn: #{outcome}",
              else: "no process runs it on #{machine} any more (Runtime restarted)"

          lost(names, turn["key"], why)
        end

        # Let Flow reconcile those ends before another turn can start from this round's
        # old ownership snapshot.
        ended_items = Enum.flat_map(orphaned, &(get_in(&1, ["links", names.on]) || []))
        owned = Enum.reject(owned, &(&1.item in ended_items))

        # A stored outcome belongs to the agent; only Runtime ends the turn.
        for turn <- mine,
            names.outcome != nil,
            outcome = turn["values"][names.outcome],
            is_binary(outcome) and outcome != "",
            {pid, _} <- Registry.lookup(AtlasRuntime.Turns, turn["key"]) do
          Turn.finish(pid, "the agent ended its turn: #{outcome}")
        end

        # 2. Its item is no longer its agent's, or no longer open.
        for {key, {agent, item}} <- local,
            {agent, item} not in Enum.map(owned, &{&1.agent, &1.item}),
            {pid, _} <- Registry.lookup(AtlasRuntime.Turns, key) do
          Turn.leave(pid, "#{item} is no longer #{agent}'s to work on")
        end

        # 3. An owned open fact without a turn: one, unless its agent is in one already.
        busy = MapSet.new(for {_key, {agent, _item}} <- local, do: agent)

        turns_here =
          turns
          |> Enum.filter(&(&1["values"][names.machine] == machine))
          |> Enum.flat_map(&(get_in(&1, ["links", names.by]) || []))
          |> Enum.frequencies()

        opts = Keyword.put(state.opts, :turns_here, turns_here)
        able = able(description, names, mine_ended(turns, names, machine), agents, opts)

        owned
        |> Enum.reject(
          &(MapSet.member?(busy, &1.agent) or {&1.agent, &1.item} in Map.values(local))
        )
        |> Enum.filter(&(&1.startable? and &1.agent in able))
        |> Enum.uniq_by(& &1.agent)
        |> Enum.each(
          &start(&1, names, turns, agents, Keyword.put(state.opts, :description, description))
        )

        state = history(state, description, names, turns, local, agents, kinds)
        %{state | kinds: MapSet.new([names.kind | Enum.map(kinds, &elem(&1, 0))])}
      else
        _ -> state
      end
    else
      _ -> state
    end
  end

  # The kinds flows write on, with their definition: `[{kind, flow}]`.
  defp written(description) do
    for {_name, %{"owner_relation" => relation} = flow} <- Enum.sort(description["flows"] || %{}),
        is_binary(relation),
        kind <-
          (case flow["on"] && get_in(description, ["relations", flow["on"], "to"]) do
             [to] -> [to]
             _ -> flow["kinds"] || []
           end),
        uniq: true,
        do: {kind, flow}
  end

  # Ownership still includes a held item, so its current turn may finish normally.
  # A nonempty handover field only bars a new turn, until Flow transfers or cancels it.
  # Runtime treats this as an opaque barrier; Flow alone interprets its origin/owner.
  # The open facts each agent owns: `[%{agent, item, kind, startable?}]`.
  defp owned(kinds, agents) do
    Enum.reduce_while(kinds, {:ok, []}, fn {kind, flow}, {:ok, acc} ->
      found =
        Enum.reduce_while(Enum.sort(Map.keys(agents)), {:ok, []}, fn agent, {:ok, acc} ->
          case Talk.read(kind, %{"linked" => %{flow["owner_relation"] => agent}, "plain" => true}) do
            %{"facts" => facts} ->
              open =
                for fact <- facts,
                    open?(fact, flow),
                    do: %{
                      agent: agent,
                      item: fact["key"],
                      kind: kind,
                      ownership: flow,
                      startable?: handover_clear?(fact, flow)
                    }

              {:cont, {:ok, acc ++ open}}

            _ ->
              {:halt, :unavailable}
          end
        end)

      case found do
        {:ok, more} -> {:cont, {:ok, acc ++ Enum.sort_by(more, & &1.item)}}
        other -> {:halt, other}
      end
    end)
  end

  defp handover_clear?(fact, %{"handover_field" => field}) when is_binary(field),
    do: fact["values"][field] in [nil, ""]

  defp handover_clear?(_fact, _flow), do: true

  # Open while Flow has a state for it (its `state_field`); without one, while it is owned.
  defp open?(fact, %{"state_field" => field}) when is_binary(field),
    do: fact["values"][field] not in [nil, ""]

  defp open?(_fact, _flow), do: true

  defp start(owned, names, turns, agents, opts) do
    n = Enum.count(turns, &(owned.item in (get_in(&1, ["links", names.on]) || []))) + 1

    key =
      names.key
      |> String.replace("{on}", owned.item)
      |> String.replace("{n}", Integer.to_string(n))

    case port(agents[owned.agent], opts) do
      nil ->
        Logger.warning("runtime: #{owned.agent} has no port this machine knows; no turn")

      port ->
        turn = %{
          key: key,
          item: owned.item,
          kind: owned.kind,
          agent: owned.agent,
          port: port,
          port_opts: port_opts(agents[owned.agent], opts),
          guidance_every: Keyword.get(opts, :guidance_every, Keyword.fetch!(opts, :lease)),
          description: Keyword.get(opts, :description, %{}),
          ownership: owned.ownership,
          talk_opts: Keyword.get(opts, :talk_opts, []),
          names: names,
          turn_kind: names.kind,
          machine: Keyword.fetch!(opts, :machine),
          silence:
            seconds(agents[owned.agent]["silence_seconds"], Keyword.fetch!(opts, :silence)),
          max: seconds(agents[owned.agent]["max_seconds"], Keyword.fetch!(opts, :max)),
          leave_grace:
            seconds(
              agents[owned.agent]["leave_grace_seconds"],
              Keyword.get(opts, :leave_grace, 10_000)
            ),
          lease: Keyword.fetch!(opts, :lease),
          cause: "#{owned.agent} owns #{owned.item}, and no turn of it runs: a turn (#{n})"
        }

        DynamicSupervisor.start_child(AtlasRuntime.Supervisor, {Turn, turn})
    end
  end

  # Explicit dependency injection for private proof tests, never read from machine settings.
  defp port(settings, opts),
    do: Keyword.get(opts, :ports, %{})[settings["port"]] || Agent.port(settings)

  # Startup and historical recovery must preserve the same adapter binding. The
  # immutable execution is checked separately; current settings cannot redefine it.
  defp port_opts(settings, opts) do
    Keyword.merge(
      [
        stub_dir: Keyword.get(opts, :stub_dir),
        agent: settings,
        turns_dir: Keyword.get(opts, :turns_dir),
        env_file: Keyword.get(opts, :env_file),
        atlas_bin: Keyword.get(opts, :atlas_bin)
      ],
      Keyword.get(opts, :port_opts, [])
    )
  end

  # One historical turn/page per round, no model restart and no successor resolution.
  # The bounded cursor is an optimization; Facts and native history remain authoritative.
  defp history(state, d, n, turns, local, agents, kinds) do
    machine = Keyword.fetch!(state.opts, :machine)

    candidates =
      for t <- turns,
          t["values"][n.machine] == machine,
          t["values"][n.state] == n.ended,
          is_binary(n.attempt) and is_binary(t["values"][n.attempt]),
          not Map.has_key?(local, t["key"]),
          do: t

    candidates = Enum.sort_by(candidates, & &1["key"])

    chosen =
      Enum.find(candidates, &(&1["key"] >= (state.history_key || ""))) || List.first(candidates)

    with %{} = t <- chosen,
         [agent] <- t["links"][n.by],
         [item] <- t["links"][n.on],
         %{} = settings <- agents[agent],
         port when not is_nil(port) <- port(settings, state.opts),
         {kind, flow} <-
           Enum.find(kinds, fn {kind, _} ->
             kind in (get_in(d, ["relations", n.on, "to"]) || [])
           end),
         execution_kind when is_binary(execution_kind) <-
           get_in(d, ["guidance", "execution", "kind"]),
         %{"fact" => ex} <-
           Talk.read(execution_kind, %{"turn" => t["key"], "attempt" => t["values"][n.attempt]}) do
      turn = %{
        key: t["key"],
        agent: agent,
        item: item,
        attempt: t["values"][n.attempt],
        machine: machine,
        kind: kind,
        ownership: flow,
        names: n,
        turn_kind: n.kind,
        description: d,
        port: port,
        port_opts: port_opts(settings, state.opts),
        talk_opts: Keyword.get(state.opts, :talk_opts, [])
      }

      cursor =
        Guidance.historical(
          turn,
          ex,
          if(state.history_key == t["key"], do: state.history_cursor, else: 0)
        )

      next = if cursor == 0, do: t["key"] <> <<0>>, else: t["key"]
      %{state | history_key: next, history_cursor: cursor}
    else
      _ ->
        %{
          state
          | history_key: if(chosen, do: chosen["key"] <> <<0>>, else: nil),
            history_cursor: 0
        }
    end
  end

  # A turn without its process: ended in Facts, with why.
  defp lost(names, key, why) do
    content = %{
      "op" => "change",
      "key" => key,
      "values" => %{
        names.state => names.ended,
        names.why => why,
        names.lease => "",
        names.ended_at => now_text()
      },
      "version" => nil,
      "by" => "runtime",
      "cause" => why
    }

    case Talk.put(names.kind, content) do
      {:stored, _} -> Logger.info("runtime: #{key} ended: #{why}")
      other -> Logger.warning("runtime: #{key} not ended: #{inspect(other)}; tried again")
    end
  end

  # The turns running here: `%{key => {agent, item}}`.
  defp local do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(AtlasRuntime.Supervisor),
        is_pid(pid),
        [{key, value}] <- [Registry.keys(AtlasRuntime.Turns, pid) |> Enum.map(&{&1, value(&1)})],
        value != nil,
        into: %{},
        do: {key, value}
  end

  defp value(key) do
    case Registry.lookup(AtlasRuntime.Turns, key) do
      [{_pid, value}] -> value
      _ -> nil
    end
  end

  @names ~w(kind key on by state running ended machine lease activity why ended_at outcome attempt)

  # The ended turns of this machine, newest first: `[{agent, ended at (ms), crashed?}]`.
  defp mine_ended(turns, names, machine) do
    for turn <- turns,
        turn["values"][names.state] == names.ended,
        turn["values"][names.machine] == machine,
        {:ok, at, _} <- [DateTime.from_iso8601(to_string(turn["values"][names.ended_at]))],
        [agent] <- [get_in(turn, ["links", names.by]) || []] do
      crashed? = String.starts_with?(to_string(turn["values"][names.why]), "the agent crashed")
      {agent, DateTime.to_unix(at, :millisecond), crashed?}
    end
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @crashes 3
  @window 10 * 60_000

  # The agents that may start a turn now: not 3 crashes in 10 minutes here, and past the
  # pause after the crashes in a row they ended with. Says so on the agent when it changes.
  defp able(description, names, ended, agents, opts) do
    now = System.system_time(:millisecond)
    machine = Keyword.fetch!(opts, :machine)

    Enum.filter(Map.keys(agents), fn agent ->
      theirs = for {^agent, at, crashed?} <- ended, do: {at, crashed?}
      recent = for {at, true} <- theirs, now - at < @window, do: at
      cannot? = length(recent) >= @crashes
      :ok = cannot_run(description, names, agent, machine, cannot? && List.last(recent))
      in_a_row = theirs |> Enum.take_while(&elem(&1, 1)) |> length()

      paused? =
        in_a_row > 0 and
          now <
            elem(hd(theirs), 0) +
              Keyword.fetch!(opts, :crash_pause) * Integer.pow(2, in_a_row - 1)

      under_limit?(agents[agent], agent, Keyword.get(opts, :turns_here, %{})) and not cannot? and
        not paused?
    end)
  end

  # An agent's `turn_limit`: no more turns on this machine than that, ever (a trial's one).
  defp under_limit?(%{"turn_limit" => limit}, agent, turns_here) when is_integer(limit),
    do: Map.get(turns_here, agent, 0) < limit

  defp under_limit?(_settings, _agent, _turns_here), do: true

  # The agent's field that says it cannot run here (`runtime.agent.cannot_run`): set when it
  # crashed 3 times in 10 minutes on this machine, cleared once that is no longer so.
  defp cannot_run(description, names, agent, machine, since) do
    with field when is_binary(field) <- get_in(description, ["runtime", "agent", "cannot_run"]),
         [kind] <- get_in(description, ["relations", names.by, "to"]),
         %{"fact" => %{} = fact} <- Talk.read(kind, %{"key" => agent, "plain" => true}) do
      was = to_string(fact["values"][field])
      here? = String.starts_with?(was, "on #{machine} ")

      {value, cause} =
        cond do
          since && not here? ->
            text = "on #{machine} since #{text_at(since)}: #{@crashes} crashes in 10 minutes"
            {text, "#{agent} crashed #{@crashes} times in 10 minutes on #{machine}"}

          !since && here? ->
            {"", "#{agent} no longer crashed #{@crashes} times in 10 minutes on #{machine}"}

          true ->
            {nil, nil}
        end

      if cause do
        content = %{
          "op" => "change",
          "key" => agent,
          "values" => %{field => value},
          "version" => nil,
          "by" => "runtime",
          "cause" => cause
        }

        case Talk.put(kind, content) do
          {:stored, _} -> Logger.info("runtime: #{agent}: #{cause}")
          other -> Logger.warning("runtime: #{agent} not marked: #{inspect(other)}")
        end
      end

      :ok
    else
      _ -> :ok
    end
  end

  defp seconds(n, _default) when is_number(n), do: Kernel.round(n * 1000)
  defp seconds(_n, default), do: default

  defp now_text, do: text_at(System.system_time(:millisecond))

  defp text_at(ms),
    do:
      ms
      |> DateTime.from_unix!(:millisecond)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

  defp atomize(names), do: Map.new(@names, &{String.to_atom(&1), names[&1]})
end
