defmodule AtlasFlow.Capacity do
  @moduledoc """
  The single capacity writer. Every round reconstructs reservations, waiting work
  and releases from Facts. Unknown reads abort a round, including after an uncertain
  write. Only the queue presentation is cached; it grants no execution authority.
  """
  use GenServer
  alias AtlasBus.Envelope
  alias AtlasFlow.{Model, Talk}
  alias AtlasFlow.Capacity.Policy
  alias AtlasFlow.Runs.Clock

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  def round(pid), do: GenServer.call(pid, :round, 60_000)

  @impl true
  def init(opts) do
    model = Keyword.get_lazy(opts, :model, &Model.configured!/0)
    runner = Model.load(model, Keyword.get_lazy(opts, :environment, &Model.environment/0))

    settings =
      Keyword.get_lazy(opts, :settings, fn -> Application.get_env(:atlas_flow, :capacity, %{}) end)

    :ok = AtlasBus.attach("flow/capacity")
    clock = Keyword.get(opts, :clock)
    mono = Keyword.get(opts, :monotonic, fn -> System.monotonic_time(:millisecond) end)
    send(self(), :round)

    {:ok,
     %{
       runner: runner,
       agent: model.agent(),
       settings: settings,
       clock: clock,
       mono: mono,
       registry: Keyword.get(opts, :registry, &AtlasBus.endpoints/0),
       boot: mono.(),
       absent: %{},
       waiting: [],
       queue_error: :not_ready,
       every: Keyword.get(opts, :every, 1000),
       timer: nil
     }}
  end

  @impl true
  def handle_call(:round, _from, state) do
    {result, state} = reconcile(state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:round, state) do
    {_, state} = reconcile(state)
    Clock.cancel(state.clock, state.timer)
    {:noreply, %{state | timer: Clock.schedule(state.clock, self(), :round, state.every)}}
  end

  def handle_info({:atlas_bus, %Envelope{class: "request", kind: "_capacity"} = e, _}, state) do
    answer =
      if state.queue_error,
        do: %{"error" => "capacity_unavailable"},
        else: %{"waiting" => state.waiting}

    AtlasBus.send(Envelope.reply(e, "answer"), answer)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: Clock.cancel(state.clock, state.timer)

  defp reconcile(%{runner: %{capacity: nil}} = s), do: {:ok, %{s | waiting: [], queue_error: nil}}
  defp reconcile(%{runner: %{config: nil}} = s), do: {:ok, %{s | waiting: [], queue_error: nil}}

  defp reconcile(%{runner: %{refusal: refusal}} = s) when refusal != nil,
    do: {{:error, refusal}, s}

  defp reconcile(s) do
    try do
      pool = s.settings["pool"] || %{}
      mono = s.mono.()
      endpoints = registry!(s.registry)

      live =
        for {_, slot} <- pool,
            ("runtime@" <> slot["machine"]) in endpoints,
            uniq: true,
            do: slot["machine"]

      absent =
        Map.new(pool, fn {_, slot} ->
          machine = slot["machine"]
          {machine, if(machine in live, do: mono, else: Map.get(s.absent, machine, s.boot))}
        end)

      s = %{s | absent: absent}

      now = %{
        wall: DateTime.to_unix(Clock.now(s.clock), :millisecond),
        mono: mono,
        boot: s.boot,
        absent: absent,
        grace: seconds(s, "release_grace", 300),
        timeout: seconds(s, "start_timeout", 120)
      }

      turns = list!(s.runner.turn["kind"]) |> Enum.map(&turn(&1, s.runner.turn))
      items = items!(s, turns)
      fields = s.runner.capacity
      # Entry transitions leave ownership to this process too. A historical
      # automatic owner is released only after its running turn finishes.
      for i <- items,
          i.owner != nil,
          not i.manual,
          not i.running,
          i.pick in [nil, ""],
          do: release!(i, fields)

      items = items!(s, turns)

      picks =
        for i <- items,
            i.pick not in [nil, ""],
            i.owner != nil,
            not i.manual,
            slot = pool[i.owner],
            slot != nil,
            do:
              Map.merge(i, %{machine: slot["machine"], at: time(i.fact["values"][fields["at"]])})

      for i <- Policy.release(picks, turns, live, now), do: release!(i, fields)
      items = items!(s, turns)
      slots = slots!(pool, s, turns)
      queue = Enum.filter(items, &(&1.owner == nil and not &1.running))
      chosen = Policy.pick(queue, slots, live, now)
      for {i, slot, backend, model} <- chosen, do: pick!(i, slot, backend, model, fields, now)
      chosen_keys = MapSet.new(chosen, fn {i, _, _, _} -> i.key end)

      retained =
        Enum.filter(items, fn i ->
          i.owner != nil and not i.manual and i.pick not in [nil, ""] and
            (not bound?(i, slots, fields) or (pool[i.owner] || %{})["machine"] not in live or
               Enum.any?(
                 turns,
                 &(&1.pick == i.pick and &1.state == :running and
                     &1.lease != nil and now.wall >= &1.lease)
               ) or
               (not i.running and
                  now.wall - (time(i.fact["values"][fields["at"]]) || now.wall) >= now.timeout))
        end)

      waiting =
        (Enum.reject(queue, &MapSet.member?(chosen_keys, &1.key)) ++
           retained ++
           Enum.filter(items, &(&1.owner == nil and &1.running)))
        |> Enum.sort_by(&{Policy.timestamp(&1.since), &1.key})
        |> Enum.with_index(1)
        |> Enum.map(fn {i, position} ->
          %{
            "key" => i.subject_key,
            "kind" => i.subject_kind,
            "label" => i.subject_key,
            "state" => i.state,
            "need" => i.need,
            "since" => i.since,
            "position" => position,
            "why" =>
              cond do
                i.owner != nil and not bound?(i, slots, fields) ->
                  "execution binding unavailable; reservation retained"

                i.owner != nil or i.running ->
                  "execution outcome unknown; reconciliation required"

                true ->
                  if(Policy.pick([i], Enum.map(slots, &%{&1 | busy: false}), live, now) == [],
                    do: "no live slot fits",
                    else: "every fitting slot is busy"
                  )
              end
          }
        end)

      {:ok, %{s | waiting: waiting, queue_error: nil}}
    catch
      {:capacity_unavailable, reason} ->
        {{:error, reason}, %{s | waiting: [], queue_error: reason}}
    end
  end

  defp bound?(item, slots, f) do
    Enum.any?(slots, fn slot ->
      slot.key == item.owner and slot.machine == item.fact["values"][f["machine"]] and
        item.fact["values"][f["model"]] in Map.get(
          slot.models,
          item.fact["values"][f["backend"]],
          []
        )
    end)
  end

  defp list!(kind) do
    case Talk.read(kind, %{"plain" => true, "presentation" => true}) do
      %{"facts" => facts} when is_list(facts) -> facts
      _ -> throw({:capacity_unavailable, {:read, kind}})
    end
  end

  defp registry!(read) do
    case read.() do
      endpoints when is_list(endpoints) -> endpoints
      _ -> throw({:capacity_unavailable, :registry_unavailable})
    end
  rescue
    ArgumentError -> throw({:capacity_unavailable, :registry_unavailable})
  end

  defp fact!(kind, key) do
    case Talk.read(kind, %{"key" => key, "plain" => true}) do
      %{"fact" => fact} when is_map(fact) -> fact
      _ -> throw({:capacity_unavailable, {:read, kind, key}})
    end
  end

  defp items!(s, turns) do
    c = s.runner.config
    f = c["fields"]

    for stored <- list!(c["kind"]),
        v = stored["values"],
        name = v[f["flow"]],
        selection = c["selection"][name],
        selection != nil,
        subflow = s.runner.flows[name],
        v[f["status"]] == "active",
        v[f["definition_sha256"]] == subflow.digest(),
        state = v[f["state"]],
        rule = subflow.owner(state)["capacity"],
        rule != nil,
        projection = selection["projection"],
        is_map(projection) do
      subject_key = v[f["subject_key"]]
      subject = fact!(selection["subject"], subject_key)
      {kind, key} = target!(s.runner.relations, selection["subject"], subject, projection)
      fact = fact!(kind, key)
      entry = "#{stored["key"]}:#{v[f["generation"]]}:#{v[f["entry"]]}"

      history =
        Enum.filter(turns, &(&1.item == key))
        |> Enum.sort_by(&{Policy.timestamp(&1.ended_at), &1.key}, :desc)

      related = history ++ ancestors!(s, selection["subject"], subject, turns, 8)

      earlier =
        related
        |> Enum.sort_by(&{&1.state == :running, Policy.timestamp(&1.ended_at), &1.key}, :desc)
        |> Enum.find(&(&1.step == rule["differs_from"] and &1.backend not in [nil, ""]))

      %{
        key: key,
        kind: kind,
        fact: fact,
        entry: entry,
        ready: fact["values"][s.runner.capacity["entry"]] == entry,
        subject_key: subject_key,
        subject_kind: selection["subject"],
        state: state,
        relation: projection["owner_relation"],
        owner: List.first(get_in(fact, ["links", projection["owner_relation"]]) || []),
        manual: AtlasFlow.Runs.Presentation.manual?(fact, projection["owner_relation"]),
        pick: fact["values"][s.runner.capacity["pick"]],
        need: rule,
        picked_entry: fact["values"][s.runner.capacity["picked_entry"]],
        since: v[f["entered_at"]],
        running: Enum.any?(history, &(&1.state == :running)),
        affinity: List.first(history) && hd(history).agent,
        previous: List.first(history) && hd(history).key,
        excluded_backend: earlier && earlier.backend,
        history_missing: rule["differs_from"] != nil and earlier == nil
      }
    end
    |> Enum.filter(& &1.ready)
    |> Enum.uniq_by(& &1.key)
  end

  defp ancestors!(_s, _kind, _fact, _turns, 0), do: []

  defp ancestors!(s, kind, fact, turns, depth) do
    for {relation, spec} <- s.runner.relations,
        spec["parent"] == true,
        kind in spec["from"],
        parent_kind <- spec["to"],
        key <- get_in(fact, ["links", relation]) || [],
        parent = fact!(parent_kind, key),
        {_name, selection} <- s.runner.config["selection"],
        selection["subject"] == parent_kind,
        projection = selection["projection"],
        is_map(projection),
        {_target_kind, target} = target!(s.runner.relations, parent_kind, parent, projection),
        turn <-
          Enum.filter(turns, &(&1.item == target)) ++
            ancestors!(s, parent_kind, parent, turns, depth - 1),
        do: turn
  end

  defp target!(relations, subject_kind, subject, projection) do
    if on = projection["on"] do
      case {relations[on]["to"], get_in(subject, ["links", on])} do
        {[kind], [key]} -> {kind, key}
        _ -> throw({:capacity_unavailable, {:projection, subject["key"]}})
      end
    else
      {subject_kind, subject["key"]}
    end
  end

  defp slots!(pool, s, turns) do
    reserved =
      for item <- s.runner.turn["items"] || [],
          fact <- list!(item["kind"]),
          get_in(fact, ["presentation", "actionable"]) == true,
          owner <- get_in(fact, ["links", item["owner_relation"]]) || [],
          do: owner

    for {key, slot} <- Enum.sort(pool) do
      agent = fact!(s.agent["kind"], key)
      history = Enum.filter(turns, &(&1.agent == key))
      latest = Enum.max_by(history, &{Policy.timestamp(&1.ended_at), &1.key}, fn -> nil end)

      %{
        key: key,
        machine: slot["machine"],
        models: bindings(key, slot, s),
        cannot_run: agent["values"][s.agent["cannot_run"]],
        warm: false,
        idle_since: latest && latest.ended_at,
        busy: key in reserved or Enum.any?(history, &(&1.state == :running))
      }
    end
  end

  # A declaration and an endpoint are preferences/connectivity, not execution readiness.
  # Ask the owning Runtime to validate each exact binding before reserving anything.
  defp bindings(agent, slot, s) do
    if "runtime@#{slot["machine"]}" in registry!(s.registry) do
      for {backend, models} <- Map.take(slot["models"] || %{}, slot["backends"] || []),
          model <- models,
          binding?(agent, slot["machine"], backend, model),
          reduce: %{} do
        acc -> Map.update(acc, backend, [model], &[model | &1])
      end
    else
      %{}
    end
  end

  defp binding?(agent, machine, backend, model) do
    e = %{Envelope.new("request", "_capacity_binding") | address: "runtime@" <> machine}
    binding = %{"agent" => agent, "machine" => machine, "backend" => backend, "model" => model}

    with :ok <- AtlasBus.send(e, binding) do
      receive do
        {:atlas_bus, %Envelope{id: id, class: "answer", sender: sender}, answer}
        when id == e.id and sender == e.address ->
          answer == Map.put(binding, "ready", true)
      after
        500 -> false
      end
    else
      _ -> false
    end
  end

  defp turn(fact, n) do
    v = fact["values"]

    %{
      key: fact["key"],
      item: List.first(get_in(fact, ["links", n["on"]]) || []),
      agent: List.first(get_in(fact, ["links", n["by"]]) || []),
      state:
        if(
          v[n["state"]] == n["ended"] and v[n["quiescent"]] == true,
          do: :ended,
          else: :running
        ),
      quiescent: v[n["quiescent"]] == true,
      pick: v[n["pick"]],
      backend: v[n["backend"]],
      step: v[n["step"]],
      ended_at: v[n["ended_at"]] || "",
      lease: time(v[n["lease"]]),
      fact: fact
    }
  end

  defp pick!(i, slot, backend, model, f, now) do
    # A successor on the same slot and entry must not match the previous turn.
    pick = Envelope.new_id()

    values = %{
      f["pick"] => pick,
      f["picked_entry"] => i.entry,
      f["backend"] => backend,
      f["model"] => model,
      f["machine"] => slot.machine,
      f["at"] => DateTime.from_unix!(now.wall, :millisecond) |> DateTime.to_iso8601()
    }

    was =
      Map.new(Map.keys(values), &{&1, i.fact["values"][&1]})
      |> Map.merge(%{i.relation => [], f["entry"] => i.entry})

    write!(i.kind, i.key, values, %{i.relation => [slot.key]}, was, i.fact["version"])
  end

  defp release!(i, f) do
    values = Map.new(["pick", "picked_entry", "backend", "model", "machine", "at"], &{f[&1], ""})

    was =
      Map.new(Map.keys(values), &{&1, i.fact["values"][&1]})
      |> Map.merge(%{f["entry"] => i.entry, i.relation => [i.owner]})

    write!(i.kind, i.key, values, %{i.relation => []}, was, i.fact["version"])
  end

  defp write!(kind, key, values, links, was, version) do
    case Talk.put(kind, %{
           "op" => "change",
           "key" => key,
           "values" => values,
           "links" => links,
           "was" => was,
           "version" => version,
           "by" => "flow",
           "cause" => "capacity reconciliation"
         }) do
      {:stored, _} -> :ok
      other -> throw({:capacity_unavailable, {:write, kind, key, other}})
    end
  end

  defp seconds(s, key, default), do: (s.settings[key] || default) * 1000
  defp time(nil), do: nil
  defp time(""), do: nil

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> DateTime.to_unix(date, :millisecond)
      _ -> nil
    end
  end
end
