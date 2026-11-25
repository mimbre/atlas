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

  # Stable internal request identities: a run's key and the ids of its pending writes are
  # digests of their terms, so a replay keeps the same keys.
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def key(flow, kind, key, generation), do: digest({flow, kind, key, generation})

  @doc "Pure one-time retirement/reentry. Receipt and composition checks belong to Store."
  def reenter_refused_tally_wait(run, flow, subject, retirement, now) do
    safe =
      run["status"] == "active" and
        run["subject_kind"] == flow.subject() and run["subject_key"] == subject["key"] and
        is_integer(run["entry"]) and run["entry"] > 0 and is_integer(run["generation"]) and
        run["generation"] > 0 and
        run["key"] == key(run["flow"], run["subject_kind"], run["subject_key"], run["generation"]) and
        run["state"] in flow.states() and not flow.final?(run["state"]) and
        flow.mechanism(run["state"]) == nil and
        flow.enter(run["state"], subject["values"] || %{}) == [] and
        reconciled(run)["deadlines"] == %{"version" => 1, "timers" => []} and
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

  @doc """
  `run` on its subflow's current states, which it is matched to by name. A run whose state
  is a state of `flow` (an idle run has none yet) continues there; one that was blocked
  with its status kept in `pending.definition_block` gets that status back. A run whose
  state is not a state of `flow` is blocked with `"state_removed: <state>"`, its status
  kept in `pending.definition_block`, so it continues once its subflow has the state again.
  """
  def match_states(run, flow) do
    block = run["pending"]["definition_block"]

    cond do
      not state_removed?(run, flow) and block != nil ->
        run
        |> Map.put("status", block["status"])
        |> Map.put("blocked_reason", "")
        |> update_in(["pending"], &Map.delete(&1, "definition_block"))

      not state_removed?(run, flow) ->
        run

      true ->
        run
        |> Map.put("status", "blocked")
        |> Map.put("blocked_reason", "state_removed: #{run["state"]}")
        |> update_in(
          ["pending"],
          &Map.put_new(&1, "definition_block", %{"status" => run["status"]})
        )
    end
  end

  @doc """
  Whether `run` is in a state its subflow `flow` does not have. An idle run (also one
  blocked while idle) is in none yet.
  """
  def state_removed?(run, flow) do
    status = get_in(run, ["pending", "definition_block", "status"]) || run["status"]
    status != "idle" and run["state"] not in flow.states()
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
  A refusal whose reason the state maps (`on: [no_changes: …]`) takes that branch, and its
  reason is the result field's value; any other takes `refused`.
  """
  def effect_result(run, flow, subject, now, reply) do
    {:effect, spec} = flow.mechanism(run["state"])
    intent = run["pending"]["effect"]

    with {:ok, result} <- Effect.validate_reply(intent, reply),
         true <- result["status"] in ["done", "refused"],
         outcome = effect_outcome(flow, run["state"], spec["field"], result),
         {:to, to} <- flow.next(run["state"], %{spec["field"] => outcome}, :result) do
      writes = Effect.writes(intent, spec, run, result, outcome)
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

  defp effect_outcome(flow, state, field, %{"status" => "refused", "reason" => reason}) do
    case flow.next(state, %{field => reason}, :result) do
      {:to, _} -> reason
      _ -> "refused"
    end
  end

  defp effect_outcome(_flow, _state, _field, result), do: result["status"]

  @doc """
  Enter the branch for a task's `outcome` (`AtlasFlow.Activities.Task.step/4`): its
  `result` joins the run's tasks (`pending.tasks`, kept across entries), and its record
  `writes` join the entry's pending writes with their stable ids. Leaving the state drops
  the task (`pending.task`), so a late result of its work is never taken. A ladder task's
  outcome is the ladder's step, and `ladder` (F2) becomes the run's `pending.ladder`,
  kept across entries as the tasks are; nil leaves it as it is.
  """
  def task_result(run, flow, subject, now, outcome, result, writes, ladder \\ nil) do
    {:task, spec} = flow.mechanism(run["state"])

    with true <- outcome in Task.results(spec),
         {:to, to} <- flow.next(run["state"], %{spec["field"] => outcome}, :result) do
      {:ok,
       run
       |> then(&if(ladder, do: put_in(&1, ["pending", "ladder"], ladder), else: &1))
       |> enter(flow, to, now, true, subject)
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

  @doc """
  A task's state, its task made or not: entered where the first of its plain branches
  (those of no role) that holds on `subject` leads, as a state without a mechanism is.
  `{:ok, run, intent}`, `intent` the task it held (nil when none was made yet), which the
  caller cancels; `:stay` when none holds or its entry writes are not acknowledged yet. A
  plain branch takes the run whether its task waits, runs or ended: what the subject says
  now (an effect it waits on undone elsewhere, say) outranks the work, whose result is never taken.
  """
  def unheld(run, flow, subject, now) do
    with "active" <- run["status"],
         [] <- run["pending"]["writes"],
         {:task, _} <- flow.mechanism(run["state"]),
         {:to, to} <- flow.next(run["state"], subject["values"] || %{}, nil) do
      intent = run["pending"]["task"]

      {:ok,
       enter(run, flow, to, now, true, subject)
       |> input(subject, %{"branch" => to, "subject_version" => subject["version"]}), intent}
    else
      _ -> :stay
    end
  end

  @doc """
  A run whose subject is completed (its kind's `completion`, which a read of Facts with
  its progress derives: `subject["completion"]["done"]`), entered in `state`, the final
  state its selection names (`completed:`), from any open state: `{:ok, run, intent}`,
  `intent` the task it held (nil for none), which the caller cancels. `:stay` when the
  subject is not completed, the run is not active, its entry writes are not acknowledged
  yet, or it waits for a service's answer to a frozen request (only that answer moves an
  effect, which leads to a state this then ends). nil `state` ends none.
  """
  def completed(_run, _flow, _subject, nil, _now), do: :stay

  def completed(run, flow, subject, state, now) do
    with "active" <- run["status"],
         [] <- run["pending"]["writes"],
         true <- get_in(subject, ["completion", "done"]) == true,
         false <- flow.final?(run["state"]),
         false <-
           match?({:effect, _}, flow.mechanism(run["state"])) and
             run["pending"]["effect"] != nil do
      intent = run["pending"]["task"]

      {:ok,
       enter(run, flow, state, now, true, subject)
       |> input(subject, %{"completed" => state, "subject_version" => subject["version"]}),
       intent}
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
  `next` (a new generation of `run`'s subflow on its subject key) knowing the keys of the
  tasks `run` and the generations before it made (`pending.former_tasks`), the one it
  holds too: its own are numbered past them (`AtlasFlow.Activities.Task.number/2`).
  """
  def former_tasks(next, run) do
    pending = run["pending"] || %{}

    keys =
      ((pending["former_tasks"] || []) ++
         for(t <- pending["tasks"] || [], do: t["key"]) ++
         List.wrap((pending["task"] || %{})["key"]))
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    if keys == [],
      do: next,
      else: update_in(next, ["pending"], &Map.put(&1 || %{}, "former_tasks", keys))
  end

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

  @doc """
  The run without the reconcile back-off a failed reconcile left in its deadlines
  (`AtlasFlow.Runs.Store.defer/3`): what a reaction that ended stores.
  """
  def reconciled(%{"deadlines" => %{"reconcile" => _} = deadlines} = run),
    do: %{run | "deadlines" => Map.delete(deadlines, "reconcile")}

  def reconciled(run), do: run

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
      (supervised = supervision(run, flow, inputs, opts[:supervision], opts[:hand_over])) !=
          :none ->
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

  `to_do` builds the writes that give a hand-over's holder their To-Do
  (`AtlasFlow.Runs.HandOver`): called with the run, its `pending.hand_over` and the
  supervisor who handed it over, it answers `{:ok, writes}`, or `:unavailable` when they
  cannot be built now (nothing is decided then). nil builds none.

  Inputs are taken in position order: a supervision input waits behind an earlier
  input of the run's entry that the run can take now (a choice, or one it passes over),
  so the cursor never moves past it. In a state that runs a mechanism, or waits on its
  writes, no other input is taken, so a supervision input does not wait there.
  """
  def supervision(run, flow, inputs, check, to_do \\ nil)
  def supervision(_run, _flow, _inputs, nil, _to_do), do: :none

  def supervision(run, flow, inputs, check, to_do) do
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
          case to_do(to_do, run, input, checked) do
            {:ok, writes} -> {:halt, {:ok, supervise(run, input, checked, writes)}}
            _ -> {:halt, {:error, :supervision_unavailable}}
          end
      end
    end)
  end

  # The To-Do writes of a hand-over (none for anything else, or without a builder).
  defp to_do(to_do, run, input, {:hand_over, from, to}) when is_function(to_do, 3),
    do: to_do.(run, %{"to" => to, "input" => input["key"]}, from)

  defp to_do(_to_do, _run, _input, _checked), do: {:ok, []}

  @doc """
  Apply one checked supervision input (`AtlasFlow.Runs.Inputs.supervision/4`) to `run`:
  a pickup sets its supervisor (`supervised_by`); a hand-over clears it and keeps the
  holder it is handed to, with the input, as `pending.hand_over`, and its To-Do's
  `writes` (`AtlasFlow.Runs.HandOver`) join the run's pending writes, so they are sent
  only once the run that holds them is stored; a retry is only named here (the store
  takes the run back, `retry/5`); a refusal changes nothing else. Each
  moves the cursor to the input and names it as the last input, with what it did, or
  why it was refused, as `supervision`; a pickup or retry an agent made on behalf of the
  holder names that agent as `by` (IS-Atlas-47).
  """
  def supervise(run, input, checked, writes \\ []) do
    {run, last} =
      case checked do
        {:pick_up, holder} ->
          by = if input["actor"] != holder, do: %{"by" => input["actor"]}, else: %{}
          {Map.put(run, "supervised_by", holder), Map.put(by, "supervision", "pick_up")}

        {:hand_over, _from, to} ->
          {run
           |> Map.delete("supervised_by")
           |> put_in(["pending", "hand_over"], %{"to" => to, "input" => input["key"]})
           |> update_in(["pending", "writes"], &((&1 || []) ++ writes)),
           %{"supervision" => "hand_over"}}

        {:retry, holder} ->
          by = if input["actor"] != holder, do: %{"by" => input["actor"]}, else: %{}
          {run, Map.put(by, "supervision", "retry")}

        {:refused, tag} ->
          {run, %{"supervision" => tag, "refused" => true}}
      end

    run
    |> Map.put("input_cursor", input["position"])
    |> Map.put("last_input", Map.merge(last, %{"version" => 1, "input" => input["key"]}))
  end

  @doc """
  `run` taken back to `state` by its supervisor's retry (IS-Atlas-09): entered again, as
  if for the first time, without what it held of its work since (its task and their
  results, a ladder, a frozen request); its supervisor, cursor and last input stay. The
  task it held is the caller's to cancel.
  """
  def retry(run, flow, state, subject, now) do
    pending = Map.take(run["pending"], ~w(migrations composition))

    run
    |> Map.put("pending", Map.merge(pending, %{"version" => 1, "writes" => []}))
    |> enter(flow, state, now, true, subject)
    |> Map.put("last_input", run["last_input"])
  end

  @doc """
  `run` after one transition from `previous`, with its supervisor (`supervised_by`)
  cleared when the transition left the supervised span `previous` was in (work
  acquisition decision 2026-11-17 §5.6, S2). `spans` are the run's subflow's spans, each
  with its `states`. The supervisor stays only while both states lie in one span: a move
  to another span, even an adjacent one, out of every span or into a final state clears
  it, and only a new pickup sets it again. A new generation (another run key) is not a
  transition of `previous`, and starts without a supervisor of its own (`new/6`).
  """
  def leave_span(previous, run, spans) do
    kept? =
      previous["key"] != run["key"] or
        Enum.any?(spans, fn span ->
          states = span["states"] || []
          previous["state"] in states and run["state"] in states
        end)

    if kept?, do: run, else: Map.delete(run, "supervised_by")
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

    {run, discards} = if effects? == true, do: discards(run, flow, state_name), else: {run, []}

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
            "former_tasks",
            "ladder",
            "composition",
            "hand_over"
          ]),
          %{
            "version" => 1,
            "writes" => discards ++ writes ++ creates
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

  # A task state whose proposal is discarded when it is entered again (`creates` with
  # `discard: true`; its supervisor did not accept it): one delete, by Flow, of each fact
  # the run's last task result made (`made`), so what was added by hand stays. That result
  # is marked `discarded`, so it is never deleted twice (a later proposal may reuse its
  # keys). A run without one (its first entry, or after a Retry) deletes nothing.
  defp discards(run, flow, state_name) do
    tasks = (run["pending"] || %{})["tasks"] || []

    with {:task, %{"creates" => %{"discard" => true}}} <- flow.mechanism(state_name),
         %{"made" => [_ | _] = made} = last when not is_map_key(last, "discarded") <-
           List.last(tasks) do
      deletes =
        for {[kind, key], index} <- Enum.with_index(made) do
          %{
            "id" => digest({run["key"], run["entry"] + 1, "discard", index}),
            "kind" => kind,
            "content" => %{
              "op" => "delete",
              "key" => key,
              "values" => %{},
              "by" => "flow",
              "cause" => "Not accepted: proposed by #{last["key"]}, discarded"
            }
          }
        end

      marked = List.replace_at(tasks, -1, Map.put(last, "discarded", true))
      {put_in(run, ["pending", "tasks"], marked), deletes}
    else
      _ -> {run, []}
    end
  end

  defp timer_origin(%{"since" => field}, subject, _now) when is_binary(field),
    do: parse!(subject["values"][field])

  defp timer_origin(_, _, now), do: now

  def parse!(time) do
    {:ok, utc, 0} = DateTime.from_iso8601(time)
    utc
  end
end
