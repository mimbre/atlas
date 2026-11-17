defmodule AtlasFlow.Runs.Run do
  @moduledoc """
  The bounded transition machine. No IO; the cursor is always explicit. `flow` is a
  compiled subflow (`AtlasFlow.Subflow`): the run asks it where a run starts, what
  entering a state writes, and where a change, an input or a result leads.
  """

  alias AtlasFlow.Runs.Inputs
  alias AtlasFlow.Activities.Gate
  alias AtlasFlow.Activities.Effect
  alias AtlasFlow.Activities.Task

  # A subflow's identity is its compiled digest (`flow.digest()`); stable internal
  # request identities keep their term encoding so pending writes keep their keys.
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def key(flow, kind, key, generation), do: digest({flow, kind, key, generation})

  @doc "Pure one-time retirement/reentry. Receipt and composition checks belong to Store."
  def reenter_refused_tally_wait(run, flow, subject, retirement, now) do
    safe =
      run["status"] == "active" and run["definition_sha256"] == flow.digest() and
        run["subject_kind"] == flow.subject() and run["subject_key"] == subject["key"] and
        is_integer(run["entry"]) and run["entry"] > 0 and is_integer(run["generation"]) and
        run["generation"] > 0 and
        run["key"] == key(run["flow"], run["subject_kind"], run["subject_key"], run["generation"]) and
        run["state"] in flow.states() and not flow.final?(run["state"]) and
        flow.mechanism(run["state"]) == nil and
        flow.enter(run["state"], subject["values"] || %{}) == [] and
        run["deadlines"] == %{"version" => 1, "timers" => []} and
        Enum.all?(~w(gate pass effect task definition_block), &(run["pending"][&1] == nil)) and
        match?([%{}], run["pending"]["writes"])

    if safe do
      audit =
        Map.merge(retirement, %{
          "type" => "retire_refused_tally_wait",
          "at" => DateTime.to_iso8601(now),
          "from_entry" => run["entry"],
          "to_entry" => run["entry"] + 1,
          "from_entered_at" => run["entered_at"],
          "state" => run["state"],
          "run_key" => run["key"],
          "generation" => run["generation"],
          "definition_sha256" => run["definition_sha256"],
          "retired" => Map.take(run["pending"], ~w(writes synthetic composition))
        })

      {:ok,
       run
       |> update_in(
         ["pending"],
         &Map.update(&1, "migrations", [audit], fn old -> old ++ [audit] end)
       )
       |> enter(flow, run["state"], now, true, subject)}
    else
      {:error, :unsafe_tally_wait}
    end
  end

  def migrate(run, flow, migrations, now) do
    if run["definition_sha256"] == flow.digest() do
      {:ok, run}
    else
      migrate_changed(run, flow, migrations, now)
    end
  end

  defp migrate_changed(run, flow, migrations, now) do
    mapping =
      Enum.find(
        migrations,
        &(&1["from"] == run["definition_sha256"] and &1["to"] == flow.digest())
      )

    state = mapping && mapping["states"][run["state"]]
    preserve? = mapping != nil and (mapping["rekey"] == true or mapping["preserve_entry"] == true)
    {run, retired} = if preserve?, do: retire_passes(run), else: {run, %{}}

    safe =
      state != nil and state in flow.states() and run["pending"]["writes"] == [] and
        run["pending"]["gate"] == nil and run["pending"]["pass"] == nil and
        run["pending"]["effect"] == nil and run["pending"]["task"] == nil and
        run["deadlines"]["timers"] == []

    original = run

    run =
      if run["pending"]["definition_block"] do
        run
        |> Map.put("status", run["pending"]["definition_block"]["status"])
        |> Map.put("blocked_reason", "")
        |> update_in(["pending"], &Map.delete(&1, "definition_block"))
      else
        run
      end

    migration = %{
      "from" => original["definition_sha256"],
      "to" => flow.digest(),
      "state" => original["state"],
      "entry" => original["entry"],
      "at" => DateTime.to_iso8601(now),
      "reason" => (mapping && mapping["reason"]) || "explicit state migration"
    }

    migration = if retired == %{}, do: migration, else: Map.put(migration, "retired", retired)

    migrated =
      run
      |> Map.put("definition_sha256", flow.digest())
      |> update_in(["pending"], fn pending ->
        Map.update(pending, "migrations", [migration], &(&1 ++ [migration]))
      end)

    cond do
      preserve? ->
        # An explicitly reviewed encoding change carries the exact same definition.
        # Keep entry, deadlines, frozen requests and outbox IDs intact, even mid-entry.
        if state != nil and state == run["state"] and state in flow.states(),
          do: {:ok, migrated},
          else: {:error, :definition_changed}

      not safe ->
        {:error, :definition_changed}

      run["status"] == "completed" and flow.final?(state) ->
        # Historical imports are evidence, not executable entries.
        if run["last_input"]["import"],
          do: {:ok, run},
          else: {:ok, Map.put(migrated, "state", state)}

      run["status"] == "active" ->
        {:ok, enter(migrated, flow, state, now, true)}

      true ->
        {:error, :definition_changed}
    end
  end

  # Flow has no pass (F0). What a run of a subflow that had one still holds of it (its
  # frozen request, with any result, `pass`; the passes it left or that answered, `passes`;
  # a pass's last result, `pass_result`) is retired from the run into its migration's
  # audit (`retired`), so nothing asks for it, waits on it or takes its late reply again.
  # Only an entry-preserving migration carries pending state across; any other one still
  # refuses a run with a frozen activity (`safe` above).
  @pass_state ~w(pass passes pass_result)

  defp retire_passes(%{"pending" => %{} = pending} = run) do
    case Map.take(pending, @pass_state) do
      empty when empty == %{} -> {run, %{}}
      retired -> {Map.put(run, "pending", Map.drop(pending, @pass_state)), retired}
    end
  end

  defp retire_passes(run), do: {run, %{}}

  def block_definition(run, flow) do
    run
    |> Map.put("status", "blocked")
    |> Map.put(
      "blocked_reason",
      "definition_changed: #{run["definition_sha256"]} -> #{flow.digest()}; no safe state migration"
    )
    |> update_in(["pending"], fn pending ->
      Map.put_new(pending, "definition_block", %{"status" => run["status"]})
    end)
  end

  @doc """
  Whether a runner can run the subflow here: one run per subject, and every mechanism
  one it knows, with a spec it accepts (an effect's service must be enabled). The rest
  (conditions, timers, states) the model's compile checked.
  """
  def validate(flow) do
    supported =
      flow.per_subject() == "one" and
        Enum.all?(flow.states(), &valid_activity?(flow.mechanism(&1)))

    if supported, do: :ok, else: {:error, :unsupported_definition}
  end

  defp valid_activity?({:gate, %{"gate" => g, "version" => v}}),
    do: is_binary(g) and is_integer(v)

  defp valid_activity?({:effect, spec}), do: Effect.valid?(spec)
  defp valid_activity?({:task, spec}), do: Task.valid?(spec)
  defp valid_activity?(nil), do: true
  defp valid_activity?(_), do: false

  @doc """
  Enter the branch for a fenced effect reply. The record and subject writes join the
  entry's pending writes with stable ids, so a partial replay completes them exactly once.
  """
  def effect_result(run, flow, subject, now, reply) do
    {:effect, spec} = flow.mechanism(run["state"])
    intent = run["pending"]["effect"]

    with {:ok, result} <- Effect.validate_reply(intent, reply),
         true <- result["status"] in ["done", "refused"],
         {:to, to} <- flow.next(run["state"], %{spec["field"] => result["status"]}, :result) do
      writes = Effect.writes(intent, spec, run, result)
      record = %{"request" => intent["request"], "result" => result}

      {:ok,
       enter(run, flow, to, now, true, subject)
       |> update_in(["pending", "writes"], &(writes ++ &1))
       |> update_in(["pending"], &Map.update(&1, "effects", [record], fn l -> l ++ [record] end))
       |> Map.put("last_input", %{
         "version" => 1,
         "effect" => result["id"],
         "status" => result["status"],
         "reference" => result["reference"]
       })}
    else
      _ -> {:error, :invalid_effect_result}
    end
  end

  @doc """
  Enter the branch for a task's `outcome` (`AtlasFlow.Activities.Task.step/4`): its
  `result` joins the run's tasks (`pending.tasks`, kept across entries), and its record
  `writes` join the entry's pending writes with their stable ids. Leaving the state drops
  the task (`pending.task`), so a late result of its work is never taken.
  """
  def task_result(run, flow, subject, now, outcome, result, writes) do
    {:task, spec} = flow.mechanism(run["state"])

    with true <- outcome in Task.results(),
         {:to, to} <- flow.next(run["state"], %{spec["field"] => outcome}, :result) do
      {:ok,
       enter(run, flow, to, now, true, subject)
       |> update_in(["pending", "writes"], &(writes ++ &1))
       |> update_in(["pending"], &Map.update(&1, "tasks", [result], fn l -> l ++ [result] end))
       |> Map.put("last_input", %{"version" => 1, "task" => result["key"], "outcome" => outcome})}
    else
      _ -> {:error, :invalid_task_result}
    end
  end

  @doc """
  An effect's state before its request is frozen: entered where the first of its plain
  branches (those of no role) that holds on `subject` leads, `{:ok, run}`, as a state
  without a mechanism is; `:stay` when none holds, its entry writes are not acknowledged
  yet, or a request is frozen (then only the service's answer moves it).
  """
  def unfrozen(run, flow, subject, now) do
    with "active" <- run["status"],
         [] <- run["pending"]["writes"],
         nil <- run["pending"]["effect"],
         {:effect, _} <- flow.mechanism(run["state"]),
         {:to, to} <- flow.next(run["state"], subject["values"] || %{}, nil) do
      {:ok,
       enter(run, flow, to, now, true, subject)
       |> input(subject, %{"branch" => to, "subject_version" => subject["version"]})}
    else
      _ -> :stay
    end
  end

  def gate_result(run, flow, subject, now, answer) do
    with {:ok, result} <- Gate.result(run["pending"]["gate"], answer),
         true <-
           AtlasBus.SubjectFingerprint.of(subject, result["fingerprint_definition"]) ==
             result["fingerprint"],
         {:to, to} <- flow.next(run["state"], %{"gate_result" => result["outcome"]}, :result) do
      updated = enter(run, flow, to, now, true, subject)

      output = %{
        "id" => digest({run["key"], run["entry"], "gate-result"}),
        "kind" => run["subject_kind"],
        "content" => %{
          "op" => "change",
          "key" => run["subject_key"],
          "by" => "flow",
          "values" => %{"gate_result" => result["outcome"]}
        }
      }

      {:ok,
       updated
       |> put_in(["pending", "verdict"], result)
       |> update_in(["pending", "writes"], &[output | &1])}
    else
      _ -> {:error, :invalid_gate_result}
    end
  end

  def refresh_gate(run, flow, subject, now) do
    result = run["pending"]["verdict"]

    gate = result["gate"]
    state = Enum.find(flow.states(), &match?({:gate, %{"gate" => ^gate}}, flow.mechanism(&1)))

    case state do
      name when is_binary(name) ->
        {:ok,
         enter(Map.put(run, "last_input", %{"version" => 1}), flow, name, now, true, subject)}

      _ ->
        {:error, :missing_gate_activity}
    end
  end

  def restart_gate(run, flow, subject, now),
    do:
      {:ok,
       enter(
         Map.put(run, "last_input", %{"version" => 1}),
         flow,
         run["state"],
         now,
         true,
         subject
       )}

  def duration(period) when is_binary(period) do
    case Regex.run(~r/\A([1-9][0-9]*)(ms|s|m|h|d)\z/, period) do
      [_, n, unit] ->
        String.to_integer(n) *
          %{"ms" => 1, "s" => 1000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}[unit]

      _ ->
        :error
    end
  end

  def duration(_), do: :error

  @doc """
  Whether `values` hold `condition` (`%{field => allowed}`): each field has one of its
  allowed values. A `nil` among them allows no value: the field absent, nil or empty.
  """
  def holds?(condition, values),
    do:
      Enum.all?(condition, fn {field, allowed} ->
        case values[field] do
          blank when blank in [nil, ""] -> nil in List.wrap(allowed)
          value -> value in List.wrap(allowed)
        end
      end)

  @doc """
  A new run of `name` on `subject`, of `generation`. The first of `imports` that holds
  gives its entry: a final state is completed history, any other a wait it joins. A row
  holds on the subject's values (`when`) and, when it names `completed`, on whether the
  subject is completed (its `completion`, which a full read of Facts derives).
  """
  def new(name, flow, subject, imports, now, generation \\ 1) do
    kind = flow.subject()

    run = %{
      "flow" => name,
      "subject_kind" => kind,
      "subject_key" => subject["key"],
      "generation" => generation,
      "definition_sha256" => flow.digest(),
      "entry" => 0,
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    run = Map.put(run, "key", key(name, kind, subject["key"], generation))
    import = Enum.find(imports, &imports?(&1, subject))

    cond do
      import && flow.final?(import["state"]) ->
        run
        |> enter(flow, import["state"], now, false)
        |> Map.put("status", "completed")
        |> Map.put("last_input", %{"version" => 1, "import" => true})

      # An open subject joins its wait: the state's timers run from the import, but
      # nothing is written or rerun (`importable?/2` admits only states with neither).
      import ->
        run
        |> enter(flow, import["state"], now, :timers, subject)
        |> Map.put("last_input", %{"version" => 1, "import" => true})

      true ->
        if starts?(flow, subject),
          do: enter(run, flow, flow.initial(), now, true, subject),
          else: idle(run, now)
    end
  end

  defp imports?(row, subject),
    do:
      holds?(row["when"] || %{}, subject["values"] || %{}) and
        (not Map.has_key?(row, "completed") or
           subject["completion"] not in [nil, false] == row["completed"])

  @doc """
  An explicit restart: the next generation of a completed run, started as a new run of
  its subflow on `subject`, without imports. Reopened work gets one only so, unless
  its selection declares `reopen: "new_generation"` (`step/6`). `{:error, :not_completed}`
  for a run that is not completed.
  """
  def restart(%{"status" => "completed"} = run, flow, subject, now) do
    next = new(run["flow"], flow, subject, [], now, run["generation"] + 1)
    # An explicit request supplies the start edge even when the predicate is false.
    {:ok,
     if(next["status"] == "idle",
       do: enter(next, flow, flow.initial(), now, true, subject),
       else: next
     )}
  end

  def restart(_run, _flow, _subject, _now), do: {:error, :not_completed}

  @doc """
  Whether an import row may lead to `state` of `flow`: a final state (completed history),
  or a state a run can wait in without anything being done for it on entry: no entry
  writes (no set, no create) and no mechanism.
  """
  def importable?(flow, state),
    do:
      state in flow.states() and
        (flow.final?(state) or (flow.mechanism(state) == nil and flow.enter(state, %{}) == []))

  def starts?(flow, subject),
    do: flow.start?(:create, subject) or flow.start?(:predicate, subject["values"] || %{})

  defp idle(run, now),
    do:
      Map.merge(run, %{
        "state" => "",
        "status" => "idle",
        "entered_at" => DateTime.to_iso8601(now),
        "pending" => %{"version" => 1, "writes" => []},
        "deadlines" => %{"version" => 1, "timers" => []},
        "last_input" => %{"version" => 1, "start_edge" => false}
      })

  @doc """
  Whether `run` takes inputs: only an active one does (`step/6` moves no other on one, and
  Facts applies a prepared input to an active run only).
  """
  def takes_inputs?(run), do: run["status"] == "active"

  @doc """
  The run after what `subject` and `inputs` say now: `{:ok, run}`. An idle run starts on
  its predicate. A completed one stays completed: reopened work (its start predicate false,
  then true again) starts a new generation only when the selection says so, `reopen:
  "new_generation"` in `opts`; by default only an explicit restart (`restart/4`) does.
  """
  def step(run, flow, subject, now, inputs \\ [], opts \\ []) do
    cond do
      run["definition_sha256"] != flow.digest() ->
        {:error, :definition_changed}

      run["status"] == "idle" and starts?(flow, subject) ->
        {:ok, enter(run, flow, flow.initial(), now, true, subject)}

      run["status"] == "completed" and opts[:reopen] == "new_generation" and
          not flow.start?(:create, subject) ->
        edge = starts?(flow, subject)
        previous = Map.get(run["last_input"], "start_edge", true)

        if edge and not previous do
          restart(run, flow, subject, now)
        else
          {:ok, put_in(run, ["last_input", "start_edge"], edge)}
        end

      run["status"] != "active" ->
        {:ok, run}

      # A pickup or hand-over is taken before the early return below: it moves no state,
      # so it is taken in a state that runs a task, or waits on its writes, too.
      (supervised = supervision(run, flow, inputs, opts[:supervision])) != :none ->
        supervised

      run["pending"]["writes"] != [] or flow.mechanism(run["state"]) != nil ->
        {:ok, run}

      true ->
        state = run["state"]

        timer =
          run["deadlines"]["timers"]
          |> Enum.filter(&(DateTime.compare(now, parse!(&1["due"])) != :lt))
          |> Enum.min_by(&DateTime.to_unix(parse!(&1["due"]), :microsecond), fn -> nil end)

        # The first input in order that a role's branch takes, before the timer is due.
        choice =
          Enum.find_value(Enum.sort_by(inputs, & &1["position"]), fn input ->
            if timer == nil or
                 DateTime.compare(parse!(input["prepared_at"]), parse!(timer["due"])) != :gt do
              with to when is_binary(to) <- Inputs.choice(input, run, subject, flow),
                   do: {to, input}
            end
          end)

        branch =
          case flow.next(state, subject["values"] || %{}, nil) do
            {:to, to} -> to
            :stay -> nil
          end

        unconsumed =
          Enum.find(Enum.sort_by(inputs, & &1["position"]), fn i ->
            i["status"] == "applied" and i["run"] == run["key"] and
              i["entry"] == run["entry"] and i["position"] > run["input_cursor"] and
              (timer == nil or
                 DateTime.compare(parse!(i["prepared_at"]), parse!(timer["due"])) != :gt)
          end)

        cond do
          choice != nil ->
            {to, accepted} = choice

            {:ok,
             enter(run, flow, to, now, true, subject)
             |> Map.put("input_cursor", accepted["position"])
             |> Map.put("last_input", %{
               "version" => 1,
               "input" => accepted["key"],
               "subject_version" => accepted["subject_version"]
             })}

          branch ->
            {:ok,
             enter(run, flow, branch, now, true, subject)
             |> input(subject, %{
               "branch" => branch,
               "subject_version" => subject["version"]
             })}

          unconsumed ->
            {:ok,
             run
             |> Map.put("input_cursor", unconsumed["position"])
             |> Map.put("last_input", %{
               "version" => 1,
               "input" => unconsumed["key"],
               "ignored" => true
             })}

          timer ->
            {:ok,
             enter(run, flow, timer["to"], now, true, subject)
             |> input(
               subject,
               Map.put(
                 Map.take(timer, ["name", "entry", "due"]),
                 "waited_from",
                 run["entered_at"]
               )
             )}

          true ->
            {:ok, run}
        end
    end
  end

  @doc """
  The first pickup or hand-over input `run` takes now, checked and applied
  (`supervise/3`): `{:ok, run}`, `:none` when it takes none, or `{:error,
  :supervision_unavailable}` when a check could not be made now. `check` gives an
  input's check (`AtlasFlow.Runs.Inputs.supervision/4`, nil for any other input); nil
  checks none.

  Inputs are taken in position order: a supervision input waits behind an earlier
  input of the run's entry that the run can take now (a choice, or one it passes over),
  so the cursor never moves past it. In a state that runs a mechanism, or waits on its
  writes, no other input is taken, so a supervision input does not wait there.
  """
  def supervision(_run, _flow, _inputs, nil), do: :none

  def supervision(run, flow, inputs, check) do
    takes_others? =
      run["status"] == "active" and run["pending"]["writes"] == [] and
        flow.mechanism(run["state"]) == nil

    inputs
    |> Enum.filter(&(is_integer(&1["position"]) and &1["position"] > run["input_cursor"]))
    |> Enum.sort_by(& &1["position"])
    |> Enum.reduce_while(:none, fn input, :none ->
      case check.(input) do
        nil ->
          other? =
            takes_others? and input["status"] == "applied" and input["run"] == run["key"] and
              input["entry"] == run["entry"]

          if other?, do: {:halt, :none}, else: {:cont, :none}

        :unavailable ->
          {:halt, {:error, :supervision_unavailable}}

        checked ->
          {:halt, {:ok, supervise(run, input, checked)}}
      end
    end)
  end

  @doc """
  Apply one checked supervision input (`AtlasFlow.Runs.Inputs.supervision/4`) to `run`:
  a pickup sets its supervisor (`supervised_by`); a hand-over clears it and keeps the
  holder it is handed to, with the input, as `pending.hand_over`; a refusal changes
  nothing else. Each moves the cursor to the input and names it as the last input, with
  what it did, or why it was refused, as `supervision`.
  """
  def supervise(run, input, checked) do
    {run, last} =
      case checked do
        {:pick_up, holder} ->
          {Map.put(run, "supervised_by", holder), %{"supervision" => "pick_up"}}

        {:hand_over, _from, to} ->
          {run
           |> Map.delete("supervised_by")
           |> put_in(["pending", "hand_over"], %{"to" => to, "input" => input["key"]}),
           %{"supervision" => "hand_over"}}

        {:refused, tag} ->
          {run, %{"supervision" => tag, "refused" => true}}
      end

    run
    |> Map.put("input_cursor", input["position"])
    |> Map.put("last_input", Map.merge(last, %{"version" => 1, "input" => input["key"]}))
  end

  # Flow's own writer role: the branches a subflow takes `by: :atlas` and its `await`s.
  @writer "atlas-flow"

  @doc """
  Take the run's synthetic input, if it holds one: the values its subject's links and
  counts changed (`AtlasFlow.Runs.Store`), given as an input of Flow's own role on those
  fields, so the state's `await` and `by: :atlas` branches see them. `{:ok, run}`: entered
  where the first such branch leads, with the input and its sources as `last_input`, or
  unmoved without the input (it is taken once, at this entry). `:none` when it holds none.
  """
  def synthetic(run, flow, subject, now) do
    case run["pending"]["synthetic"] do
      nil ->
        :none

      %{"values" => changed} = synthetic ->
        values = Map.merge(subject["values"] || %{}, changed)

        to =
          if run["status"] == "active" and run["pending"]["writes"] == [] and
               flow.mechanism(run["state"]) == nil,
             do: flow.next(run["state"], values, %{roles: [@writer], changed: changed}),
             else: :stay

        case to do
          {:to, state} ->
            {:ok,
             enter(run, flow, state, now, true, subject)
             |> input(subject, %{
               "synthetic" => synthetic["id"],
               "sources" => synthetic["sources"],
               "subject_version" => subject["version"]
             })}

          :stay ->
            {:ok, update_in(run, ["pending"], &Map.delete(&1, "synthetic"))}
        end
    end
  end

  defp input(run, subject, input),
    do:
      run
      |> Map.put("input_cursor", subject["position"] || 0)
      |> Map.put("last_input", Map.put(input, "version", 1))

  defp enter(run, flow, state_name, now, effects?, subject \\ %{"values" => %{}}) do
    outputs = flow.enter(state_name, subject["values"] || %{})
    entry = run["entry"] + 1

    sets =
      for {:set, values} <- outputs do
        %{
          "id" => digest({run["key"], entry, "set"}),
          "kind" => run["subject_kind"],
          "content" => %{
            "op" => "change",
            "key" => run["subject_key"],
            "values" => values,
            "by" => "flow"
          }
        }
      end

    # `:timers` (an import into an open state) arms the timers alone.
    writes = if effects? == true, do: sets, else: []

    creates =
      if effects? == true,
        do:
          Enum.with_index(for {:create, c} <- outputs, do: c)
          |> Enum.map(fn {c, index} ->
            id = digest({run["key"], entry, "create", index})

            %{
              "id" => id,
              "kind" => c["type"],
              "content" => %{
                "op" => "create",
                "key" => id,
                "values" => c["properties"],
                "links" => if(c["relate"], do: %{c["relate"] => [run["subject_key"]]}, else: %{}),
                "by" => "flow"
              }
            }
          end),
        else: []

    timers =
      if effects? in [true, :timers],
        do:
          Enum.map(flow.timers(state_name), fn t ->
            %{
              "name" => t["name"],
              "entry" => entry,
              "to" => t["to"],
              "due" =>
                DateTime.add(timer_origin(t, subject, now), duration(t["period"]), :millisecond)
                |> DateTime.to_iso8601()
            }
          end),
        else: []

    Map.merge(run, %{
      "state" => state_name,
      "entry" => entry,
      "entered_at" => DateTime.to_iso8601(now),
      "status" => if(flow.final?(state_name), do: "completed", else: "active"),
      "pending" =>
        Map.merge(
          Map.take(run["pending"] || %{}, [
            "verdict",
            "migrations",
            "effects",
            "tasks",
            "composition",
            "hand_over"
          ]),
          %{
            "version" => 1,
            "writes" => writes ++ creates
          }
        ),
      "deadlines" => %{"version" => 1, "timers" => timers}
    })
  rescue
    _ in [ArgumentError, MatchError, FunctionClauseError] ->
      Map.merge(run, %{
        "state" => state_name,
        "entry" => run["entry"] + 1,
        "entered_at" => DateTime.to_iso8601(now),
        "status" => "blocked",
        "blocked_reason" => "missing or invalid timer since field",
        "pending" => %{"version" => 1, "writes" => []},
        "deadlines" => %{"version" => 1, "timers" => []}
      })
  end

  defp timer_origin(%{"since" => field}, subject, _now) when is_binary(field),
    do: parse!(subject["values"][field])

  defp timer_origin(_, _, now), do: now

  def parse!(time) do
    {:ok, utc, 0} = DateTime.from_iso8601(time)
    utc
  end
end
