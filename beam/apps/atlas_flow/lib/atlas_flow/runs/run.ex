defmodule AtlasFlow.Runs.Run do
  @moduledoc """
  The bounded transition machine. No IO; the cursor is always explicit. `flow` is a
  compiled subflow (`AtlasFlow.Subflow`): the run asks it where a run starts, what
  entering a state writes, and where a change, an input or a result leads.
  """

  alias AtlasFlow.Runs.Inputs
  alias AtlasFlow.Activities.Gate
  alias AtlasFlow.Activities.Pass
  alias AtlasFlow.Activities.Effect

  # A subflow's identity is its compiled digest (`flow.digest()`); stable internal
  # request identities keep their term encoding so pending writes keep their keys.
  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def key(flow, kind, key, generation), do: digest({flow, kind, key, generation})

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

    safe =
      state != nil and state in flow.states() and run["pending"]["writes"] == [] and
        run["pending"]["gate"] == nil and run["pending"]["pass"] == nil and
        run["pending"]["effect"] == nil and
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

    migrated =
      run
      |> Map.put("definition_sha256", flow.digest())
      |> update_in(["pending"], fn pending ->
        Map.update(pending, "migrations", [migration], &(&1 ++ [migration]))
      end)

    cond do
      mapping && (mapping["rekey"] == true or mapping["preserve_entry"] == true) ->
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

  defp valid_activity?({:pass, spec}), do: Pass.valid?(spec)
  defp valid_activity?({:effect, spec}), do: Effect.valid?(spec)
  defp valid_activity?(nil), do: true
  defp valid_activity?(_), do: false

  def pass_result(run, flow, subject, now, reply) do
    with {:ok, result} <- Pass.validate_reply(run["pending"]["pass"], reply),
         "completed" <- result["status"],
         true <-
           AtlasBus.SubjectFingerprint.of(
             subject,
             run["pending"]["pass"]["request"]["fingerprint_definition"]
           ) == result["fingerprint"],
         {:to, to} <- flow.next(run["state"], %{"pass_result" => result["outcome"]}, :result) do
      {:ok,
       enter(run, flow, to, now, true, subject)
       |> put_in(["pending", "pass_result"], result)
       |> update_in(["pending"], fn pending ->
         record = %{"request" => run["pending"]["pass"]["request"], "result" => result}
         Map.update(pending, "passes", [record], &(&1 ++ [record]))
       end)
       |> Map.put("last_input", %{
         "version" => 1,
         "pass" => result["id"],
         "execution" => result["execution"]
       })}
    else
      _ -> {:error, :invalid_pass_result}
    end
  end

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
  def restart(%{"status" => "completed"} = run, flow, subject, now),
    do: {:ok, new(run["flow"], flow, subject, [], now, run["generation"] + 1)}

  def restart(_run, _flow, _subject, _now), do: {:error, :not_completed}

  @doc """
  Whether an import row may lead to `state` of `flow`: a final state (completed history),
  or a state a run can wait in without anything being done for it on entry: no mechanism
  (no activity is run again) and no entry writes (no set, no create).
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
            "passes",
            "effects",
            "composition"
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
