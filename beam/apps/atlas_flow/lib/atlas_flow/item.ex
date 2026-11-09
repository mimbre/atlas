defmodule AtlasFlow.Item do
  @moduledoc """
  One open fact's process (architecture, rule 2): alive while the fact is open, with a
  timer in every state. On its timer, and at once when poked (a hint), it reads its fact
  and what hangs under it from Facts, works out its state from the flow definition, and
  when the owner or what is expected differs from what is stored, stores the change, with
  its cause. It keeps nothing Facts does not hold: restarted at any moment, it goes on
  from Facts. When its fact is done (or gone) it stops.

  Registered as `{kind, key}` in `AtlasFlow.Items`, so there is one per fact; starting a
  second one fails.
  """
  use GenServer, restart: :transient

  require Logger

  alias AtlasFlow.{Definition, Talk}
  alias AtlasFlow.Runs.{Clock, Run, Store}

  # A burst of hints is looked at once.
  @settle 50

  def start_link({kind, key, opts}),
    do: GenServer.start_link(__MODULE__, {kind, key, opts}, name: via(kind, key))

  def via(kind, key), do: {:via, Registry, {AtlasFlow.Items, {kind, key}}}

  @doc """
  Look again soon: something it depends on may have changed. `description` is the
  engine's copy (read every round), so a poke costs no read of it; the timer reads it.
  """
  def poke(pid, description \\ nil), do: send(pid, {:poke, description})

  @impl true
  def init({kind, key, opts}) do
    :ok = AtlasBus.attach("flow/#{kind}/#{key}")
    send(self(), :look)

    {:ok,
     %{
       kind: kind,
       key: key,
       every: Keyword.fetch!(opts, :every),
       clock: Keyword.get(opts, :clock, {Clock, nil}),
       target: Keyword.get(opts, :target, AtlasFlow.Generated),
       yaml: Keyword.get(opts, :deployed_yaml),
       timer: nil,
       soon: false,
       description: nil
     }}
  end

  @impl true
  def handle_info({:poke, description}, %{soon: true} = state),
    do: {:noreply, %{state | description: description || state.description}}

  def handle_info({:poke, description}, state) do
    Clock.schedule(state.clock, self(), {:look, :poked}, @settle)
    {:noreply, %{state | soon: true, description: description}}
  end

  # On its timer it reads everything, the description too.
  def handle_info(:look, state), do: handle_info({:look, :timer}, %{state | description: nil})

  def handle_info({:look, _why}, state) do
    if state.timer, do: Clock.cancel(state.clock, state.timer)
    state = %{state | soon: false, timer: nil}

    case look(state) do
      # Back to waiting: hibernate, so the copies of the description the look read are
      # collected now rather than kept as garbage until the next look. The engine's copy a
      # poke brought is let go too: the next look gets a fresh one (a poke) or reads it.
      {:wait, every} ->
        timer = Clock.schedule(state.clock, self(), :look, every)
        {:noreply, %{state | timer: timer, description: nil}, :hibernate}

      :stop ->
        {:stop, :normal, state}
    end
  end

  # Answers that came after their wait, and anything else: back to waiting as it was.
  def handle_info(_message, %{soon: true} = state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state, :hibernate}

  defp look(state) do
    with %{"description" => description} <- description(state),
         {name, flow} <- Definition.for_kind(description, state.kind),
         %{"fact" => fact} when is_map(fact) <-
           Talk.read(state.kind, %{"key" => state.key, "incoming" => false}) do
      parents = parent_relations(description, state.kind)
      pointing = Definition.pointing(description, flow, state.kind)

      children =
        children(parents, description, state.key) ++ pointed(pointing, description, state.key)

      flow =
        case Store.selected(description, state.kind, fact) do
          {_, selection} -> Map.merge(flow, selection["projection"])
          _ -> flow
        end

      {current, vars} = projection(state, description, flow, fact, children, parents, pointing)
      result = if current, do: move(state, description, {name, flow}, fact, current, vars)

      if current["done"] == true and result != :held,
        do: :stop,
        else: {:wait, Definition.every(current || %{}, state.every)}
    else
      # Gone, or no flow runs on it any more: nothing to keep alive.
      %{"fact" => nil} -> :stop
      nil -> :stop
      # Facts did not answer: try again on the timer.
      _ -> {:wait, state.every}
    end
  end

  defp projection(state, description, legacy, fact, children, parents, pointing) do
    case Store.selected(description, state.kind, fact) do
      nil ->
        Definition.state_of(legacy, fact, children, parents, pointing)

      {name, selection} ->
        with {:ok, config} <- Store.activate(description, state.target, state.yaml),
             key = Run.key(name, state.kind, state.key, 1),
             %{"fact" => %{} = stored} <-
               Talk.read(config["kind"], %{"key" => key, "plain" => true}),
             {:ok, run} <- Store.decode(config, stored),
             true <- run["definition_sha256"] == Run.digest(state.target.flows()[name]) do
          follow = selection["follow_through"]

          cond do
            run["status"] == "completed" and follow != nil and run["state"] == follow["state"] and
                Run.holds?(follow["when"], fact["values"] || %{}) ->
              Definition.state_of(legacy, fact, children, parents, pointing)

            run["status"] == "completed" ->
              {%{"name" => run["state"], "done" => true}, %{}}

            run["status"] == "active" ->
              flow = state.target.flows()[name]
              current = flow["states"][run["state"]]
              binding = current["owner"] || flow["owner"] || %{}
              owner = binding["default"]

              deadline =
                Enum.find_value(run["deadlines"]["timers"] || [], fn timer ->
                  if timer["name"] == current["present"]["deadline"], do: timer["due"]
                end)

              {Map.merge(current["present"] || %{}, %{
                 "name" => run["state"],
                 "owner" => owner,
                 "preserve_kind" => binding["preserve_kind"],
                 "deadline" => deadline
               }), fact["values"] || %{}}

            true ->
              {nil, %{}}
          end
        else
          _ -> {nil, %{}}
        end
    end
  end

  defp description(%{description: nil}), do: Talk.read("_description", %{})
  defp description(%{description: description}), do: %{"description" => description}

  # Store what differs: what is expected, and the owner, in one change with its cause, on
  # the fact the definition writes on: its own, or the one its `on` relation points at.
  defp move(state, description, {name, flow}, fact, current, vars) do
    case written(description, flow, state.kind, fact) do
      {:ok, kind, target} ->
        write(state, description, name, flow, kind, target, current, vars)

      {:missing, relation} ->
        Logger.warning("flow #{name}: #{state.key} has no #{relation} to write on; tried again")

      :unavailable ->
        :ok
    end
  end

  defp written(description, %{"on" => relation}, _kind, fact) when is_binary(relation) do
    with [to] <- get_in(description, ["relations", relation, "to"]),
         [key] <- get_in(fact, ["links", relation]) || [],
         %{"fact" => target} when is_map(target) <-
           Talk.read(to, %{"key" => key, "plain" => true}) do
      {:ok, to, target}
    else
      %{"fact" => nil} -> {:missing, relation}
      %{"error" => _} -> :unavailable
      _ -> {:missing, relation}
    end
  end

  defp written(_description, _flow, kind, fact), do: {:ok, kind, fact}

  defp write(state, description, name, flow, kind, fact, current, vars) do
    expected = Definition.expected(current, vars)
    field = flow["field"]

    values =
      if field && blank(fact["values"][field]) != blank(expected),
        do: %{field => expected || ""},
        else: %{}

    current = preserve_owner(current, fact, flow["owner_relation"])
    owner = Definition.owner(current)
    relation = flow["owner_relation"]
    # A move is a change of state: what is expected changes from one thing to another. The
    # first look at a fact (nothing expected yet) is none, so an owner handed over before
    # it stays.
    moved? = values != %{} and blank(fact["values"][field]) != nil

    held_field = flow["handover_field"]
    owners = get_in(fact, ["links", relation]) || []
    origin = get_in(fact, ["origins", relation, "position"])
    pending = pending(fact, held_field)
    deferred? = pending["from"] == owners and pending["position"] == origin
    cancelled? = pending != %{} and not deferred?

    wanted? =
      relation != nil and owners != List.wrap(owner) and
        (current["preserve_kind"] != nil or moved? or deferred? or
           (not cancelled? and not by_hand?(fact, relation)))

    owner? =
      cond do
        current["owner_unavailable"] -> :unknown
        wanted? -> owner_exists(current)
        true -> :no
      end

    hold? =
      wanted? and current["done"] != true and held_field != nil and
        running?(description, fact["key"], owners)

    links = if owner? == :yes and not hold?, do: %{relation => List.wrap(owner)}, else: %{}

    held_value =
      if hold? or (wanted? and deferred? and owner? != :yes),
        do: JSON.encode!(%{"from" => owners, "position" => origin}),
        else: ""

    values =
      if held_field && to_string(fact["values"][held_field]) != held_value,
        do: Map.put(values, held_field, held_value),
        else: values

    # The state's name, so a page can show its owner what to do (`state_field`). Written
    # with the rest, and alone when only it differs; it never counts as a move by itself.
    values = Map.merge(values, state_value(flow["state_field"], fact, current))

    # The due time of the timer the state presents (`present.deadline`), for a selected
    # flow whose projection names a `deadline_field`; cleared in every other state.
    values =
      if field = flow["deadline_field"] do
        if same_time?(fact["values"][field], current["deadline"]),
          do: values,
          else: Map.put(values, field, current["deadline"] || "")
      else
        values
      end

    cond do
      # Facts did not say whether the owner exists: write nothing now, rather than what
      # is expected without its owner; the timer tries again.
      owner? == :unknown ->
        Logger.warning("flow #{name}: #{state.key} not moved: Facts did not answer; tried again")

      values != %{} or links != %{} ->
        # By flow: Flow passes over the hints of its own writes, on whichever fact.
        content = %{
          "op" => "change",
          "key" => fact["key"],
          "values" => values,
          "version" => nil,
          "by" => "flow",
          "cause" => cause(name, current, owner),
          "was" =>
            Map.merge(
              Map.new(Map.keys(values), &{&1, fact["values"][&1]}),
              Map.new(Map.keys(links), &{&1, fact["links"][&1] || []})
            )
        }

        content = if links == %{}, do: content, else: Map.put(content, "links", links)

        case Talk.put(kind, content) do
          {:stored, _} ->
            Logger.info("flow #{name}: #{state.key} #{current["name"]} (#{inspect(values)})")

          other ->
            Logger.warning("flow #{name}: #{state.key} not moved: #{inspect(other)}; tried again")
        end

      true ->
        :ok
    end

    if hold?, do: :held, else: :ok
  end

  defp preserve_owner(current, fact, relation) do
    AtlasFlow.Ownership.resolve(current, get_in(fact, ["links", relation]) || [], fn kind, key ->
      Talk.read(kind, %{"key" => key, "plain" => true})
    end)
  end

  defp pending(_fact, nil), do: %{}

  defp pending(fact, field) do
    case JSON.decode(fact["values"][field] || "") do
      {:ok, %{} = value} -> value
      _ -> %{}
    end
  end

  # Unknown Facts availability preserves the owner and durable deferred handover.
  defp running?(_description, _key, []), do: false

  defp running?(description, key, owners) do
    case get_in(description, ["runtime", "turn"]) do
      %{"kind" => kind} = n ->
        case Talk.read(kind, %{"linked" => %{n["on"] => key}, "plain" => true}) do
          %{"facts" => turns} ->
            Enum.any?(turns, fn turn ->
              turn["values"][n["state"]] == n["running"] and
                Enum.any?(get_in(turn, ["links", n["by"]]) || [], &(&1 in owners))
            end)

          _ ->
            true
        end

      _ ->
        false
    end
  end

  # An owner a user or an agent set stays while the state does not change: Flow moves it
  # only when the state changes (what is expected changes), or when Flow, a migration or
  # nobody set it.
  defp by_hand?(fact, relation) do
    case get_in(fact, ["origins", relation]) do
      %{"by" => by} when by not in [nil, "flow", "migration"] -> true
      _ -> false
    end
  end

  # The owner a state names must exist; until it does, only what is expected is written.
  # :yes, :no (Facts says there is no such fact), or :unknown (Facts did not answer).
  defp owner_exists(current) do
    case {Definition.owner(current), Definition.owner_kind(current)} do
      {key, kind} when is_binary(key) and is_binary(kind) ->
        case Talk.read(kind, %{"key" => key, "plain" => true}) do
          %{"fact" => %{}} ->
            :yes

          %{"fact" => nil} ->
            Logger.warning("flow: #{kind} #{key} does not exist; the owner waits for it")
            :no

          _ ->
            :unknown
        end

      _ ->
        :yes
    end
  end

  defp cause(name, current, owner) do
    why = current["why"] || current["name"]
    to = if owner, do: " → #{owner}", else: ""
    "Flow #{name}: #{why}#{to}"
  end

  defp state_value(nil, _fact, _current), do: %{}

  defp state_value(field, fact, current) do
    name = if current && !current["done"], do: current["name"], else: nil
    if blank(fact["values"][field]) == blank(name), do: %{}, else: %{field => name || ""}
  end

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  # The same instant however it is written (Facts may store it with other precision).
  defp same_time?(a, b) do
    case {blank(a), blank(b)} do
      {nil, nil} ->
        true

      {a, b} when is_binary(a) and is_binary(b) ->
        with {:ok, x, _} <- DateTime.from_iso8601(a),
             {:ok, y, _} <- DateTime.from_iso8601(b),
             do: DateTime.compare(x, y) == :eq,
             else: (_ -> a == b)

      _ ->
        false
    end
  end

  # The relations by which facts belong under one of `kind`, as the description marks them.
  defp parent_relations(description, kind) do
    for {relation, %{"parent" => true, "to" => to}} <- description["relations"] || %{},
        kind in to,
        do: relation
  end

  defp children(parents, description, key) do
    Enum.flat_map(parents, fn relation ->
      [from | _] = get_in(description, ["relations", relation, "from"]) || [nil]

      case from && Talk.read(from, %{"linked" => %{relation => key}, "plain" => true}) do
        %{"facts" => facts} -> facts
        _ -> []
      end
    end)
  end

  # The facts that point at it through the associations its flow reads (`empty`), of every
  # kind they start at. A read Facts does not answer counts as something pointing at it:
  # not knowing is never "nothing is based on it".
  defp pointed(relations, description, key) do
    for relation <- relations,
        from <- get_in(description, ["relations", relation, "from"]) || [],
        fact <-
          (case Talk.read(from, %{"linked" => %{relation => key}, "plain" => true}) do
             %{"facts" => facts} -> facts
             _ -> [%{"links" => %{relation => [key]}}]
           end),
        do: fact
  end
end
