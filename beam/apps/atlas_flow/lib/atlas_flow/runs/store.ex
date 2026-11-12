defmodule AtlasFlow.Runs.Store do
  @moduledoc "One writer reconciles durable cursors through Facts before sending entry writes."
  alias AtlasFlow.Runs.Run
  alias AtlasFlow.Talk
  alias AtlasFlow.Activities.Gate
  alias AtlasFlow.Activities.Pass
  alias AtlasFlow.Activities.Effect

  @structured ~w(deadlines pending last_input)

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
        config = Map.put(runs, "selection", selection)
        {config, validate_selection(config, flows)}

      _ ->
        {nil, nil}
    end
  end

  defp validate_selection(config, flows) do
    Enum.find_value(Enum.sort(config["selection"]), fn {name, selection} ->
      flow = flows[name]

      valid_imports =
        flow != nil and flow.subject() == selection["subject"] and
          Enum.all?(selection["imports"], &flow.final?(&1["state"]))

      if not valid_imports or Run.validate(flow) != :ok,
        do: {:unsupported_definition, name}
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
    with {:ok, restored} <- restore(config, flows, now),
         {:ok, runs} <- scan(config, flows, now, restored) do
      {:ok,
       runs
       |> Enum.group_by(&{&1["flow"], &1["subject_key"]})
       |> Enum.map(fn {_, group} -> Enum.max_by(group, & &1["generation"]) end)}
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
        case drain(config, run["key"], flows[run["flow"]], now, 32) do
          {:ok, restored} -> {:cont, {:ok, [restored | acc]}}
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
                  {:ok, run} -> {:cont, {:ok, [run | acc]}}
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
      if fact == nil do
        run = Run.new(name, flow, subject, selection["imports"], now)

        content = %{
          "op" => "create",
          "key" => key,
          "values" => encode(config, run),
          "by" => config["writer"]["by"]
        }

        # A lost create answer is recovered by reading the stable fact key.
        Talk.put(config["kind"], content, Run.digest({key, "create"}))
      end

      drain(config, key, flow, now, 32)
    end
  end

  defp drain(_config, _key, _flow, _now, 0), do: {:error, :transition_limit}

  defp drain(config, key, flow, now, remaining) do
    with {:ok, %{} = fact} <- fetch(config, key),
         {:ok, run} <- decode(config, fact) do
      if run["definition_sha256"] != flow.digest() do
        migrations = config["selection"][run["flow"]]["migrations"] || []

        case Run.migrate(run, flow, migrations, now) do
          {:ok, ^run} ->
            {:ok, run}

          {:ok, updated} ->
            advance(config, fact, run, updated, flow, now, remaining)

          _ ->
            blocked = Run.block_definition(run, flow)

            if blocked == run,
              do: {:ok, run},
              else: advance(config, fact, run, blocked, flow, now, remaining)
        end
      else
        case run["pending"]["writes"] do
          [write | rest] ->
            case Talk.put(write["kind"], write["content"], write["id"]) do
              {:stored, _} ->
                updated = put_in(run, ["pending", "writes"], rest)
                advance(config, fact, run, updated, flow, now, remaining)

              error ->
                {:error, {:pending, error}}
            end

          [] ->
            with :ok <- consume_input(config["inputs"], run),
                 {:ok, inputs} <- read_inputs(config["inputs"], run) do
              # Recover prepared writes first, then fetch the subject's current ETag.
              case Talk.transition_read(run["subject_kind"], %{
                     "key" => run["subject_key"],
                     "plain" => true
                   }) do
                %{"fact" => %{} = subject} = answer ->
                  subject =
                    Map.put(subject, "position", answer["position"] || subject["position"] || 0)

                  with {:ok, updated} <- next(config, run, flow, subject, now, inputs) do
                    if updated == run,
                      do: {:ok, run},
                      else: advance(config, fact, run, updated, flow, now, remaining)
                  end

                other ->
                  {:error, {:subject_unavailable, other}}
              end
            end
        end
      end
    else
      false -> {:error, {:definition_changed, key}}
      other -> {:error, {:invalid_run, key, other}}
    end
  end

  defp next(config, run, flow, subject, now, inputs) do
    mechanism = if run["status"] == "active", do: flow.mechanism(run["state"])
    review = config["selection"][run["flow"]]["verification"]
    verdict = run["pending"]["verdict"]

    cond do
      match?({:pass, _}, mechanism) ->
        pass_next(run, flow, subject, now, elem(mechanism, 1))

      match?({:effect, _}, mechanism) ->
        effect_next(run, flow, subject, now, elem(mechanism, 1))

      match?({:gate, _}, mechanism) ->
        gate_next(run, flow, subject, now, elem(mechanism, 1))

      Enum.any?(inputs, &(AtlasFlow.Runs.Inputs.choice(&1, run, subject, flow) != nil)) ->
        Run.step(run, flow, subject, now, inputs)

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
              Run.step(run, flow, subject, now, inputs)
            end

          other ->
            {:error, {:review_unavailable, other}}
        end

      true ->
        Run.step(run, flow, subject, now, inputs)
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

  defp effect_next(run, flow, subject, now, spec) do
    intent = run["pending"]["effect"]

    due =
      Enum.find(
        run["deadlines"]["timers"],
        &(DateTime.compare(now, Run.parse!(&1["due"])) != :lt)
      )

    cond do
      intent == nil ->
        # The request is stored before the first attempt; a missing target or approval waits.
        case Effect.freeze(run, spec, subject) do
          {:ok, frozen} -> {:ok, put_in(run, ["pending", "effect"], frozen)}
          {:error, _} -> {:ok, run}
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

  defp advance(config, fact, old, updated, flow, now, remaining) do
    if old["key"] != updated["key"] do
      content = %{
        "op" => "create",
        "key" => updated["key"],
        "values" => encode(config, updated),
        "by" => config["writer"]["by"]
      }

      Talk.put(config["kind"], content, Run.digest({updated["key"], "create"}))
      drain(config, updated["key"], flow, now, remaining - 1)
    else
      advance_same(config, fact, old, updated, flow, now, remaining)
    end
  end

  defp advance_same(config, fact, old, updated, flow, now, remaining) do
    values = encode(config, updated)

    content = %{
      "op" => "change",
      "key" => old["key"],
      "values" => values,
      "version" => fact["version"],
      "was" => Map.new(Map.keys(values), &{&1, fact["values"][&1]}),
      "by" => config["writer"]["by"]
    }

    # Conflict or lost acknowledgement: reread, never assume it was committed.
    Talk.put(config["kind"], content)
    drain(config, old["key"], flow, now, remaining - 1)
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
