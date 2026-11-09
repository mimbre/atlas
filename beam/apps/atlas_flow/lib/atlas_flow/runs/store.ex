defmodule AtlasFlow.Runs.Store do
  @moduledoc """
  One writer reconciles durable cursors through Facts before sending entry writes. A run's
  reaction to what Facts holds now is stored once: the transitions it takes one after the
  other are worked out in memory and written together, sooner only where Facts or a
  service must see the stored cursor first (see "One reaction, stored once" below).

  A run on a parent of the model's composition (`AtlasFlow.Model.composition/0`) also
  owes its subject the values of its links and counts. Each drain works them out again
  from the parent's children and their latest runs (`AtlasFlow.Composition.Links`,
  `AtlasFlow.Composition.Counts`), so a deleted or moved child and a lost hint are
  counted right. Owed writes join the run's pending writes, with stable ids, before any
  is sent; the run keeps the sources it applied, so a duplicate or replayed completion
  writes nothing again. A changed aggregate becomes a synthetic input of Flow's own
  writer role to the run, so the parent's `await` and `by: :atlas` branches take it.
  """

  require Logger
  alias AtlasFlow.Runs.Run
  alias AtlasFlow.Talk
  alias AtlasFlow.Activities.Gate
  alias AtlasFlow.Activities.Pass
  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.Composition.{Counts, Links}

  @structured ~w(deadlines pending last_input)
  # What a child's run moving means to its parents.
  @moved ~w(state entry status)

  @doc """
  What the runs of `model` are kept and selected by, for its compiled subflows `flows`
  (by name): `{config, refusal}`. `config` is nil when no subflow is selected; a
  refusal (a selected subflow this runner cannot run) runs none of them.
  """
  def activate(model, flows) do
    selection =
      for {name, _} <- flows, s = model.selection(name), s != nil, into: %{}, do: {name, s}

    case model.runs() do
      runs when is_map(runs) and selection != %{} ->
        {composition, refused} = composition(model.composition(), selection, flows)

        config =
          runs
          |> Map.put("selection", selection)
          |> Map.put("composition", composition)

        {config,
         validate_selection(config, flows) || two_writers(model, selection, flows) || refused}

      _ ->
        {nil, nil}
    end
  end

  # The links and counts Flow applies: those whose child subflow is selected and some
  # selected subflow runs on the parent. Production selects none of them unless the model
  # selects both ends. A version this runner does not know, or an active link or count it
  # cannot apply, refuses every run.
  defp composition(%{"version" => version} = c, selection, flows) do
    active = fn x ->
      Map.has_key?(selection, x["child"]) and
        Enum.any?(selection, fn {name, _} ->
          flows[name] != nil and flows[name].subject() == x["parent_subject"]
        end)
    end

    links = Enum.filter(c["links"] || [], active)
    counts = Enum.filter(c["counts"] || [], active)

    refused =
      cond do
        version != Links.version() ->
          {:unsupported_composition, version}

        true ->
          Enum.find_value(links, &(Links.valid?(&1) != :ok and {:unsupported_link, &1["child"]})) ||
            Enum.find_value(
              counts,
              &(Counts.valid?(&1) != :ok and {:unsupported_count, &1["child"]})
            )
      end

    {%{"links" => links, "counts" => counts}, refused}
  end

  defp composition(other, _selection, _flows),
    do: {%{"links" => [], "counts" => []}, {:unsupported_composition, other}}

  defp validate_selection(config, flows) do
    Enum.find_value(Enum.sort(config["selection"]), fn {name, selection} ->
      flow = flows[name]

      valid_imports =
        flow != nil and flow.subject() == selection["subject"] and
          Enum.all?(selection["imports"], &Run.importable?(flow, &1["state"]))

      if not valid_imports or Run.validate(flow) != :ok,
        do: {:unsupported_definition, name}
    end)
  end

  # One writer per subject's presentation: a selected subflow on a kind a legacy flow also
  # runs takes that kind's facts from it only by naming it (`legacy`) and giving its own
  # `projection`; and no two selected subflows that project may admit the same fact.
  # Otherwise two writers would present one fact: refuse every run.
  defp two_writers(model, selection, flows) do
    legacy = model.legacy()

    Enum.find_value(Enum.sort(selection), fn {name, s} ->
      kind = flows[name] && flows[name].subject()
      runs_kind = Enum.filter(legacy, &(kind in &1.kinds()))

      cond do
        runs_kind != [] and
            (not is_map(s["projection"]) or Enum.map(runs_kind, & &1.name()) != [s["legacy"]]) ->
          {:two_writers, name}

        is_map(s["projection"]) and
            Enum.any?(selection, fn {other, o} ->
              other != name and is_map(o["projection"]) and o["subject"] == s["subject"] and
                  overlap?(o["admission"], s["admission"])
            end) ->
          {:two_writers, name}

        true ->
          nil
      end
    end)
  end

  # Two field-equality admissions admit a fact in common unless a field they both name
  # has no value in common.
  defp overlap?(a, b) do
    a = Map.new(a || [])
    b = Map.new(b || [])

    Enum.all?(Map.take(a, Map.keys(b)), fn {field, allowed} ->
      Enum.any?(List.wrap(allowed), &(&1 in List.wrap(b[field])))
    end)
  end

  @doc "The selected subflow that runs `fact` of `kind`: `{name, selection}`, or nil."
  def selected(nil, _kind, _fact), do: nil

  def selected(config, kind, fact) do
    Enum.find(config["selection"], fn {_name, selection} ->
      kind == selection["subject"] and Run.holds?(selection["admission"], fact["values"] || %{})
    end)
  end

  def reconcile(nil, _flows, _now), do: {:ok, []}

  def reconcile(config, flows, now) do
    config = with_flows(config, flows)

    with {:ok, restored} <- restore(config, flows, now),
         {:ok, runs} <- scan(config, flows, now, restored) do
      {:ok,
       runs
       |> Enum.group_by(&{&1["flow"], &1["subject_key"]})
       |> Enum.map(fn {_, group} -> Enum.max_by(group, & &1["generation"]) end)}
    end
  end

  @doc """
  Reconcile only the runs of `subjects` (`[{kind, key}]`, the facts a hint is about), as
  `reconcile/3` does for each: its run as `known` holds it (the latest generation, from
  the last reconcile) is drained; a subject the selection admits that has none gets one.
  `{:ok, runs}`: the runs it reconciled.
  """
  def reconcile_subjects(nil, _flows, _now, _known, _subjects), do: {:ok, []}

  def reconcile_subjects(config, flows, now, known, subjects) do
    config = with_flows(config, flows)

    pairs =
      for {name, selection} <- Enum.sort(config["selection"]),
          {kind, key} <- subjects,
          kind == selection["subject"],
          do: {name, selection, kind, key}

    Enum.reduce_while(pairs, {:ok, []}, fn {name, selection, kind, key}, {:ok, acc} ->
      existing =
        Enum.find(known, fn run ->
          run["flow"] == name and run["subject_kind"] == kind and run["subject_key"] == key
        end)

      result =
        if existing do
          settle(config, existing["key"], flows[name], now)
        else
          admitted(config, name, flows[name], selection, kind, key, now)
        end

      case result do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, run, parents} -> {:cont, {:ok, parents ++ [run | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  # The compiled subflows this reconcile runs, which a parent's children are run by; a
  # configuration that names no composition has no links or counts.
  defp with_flows(config, flows),
    do:
      config
      |> Map.put("flows", flows)
      |> Map.put_new("composition", %{"links" => [], "counts" => []})

  # A subject with no run known: one is made when the selection admits it, as a scan does.
  defp admitted(config, name, flow, selection, kind, key, now) do
    # Read as a scan reads it (with what Facts derives), so admission is decided alike.
    case Talk.transition_read(kind, %{"key" => key}) do
      %{"fact" => %{} = subject} = answer ->
        subject = Map.put(subject, "position", answer["position"] || subject["position"] || 0)

        if Run.holds?(selection["admission"], subject["values"] || %{}),
          do: reconcile_subject(config, name, flow, selection, subject, now, []),
          else: {:ok, nil}

      %{"fact" => nil} ->
        {:ok, nil}

      other ->
        {:error, {:unavailable, other}}
    end
  end

  defp restore(config, flows, now) do
    with %{"facts" => facts} <- Talk.transition_read(config["kind"], %{}),
         decoded = Enum.map(facts, &decode(config, &1)),
         true <- Enum.all?(decoded, &match?({:ok, _}, &1)) do
      runs = for {:ok, run} <- decoded, Map.has_key?(config["selection"], run["flow"]), do: run

      runs =
        runs
        |> Enum.group_by(&{&1["flow"], &1["subject_kind"], &1["subject_key"]})
        |> Enum.map(fn {_, group} -> Enum.max_by(group, & &1["generation"]) end)

      Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
        case settle(config, run["key"], flows[run["flow"]], now) do
          {:ok, restored, parents} -> {:cont, {:ok, parents ++ [restored | acc]}}
          error -> {:halt, error}
        end
      end)
    else
      other -> {:error, {:runs_unavailable, other}}
    end
  end

  defp scan(config, flows, now, restored) do
    Enum.reduce_while(config["selection"], {:ok, restored}, fn {name, selection}, {:ok, runs} ->
      case Talk.transition_read(selection["subject"], %{}) do
        %{"facts" => subjects} = answer ->
          subjects =
            Enum.map(
              subjects,
              &Map.put(&1, "position", answer["position"] || &1["position"] || 0)
            )

          result =
            Enum.reduce_while(subjects, {:ok, runs}, fn subject, {:ok, acc} ->
              if Run.holds?(selection["admission"], subject["values"] || %{}) do
                case reconcile_subject(config, name, flows[name], selection, subject, now, acc) do
                  {:ok, run, parents} -> {:cont, {:ok, parents ++ [run | acc]}}
                  error -> {:halt, error}
                end
              else
                {:cont, {:ok, acc}}
              end
            end)

          case result do
            {:ok, _} -> {:cont, result}
            error -> {:halt, error}
          end

        other ->
          {:halt, {:error, {:unavailable, other}}}
      end
    end)
  end

  defp reconcile_subject(config, name, flow, selection, subject, now, restored) do
    existing = Enum.find(restored, &(&1["flow"] == name and &1["subject_key"] == subject["key"]))

    key =
      if existing, do: existing["key"], else: Run.key(name, flow.subject(), subject["key"], 1)

    with {:ok, fact} <- fetch(config, key) do
      # A new run is made in the same write as its first reaction is stored (`react/6`);
      # a lost create answer is recovered by reading the stable fact key.
      if fact == nil,
        do:
          settle(config, key, flow, now, Run.new(name, flow, subject, selection["imports"], now)),
        else: settle(config, key, flow, now)
    end
  end

  # Drain one run; when it is a child of an applied link or count and it moved (another
  # state, entry or status), drain the runs on its parents too, so a child's completion
  # reaches its parent in the same reconcile and not only after a hint Flow never gets
  # (its own writes are not hinted). `{:ok, run, parents}`: the runs it drained.
  defp settle(config, key, flow, now, new \\ nil) do
    # A new run moved when its reaction took it from where it was made.
    before =
      case new || fetch(config, key) do
        %{} = new -> new
        {:ok, %{} = fact} -> with {:ok, run} <- decode(config, fact), do: run
        _ -> nil
      end

    drained =
      if new,
        do: react(config, %{fact: nil, stored: nil, consumed: nil}, new, flow, now, 32),
        else: drain(config, key, flow, now, 32)

    with {:ok, run} <- drained do
      moved = fn -> Map.take(before || %{}, @moved) != Map.take(run, @moved) end

      if child?(config, run["flow"]) and moved.() do
        with {:ok, parents} <- parents(config, run, now), do: {:ok, run, parents}
      else
        {:ok, run, []}
      end
    end
  end

  # -- One reaction, stored once ------------------------------------------------------------
  #
  # A run reacts to what Facts holds now: it takes every transition that holds, one after
  # the other, in memory, and stores the result in one versioned write. It stores it
  # sooner only where something outside the run must see the stored cursor first (the
  # durable-cursor protocol, docs/design/flow-runs-state-machines.md §3):
  #
  # - before its pending writes are sent: the writes and the entry they belong to are
  #   stored first, and sent with their stable ids; their acknowledgement is noted in
  #   memory and stored with the next write of the run, so a crash in between replays them
  #   under the same ids, which Facts answers from its ledger;
  # - before an activity is asked (a gate, a pass, an effect): its frozen request is
  #   stored before it is sent;
  # - before an accepted input is consumed: Facts consumes only the input the stored run
  #   names;
  # - before its inputs are read once its cursor moved: Facts applies a prepared input
  #   only to the entry the stored run is in.
  #
  # A crash between two such writes loses only transitions computed in memory since the
  # last one, which the next reaction takes again from the stored run, as it would have
  # after a crash just before them. `d` is what Facts holds of the run: its fact (nil
  # before it is made), that fact decoded (`stored`), and the input this reaction
  # consumed.

  defp drain(_config, _key, _flow, _now, 0), do: {:error, :transition_limit}

  defp drain(config, key, flow, now, remaining) do
    with {:ok, %{} = fact} <- fetch(config, key),
         {:ok, run} <- decode(config, fact) do
      react(config, %{fact: fact, stored: run, consumed: nil}, run, flow, now, remaining)
    else
      other -> {:error, {:invalid_run, key, other}}
    end
  end

  defp react(_config, _d, _run, _flow, _now, 0), do: {:error, :transition_limit}

  defp react(config, d, run, flow, now, remaining) do
    if run["definition_sha256"] != flow.digest() do
      migrations = config["selection"][run["flow"]]["migrations"] || []

      case Run.migrate(run, flow, migrations, now) do
        {:ok, ^run} ->
          finish(config, d, run, flow, now, remaining)

        {:ok, updated} ->
          step(config, d, run, updated, flow, now, remaining)

        _ ->
          blocked = Run.block_definition(run, flow)

          if blocked == run,
            do: finish(config, d, run, flow, now, remaining),
            else: step(config, d, run, blocked, flow, now, remaining)
      end
    else
      case run["pending"]["writes"] do
        [_ | _] ->
          stored(config, d, run, :all, flow, now, remaining, fn d, run ->
            with :ok <- send_writes(run["pending"]["writes"]),
                 do:
                   step(
                     config,
                     d,
                     run,
                     put_in(run, ["pending", "writes"], []),
                     flow,
                     now,
                     remaining
                   )
          end)

        [] ->
          consumed(config, d, run, flow, now, remaining, fn d, run ->
            look(config, d, run, flow, now, remaining)
          end)
      end
    end
  end

  # What the run's subject, its children and its inputs say now: the next transition, or
  # the end of the reaction.
  defp look(config, d, run, flow, now, remaining) do
    # The inputs are read on a stored cursor only (Facts applies a prepared input to the
    # entry the stored run is in). A moved cursor reads none yet: a link, count or
    # synthetic input may move it on without them, and it is stored before they are read.
    cursor? = config["inputs"] == nil or durable?(d, run, ~w(state entry status deadlines))

    with {:ok, inputs} <- if(cursor?, do: read_inputs(config["inputs"], run), else: {:ok, []}) do
      # Recover prepared writes first, then fetch the subject's current ETag.
      case Talk.transition_read(run["subject_kind"], %{
             "key" => run["subject_key"],
             "plain" => true
           }) do
        %{"fact" => %{} = subject} = answer ->
          subject =
            Map.put(subject, "position", answer["position"] || subject["position"] || 0)

          # The parent's writes of its links and counts are stored before they are
          # sent; a changed aggregate is then the run's input.
          with {:ok, composed} <- compose(config, run, subject) do
            cond do
              composed != run ->
                step(config, d, run, composed, flow, now, remaining)

              (synthetic = Run.synthetic(run, flow, subject, now)) != :none ->
                {:ok, updated} = synthetic
                step(config, d, run, updated, flow, now, remaining)

              not cursor? ->
                stored(config, d, run, :all, flow, now, remaining, fn d, run ->
                  look(config, d, run, flow, now, remaining)
                end)

              activity?(run, flow) ->
                # A frozen request is stored before it is sent.
                stored(config, d, run, :all, flow, now, remaining, fn d, run ->
                  with {:ok, updated} <- next(config, run, flow, subject, now, inputs),
                       do: step(config, d, run, updated, flow, now, remaining)
                end)

              true ->
                with {:ok, updated} <- next(config, run, flow, subject, now, inputs),
                     do: step(config, d, run, updated, flow, now, remaining)
            end
          end

        # A deleted subject leaves its run as it is: nothing moves it or is
        # written for it, and the other runs go on (a parent counts its children
        # as Facts holds them, so a deleted child is no longer among them).
        %{"fact" => nil} ->
          finish(config, d, run, flow, now, remaining)

        other ->
          {:error, {:subject_unavailable, other}}
      end
    end
  end

  defp activity?(run, flow), do: run["status"] == "active" and flow.mechanism(run["state"]) != nil

  # One transition taken: the next one from it, or the end of the reaction when it
  # changed nothing. A new generation is another run: the one it ends is stored first.
  defp step(config, d, run, updated, flow, now, remaining) do
    cond do
      updated == run ->
        finish(config, d, run, flow, now, remaining)

      updated["key"] != run["key"] ->
        stored(config, d, run, :all, flow, now, remaining, fn _d, _run ->
          react(
            config,
            %{fact: nil, stored: nil, consumed: nil},
            updated,
            flow,
            now,
            remaining - 1
          )
        end)

      true ->
        react(config, d, updated, flow, now, remaining - 1)
    end
  end

  # The end of a reaction: the run as Facts holds it.
  defp finish(config, d, run, flow, now, remaining),
    do: stored(config, d, run, :all, flow, now, remaining, fn _d, run -> {:ok, run} end)

  # The accepted input the run names consumed, once per reaction, once the run that
  # accepted it is stored.
  defp consumed(config, d, run, flow, now, remaining, go) do
    key = run["last_input"]["input"]

    if is_binary(key) and config["inputs"] != nil and key != d.consumed do
      stored(config, d, run, ~w(last_input input_cursor), flow, now, remaining, fn d, run ->
        with :ok <- consume_input(config["inputs"], run), do: go.(%{d | consumed: key}, run)
      end)
    else
      go.(d, run)
    end
  end

  defp durable?(%{stored: nil}, _run, _fields), do: false
  defp durable?(%{stored: stored}, run, :all), do: stored == run

  defp durable?(%{stored: stored}, run, fields),
    do: Map.take(stored, fields) == Map.take(run, fields)

  # Go on with `go.(d, run)` once Facts holds `fields` of `run` (`:all`: all of it), as one
  # write when it does not yet. A write Facts did not take as sent (a conflict, a lost
  # answer that was not committed) is never assumed: the reaction starts again from what
  # Facts holds.
  defp stored(config, d, run, fields, flow, now, remaining, go) do
    if durable?(d, run, fields) do
      go.(d, run)
    else
      with {:ok, d} <- write(config, d, run) do
        if d.stored == run,
          do: go.(d, run),
          else: react(config, d, d.stored, flow, now, remaining - 1)
      end
    end
  end

  defp write(config, d, run) do
    key = run["key"]

    if d.fact == nil do
      content = %{
        "op" => "create",
        "key" => key,
        "values" => encode(config, run),
        "by" => config["writer"]["by"]
      }

      # A lost create answer is recovered by reading the stable fact key.
      Talk.put(config["kind"], content, Run.digest({key, "create"}))
    else
      values = encode(config, run)

      content = %{
        "op" => "change",
        "key" => key,
        "values" => values,
        "version" => d.fact["version"],
        "was" => Map.new(Map.keys(values), &{&1, d.fact["values"][&1]}),
        "by" => config["writer"]["by"]
      }

      # Conflict or lost acknowledgement: reread, never assume it was committed.
      Talk.put(config["kind"], content)
    end

    with {:ok, %{} = fact} <- fetch(config, key),
         {:ok, stored} <- decode(config, fact) do
      {:ok, %{d | fact: fact, stored: stored}}
    else
      other -> {:error, {:invalid_run, key, other}}
    end
  end

  # Each pending write, in order, under its stable id.
  defp send_writes(writes) do
    Enum.reduce_while(writes, :ok, fn write, :ok ->
      case Talk.put(write["kind"], write["content"], write["id"]) do
        {:stored, _} -> {:cont, :ok}
        error -> {:halt, {:error, {:pending, error}}}
      end
    end)
  end

  # -- Composition: links and counts on the run's subject, as a parent ---------------------

  defp child?(config, name),
    do:
      Enum.any?(
        config["composition"]["links"] ++ config["composition"]["counts"],
        &(&1["child"] == name)
      )

  # The runs on the parents a child run relates to now, drained. A parent the child left
  # (a delete or a move) is counted again by its own hint or the next round.
  defp parents(config, child, now) do
    entries =
      for x <- config["composition"]["links"] ++ config["composition"]["counts"],
          x["child"] == child["flow"],
          uniq: true,
          do: {x["relation"], x["parent_subject"]}

    case Talk.transition_read(child["subject_kind"], %{
           "key" => child["subject_key"],
           "plain" => true
         }) do
      %{"fact" => fact} ->
        targets =
          for {relation, kind} <- entries,
              parent <- List.wrap(get_in(fact || %{}, ["links", relation])),
              is_binary(parent),
              {name, selection} <- Enum.sort(config["selection"]),
              selection["subject"] == kind,
              uniq: true,
              do: {name, kind, parent}

        Enum.reduce_while(targets, {:ok, []}, fn {name, kind, parent}, {:ok, acc} ->
          with {:ok, %{} = run} <- latest(config, name, kind, parent),
               {:ok, drained} <- drain(config, run["key"], config["flows"][name], now, 32) do
            {:cont, {:ok, [drained | acc]}}
          else
            {:ok, nil} -> {:cont, {:ok, acc}}
            error -> {:halt, error}
          end
        end)

      other ->
        {:error, {:child_unavailable, other}}
    end
  end

  @doc """
  The latest generation of the run of subflow `name` on `{kind, key}`: `{:ok, run}`,
  `{:ok, nil}` when it has none, or `{:error, why}`. Runs are numbered from 1 without
  gaps, so the first missing key ends the search. An explicit restart's run is the one
  that counts, presents and is drained, never the completed generation before it.
  """
  def latest(config, name, kind, key), do: latest(config, name, kind, key, 1, nil)

  defp latest(_config, _name, _kind, _key, 65, found), do: {:ok, found}

  defp latest(config, name, kind, key, generation, found) do
    case fetch(config, Run.key(name, kind, key, generation)) do
      {:ok, nil} ->
        {:ok, found}

      {:ok, fact} ->
        case decode(config, fact) do
          {:ok, run} -> latest(config, name, kind, key, generation + 1, run)
          error -> error
        end

      error ->
        error
    end
  end

  # What the run's subject owes its links and counts now: the writes, stored in the run
  # before they are sent (stable ids), the sources it applied, the ambiguity it refuses,
  # and the synthetic input its changed aggregate gives it. Unchanged when it owes none.
  defp compose(config, run, subject) do
    kind = run["subject_kind"]
    links = for l <- config["composition"]["links"], l["parent_subject"] == kind, do: l
    counts = for c <- config["composition"]["counts"], c["parent_subject"] == kind, do: c

    if links == [] and counts == [] do
      {:ok, run}
    else
      with {:ok, children} <- children(config, links ++ counts, subject) do
        {:ok, composed(run, subject, links, counts, children)}
      end
    end
  end

  defp composed(run, subject, links, counts, children) do
    active = run["status"] == "active"
    record = run["pending"]["composition"] || %{"version" => 1, "links" => %{}}
    held = subject["values"] || %{}
    acc = %{writes: [], values: %{}, sources: [], record: record}

    acc =
      Enum.reduce(if(active, do: links, else: []), acc, fn l, acc ->
        {facts, runs} = children[{l["child_subject"], l["relation"], l["child"]}]
        field = l["field"]

        case Links.select(l, subject, facts, runs, acc.record["links"][field]) do
          {:write, value, source} ->
            write =
              if held[field] == value,
                do: [],
                else: [subject_write(run, {"link", field, source}, %{field => value})]

            %{
              acc
              | writes: acc.writes ++ write,
                values: Map.put(acc.values, field, value),
                sources: acc.sources ++ [Map.put(source, "field", field)],
                record:
                  acc.record
                  |> put_in(["links", field], source)
                  |> refused(field, nil)
            }

          {:refused, :ambiguous, keys} ->
            if acc.record["refused"][field] != keys,
              do:
                Logger.warning(
                  "flow #{run["flow"]}: #{kind_key(run)} has more than one current " <>
                    "#{l["child_subject"]} for #{field} (#{Enum.join(keys, ", ")}); nothing written"
                )

            %{acc | record: refused(acc.record, field, keys)}

          _ ->
            %{acc | record: refused(acc.record, field, nil)}
        end
      end)

    {acc, aggregate} =
      Enum.reduce(counts, {acc, %{}}, fn c, {acc, aggregate} ->
        {facts, runs} = children[{c["child_subject"], c["relation"], c["child"]}]
        values = Counts.values(c, facts, runs)
        changes = Counts.changes(values, subject)

        write =
          if changes == %{},
            do: [],
            else: [
              subject_write(
                run,
                {"count", c["child"], changes, subject["version"], run["key"], run["entry"]},
                changes
              )
            ]

        {%{acc | writes: acc.writes ++ write}, Map.merge(aggregate, values)}
      end)

    # A count is offered on each entry and on each change; a link once per completion.
    offered = %{"entry" => run["entry"], "values" => aggregate}

    acc =
      if active and counts != [] and acc.record["offered"] != offered,
        do: %{
          acc
          | values: Map.merge(acc.values, aggregate),
            record: Map.put(acc.record, "offered", offered)
        },
        else: acc

    pending =
      run["pending"]
      |> Map.put("composition", acc.record)
      |> Map.update!("writes", &(&1 ++ acc.writes))

    pending =
      if acc.values == %{},
        do: pending,
        else:
          Map.put(pending, "synthetic", %{
            "id" => Run.digest({run["key"], run["entry"], acc.values, acc.sources}),
            "values" => acc.values,
            "sources" => acc.sources
          })

    # A run that owes and applied nothing yet keeps no record.
    untouched =
      acc.writes == [] and acc.values == %{} and acc.record == record and
        run["pending"]["composition"] == nil

    if pending == run["pending"] or untouched, do: run, else: Map.put(run, "pending", pending)
  end

  defp refused(record, field, nil) do
    case record["refused"] do
      %{^field => _} = r ->
        r = Map.delete(r, field)
        if r == %{}, do: Map.delete(record, "refused"), else: Map.put(record, "refused", r)

      _ ->
        record
    end
  end

  defp refused(record, field, keys),
    do: Map.update(record, "refused", %{field => keys}, &Map.put(&1, field, keys))

  defp kind_key(run), do: "#{run["subject_kind"]} #{run["subject_key"]}"

  defp subject_write(run, identity, values),
    do: %{
      "id" => Run.digest({run["subject_kind"], run["subject_key"], identity}),
      "kind" => run["subject_kind"],
      "content" => %{
        "op" => "change",
        "key" => run["subject_key"],
        "values" => values,
        "by" => "flow"
      }
    }

  # Each link's or count's children of the subject as they relate to it now, with the
  # latest run of the child subflow on each: `%{{kind, relation, child} => {facts, runs}}`.
  defp children(config, entries, subject) do
    Enum.reduce_while(
      Enum.uniq_by(entries, &{&1["child_subject"], &1["relation"], &1["child"]}),
      {:ok, %{}},
      fn x, {:ok, acc} ->
        kind = x["child_subject"]

        with %{"facts" => facts} <-
               Talk.transition_read(kind, %{
                 "linked" => %{x["relation"] => subject["key"]},
                 "plain" => true
               }),
             {:ok, runs} <- child_runs(config, x["child"], kind, facts) do
          {:cont, {:ok, Map.put(acc, {kind, x["relation"], x["child"]}, {facts, runs})}}
        else
          {:error, _} = error -> {:halt, error}
          other -> {:halt, {:error, {:children_unavailable, other}}}
        end
      end
    )
  end

  defp child_runs(config, name, kind, facts) do
    Enum.reduce_while(facts, {:ok, %{}}, fn fact, {:ok, acc} ->
      case latest(config, name, kind, fact["key"]) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, run} -> {:cont, {:ok, Map.put(acc, fact["key"], run)}}
        error -> {:halt, error}
      end
    end)
  end

  defp next(config, run, flow, subject, now, inputs) do
    mechanism = if run["status"] == "active", do: flow.mechanism(run["state"])
    review = config["selection"][run["flow"]]["verification"]
    verdict = run["pending"]["verdict"]
    # Reopened work starts a new generation only when the selection declares it.
    opts = [reopen: config["selection"][run["flow"]]["reopen"]]

    cond do
      match?({:pass, _}, mechanism) ->
        pass_next(run, flow, subject, now, elem(mechanism, 1))

      match?({:effect, _}, mechanism) ->
        effect_next(config, run, flow, subject, now, elem(mechanism, 1))

      match?({:gate, _}, mechanism) ->
        gate_next(run, flow, subject, now, elem(mechanism, 1))

      Enum.any?(inputs, &(AtlasFlow.Runs.Inputs.choice(&1, run, subject, flow) != nil)) ->
        Run.step(run, flow, subject, now, inputs, opts)

      run["status"] == "active" and verdict != nil and
        is_map(verdict["fingerprint_definition"]) and
          AtlasBus.SubjectFingerprint.of(subject, verdict["fingerprint_definition"]) !=
            verdict["fingerprint"] ->
        Run.refresh_gate(run, flow, subject, now)

      review != nil and subject["values"][review["field"]] == true and
          run["pending"]["verdict"] != nil ->
        verdict = run["pending"]["verdict"]

        case Talk.transition_read(review["kind"], %{"key" => verdict["recorded"], "plain" => true}) do
          %{"fact" => %{} = fact} ->
            if Enum.any?(review["relations"], &(List.wrap(fact["links"][&1]) != [])) do
              write = %{
                "id" => Run.digest({run["key"], verdict["recorded"], "verified"}),
                "kind" => run["subject_kind"],
                "content" => %{
                  "op" => "change",
                  "key" => run["subject_key"],
                  "by" => "flow",
                  "values" => %{review["field"] => false}
                }
              }

              {:ok, put_in(run, ["pending", "writes"], [write])}
            else
              Run.step(run, flow, subject, now, inputs, opts)
            end

          other ->
            {:error, {:review_unavailable, other}}
        end

      true ->
        Run.step(run, flow, subject, now, inputs, opts)
    end
  end

  defp pass_next(run, flow, subject, now, spec) do
    with {:ok, assignment, owner} <- pass_owner(flow.owner(), subject) do
      intent = run["pending"]["pass"]

      cond do
        intent == nil ->
          case Pass.freeze(run, spec, subject, assignment, owner) do
            {:ok, frozen} -> {:ok, put_in(run, ["pending", "pass"], frozen)}
            {:error, :invalid_pass_binding} -> {:ok, run}
          end

        not Pass.current?(intent, subject, assignment, owner) ->
          {:ok,
           Map.merge(run, %{
             "status" => "blocked",
             "blocked_reason" => "pass binding changed; reconciliation required"
           })}

        true ->
          case Pass.poll(intent, now) do
            {:waiting, updated} ->
              {:ok, put_in(run, ["pending", "pass"], updated)}

            {:ok, %{"status" => "completed"} = reply} ->
              Run.pass_result(run, flow, subject, now, reply)

            {:ok, reply} ->
              {:ok, put_in(run, ["pending", "pass", "execution"], reply["execution"])}

            {:error, :pass_requires_reconciliation} ->
              {:ok,
               Map.merge(run, %{
                 "status" => "blocked",
                 "blocked_reason" => "Runtime pass requires reconciliation"
               })}

            {:error, _} ->
              {:ok, run}
          end
      end
    else
      # Missing owners or routing data wait, never fall back to another machine.
      _ -> {:ok, run}
    end
  end

  defp pass_owner(binding, subject) do
    with %{"description" => d} <- Talk.transition_read("_description", %{}),
         {:ok, assignment} <- pass_assignment(binding, subject, d),
         [key] <- assignment["links"][binding["relation"]],
         [kind] <- d["relations"][binding["relation"]]["to"],
         %{"fact" => %{} = owner} <- Talk.transition_read(kind, %{"key" => key, "plain" => true}) do
      # Version/position changes alone do not change an assignment binding.
      {:ok, Map.take(assignment, ~w(key values links)), owner}
    else
      _ -> {:error, :owner_unavailable}
    end
  end

  defp pass_assignment(%{"via" => via}, subject, d) when is_binary(via) do
    with [key] <- subject["links"][via],
         [kind] <- d["relations"][via]["to"],
         %{"fact" => %{} = assignment} <-
           Talk.transition_read(kind, %{"key" => key, "plain" => true}),
         do: {:ok, assignment}
  end

  defp pass_assignment(_, subject, _), do: {:ok, subject}

  defp effect_next(config, run, flow, subject, now, spec) do
    intent = run["pending"]["effect"]
    links = for l <- config["composition"]["links"], l["parent_subject"] == run["subject_kind"], do: l

    due =
      Enum.find(
        run["deadlines"]["timers"],
        &(DateTime.compare(now, Run.parse!(&1["due"])) != :lt)
      )

    cond do
      intent == nil ->
        # Nothing asked yet: a plain branch that holds moves it as in a state without a
        # mechanism. Otherwise the request is stored before the first attempt; a missing
        # target or approval waits, on those branches.
        with :stay <- Run.unfrozen(run, flow, subject, now) do
          case Effect.freeze(run, spec, subject, Effect.receivers(), links) do
            {:ok, frozen} -> {:ok, put_in(run, ["pending", "effect"], frozen)}
            {:error, _} -> {:ok, run}
          end
        end

      not Effect.current?(intent, subject) ->
        block(run, "effect binding changed; reconciliation required")

      true ->
        case Effect.poll(intent, now) do
          {:ok, reply} ->
            Run.effect_result(run, flow, subject, now, reply)

          {:retry, updated} ->
            {:ok, put_in(run, ["pending", "effect"], updated)}

          {:error, :effect_requires_reconciliation} ->
            block(run, "effect outcome unknown or conflicting; reconciliation required")

          # A timeout is not proof that the service did nothing: keep the frozen request.
          _ when due != nil ->
            block(
              run,
              "effect timer #{due["name"]} passed without an answer; reconciliation required"
            )

          {:waiting, updated} ->
            {:ok, put_in(run, ["pending", "effect"], updated)}

          {:error, _} ->
            {:ok, run}
        end
    end
  end

  defp block(run, reason),
    do: {:ok, Map.merge(run, %{"status" => "blocked", "blocked_reason" => reason})}

  defp gate_next(run, flow, subject, now, spec) do
    intent = run["pending"]["gate"]

    cond do
      intent == nil ->
        {:ok, put_in(run, ["pending", "gate"], Gate.intent(run, spec))}

      intent["request"] == nil ->
        with {:ok, reply} <- Talk.gate("prepare", intent),
             {:ok, frozen} <- Gate.freeze(intent, reply),
             do: {:ok, put_in(run, ["pending", "gate"], frozen)}

      AtlasBus.SubjectFingerprint.of(subject, intent["request"]["fingerprint_definition"]) !=
          intent["request"]["fingerprint"] ->
        Run.restart_gate(run, flow, subject, now)

      true ->
        with {:ok, reply} <- Talk.gate("decide", intent),
             do: Run.gate_result(run, flow, subject, now, reply)
    end
  end

  defp fetch(config, key) do
    case Talk.transition_read(config["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => fact} -> {:ok, fact}
      other -> {:error, other}
    end
  end

  defp read_inputs(nil, _run), do: {:ok, []}

  defp read_inputs(config, run) do
    case Talk.read(config["kind"], %{"run" => run["key"]}) do
      %{"inputs" => inputs} -> {:ok, inputs}
      other -> {:error, {:inputs_unavailable, other}}
    end
  end

  defp consume_input(nil, _run), do: :ok

  defp consume_input(config, run) do
    case run["last_input"]["input"] do
      nil ->
        :ok

      key ->
        case Talk.put(
               config["kind"],
               %{"op" => "consume", "key" => key, "run" => run["key"]},
               AtlasBus.Digest.of_term([key, "consume"])
             ) do
          {:stored, _} -> :ok
          other -> {:error, {:consume, other}}
        end
    end
  end

  def encode(config, run) do
    Map.new(config["fields"], fn {logical, field} ->
      value = run[logical]
      {field, if(logical in @structured, do: JSON.encode!(value), else: value)}
    end)
  end

  def decode(config, fact) do
    run =
      Map.new(config["fields"], fn {logical, field} ->
        value = fact["values"][field]
        {logical, if(logical in @structured, do: JSON.decode!(value), else: value)}
      end)

    if Enum.all?(@structured, &(run[&1]["version"] == 1)),
      do: {:ok, Map.put(run, "key", fact["key"])},
      else: {:error, :unknown_record_version}
  rescue
    _ -> {:error, :invalid_record}
  end
end
