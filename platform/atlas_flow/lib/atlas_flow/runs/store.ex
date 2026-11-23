defmodule AtlasFlow.Runs.Store do
  @moduledoc """
  One writer reconciles durable cursors through Facts before sending entry writes. A run's
  reaction to what Facts holds now is stored once: the transitions it takes one after the
  other are worked out in memory and written together, sooner only where Facts or a
  service must see the stored cursor first (see "One reaction, stored once" below).

  A run on a parent of the model's composition (`AtlasFlow.Model.composition/0`) also
  owes its subject the values of its links, counts and tallies. Each drain works them out
  again from the parent's children and their latest runs (`AtlasFlow.Composition.Links`,
  `AtlasFlow.Composition.Counts`), and from every fact that relates to it
  (`AtlasFlow.Composition.Tallies`), so a deleted or moved child and a lost hint are
  counted right. Owed writes join the run's pending writes, with stable ids, before any
  is sent; the run keeps the sources it applied, so a duplicate or replayed completion
  writes nothing again. A changed aggregate becomes a synthetic input of Flow's own
  writer role to the run, so the parent's `await` and `by: :atlas` branches take it.
  """

  require Logger
  alias AtlasFlow.{Dispatch, Results, Supervision}
  alias AtlasFlow.Runs.{HandOver, Run}
  alias AtlasFlow.Talk
  alias AtlasFlow.Activities.Gate
  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.Activities.Task
  alias AtlasFlow.Composition.{Counts, Links, Tallies}

  @structured ~w(deadlines pending last_input)
  # What a child's run moving means to its parents.
  @moved ~w(state entry status)

  @doc "Apply one reviewed plan (%{id, reason, run}) without changing ordinary replay."
  def recover_refused_tally(config, flows, plan, now) when is_map(config) and is_map(plan) do
    with true <- Enum.sort(Map.keys(plan)) == ~w(id reason run),
         true <-
           is_binary(plan["id"]) and plan["id"] != "" and
             is_binary(plan["reason"]) and plan["reason"] != "",
         %{"key" => key} = expected <- plan["run"],
         {:ok, %{} = fact} <- fetch(config, key),
         {:ok, run} <- decode(config, fact),
         flow when not is_nil(flow) <- flows[run["flow"]] do
      fingerprint = Run.digest(plan)
      audit = Enum.find(run["pending"]["migrations"] || [], &(&1["plan_id"] == plan["id"]))

      cond do
        audit && audit["plan_digest"] == fingerprint ->
          cond do
            run["definition_sha256"] != expected["definition_sha256"] or
                flow.digest() != expected["definition_sha256"] ->
              {:error, :recovery_definition_changed}

            run["entry"] == audit["to_entry"] and
                (run["pending"]["writes"] != [] or run["pending"]["synthetic"] != nil) ->
              drain(with_flows(config, flows), key, flow, now, 64)

            true ->
              {:ok, run}
          end

        audit != nil ->
          {:error, :recovery_plan_conflict}

        run != expected ->
          {:error, :recovery_snapshot_changed}

        true ->
          recover_tally(config, flows, fact, run, flow, plan, fingerprint, now)
      end
    else
      _ -> {:error, :invalid_recovery_plan}
    end
  rescue
    _ in [ArgumentError, BadMapError, KeyError, FunctionClauseError] ->
      {:error, :invalid_recovery_plan}
  end

  def recover_refused_tally(_config, _flows, _plan, _now), do: {:error, :invalid_recovery_plan}

  defp recover_tally(config, flows, fact, run, flow, plan, fingerprint, now) do
    config = with_flows(config, flows)

    with true <- get_in(config, ["selection", run["flow"], "choices"]) == [],
         [write] <- run["pending"]["writes"],
         true <- recovery_tally?(config, run, write),
         :ok <- recovery_inputs(config["inputs"], run),
         %{"fact" => %{} = subject} <-
           Talk.transition_read(run["subject_kind"], %{
             "key" => run["subject_key"],
             "plain" => true
           }),
         {:ok, receipt} <- Talk.recovery_evidence(write, config["writer"]),
         retirement = %{
           "plan_id" => plan["id"],
           "plan_digest" => fingerprint,
           "reason" => plan["reason"],
           "snapshot_digest" => Run.digest(run),
           "receipt" => receipt
         },
         {:ok, entered} <- Run.reenter_refused_tally_wait(run, flow, subject, retirement, now),
         {:ok, proposed} <- compose(config, entered, subject),
         :ok <- recovery_successor(proposed, write, config["writer"], receipt),
         # No effect can escape this versioned cursor claim. A lost acknowledgement
         # is resolved by the same reread as ordinary writes, never by assuming success.
         {:ok, committed} <- write(config, %{fact: fact, stored: run, consumed: nil}, proposed),
         true <- committed.stored == proposed do
      drain(config, run["key"], flow, now, 64)
    else
      {:error, _} = error -> error
      _ -> {:error, :recovery_ineligible_or_conflicted}
    end
  end

  defp recovery_successor(%{"pending" => %{"writes" => []}}, _old, _writer, _receipt), do: :ok

  defp recovery_successor(%{"pending" => %{"writes" => [candidate]}}, old, writer, receipt) do
    case Talk.recovery_evidence(old, writer, candidate) do
      {:ok, ^receipt} -> :ok
      _ -> {:error, :recovery_successor_ineligible}
    end
  end

  defp recovery_successor(_run, _old, _writer, _receipt),
    do: {:error, :recovery_successor_ineligible}

  defp recovery_tally?(config, run, %{"id" => id, "kind" => kind, "content" => content})
       when is_map(content) do
    tallies =
      for t <- config["composition"]["tallies"],
          t["parent_subject"] == run["subject_kind"] and run["flow"] in t["readers"],
          do: t

    other = config["composition"]["links"] ++ config["composition"]["counts"]

    with true <- is_binary(id) and id != "" and kind == run["subject_kind"],
         true <- Enum.all?(other, &(&1["parent_subject"] != kind)),
         [%{"all" => field}] <- tallies,
         true <- Map.keys(content) -- ~w(op key values by links) == [],
         true <- is_map(content["values"]),
         true <-
           content["op"] == "change" and content["key"] == run["subject_key"] and
             content["by"] == config["writer"]["by"] and (content["links"] || %{}) == %{},
         [{^field, n}] when is_integer(n) and n >= 0 <- Map.to_list(content["values"]) do
      true
    else
      _ -> false
    end
  end

  defp recovery_tally?(_config, _run, _write), do: false

  # Unlike the typed inputs read, this plain list never applies prepared choices.
  defp recovery_inputs(nil, _run), do: :ok

  defp recovery_inputs(c, run) do
    case Talk.transition_read(c["kind"], %{"plain" => true}) do
      %{"facts" => facts} when is_list(facts) ->
        readable =
          Enum.all?(
            [c["kind"], c["fields"]["run"], c["fields"]["status"]],
            &(is_binary(&1) and &1 != "")
          ) and
            Enum.all?(facts, fn f ->
              is_binary(f["values"][c["fields"]["run"]]) and
                f["values"][c["fields"]["status"]] in ~w(prepared applied consumed)
            end)

        cond do
          not readable ->
            {:error, :recovery_inputs_unavailable}

          Enum.any?(facts, fn f ->
            f["values"][c["fields"]["run"]] == run["key"] and
                f["values"][c["fields"]["status"]] in ~w(prepared applied)
          end) ->
            {:error, :recovery_pending_input}

          true ->
            :ok
        end

      _ ->
        {:error, :recovery_inputs_unavailable}
    end
  end

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
        {composition, refused} =
          composition(model.composition(), selection, flows, model.relations())

        {supervision, unsupported} = supervision(model)

        config =
          runs
          |> Map.put("selection", selection)
          |> Map.put("composition", composition)
          |> Map.put("supervision", supervision)
          |> Map.put("hand_over", hand_over(model, supervision))
          |> Map.put("parents", parents(model.relations()))
          |> Map.put("relations", model.relations())
          |> Map.put("ids", if(function_exported?(model, :ids, 0), do: model.ids(), else: %{}))
          |> Map.put(
            "read_first",
            if(function_exported?(model, :read_first, 2), do: &model.read_first/2)
          )

        {config,
         validate_selection(config, flows) || two_writers(selection) || refused || unsupported}

      _ ->
        {nil, nil}
    end
  end

  # The relations the model marks `parent`, by the kind they lead from: `%{kind =>
  # [[relation, parent kind]]}`, sorted, for a task's `parents` (`AtlasFlow.Activities.Task`).
  defp parents(relations) do
    pairs =
      for {relation, %{"parent" => true, "from" => from, "to" => [to]}} <-
            Enum.sort(relations || %{}),
          kind <- from,
          do: {kind, [relation, to]}

    Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
  end

  # Who supervises a run, as the model declares it (`supervision/0`, work acquisition
  # decision 2026-11-17 §5.6): the relation from a run to its supervisor, with the kinds
  # a supervisor is a fact of (`holders`), the pickup and hand-over input fields, and
  # each subflow's spans. nil when the model declares none; a version this runner does
  # not know refuses every run.
  defp supervision(model) do
    case function_exported?(model, :supervision, 0) && model.supervision() do
      %{"version" => 1, "relation" => relation} = s when is_binary(relation) ->
        holders = get_in(model.relations(), [relation, "to"]) || []
        {Map.put(s, "holders", holders), nil}

      %{} = s ->
        {nil, {:unsupported_supervision, s["version"]}}

      _ ->
        {nil, nil}
    end
  end

  # The To-Do a hand-over gives its holder (`AtlasFlow.Runs.HandOver`), as configured
  # (`config :atlas_flow, :hand_over`) and checked against the model's relations: nil
  # when the runs are not supervised, it is not configured, or the model has no part to
  # assign it through. A hand-over then makes no To-Do.
  defp hand_over(_model, nil), do: nil

  defp hand_over(model, supervision),
    do:
      HandOver.resolve(
        Application.get_env(:atlas_flow, :hand_over),
        model.relations(),
        supervision["holders"]
      )

  # The links and counts Flow applies: those whose child subflow is selected and some
  # selected subflow runs on the parent; the tallies whose parent a selected subflow runs
  # on. Production selects none of them unless the model selects both ends. A version
  # this runner does not know, or an active link, count or tally it cannot apply, refuses
  # every run.
  defp composition(%{"version" => version} = c, selection, flows, relations) do
    parent? = fn x ->
      Enum.any?(selection, fn {name, _} ->
        flows[name] != nil and flows[name].subject() == x["parent_subject"]
      end)
    end

    active = &(Map.has_key?(selection, &1["child"]) and parent?.(&1))
    links = Enum.filter(c["links"] || [], active)
    counts = Enum.filter(c["counts"] || [], active)

    tallies =
      for t <- c["tallies"] || [], parent?.(t), do: Tallies.resolve(t, relations)

    refused =
      cond do
        version != Links.version() ->
          {:unsupported_composition, version}

        true ->
          Enum.find_value(links, &(Links.valid?(&1) != :ok and {:unsupported_link, &1["child"]})) ||
            Enum.find_value(
              counts,
              &(Counts.valid?(&1) != :ok and {:unsupported_count, &1["child"]})
            ) ||
            Enum.find_value(
              tallies,
              &(Tallies.valid?(&1) != :ok and {:unsupported_tally, &1["relation"]})
            )
      end

    {%{"links" => links, "counts" => counts, "tallies" => tallies}, refused}
  end

  defp composition(other, _selection, _flows, _relations),
    do: {%{"links" => [], "counts" => [], "tallies" => []}, {:unsupported_composition, other}}

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

  # One writer per subject's presentation: no two selected subflows that project may admit
  # the same fact. Otherwise two writers would present one fact: refuse every run.
  defp two_writers(selection) do
    Enum.find_value(Enum.sort(selection), fn {name, s} ->
      if is_map(s["projection"]) and
           Enum.any?(selection, fn {other, o} ->
             other != name and is_map(o["projection"]) and o["subject"] == s["subject"] and
               overlap?(o["admission"], s["admission"])
           end),
         do: {:two_writers, name}
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
    with {:ok, %{runs: known, subjects: subjects}} <- plan(config, flows) do
      Enum.reduce_while(subjects, {:ok, known}, fn subject, {:ok, known} ->
        case reconcile_subjects(config, flows, now, known, [subject]) do
          {:ok, runs} -> {:cont, {:ok, merge(known, runs)}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  What a round reconciles, read whole from Facts but not reconciled yet: `{:ok, %{runs:,
  subjects:}}`. `runs`: the latest generation of every run of a selected subflow, as Facts
  holds it. `subjects` (`[{kind, key}]`, each once): the subject of each of those runs,
  then each subject a selection admits that has none yet. Reconciling each subject with
  `reconcile_subjects/5` (one after the other, in any number of steps) reconciles every
  run, as one reconcile would: a subject reconciled again (by a hint in between) is only
  drained again, and writes nothing it wrote already.
  """
  def plan(nil, _flows), do: {:ok, %{runs: [], subjects: []}}

  def plan(config, _flows) do
    with {:ok, runs} <- stored_runs(config),
         {:ok, admitted} <- admitted_subjects(config) do
      subjects = for(run <- runs, do: {run["subject_kind"], run["subject_key"]}) ++ admitted
      {:ok, %{runs: runs, subjects: Enum.uniq(subjects)}}
    end
  end

  @doc """
  `known` runs with `runs` reconciled since (as `reconcile_subjects/5` answers them, the
  latest drained first): each replaces the one of its subflow and subject, and the latest
  generation is kept.
  """
  def merge(known, runs) do
    (known ++ Enum.reverse(runs))
    |> Enum.group_by(&{&1["flow"], &1["subject_kind"], &1["subject_key"]})
    |> Enum.map(fn {_, group} ->
      # The last one reconciled of the latest generation.
      top = Enum.max_by(group, & &1["generation"])
      group |> Enum.filter(&(&1["generation"] == top["generation"])) |> List.last()
    end)
  end

  # The latest generation of every run of a selected subflow, as Facts holds it.
  defp stored_runs(config) do
    with %{"facts" => facts} <- Talk.transition_read(config["kind"], %{}),
         decoded = Enum.map(facts, &decode(config, &1)),
         true <- Enum.all?(decoded, &match?({:ok, _}, &1)) do
      runs = for {:ok, run} <- decoded, Map.has_key?(config["selection"], run["flow"]), do: run

      {:ok,
       runs
       |> Enum.group_by(&{&1["flow"], &1["subject_kind"], &1["subject_key"]})
       |> Enum.map(fn {_, group} -> Enum.max_by(group, & &1["generation"]) end)
       |> Enum.sort_by(&{&1["subject_kind"], &1["subject_key"], &1["flow"]})}
    else
      other -> {:error, {:runs_unavailable, other}}
    end
  end

  # Every subject a selection admits now, `{kind, key}`, in the selection's order.
  defp admitted_subjects(config) do
    Enum.reduce_while(Enum.sort(config["selection"]), {:ok, []}, fn {_name, selection},
                                                                    {:ok, acc} ->
      case Talk.transition_read(selection["subject"], %{}) do
        %{"facts" => subjects} ->
          admitted =
            for subject <- Enum.sort_by(subjects, & &1["key"]),
                Run.holds?(selection["admission"], subject["values"] || %{}),
                do: {selection["subject"], subject["key"]}

          {:cont, {:ok, acc ++ admitted}}

        other ->
          {:halt, {:error, {:unavailable, other}}}
      end
    end)
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
      |> Map.put_new("composition", %{"links" => [], "counts" => [], "tallies" => []})

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
  # reaches its ancestors in the same reconcile and not only after a hint Flow never
  # gets (its own writes are not hinted). Bound the parent chain as the drain's own
  # transitions are bounded. `{:ok, run, parents}`: the runs it drained, latest first.
  defp settle(config, key, flow, now, new \\ nil, remaining \\ 32)
  defp settle(_config, _key, _flow, _now, _new, 0), do: {:error, :transition_limit}

  defp settle(config, key, flow, now, new, remaining) do
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
        with {:ok, parents} <- parents(config, run, now, remaining - 1),
             do: {:ok, run, parents}
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
  # - before an activity is asked (a gate, an effect): its frozen request is
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

  defp react(config, d, %{"status" => "ended"} = run, flow, now, remaining),
    do: reused(config, d, run, flow, now, remaining)

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
      resume(config, d, run, flow, now, remaining)
    end
  end

  # A new generation keeps its source request pending until the old run acknowledges
  # it. Boot restores the latest generation, so recovery cannot depend on loading its
  # predecessor again.
  defp resume(config, d, run, flow, now, remaining) do
    case run["pending"]["restart"] do
      %{} = request ->
        stored(config, d, run, :all, flow, now, remaining, fn d, run ->
          with :ok <- acknowledge_restart(config, request) do
            updated = update_in(run, ["pending"], &Map.delete(&1, "restart"))
            step(config, d, run, updated, flow, now, remaining)
          end
        end)

      nil ->
        resume_writes(config, d, run, flow, now, remaining)
    end
  end

  defp acknowledge_restart(config, request) do
    with {:ok, %{} = fact} <- fetch(config, request["run"]),
         {:ok, old} <- decode(config, fact) do
      accepted =
        old
        |> Map.put("input_cursor", max(old["input_cursor"], request["position"]))
        |> put_in(["last_input", "input"], request["input"])

      d = %{fact: fact, stored: old, consumed: nil}
      result = if accepted == old, do: {:ok, d}, else: write(config, d, accepted)

      with {:ok, %{stored: ^accepted}} <- result do
        consume_input(config["inputs"], accepted)
      else
        other -> {:error, {:restart_acknowledgement, other}}
      end
    else
      other -> {:error, {:restart_source_unavailable, other}}
    end
  end

  defp resume_writes(config, d, run, flow, now, remaining) do
    case run["pending"]["writes"] do
      [_ | _] ->
        stored(config, d, run, :all, flow, now, remaining, fn d, run ->
          case send_writes(config, run) do
            :ok ->
              step(config, d, run, sent(run), flow, now, remaining)

            # A hand-over's To-Do number was taken meanwhile: the run is stored with the
            # next one before it is sent again.
            {:renumbered, writes} ->
              step(
                config,
                d,
                run,
                put_in(run, ["pending", "writes"], writes),
                flow,
                now,
                remaining
              )

            error ->
              error
          end
        end)

      [] ->
        consumed(config, d, run, flow, now, remaining, fn d, run ->
          look(config, d, run, flow, now, remaining)
        end)
    end
  end

  # What the run's subject, its children and its inputs say now: the next transition, or
  # the end of the reaction.
  defp look(config, d, run, flow, now, remaining) do
    # The inputs are read on a stored cursor only (Facts applies a prepared input to the
    # entry the stored run is in). A moved cursor reads none yet: a link, count or
    # synthetic input may move it on without them, and it is stored before they are read.
    cursor? = config["inputs"] == nil or durable?(d, run, ~w(state entry status deadlines))

    restart? =
      run["status"] == "completed" and
        (config["selection"][run["flow"]]["restart_by"] || []) != []

    read? = cursor? and (Run.takes_inputs?(run) or restart?)

    with {:ok, inputs} <- if(read?, do: read_inputs(config["inputs"], run), else: {:ok, []}) do
      restart =
        Enum.find(inputs, fn input ->
          run["status"] == "completed" and input["run"] == run["key"] and
            input["roles"] == ["restart"] and input["changed_fields"] == %{} and
            input["status"] in ~w(applied consumed)
        end)

      if restart do
        restart_requested(config, d, run, flow, restart, now, remaining)
      else
        look_subject(config, d, run, flow, inputs, cursor?, now, remaining)
      end
    end
  end

  # Store the new generation before consuming its request on the old one. A crash or
  # lost create acknowledgement finds the same next key, even if that run already ended.
  defp restart_requested(config, _d, run, flow, input, now, remaining) do
    with %{"fact" => %{} = subject} <-
           Talk.transition_read(run["subject_kind"], %{
             "key" => run["subject_key"],
             "plain" => true
           }),
         {:ok, new} <- Run.restart(run, flow, subject, now),
         new =
           put_in(new, ["pending", "restart"], %{
             "run" => run["key"],
             "input" => input["key"],
             "position" => input["position"]
           }),
         {:ok, existing} <- fetch(config, new["key"]),
         {:ok, restarted} <-
           if(existing,
             do: drain(config, new["key"], flow, now, remaining - 1),
             else:
               react(
                 config,
                 %{fact: nil, stored: nil, consumed: nil},
                 new,
                 flow,
                 now,
                 remaining - 1
               )
           ) do
      {:ok, restarted}
    else
      other -> {:error, {:restart_unavailable, other}}
    end
  end

  defp look_subject(config, d, run, flow, inputs, cursor?, now, remaining) do
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

      # A deleted subject ends its run (`ended`), stored before its held task is
      # cancelled: nothing moves it or is written for it any more, and the other runs go
      # on (a parent counts its children as Facts holds them, so a deleted child is no
      # longer among them).
      %{"fact" => nil} ->
        stored(config, d, Map.put(run, "status", "ended"), :all, flow, now, remaining, fn
          _d, ended ->
            with %{"key" => task} <- ended["pending"]["task"] do
              Dispatch.cancel(task, "subject_deleted")
              Results.unpin(task, now)
            end

            {:ok, ended}
        end)

      other ->
        {:error, {:subject_unavailable, other}}
    end
  end

  defp activity?(run, flow), do: run["status"] == "active" and flow.mechanism(run["state"]) != nil

  # A run whose subject was deleted stays ended. A fact made later under the same key
  # (Facts frees a deleted key after a while) is another subject: once its selection
  # admits it, it gets the next generation, a new run, and never this one.
  defp reused(config, d, run, flow, now, remaining) do
    selection = config["selection"][run["flow"]]

    case Talk.transition_read(run["subject_kind"], %{"key" => run["subject_key"]}) do
      %{"fact" => %{} = subject} = answer ->
        subject = Map.put(subject, "position", answer["position"] || subject["position"] || 0)

        if Run.holds?(selection["admission"], subject["values"] || %{}) do
          generation = run["generation"] + 1
          new = Run.new(run["flow"], flow, subject, selection["imports"], now, generation)
          step(config, d, run, new, flow, now, remaining)
        else
          finish(config, d, run, flow, now, remaining)
        end

      %{"fact" => nil} ->
        finish(config, d, run, flow, now, remaining)

      other ->
        {:error, {:subject_unavailable, other}}
    end
  end

  # One transition taken: the next one from it, or the end of the reaction when it
  # changed nothing. A new generation is another run: the one it ends is stored first.
  defp step(config, d, run, updated, flow, now, remaining) do
    updated = left_span(config, run, updated)

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
      content =
        %{
          "op" => "create",
          "key" => key,
          "values" => encode(config, run),
          "by" => config["writer"]["by"]
        }
        |> supervisor_link(config, run, nil)

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

      content = supervisor_link(content, config, run, d.fact)

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

  # The run's supervisor is a link of its fact (the model's supervision relation), not a
  # field: a write sets it only when it changes, in the same write as the cursor, with
  # the keys it read in `was`. A pickup an agent made on behalf of the supervisor says so
  # as the write's cause, which Facts keeps with the link (IS-Atlas-47).
  defp supervisor_link(content, config, run, fact) do
    case config["supervision"] do
      %{"relation" => relation} ->
        held = List.wrap(get_in(fact || %{}, ["links", relation]))
        wanted = List.wrap(run["supervised_by"])

        cond do
          held == wanted ->
            content

          fact == nil ->
            Map.put(content, "links", %{relation => wanted})

          true ->
            content
            |> Map.put("links", %{relation => wanted})
            |> Map.update!("was", &Map.put(&1, relation, held))
            |> on_behalf(run, wanted)
        end

      _ ->
        content
    end
  end

  defp on_behalf(content, %{"last_input" => %{"supervision" => "pick_up", "by" => by}}, [holder])
       when is_binary(by),
       do: Map.put(content, "cause", "Picked up by #{by} on behalf of #{holder}")

  defp on_behalf(content, _run, _wanted), do: content

  # A transition that leaves the run's supervised span clears its supervisor in the run it
  # leads to (`AtlasFlow.Runs.Run.leave_span/3`), before that run is stored: the write that
  # stores the new state also clears the supervisor link (`supervisor_link/4`), so no
  # write holds the new state with the old supervisor.
  defp left_span(config, run, updated) do
    case config["supervision"] do
      %{} = s -> Run.leave_span(run, updated, (s["spans"] || %{})[run["flow"]] || [])
      _ -> updated
    end
  end

  # Each pending write, in order, under its stable id. A hand-over's To-Do create that
  # Facts refuses because its key is taken (another fact holds it, or it is held back
  # after a delete) is renumbered: `{:renumbered, writes}`, the run's pending writes with
  # the next free number, under that number's ids, stored before they are sent again.
  defp send_writes(config, run) do
    writes = run["pending"]["writes"]

    Enum.reduce_while(writes, :ok, fn write, :ok ->
      case Talk.put(write["kind"], write["content"], write["id"], code: true) do
        {:stored, _} ->
          {:cont, :ok}

        error ->
          case taken(config, write, refusal_code(error)) do
            :ours -> {:cont, :ok}
            {:taken, number} -> {:halt, {:renumbered, renumber(config, run, write, number)}}
            :unknown -> {:halt, {:error, {:pending, error}}}
          end
      end
    end)
  end

  defp refusal_code({:refused, _reasons, code}), do: code
  defp refusal_code(_error), do: nil

  # Whether a refused write is a hand-over's To-Do whose key is taken, with the next free
  # number when it is. A key Facts holds back (`"reserved"`: its fact was deleted) is
  # taken and never this create's; otherwise by what Facts holds at the key
  # (`AtlasFlow.Runs.HandOver.met/2`). Facts answers a resend of the refused id from its
  # ledger, so a taken key is only ever left for the next number's ids.
  defp taken(config, write, code) do
    with true <- config["hand_over"] != nil and HandOver.create?(write),
         :taken <- held(write, code) do
      after_ = write["hand_over"]["number"] + 1

      case Talk.transition_read(write["kind"], %{"plain" => true}) do
        %{"facts" => facts} ->
          {:taken,
           max(after_, HandOver.next_number(config["hand_over"], Enum.map(facts, & &1["key"])))}

        _ ->
          {:taken, after_}
      end
    else
      :ours -> :ours
      _ -> :unknown
    end
  end

  defp held(_write, "reserved"), do: :taken

  defp held(write, _code) do
    case Talk.transition_read(write["kind"], %{"key" => write["content"]["key"], "plain" => true}) do
      %{"fact" => fact} -> HandOver.met(write, fact)
      _ -> :unknown
    end
  end

  defp renumber(config, run, write, number),
    do:
      HandOver.renumber(
        config["hand_over"],
        run,
        run["pending"]["writes"],
        write["hand_over"]["input"],
        number
      )

  # The run once its pending writes are acknowledged: none left, and its hand-over, once
  # its To-Do was among them, done.
  defp sent(run) do
    hand_over = run["pending"]["hand_over"]

    run
    |> put_in(["pending", "writes"], [])
    |> then(fn sent ->
      if is_map(hand_over) and HandOver.holds?(run["pending"]["writes"], hand_over["input"]),
        do: update_in(sent, ["pending"], &Map.delete(&1, "hand_over")),
        else: sent
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
  defp parents(config, child, now, remaining) do
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
               {:ok, drained, ancestors} <-
                 settle(config, run["key"], config["flows"][name], now, nil, remaining) do
            {:cont, {:ok, ancestors ++ [drained | acc]}}
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

  # What the run's subject owes its links, counts and tallies now: the writes, stored in
  # the run before they are sent (stable ids), the sources it applied, the ambiguity it
  # refuses, and the synthetic input its changed aggregate gives it. Unchanged when it owes
  # none.
  defp compose(config, run, subject) do
    kind = run["subject_kind"]
    links = for l <- config["composition"]["links"], l["parent_subject"] == kind, do: l
    counts = for c <- config["composition"]["counts"], c["parent_subject"] == kind, do: c

    # A tally is given only to the runs of the subflows that read it (`readers`).
    tallies =
      for t <- config["composition"]["tallies"] || [],
          t["parent_subject"] == kind and run["flow"] in t["readers"],
          do: t

    if links == [] and counts == [] and tallies == [] do
      {:ok, run}
    else
      with {:ok, children} <- children(config, links ++ counts, subject),
           {:ok, related} <- related(tallies, subject) do
        {:ok, composed(run, subject, links, counts ++ tallies, Map.merge(children, related))}
      end
    end
  end

  # Every fact that relates to the subject through a tally's relation, of each kind it
  # starts at: `%{{:tally, relation} => facts}`.
  defp related(tallies, subject) do
    Enum.reduce_while(tallies, {:ok, %{}}, fn t, {:ok, acc} ->
      facts =
        Enum.reduce_while(t["from"], {:ok, []}, fn kind, {:ok, facts} ->
          case Talk.transition_read(kind, %{
                 "linked" => %{t["relation"] => subject["key"]},
                 "plain" => true
               }) do
            %{"facts" => more} ->
              {:cont, {:ok, facts ++ Enum.map(more, &Map.put(&1, "kind", kind))}}

            other ->
              {:halt, {:error, {:related_unavailable, other}}}
          end
        end)

      case facts do
        {:ok, facts} -> {:cont, {:ok, Map.put(acc, {:tally, t["relation"]}, facts)}}
        error -> {:halt, error}
      end
    end)
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
        {identity, values} =
          case c do
            %{"child" => child} ->
              {facts, runs} = children[{c["child_subject"], c["relation"], child}]
              {child, Counts.values(c, facts, runs)}

            tally ->
              {["tally", tally["relation"]],
               Tallies.values(tally, children[{:tally, tally["relation"]}])}
          end

        changes = Counts.changes(values, subject)

        write =
          if changes == %{},
            do: [],
            else: [
              subject_write(
                run,
                {"count", identity, changes, subject["version"], run["key"], run["entry"]},
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

  # A pickup, hand-over or retry input is taken first, ahead of the mechanism branches: it
  # moves no state, so a run that runs a task takes it too (`AtlasFlow.Runs.Run.supervision/4`).
  # A retry then takes the run back (`retried/5`).
  defp next(config, run, flow, subject, now, inputs) do
    case Run.supervision(run, flow, inputs, supervision_check(config, run), to_do(config)) do
      :none ->
        moved(config, run, flow, subject, now, inputs)

      {:ok, %{"last_input" => %{"supervision" => "retry"}} = taken} ->
        retried(config, taken, flow, subject, now)

      taken ->
        taken
    end
  end

  # A retry (IS-Atlas-09): the run goes back to the first state of the span it is in,
  # where its task is made again, fresh. The task it held is cancelled as an answer
  # cancels one: Dispatch drops it now, and its fact says so once the run is stored.
  defp retried(config, run, flow, subject, now) do
    [first | _] =
      Enum.find_value(get_in(config, ["supervision", "spans", run["flow"]]), fn span ->
        if run["state"] in span["states"], do: span["states"]
      end)

    retried = Run.retry(run, flow, first, subject, now)

    case {run["pending"]["task"], flow.mechanism(run["state"])} do
      {%{"key" => key} = intent, {:task, spec}} ->
        Dispatch.cancel(key, "retry")
        Results.unpin(key, now)
        {:ok, update_in(retried, ["pending", "writes"], &[Task.cancelled(intent, spec) | &1])}

      _ ->
        {:ok, retried}
    end
  end

  defp moved(config, run, flow, subject, now, inputs) do
    mechanism = if run["status"] == "active", do: flow.mechanism(run["state"])
    review = config["selection"][run["flow"]]["verification"]
    verdict = run["pending"]["verdict"]
    # Reopened work starts a new generation only when the selection declares it.
    opts = [reopen: config["selection"][run["flow"]]["reopen"]]

    cond do
      match?({:effect, _}, mechanism) ->
        effect_next(config, run, flow, subject, now, elem(mechanism, 1))

      match?({:task, _}, mechanism) ->
        task_next(config, run, flow, subject, now, elem(mechanism, 1))

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

  # How a supervision input to `run` is checked (`AtlasFlow.Runs.Inputs.supervision/4`):
  # with its subflow's spans, and a holder read from Facts, as a fact of a supervisor's
  # kind. nil when the model declares no supervision.
  defp supervision_check(config, run) do
    case config["supervision"] do
      %{} = s ->
        of_run = %{"inputs" => s["inputs"], "spans" => (s["spans"] || %{})[run["flow"]] || []}
        &AtlasFlow.Runs.Inputs.supervision(&1, run, of_run, fn key -> holder?(s, key) end)

      _ ->
        nil
    end
  end

  # How a hand-over's To-Do is built (`AtlasFlow.Runs.HandOver.writes/5`): numbered after
  # the To-Dos Facts holds now. nil when no hand-over makes one.
  defp to_do(config) do
    case config["hand_over"] do
      nil ->
        nil

      spec ->
        fn run, hand_over, from ->
          case Talk.transition_read(spec["kind"], %{"plain" => true}) do
            %{"facts" => facts} ->
              number = HandOver.next_number(spec, Enum.map(facts, & &1["key"]))
              {:ok, HandOver.writes(spec, run, hand_over, from, number)}

            _ ->
              :unavailable
          end
        end
    end
  end

  defp holder?(supervision, key) do
    Enum.reduce_while(supervision["holders"], false, fn kind, false ->
      case Talk.transition_read(kind, %{"key" => key, "plain" => true}) do
        %{"fact" => %{}} -> {:halt, true}
        %{"fact" => nil} -> {:cont, false}
        _ -> {:halt, :unavailable}
      end
    end)
  end

  defp effect_next(config, run, flow, subject, now, spec) do
    intent = run["pending"]["effect"]

    links =
      for l <- config["composition"]["links"], l["parent_subject"] == run["subject_kind"], do: l

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

  # A task for the machinery the subject is assigned to (`AtlasFlow.Activities.Task`): its
  # intent is stored in the run before anything is sent (the run is stored before `next`
  # for an activity), its record writes after that, and Dispatch is told of it only once
  # the stored run holds them.
  defp task_next(config, run, flow, subject, now, spec) do
    projection = config["selection"][run["flow"]]["projection"] || %{}

    ctx = %{
      assignee: assignee(config, run, spec, flow, projection, subject),
      number: fn -> Task.number(spec, run) end,
      now: now,
      parents: config["parents"] || %{},
      ids: config["ids"] || %{},
      read_first: config["read_first"]
    }

    case Task.step(run, spec, subject, ctx) do
      :none ->
        {:ok, run}

      {:pending, intent, writes, ladder} ->
        {:ok,
         run
         |> put_in(["pending", "task"], intent)
         |> then(&if(ladder, do: put_in(&1, ["pending", "ladder"], ladder), else: &1))
         |> update_in(["pending", "writes"], &(&1 ++ writes))}

      # A ladder task's outcome is the ladder's step; its ladder is kept (F2).
      {:result, outcome, result, writes, ladder} ->
        Run.task_result(run, flow, subject, now, outcome, result, writes, ladder)
    end
  end

  # Who the task is for (IS-Atlas-25; decision 2026-11-17 §5.6): once its flow is picked
  # up, its human supervisor, whose Runtimes Dispatch offers it to, whatever the
  # subject is assigned to: pickup alone starts the work. Otherwise the machinery the
  # subject is assigned to (E1), whose task waits for a supervisor. A run with spans of
  # its own answers itself; any other asks `AtlasFlow.Supervision`, as Dispatch does.
  defp assignee(config, run, spec, flow, projection, subject) do
    supervision =
      case get_in(config, ["supervision", "spans", run["flow"]]) do
        [_ | _] = spans ->
          Supervision.answer(run, spans)

        _ ->
          runner = %{config: config, relations: config["relations"]}
          Supervision.of(runner, run["subject_kind"], run["subject_key"])
      end

    case supervision do
      {:supervised, _holder, _run} -> :supervised
      :unsupervised -> Task.assignee(spec, flow.owner(run["state"]), projection, subject)
      :unavailable -> :unavailable
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

  # The run's supervisor, from its fact's link: absent when it has none.
  defp supervisor(run, config, fact) do
    with %{"relation" => relation} <- config["supervision"],
         [holder] when is_binary(holder) <- List.wrap(get_in(fact, ["links", relation])) do
      Map.put(run, "supervised_by", holder)
    else
      _ -> run
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
      do: {:ok, run |> Map.put("key", fact["key"]) |> supervisor(config, fact)},
      else: {:error, :unknown_record_version}
  rescue
    _ -> {:error, :invalid_record}
  end
end
