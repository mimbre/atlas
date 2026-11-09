defmodule AtlasFlow.Engine do
  @moduledoc """
  Flow's engine: it reconciles the durable runs of the model's selected subflows
  (`AtlasFlow.Runs.Store`) and projects what each presents on its subject
  (`AtlasFlow.Runs.Projection`). The model is `AtlasFlow.Model`, given as `model:` or
  configured. It keeps no process per fact: everything it needs is in Facts.

  - At boot, and on its own timer (its round), it reads rela's schema (its kinds),
    reconciles every run, and projects every fact of each kind a selected subflow runs
    on. A run's timer due before the round brings the round forward.
  - It listens to every kind. A hint is about the facts it changed (the one it is about
    and every one in its `changes`) and every fact above them (through the model's
    parent relations, read plainly from Facts); a fact whose turn ended (the work it was
    on), the fact a changed component belongs to, and the parent of a composition's tally
    whose relation a changed fact links through are among them too. A moved or unlinked
    fact also reaches its former parents through its `changes` links (before and after).
    A delete cannot be
    read any more: what was above a fact it removed is found from the links its `changes`
    name (before and after). The runs of those facts are reconciled, then each is
    projected again. A new fact of a kind that owns work projects again the facts whose
    owner waited for it. A hint reads only around the facts it is about, never every
    fact: finding kinds, facts that changed without a hint about them, and every other
    run is the round's. A hint of Flow's own write is passed over: Flow writes only what
    no state depends on (Facts checks that). A lost hint only waits for the round.

  It reaches Facts only over the Bus, as the endpoint `flow`.

  It keeps Flow's settled position (`AtlasFlow.Settled`): a hint is settled once the
  engine reconciled and projected what it is about, through the writes it made for it
  that follow the hint without another writer's in between. A hint whose subjects could
  not be completely discovered, whose runs could not be reconciled, or whose required
  projection failed holds the position below it until a round reconciles every run and
  successfully reads and projects every subject; a
  request `_settled` (`{"position": P}`) is answered `{"settled": S}` once `S ≥ P`, at
  once when it is. At most 256 wait: one more answers the oldest at once, with `S` as it
  is. A waiter left when the engine restarts is lost; whoever asked waits no longer than
  it chose to.

  The actors the model's owners name must be filled by the environment's settings, or
  Flow does not start (`AtlasFlow.Model.load/3`). One whose fact does not exist yet is
  an owner like any other: the fact it owns waits for it, and says so
  (`AtlasFlow.Runs.Projection`), so a fresh environment starts and makes its first
  actors through Control.
  """
  use GenServer

  require Logger

  alias AtlasBus.Envelope
  alias AtlasFlow.{Settled, Talk}
  alias AtlasFlow.Runs.{Clock, Projection, Store}

  # How far up a hint looks for facts whose state it may change.
  @depth 8

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

  @doc "Read Facts, reconcile every run and project every subject, now (for tests)."
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
       # The kinds a selected subflow runs on, and the kinds their owners are.
       kinds: subjects(runner),
       owners: owner_kinds(runner),
       listening: MapSet.new(),
       timer: nil,
       # When the round is due, so a hint's run with an earlier timer can bring it forward.
       round_at: nil,
       # Whether the runs were read whole once: before that, a hint reconciles no run.
       reconciled: false,
       settled: Settled.new(),
       # The facts whose owner did not exist yet, by that owner: `%{owner => MapSet}`.
       waiting: %{}
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
    do: {:noreply, settle(state, Settled.seen(state.settled, position(hint)))}

  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind} = hint, content}, state) do
    {{state, reconciled, projected}, wrote} =
      Talk.writing(fn ->
        with {:ok, facts} <- affected(state, kind, content) do
          {state, reconciled} = reconcile_runs(state, facts)

          subjects = for {k, key, _} <- facts, k in state.kinds, uniq: true, do: {k, key}

          # A new owner (a fact of a kind work is owned by): a fact whose owner waited for
          # it can have it now.
          {waited, waiting} =
            case content do
              %{"op" => "create", "key" => key} when is_binary(key) ->
                if kind in state.owners,
                  do: Map.pop(state.waiting, {kind, key}, MapSet.new()),
                  else: {MapSet.new(), state.waiting}

              _ ->
                {MapSet.new(), state.waiting}
            end

          {state, projected} =
            project_all(
              %{state | waiting: waiting},
              Enum.uniq(subjects ++ MapSet.to_list(waited))
            )

          {state, reconciled, projected}
        else
          {:error, why} ->
            Logger.warning(
              "flow could not discover the subjects a hint is about: #{inspect(why)}"
            )

            {state, :failed, :failed}
        end
      end)

    settled =
      case {reconciled, projected} do
        {:ok, :ok} -> Settled.handled(state.settled, position(hint), wrote)
        # Incomplete discovery also waits for a complete successful recovery round.
        _ -> Settled.hold(state.settled, position(hint))
      end

    {:noreply, settle(state, settled)}
  end

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

  # A failure Control asks about (test only; IS-Atlas-23): Flow keeps no process of its
  # own per fact, so it offers none.
  def handle_info({:atlas_bus, %Envelope{class: "fault"} = envelope, content}, state) do
    answer =
      case content do
        %{"do" => "offer"} -> %{"offers" => []}
        _ -> %{"refused" => "Flow does not know that failure."}
      end

    AtlasBus.send(Envelope.reply(envelope, "answer"), answer)
    {:noreply, state}
  end

  # Answers that came after their wait, and anything else.
  def handle_info(_message, state), do: {:noreply, state}

  defp position(%Envelope{position: position}) when is_integer(position), do: position
  defp position(_hint), do: 0

  # Answer the waiters `settled` has reached.
  defp settle(state, {answered, settled}) do
    for {request, value} <- answered,
        do: AtlasBus.send(Envelope.reply(request, "answer"), %{"settled" => value})

    %{state | settled: settled}
  end

  # Project each of `subjects` (`{kind, key}`); one whose owner does not exist yet waits
  # for it.
  defp project_all(state, subjects) do
    Enum.reduce(subjects, {state, :ok}, fn {kind, key}, {state, outcome} ->
      waiting = Map.new(state.waiting, fn {o, s} -> {o, MapSet.delete(s, {kind, key})} end)
      waiting = for {o, s} <- waiting, s != MapSet.new(), into: %{}, do: {o, s}

      case Projection.project(state.runner, kind, key) do
        {:ok, %{waits: {_, _} = owner}} ->
          {%{
             state
             | waiting:
                 Map.update(
                   waiting,
                   owner,
                   MapSet.new([{kind, key}]),
                   &MapSet.put(&1, {kind, key})
                 )
           }, outcome}

        {:ok, _} ->
          {%{state | waiting: waiting}, outcome}

        {:error, why} ->
          Logger.warning("flow could not project #{kind} #{key}: #{inspect(why)}")
          {state, :failed}
      end
    end)
  end

  # The kinds a selected subflow runs on (none while the runs cannot be run).
  defp subjects(%{config: nil}), do: []

  defp subjects(%{config: config}),
    do: for({_, s} <- config["selection"], uniq: true, do: s["subject"])

  # The kinds their projections assign to: what their owner relations point at.
  defp owner_kinds(%{config: nil}), do: []

  defp owner_kinds(%{config: config, relations: relations}) do
    for {_, s} <- config["selection"],
        relation = get_in(s, ["projection", "owner_relation"]),
        is_binary(relation),
        kind <- get_in(relations, [relation, "to"]) || [],
        uniq: true,
        do: kind
  end

  # The facts a hint can change the state of, `{kind, key, how}`: each fact it changed and
  # every fact above it. A fact it deleted is only reconciled (`:existing`), and what was
  # above it is found from the links it had. A choice Facts keeps for a run is about the
  # run's subject.
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

    with {:ok, facts} <-
           discover(main ++ changes ++ subject_of(state, kind, content), &around(state, &1)) do
      {:ok, Enum.uniq(facts)}
    end
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

    targets =
      for {relation, targets} <- change["links"] || %{},
          to <- get_in(relations, [relation, "to"]) || [],
          target <- List.wrap(targets),
          is_binary(target),
          do: {to, target}

    with {:ok, above} <- discover(targets, fn {k, key} -> up(state, k, key, @depth, :found) end) do
      {:ok, [{kind, key, :existing} | Enum.map(above, fn {k, key} -> {k, key, :ensure} end)]}
    end
  end

  defp around(state, %{"kind" => kind, "key" => key} = change)
       when is_binary(kind) and is_binary(key) do
    # Facts keeps the union of links before and after the write. The current fact
    # alone cannot tell us which parent lost a child. Follow only relations whose
    # parent or tally depends on this kind, just as for its current links in `up`.
    targets = parents(state, kind, change["links"] || %{})

    with {:ok, above} <- up(state, kind, key, @depth),
         {:ok, former} <-
           discover(targets, fn {k, p} -> up(state, k, p, @depth - 1, :found) end) do
      {:ok, Enum.map(above ++ former, fn {k, key} -> {k, key, :ensure} end)}
    end
  end

  defp around(_state, _change), do: {:ok, []}

  # A partial target set is not enough to reconcile or settle a hint. Keep every
  # recursive or reverse lookup's failure instead of treating it as an empty list.
  defp discover(items, lookup) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, found} ->
      case lookup.(item) do
        {:ok, facts} -> {:cont, {:ok, found ++ facts}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # The runs of the facts a hint is about, reconciled now (`{state, :ok}`); every other
  # run waits for the round. Nothing before the runs were read whole once, or while they
  # cannot be: those, and a reconcile that fails, are `:failed`, for the round to do.
  defp reconcile_runs(%{reconciled: false} = state, _facts), do: {state, :failed}

  defp reconcile_runs(%{refusal: refusal} = state, _facts) when refusal != nil,
    do: {state, :failed}

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
        {state, :ok}

      {:ok, runs} ->
        same = fn a, b -> a["flow"] == b["flow"] and a["subject_key"] == b["subject_key"] end
        kept = Enum.reject(state.runs, fn run -> Enum.any?(runs, &same.(&1, run)) end)
        {sooner(%{state | runs: kept ++ runs}), :ok}

      {:error, why} ->
        Logger.warning("flow could not reconcile the runs a hint is about: #{inspect(why)}")
        {state, :failed}
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

          # Listen to every kind: what hangs under a fact can change its state.
          listening =
            Enum.reduce(Map.keys(description["entities"] || %{}), state.listening, fn kind, acc ->
              :ok = AtlasBus.listen(kind)
              MapSet.put(acc, kind)
            end)

          {subjects, listed} =
            Enum.reduce(state.kinds, {[], :ok}, fn kind, {subjects, outcome} ->
              case facts(kind) do
                {:ok, facts} -> {subjects ++ Enum.map(facts, &{kind, &1["key"]}), outcome}
                :failed -> {subjects, :failed}
              end
            end)

          {state, projected} = project_all(%{state | listening: listening}, subjects)

          # Release only after the complete recovery projection, including its reads.
          if state.refusal == nil and state.reconciled and listed == :ok and projected == :ok,
            do: settle(state, Settled.release(state.settled)),
            else: state

        other ->
          Logger.warning("flow has no description yet: #{inspect(other)}")
          state
      end

    schedule_round(state, next_round(state))
  end

  defp facts(kind) do
    case Talk.read(kind, %{}) do
      %{"facts" => facts} when is_list(facts) ->
        {:ok, facts}

      other ->
        Logger.warning("flow could not list #{kind}: #{inspect(other)}")
        :failed
    end
  end

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
  # of a kind it may not be). An unavailable read leaves the complete target set unknown.
  defp up(state, kind, key, depth, mode \\ :always)
  defp up(_state, _kind, _key, 0, _mode), do: {:ok, []}

  defp up(state, kind, key, depth, mode) do
    relations = state.runner.relations

    case Talk.read(kind, %{"key" => key, "plain" => true}) do
      %{"fact" => %{"links" => links} = fact} when is_map(links) ->
        n = state.runner.turn || %{}

        # A turn that is not running (any more): the work it was on may hand over now.
        ended =
          if kind == n["kind"] and fact["values"][n["state"]] != n["running"] do
            for to <- get_in(relations, [n["on"], "to"]) || [],
                item <- links[n["on"]] || [],
                do: {to, item}
          else
            []
          end

        # A changed component (an Assignment): the fact it belongs to, when work on
        # that fact is presented.
        components =
          for {relation, %{"component" => %{}, "to" => to, "from" => from}} <- relations,
              kind in to,
              from_kind <- from,
              from_kind in state.kinds,
              do: {from_kind, relation}

        with {:ok, components} <- discover(components, &component_subjects(&1, key)),
             {:ok, above} <-
               discover(Enum.uniq(parents(state, kind, links) ++ ended ++ components), fn {k, p} ->
                 up(state, k, p, depth - 1, :found)
               end) do
          {:ok, [{kind, key} | above]}
        end

      %{"fact" => nil} ->
        {:ok, if(mode == :found, do: [], else: [{kind, key}])}

      other ->
        {:error, {:discovery_unavailable, kind, key, other}}
    end
  end

  defp parents(state, kind, links) do
    parents =
      for {relation, %{"parent" => true, "from" => from, "to" => [to]}} <- state.runner.relations,
          kind in from,
          parent <- links[relation] || [],
          is_binary(parent),
          do: {to, parent}

    # A tally may count children of kinds with no selected subflow of their own.
    tallied =
      for t <- tallies(state),
          kind in t["from"],
          anchor <- links[t["relation"]] || [],
          is_binary(anchor),
          do: {t["parent_subject"], anchor}

    Enum.uniq(parents ++ tallied)
  end

  defp component_subjects({kind, relation}, key) do
    case Talk.read(kind, %{"linked" => %{relation => key}}) do
      %{"facts" => facts} when is_list(facts) ->
        {:ok, Enum.map(facts, &{kind, &1["key"]})}

      other ->
        {:error, {:component_discovery_unavailable, kind, relation, key, other}}
    end
  end

  defp tallies(%{runner: %{config: %{"composition" => %{"tallies" => tallies}}}}), do: tallies
  defp tallies(_state), do: []
end
