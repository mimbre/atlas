defmodule AtlasFlow.Engine do
  @moduledoc """
  Flow's engine: keeps one process (`AtlasFlow.Item`) running for every open fact that a
  flow of the model runs on (`AtlasFlow.Model`, given as `model:` or configured).

  - At boot, and on its own timer, it reads rela's schema (its kinds) and every fact of
    each kind a flow runs on, and starts a process for each fact that
    has none. A process stops
    by itself once its fact is done; reading again starts it when the fact opens again.
  - It listens to every kind. A hint pokes the processes of the facts it changed (the
    one it is about and every one in its `changes`) and of every fact above them (through
    the model's parent relations, read plainly from Facts), so those look again at once;
    one that has no process yet gets one. A delete cannot be read any more: what was above
    a fact it removed is found from the links its `changes` name (before and after). A
    new fact of a kind a flow assigns to pokes the processes whose owner waited for it
    (`AtlasFlow.Waiting`). The runs whose subject is among those facts are reconciled
    first, so the processes look at them as they are now. A hint reads only around the
    facts it is about, never every fact: finding kinds, facts that opened without a hint
    about them, and every other run is the timer's round. A hint of Flow's own write is
    passed over: Flow writes only what no state depends on (Facts checks that). A lost
    hint only waits for the timer (nobody depends on a hint).

  It reaches Facts only over the Bus, as the endpoint `flow`.

  It keeps Flow's settled position (`AtlasFlow.Settled`): each hint it pokes processes for
  is a ticket they answer after their next look, and a request `_settled` (`{"position":
  P}`) is answered `{"settled": S}` once `S ≥ P`, at once when it is. A waiter left when
  the engine restarts is lost; whoever asked waits no longer than it chose to.

  The actors the model's owners name must be filled by the environment's settings, or
  Flow does not start (`AtlasFlow.Model.load/3`). One whose fact does not exist yet is
  an owner like any other: the fact it owns waits for it, and says so
  (`AtlasFlow.Item`), so a fresh environment starts and makes its first actors through
  Control.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasFlow.{Item, Legacy, Settled, Talk}
  alias AtlasFlow.Runs.{Clock, Store}

  # How far up a hint looks for facts whose state it may change.
  @depth 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Read Facts and start what is missing, now (for tests)."
  def round(server), do: GenServer.call(server, :round, 30_000)

  @impl true
  def init(opts) do
    model = Keyword.get_lazy(opts, :model, &AtlasFlow.Model.configured!/0)
    environment = Keyword.get_lazy(opts, :environment, &AtlasFlow.Model.environment/0)
    actors = Keyword.get_lazy(opts, :actors, &AtlasBus.Actors.configured/0)
    runner = AtlasFlow.Model.load(model, environment, actors)
    :ok = AtlasBus.attach("flow")
    send(self(), :round)

    {:ok,
     %{
       every: Keyword.get(opts, :every, 60_000),
       clock: Keyword.get(opts, :clock, {Clock, nil}),
       runner: runner,
       runs: [],
       refusal: nil,
       flows: [],
       kinds: [],
       owners: [],
       listening: MapSet.new(),
       timer: nil,
       # When the round is due, so a hint's run with an earlier timer can bring it forward.
       round_at: nil,
       # Whether the runs were read whole once: before that, a hint reconciles no run.
       reconciled: false,
       settled: Settled.new(),
       # The processes that hold a ticket, watched so one that is gone holds none.
       watched: %{}
     }}
  end

  @impl true
  def handle_call(:round, _from, state), do: {:reply, :ok, look_all(state)}

  @impl true
  def terminate(_reason, state), do: Clock.cancel(state.clock, state.timer)

  @impl true
  def handle_info(:round, state), do: {:noreply, look_all(state)}

  # Its own write changes nothing any state depends on.
  def handle_info({:atlas_bus, %Envelope{class: "stored"} = hint, %{"by" => "flow"}}, state),
    do: {:noreply, poke(state, hint.position, [])}

  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind} = hint, content}, state) do
    facts = affected(state, kind, content)
    state = reconcile_runs(state, facts)

    # A new owner (a fact of a kind a flow assigns to): a fact whose owner waited for it
    # can have it now.
    waiting =
      case content do
        %{"op" => "create", "key" => key} when is_binary(key) ->
          if kind in state.owners,
            do: for({pid, _} <- Registry.lookup(AtlasFlow.Waiting, {kind, key}), do: pid),
            else: []

        _ ->
          []
      end

    poked =
      for {kind, key, how} <- facts,
          kind in state.kinds,
          pid = process(kind, key, how, state),
          is_pid(pid),
          do: pid

    {:noreply, poke(state, hint.position, Enum.uniq(poked ++ waiting))}
  end

  # A process looked after its pokes up to `ticket`, and wrote up to `wrote`.
  def handle_info({:looked, pid, ticket, opts}, state),
    do: {:noreply, settle(state, Settled.looked(state.settled, pid, ticket, opts[:wrote]))}

  def handle_info({:DOWN, ref, :process, pid, _why}, %{watched: watched} = state)
      when is_map_key(watched, pid) and :erlang.map_get(pid, watched) == ref,
      do: {:noreply, settle(state, Settled.down(state.settled, pid))}

  # How far Flow has settled, once it has reached the position asked for.
  def handle_info(
        {:atlas_bus, %Envelope{class: "request", kind: "_settled"} = request,
         %{"position" => position}},
        state
      )
      when is_integer(position) and position >= 0,
      do: {:noreply, settle(state, Settled.wait(state.settled, position, request))}

  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "_settled"} = request, _}, state) do
    AtlasBus.send(Envelope.reply(request, "answer"), %{
      "error" => "_settled needs a position, a whole number"
    })

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

  # Each process poked for the hint at `position` holds it as a ticket until it looked.
  defp poke(state, position, pids) when is_integer(position) do
    watched =
      Enum.reduce(pids, state.watched, fn pid, watched ->
        Map.put_new_lazy(watched, pid, fn -> Process.monitor(pid) end)
      end)

    for pid <- pids, do: Item.poke(pid, position)
    settle(%{state | watched: watched}, Settled.hint(state.settled, position, pids))
  end

  # A hint without a position: no ticket to wait for.
  defp poke(state, _position, pids) do
    for pid <- pids, do: Item.poke(pid, 0)
    state
  end

  # Answer the waiters `settled` has reached, and stop watching who holds no ticket.
  defp settle(state, {answered, settled}) do
    for {request, value} <- answered,
        do: AtlasBus.send(Envelope.reply(request, "answer"), %{"settled" => value})

    {holding, done} =
      Enum.split_with(state.watched, fn {pid, _} -> Settled.holds?(settled, pid) end)

    for {_, ref} <- done, do: Process.demonitor(ref, [:flush])
    %{state | settled: settled, watched: Map.new(holding)}
  end

  # The facts a hint can change the state of, `{kind, key, how}`: each fact it changed and
  # every fact above it (`:ensure`: given a process when it has none). A fact it deleted
  # keeps only the process it had (`:existing`), and what was above it is found from the
  # links it had. A choice Facts keeps for a run is about the run's subject.
  defp affected(state, kind, content) do
    changes = for %{"kind" => _, "key" => _} = c <- content["changes"] || [], do: c

    main =
      case content do
        %{"key" => key} when is_binary(key) ->
          if Enum.any?(changes, &(&1["kind"] == kind and &1["key"] == key)),
            do: [],
            else: [%{"kind" => kind, "key" => key, "op" => content["op"], "links" => %{}}]

        _ ->
          []
      end

    Enum.uniq(
      Enum.flat_map(main ++ changes ++ subject_of(state, kind, content), &around(state, &1))
    )
  end

  defp subject_of(%{runner: %{config: %{"inputs" => %{"kind" => kind}}}}, kind, content) do
    case content do
      %{"subject_kind" => k, "subject_key" => key} when is_binary(k) and is_binary(key) ->
        [%{"kind" => k, "key" => key, "op" => "change", "links" => %{}}]

      _ ->
        []
    end
  end

  defp subject_of(_state, _kind, _content), do: []

  defp around(state, %{"op" => "delete", "kind" => kind, "key" => key} = change) do
    relations = state.runner.relations

    above =
      for {relation, targets} <- change["links"] || %{},
          to <- get_in(relations, [relation, "to"]) || [],
          target <- List.wrap(targets),
          is_binary(target),
          entry <- up(state.flows, state.runner, to, target, @depth, :found),
          do: entry

    [{kind, key, :existing} | Enum.map(above, fn {k, key} -> {k, key, :ensure} end)]
  end

  defp around(state, %{"kind" => kind, "key" => key}) when is_binary(kind) and is_binary(key) do
    for {k, key} <- up(state.flows, state.runner, kind, key, @depth), do: {k, key, :ensure}
  end

  defp around(_state, _change), do: []

  defp process(kind, key, :ensure, state), do: ensure(kind, key, state)

  defp process(kind, key, :existing, _state) do
    case Registry.lookup(AtlasFlow.Items, {kind, key}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # The runs of the facts a hint is about, reconciled now; every other run waits for the
  # round. Nothing before the runs were read whole once, or while they cannot be.
  defp reconcile_runs(%{reconciled: false} = state, _facts), do: state
  defp reconcile_runs(%{refusal: refusal} = state, _facts) when refusal != nil, do: state

  defp reconcile_runs(state, facts) do
    subjects = for {kind, key, _} <- facts, uniq: true, do: {kind, key}
    now = Clock.now(state.clock)

    case Store.reconcile_subjects(
           state.runner.config,
           state.runner.flows,
           now,
           state.runs,
           subjects
         ) do
      {:ok, []} ->
        state

      {:ok, runs} ->
        same = fn a, b -> a["flow"] == b["flow"] and a["subject_key"] == b["subject_key"] end
        kept = Enum.reject(state.runs, fn run -> Enum.any?(runs, &same.(&1, run)) end)
        sooner(%{state | runs: kept ++ runs})

      {:error, why} ->
        Logger.warning("flow could not reconcile the runs a hint is about: #{inspect(why)}")
        state
    end
  end

  # A run's timer due before the round: the round comes then.
  defp sooner(state) do
    delay = next_round(state)
    at = DateTime.add(Clock.now(state.clock), delay, :millisecond)

    if state.round_at == nil or DateTime.compare(at, state.round_at) == :lt,
      do: schedule_round(state, delay),
      else: state
  end

  defp schedule_round(state, delay) do
    Clock.cancel(state.clock, state.timer)

    %{
      state
      | timer: Clock.schedule(state.clock, self(), :round, delay),
        round_at: DateTime.add(Clock.now(state.clock), delay, :millisecond)
    }
  end

  # When the round is due: on its interval, or at the first timer of an active run.
  defp next_round(state) do
    Enum.reduce(state.runs, state.every, fn run, delay ->
      timers = if run["status"] == "active", do: run["deadlines"]["timers"], else: []

      Enum.reduce(timers, delay, fn t, d ->
        min(
          d,
          max(
            0,
            DateTime.diff(
              AtlasFlow.Runs.Run.parse!(t["due"]),
              Clock.now(state.clock),
              :millisecond
            )
          )
        )
      end)
    end)
  end

  defp look_all(state) do
    state =
      case Talk.read("_description", %{}) do
        %{"description" => description} ->
          state = reconcile(state)
          relations = state.runner.relations
          flows = state.runner.legacy
          kinds = Legacy.kinds(flows)

          # Listen to every kind: what hangs under a fact can change its state.
          listening =
            Enum.reduce(Map.keys(description["entities"] || %{}), state.listening, fn kind, acc ->
              :ok = AtlasBus.listen(kind)
              MapSet.put(acc, kind)
            end)

          for kind <- kinds, flow = Legacy.for_kind(flows, kind) do
            case Talk.read(kind, %{}) do
              %{"facts" => facts} ->
                for fact <- facts,
                    runnable?(state, kind, fact) and
                      (Store.selected(state.runner.config, kind, fact) != nil or
                         open?(relations, kind, flow, fact)),
                    do: ensure(kind, fact["key"], state)

              other ->
                Logger.warning("flow could not list #{kind}: #{inspect(other)}")
            end
          end

          %{
            state
            | kinds: kinds,
              owners: Legacy.owner_kinds(flows, relations),
              flows: flows,
              listening: listening
          }

        other ->
          Logger.warning("flow has no description yet: #{inspect(other)}")
          state
      end

    schedule_round(state, next_round(state))
  end

  # While the runs cannot be reconciled, the facts they run on wait; the others go on.
  defp runnable?(state, kind, fact),
    do: state.refusal == nil or Store.selected(state.runner.config, kind, fact) == nil

  defp reconcile(%{runner: %{refusal: refusal}} = state) when refusal != nil do
    Logger.error("generated runner refused: #{inspect(refusal)}")
    %{state | runs: [], refusal: refusal}
  end

  defp reconcile(state) do
    case Store.reconcile(state.runner.config, state.runner.flows, Clock.now(state.clock)) do
      {:ok, runs} ->
        %{state | runs: runs, refusal: nil, reconciled: true}

      {:error, why} ->
        Logger.error("generated runner refused: #{inspect(why)}")
        %{state | runs: [], refusal: why}
    end
  end

  # The fact and every fact above it, through the parent relations the model marks. With
  # `:found`, a fact Facts says does not exist is left out (one a deleted fact linked to,
  # of a kind it may not be); a fact Facts did not answer for stays in.
  defp up(flows, runner, kind, key, depth, mode \\ :always)
  defp up(_flows, _runner, _kind, _key, 0, _mode), do: []

  defp up(flows, runner, kind, key, depth, mode) do
    relations = runner.relations
    read = Talk.read(kind, %{"key" => key, "plain" => true})

    parents =
      case read do
        %{"fact" => %{"links" => links} = fact} ->
          parents =
            for {relation, %{"parent" => true, "from" => from, "to" => [to]}} <- relations,
                kind in from,
                parent <- links[relation] || [],
                do: {to, parent}

          n = runner.turn || %{}

          ended =
            if kind == n["kind"] and fact["values"][n["state"]] != n["running"] do
              for to <- get_in(relations, [n["on"], "to"]) || [],
                  item <- links[n["on"]] || [],
                  do: {to, item}
            else
              []
            end

          # Component changes wake open work, but do not reopen a completed fact's
          # stopped process (including historical owners left for a migration).
          components =
            for {relation, %{"component" => %{}, "to" => to, "from" => from}} <- relations,
                kind in to,
                from_kind <- from,
                %{"facts" => facts} <- [
                  Talk.read(from_kind, %{"linked" => %{relation => key}})
                ],
                item <- facts,
                component_open?(flows, relations, from_kind, item),
                do: {from_kind, item["key"]}

          # An association a flow reads (`empty`): the fact it points at may wait for it.
          anchors =
            for flow <- flows,
                to <- flow.kinds(),
                relation <- Legacy.pointing(flow, relations, to),
                kind in (get_in(relations, [relation, "from"]) || []),
                anchor <- links[relation] || [],
                uniq: true,
                do: {to, anchor}

          Enum.uniq(parents ++ ended ++ components ++ anchors)

        _ ->
          []
      end

    if mode == :found and match?(%{"fact" => nil}, read),
      do: [],
      else: [
        {kind, key}
        | Enum.flat_map(parents, fn {k, p} -> up(flows, runner, k, p, depth - 1, :found) end)
      ]
  end

  defp component_open?(flows, relations, kind, fact) do
    case Legacy.for_kind(flows, kind) do
      nil -> true
      flow -> open?(relations, kind, flow, fact)
    end
  end

  # A fact that is done by itself alone (what hangs under it can only reopen work its own
  # facts already say is open) needs no process. Nothing is taken to point at it through the
  # associations its flow reads (`empty`): its process reads them and stops when done.
  defp open?(relations, kind, flow, fact) do
    {current, _} = flow.state(fact, [], [], Legacy.pointing(flow, relations, kind))
    not flow.done?(current)
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
    spec =
      {Item, {kind, key, every: state.every, clock: state.clock, runner: state.runner}}

    case DynamicSupervisor.start_child(AtlasFlow.Supervisor, spec) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
      other -> Logger.warning("flow could not start #{key}: #{inspect(other)}")
    end
  end
end
