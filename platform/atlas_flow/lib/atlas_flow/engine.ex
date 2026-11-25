defmodule AtlasFlow.Engine do
  @moduledoc """
  Flow's engine: it reconciles the durable runs of the model's selected subflows
  (`AtlasFlow.Runs.Store`) and projects what each presents on its subject
  (`AtlasFlow.Runs.Projection`). The model is `AtlasFlow.Model`, given as `model:` or
  configured. It keeps no process per fact: everything it needs is in Facts.

  - At boot, and on its own timer (its round), it reads rela's schema (its kinds),
    reconciles every run, and projects every fact of each kind a selected subflow runs
    on. A run's timer due before the round brings the round forward.
  - A round is planned in one message (`AtlasFlow.Runs.Store.plan/2`: every run and every
    admitted subject, and the facts to project), then taken one step per message: one
    subject reconciled, or one fact projected, each step sent to itself behind whatever
    waits. So a hint, and a `_settled` request, wait at most one step, never the whole
    round. Only one round steps at a time: one due while it steps is the next one, planned
    after it ends. A subject a hint reconciles before its step is reconciled again by the
    step, which finds the run as the hint left it and writes nothing it wrote already; one
    whose step passed is the hint's (and the next round's). The round keeps nothing
    durable: an engine restarted mid-round plans a new one from Facts.
  - It listens to every kind. A hint is about the facts it changed (the one it is about
    and every one in its `changes`) and every fact above them (through the model's
    parent relations, read plainly from Facts); a fact whose turn ended (the work it was
    on), the fact a changed component belongs to, and the parent of a composition's tally
    whose relation a changed fact links through are among them too. A moved or unlinked
    fact also reaches its former parents through its `changes` links (before and after).
    A delete cannot be
    read any more: what was above a fact it removed is found from the links its `changes`
    name (before and after). The runs of those facts are reconciled, then their subjects
    and those of all returned runs are projected, including composition parents and
    recursive ancestors absent from hint discovery. A spanned run whose supervisor
    changed (a pickup, a hand-over, leaving its span) projects the subjects of the runs
    its span names in `with:` right under its subject too, found downwards through the
    model's parent relations, as their owner is its supervisor's. Every required
    projection must succeed. A new fact of a kind that owns work projects again the facts whose
    owner waited for it. A hint reads only around the facts it is about, never every
    fact: finding kinds, facts that changed without a hint about them, and every other
    run is the round's. A hint of Flow's own write is passed over: the run writer's
    writes change nothing a state depends on (Facts checks that), and the task facts the
    work source writes, which a run's task result is read from, come as
    `{:reconcile, kind, key}` (below). A lost hint only waits for the round.

  It reaches Facts only over the Bus, as the endpoint `flow`.

  **Landing (F3-L).** Once a reconcile stored a task result whose check passed (exit 0)
  in a run, it casts `{:publish, task_key}` to `AtlasFlow.Landing` (option `landing:`),
  once per newly stored result. A cast, never a call: Landing talks to Code, and the
  Engine never waits on it (lesson 1). A cast lost while Landing is down is Landing's boot
  read to find.

  Tasks go through Flow's work source (`AtlasFlow.Activities.Task`, plan m3 A4). The
  Engine reads only what Facts and `AtlasFlow.Bases`' table hold, and never calls Code or a
  Runtime. `{:reconcile, kind, key}` reconciles that subject's runs now and projects them:
  `AtlasFlow.Delivery` casts it once a task's result is recorded (its writes are Flow's, so
  their hints are passed over), and Bases sends it as a plain message once a base a task
  waits for is cached. Both reach one function. Before the runs were read whole once, or
  when the reconcile fails, it waits for the round, which reads every task back anyway.

  It keeps Flow's settled position (`AtlasFlow.Settled`): a hint is settled once the
  engine reconciled and projected what it is about, through the writes it made for it
  that follow the hint without another writer's in between. A hint whose subjects could
  not be completely discovered, whose runs could not be reconciled, or whose required
  projection failed holds the position below it until a round planned after that hint
  reconciles every run and successfully reads and projects every subject. A round
  releases only holds from before it began; a failed step releases none. A
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

  @doc """
  Read Facts, reconcile every run and project every subject, now; answered once that
  round ended (for tests). A round stepping already ends first.
  """
  def round(server), do: GenServer.call(server, :round, 30_000)

  @doc "Apply one reviewed maintenance plan in the existing sole writer. No automatic retry."
  def recover_refused_tally(server, plan),
    do: GenServer.call(server, {:recover_refused_tally, plan}, 30_000)

  @doc "Answered once no round steps (at once when none does), for tests."
  def idle(server), do: GenServer.call(server, :idle, 30_000)

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
       landing: Keyword.get(opts, :landing, AtlasFlow.Landing),
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
       round: nil,
       # A due round, independently of the synchronous callers waiting for it.
       pending_round: false,
       # Flow's health (`AtlasFlow.Health`, IS-Atlas-117): when the round stepping now was
       # due, when a round became due while one stepped, and the last finished round's due
       # and end. The table they are written to (option `health:`).
       round_due: nil,
       pending_due: nil,
       last_round: nil,
       health: Keyword.get(opts, :health, AtlasFlow.Health),
       queued: [],
       settled: Settled.new(),
       # The facts whose owner did not exist yet, by that owner: `%{owner => MapSet}`.
       waiting: %{}
     }}
  end

  @impl true
  def handle_call(:round, from, %{round: nil} = state), do: {:noreply, begin_round(state, [from])}

  def handle_call(:round, from, state),
    do: {:noreply, %{due_later(state) | pending_round: true, queued: state.queued ++ [from]}}

  def handle_call(:idle, _from, %{round: nil} = state), do: {:reply, :ok, state}

  def handle_call(:idle, from, state),
    do: {:noreply, put_in(state.round.callers, state.round.callers ++ [from])}

  def handle_call({:recover_refused_tally, plan}, from, state) do
    result =
      Store.recover_refused_tally(
        state.runner.config,
        state.runner.flows,
        plan,
        Clock.now(state.clock)
      )

    case result do
      {:ok, _} ->
        # Reconcile and project after recovery before answering, through a fresh
        # stepped round. A round already in progress must finish first.
        caller = {:recovery, from, result}

        if state.round == nil,
          do: {:noreply, begin_round(state, [caller])},
          else:
            {:noreply,
             %{due_later(state) | pending_round: true, queued: state.queued ++ [caller]}}

      _ ->
        {:reply, result, state}
    end
  end

  @impl true
  def terminate(_reason, state), do: Clock.cancel(state.clock, state.timer)

  @impl true
  def handle_info(:round, %{round: nil} = state), do: {:noreply, begin_round(state, [])}
  # Due while one steps: coalesce independently of callers waiting for a round.
  def handle_info(:round, state), do: {:noreply, %{due_later(state) | pending_round: true}}
  def handle_info(:round_step, %{round: nil} = state), do: {:noreply, state}
  def handle_info(:round_step, state), do: {:noreply, round_step(state)}

  # Its own write: the run writer's change nothing a state depends on; Delivery's, which a
  # task's result is read from, come as `{:reconcile, kind, key}`.
  def handle_info({:atlas_bus, %Envelope{class: "stored"} = hint, %{"by" => "flow"}}, state),
    do: {:noreply, settle(state, Settled.seen(state.settled, position(hint)))}

  def handle_info({:atlas_bus, %Envelope{class: "stored", kind: kind} = hint, content}, state) do
    {{state, reconciled, projected}, wrote} =
      Talk.writing(fn ->
        with {:ok, facts} <- affected(state, kind, content) do
          known = state.runs
          {state, reconciled, runs} = reconcile_runs(state, facts)
          {belonging, found} = belonging(state, known, runs)

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
              Enum.uniq(subjects ++ run_subjects(runs) ++ belonging ++ MapSet.to_list(waited))
            )

          # Runs whose supervision moved with their parent's must be projected too.
          {state, reconciled, if(found == :ok, do: projected, else: :failed)}
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

  # A subject to reconcile now, as Bases' notify (a plain message).
  def handle_info({:reconcile, kind, key}, state) when is_binary(kind) and is_binary(key),
    do: {:noreply, reconcile_subject(state, kind, key)}

  # Answers that came after their wait, and anything else.
  def handle_info(_message, state), do: {:noreply, state}

  # A subject to reconcile now, as Delivery casts it.
  @impl true
  def handle_cast({:reconcile, kind, key}, state) when is_binary(kind) and is_binary(key),
    do: {:noreply, reconcile_subject(state, kind, key)}

  def handle_cast(_message, state), do: {:noreply, state}

  # One subject's runs reconciled now and projected, with those the reconcile returned; a
  # failure waits for the round, which reads every task back.
  defp reconcile_subject(state, kind, key) do
    known = state.runs
    {state, _reconciled, runs} = reconcile_runs(state, [{kind, key, :ensure}])
    {belonging, _found} = belonging(state, known, runs)

    {state, _projected} =
      project_all(state, Enum.uniq([{kind, key} | run_subjects(runs)] ++ belonging))

    state
  end

  # A run of a subflow a span names in its `with:` takes its owner from the spanned run
  # above it (`AtlasFlow.Runs.Projection`). When a reconcile changed a spanned run's
  # supervisor (a pickup, a hand-over, the run leaving its span), the subjects of those
  # runs are projected again with it: `{subjects, :ok | {:error, why}}`. Found downwards,
  # as hint discovery (which goes up) does not: the facts of a `with:` subflow's subject
  # kind that link to the spanned run's subject through a parent relation of the model.
  defp belonging(%{runner: %{config: config, relations: relations}}, known, runs)
       when is_map(config) do
    spans = get_in(config, ["supervision", "spans"]) || %{}

    lookups =
      for run <- runs,
          with = Enum.flat_map(spans[run["flow"]] || [], &(&1["with"] || [])),
          with != [],
          supervisor_changed?(known, run),
          name <- with,
          kind = get_in(config, ["selection", name, "subject"]),
          is_binary(kind),
          {relation, %{"parent" => true, "from" => from, "to" => [to]}} <- relations || %{},
          to == run["subject_kind"] and kind in from,
          uniq: true,
          do: {{kind, relation}, run["subject_key"]}

    case discover(lookups, fn {of, key} -> component_subjects(of, key) end) do
      {:ok, subjects} -> {Enum.uniq(subjects), :ok}
      {:error, _} = error -> {[], error}
    end
  end

  defp belonging(_state, _known, _runs), do: {[], :ok}

  # Whether `run`'s supervisor differs from the one of its run as last known.
  defp supervisor_changed?(known, run) do
    same =
      &(&1["flow"] == run["flow"] and &1["subject_kind"] == run["subject_kind"] and
          &1["subject_key"] == run["subject_key"])

    case Enum.find(known, same) do
      nil -> run["supervised_by"] != nil
      before -> before["supervised_by"] != run["supervised_by"]
    end
  end

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

  # The runs of the facts a hint is about, reconciled now (`{state, :ok, runs}`); every other
  # run waits for the round. Nothing before the runs were read whole once, or while they
  # cannot be: those, and a reconcile that fails, are `:failed`, for the round to do.
  defp reconcile_runs(%{reconciled: false} = state, _facts), do: {state, :failed, []}

  defp reconcile_runs(%{refusal: refusal} = state, _facts) when refusal != nil,
    do: {state, :failed, []}

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
        {state, :ok, []}

      {:ok, runs} ->
        checked(state, state.runs, runs)
        {sooner(%{state | runs: Store.merge(state.runs, runs)}), :ok, runs}

      {:error, why} ->
        Logger.warning("flow could not reconcile the runs a hint is about: #{inspect(why)}")
        {state, :failed, []}
    end
  end

  # The task results whose check passed that `runs` hold and the runs as last `known` did
  # not: Landing publishes each (F3-L). A cast, so a blocked Landing delays nothing here.
  defp checked(state, known, runs) do
    before = MapSet.new(for run <- known, t <- tasks(run), do: t["key"])

    keys =
      for run <- runs,
          t <- tasks(run),
          get_in(t, ["check", "exit_status"]) == 0,
          is_binary(t["key"]),
          not MapSet.member?(before, t["key"]),
          uniq: true,
          do: t["key"]

    Enum.each(keys, &GenServer.cast(state.landing, {:publish, &1}))
  end

  defp tasks(run), do: (run["pending"] || %{})["tasks"] || []

  defp run_subjects(runs),
    do: Enum.uniq(for run <- runs, do: {run["subject_kind"], run["subject_key"]})

  # A run's timer due before the round: the round comes then.
  defp sooner(%{round: round} = state) when round != nil, do: state

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
    |> health()
  end

  # A round became due while one steps: it is due from now, however long that one takes.
  defp due_later(%{pending_due: nil} = state), do: %{state | pending_due: Clock.now(state.clock)}
  defp due_later(state), do: state

  # When the round that begins now was due: when it became due while another stepped, when
  # its timer was set for, or now when it comes sooner (a call, a run's timer).
  defp due_now(state) do
    now = Clock.now(state.clock)

    cond do
      state.pending_due -> state.pending_due
      state.round_at && DateTime.compare(state.round_at, now) == :lt -> state.round_at
      true -> now
    end
  end

  # What Flow's health page reads (`AtlasFlow.Health`): never waited for.
  defp health(state) do
    {last_due, last_finished} = state.last_round || {nil, nil}

    AtlasFlow.Health.round(
      %{
        due: state.round_due,
        next_due: state.round_at,
        last_due: last_due,
        last_finished: last_finished
      },
      state.health
    )

    state
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

  # Plan a round: read the kinds, listen to them, read every run and subject (no
  # reconcile yet), and list what to project; then step it.
  defp begin_round(state, callers) do
    Clock.cancel(state.clock, state.timer)
    due = due_now(state)
    state = health(%{state | timer: nil, round_at: nil, round_due: due, pending_due: nil})

    case Talk.read("_description", %{}) do
      %{"description" => description} ->
        # Listen to every kind: what hangs under a fact can change its state.
        listening =
          Enum.reduce(Map.keys(description["entities"] || %{}), state.listening, fn kind, acc ->
            :ok = AtlasBus.listen(kind)
            MapSet.put(acc, kind)
          end)

        {state, reconcile} = plan(%{state | listening: listening})

        {project, listed} =
          Enum.reduce(state.kinds, {[], nil}, fn kind, {steps, failed} ->
            case facts(kind) do
              {:ok, facts} ->
                keys = Enum.sort(for fact <- facts, do: fact["key"])
                {steps ++ for(key <- keys, do: {:project, kind, key}), failed}

              :failed ->
                {steps, :listing_failed}
            end
          end)

        # The hints looked at until now are the ones this round can release.
        state = settle(state, Settled.begin(state.settled))
        round = %{steps: reconcile ++ project, failed: state.refusal || listed, callers: callers}
        send(self(), :round_step)
        %{state | round: round}

      other ->
        Logger.warning("flow has no description yet: #{inspect(other)}")
        end_round(%{state | round: %{steps: [], failed: :no_description, callers: callers}})
    end
  end

  # The runs read whole, and the subjects to reconcile one by one: `{state, steps}`.
  defp plan(%{runner: %{refusal: refusal}} = state) when refusal != nil do
    Logger.error("generated runner refused: #{inspect(refusal)}")
    {%{state | runs: [], refusal: refusal}, []}
  end

  defp plan(state) do
    case Store.plan(state.runner.config, state.runner.flows) do
      {:ok, %{runs: runs, subjects: subjects}} ->
        # Every run is known from here on, so a hint can reconcile its own as a step would.
        {%{state | runs: runs, refusal: nil, reconciled: true},
         for({kind, key} <- subjects, do: {:reconcile, kind, key})}

      {:error, why} ->
        Logger.error("generated runner refused: #{inspect(why)}")
        {%{state | runs: [], refusal: why}, []}
    end
  end

  defp round_step(%{round: %{steps: []}} = state), do: end_round(state)

  defp round_step(%{round: %{steps: [step | rest]}} = state) do
    state = put_in(state.round.steps, rest)

    state =
      case step do
        {:reconcile, kind, key} ->
          reconcile_step(state, kind, key)

        {:project, kind, key} ->
          {state, projected} = project_all(state, [{kind, key}])
          if projected == :ok, do: state, else: put_in(state.round.failed, :projection_failed)
      end

    send(self(), :round_step)
    state
  end

  # One subject's runs, as a hint reconciles them. A failure leaves the rest of the round
  # to step, but it releases nothing held.
  defp reconcile_step(state, kind, key) do
    case Store.reconcile_subjects(
           state.runner.config,
           state.runner.flows,
           Clock.now(state.clock),
           state.runs,
           [{kind, key}]
         ) do
      {:ok, runs} ->
        # Parents returned by composition are required projections too. Keep each
        # projection as its own mailbox step, including subjects absent from the plan.
        projects = for {k, key} <- run_subjects(runs), do: {:project, k, key}
        checked(state, state.runs, runs)
        state = %{state | runs: Store.merge(state.runs, runs)}
        update_in(state.round.steps, &Enum.uniq(&1 ++ projects))

      {:error, why} ->
        Logger.warning("flow could not reconcile the runs of #{kind} #{key}: #{inspect(why)}")
        put_in(state.round.failed, state.round.failed || why)
    end
  end

  defp end_round(%{round: round} = state) do
    # Every run reconciled after the hints held before the round began: those are settled.
    state =
      if round.failed == nil and state.refusal == nil and state.reconciled,
        do: settle(state, Settled.release(state.settled)),
        else: state

    # Its health is noted before anyone waiting for the round hears it ended.
    state =
      health(%{
        state
        | round: nil,
          round_due: nil,
          last_round: {state.round_due, Clock.now(state.clock)}
      })

    for caller <- round.callers do
      case caller do
        {:recovery, from, result} -> GenServer.reply(from, result)
        from -> GenServer.reply(from, :ok)
      end
    end

    if state.pending_round,
      do: begin_round(%{state | pending_round: false, queued: []}, state.queued),
      else: schedule_round(state, next_round(state))
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
