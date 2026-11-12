defmodule AtlasFlow.Runs.Store do
  @moduledoc "One writer reconciles durable cursors through Facts before sending entry writes."
  alias AtlasFlow.Runs.Run
  alias AtlasFlow.Talk

  @structured ~w(deadlines pending last_input)

  def activate(description, target, yaml_path) do
    config = description["flow_runtime"]

    if config == nil or config["selection"] == %{} do
      {:ok, nil}
    else
      with :ok <- target.check_rela_flows(read_yaml(yaml_path, target.rela_flows_sha256())),
           :ok <- validate_selection(config, target.flows()) do
        {:ok, config}
      end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp read_yaml(path, expected) do
    case File.read(path || "") do
      {:ok, bytes} ->
        bytes

      {:error, reason} ->
        raise "cannot read deployed flows.yaml #{inspect(path)}: #{inspect(reason)}; expected sha256 #{expected}, actual unavailable"
    end
  end

  defp validate_selection(config, flows) do
    Enum.reduce_while(config["selection"], :ok, fn {name, selection}, :ok ->
      flow = flows[name]

      valid_imports =
        is_map(flow) and flow["subject"] == selection["subject"] and
          Enum.all?(
            selection["imports"],
            &(get_in(flow, ["states", &1["state"], "final"]) == true)
          )

      case valid_imports && Run.validate(flow) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, {:unsupported_definition, name}}}
      end
    end)
  end

  def selected(description, kind, fact) do
    Enum.find((description["flow_runtime"] || %{})["selection"] || %{}, fn {_name, selection} ->
      kind == selection["subject"] and Run.holds?(selection["admission"], fact["values"] || %{})
    end)
  end

  def reconcile(nil, _flows, _now), do: {:ok, []}

  def reconcile(config, flows, now) do
    with {:ok, restored} <- restore(config, flows, now),
         {:ok, runs} <- scan(config, flows, now, restored) do
      {:ok, runs |> Map.new(&{&1["key"], &1}) |> Map.values()}
    end
  end

  defp restore(config, flows, now) do
    with %{"facts" => facts} <- Talk.read(config["kind"], %{}),
         decoded = Enum.map(facts, &decode(config, &1)),
         true <- Enum.all?(decoded, &match?({:ok, _}, &1)) do
      runs = for {:ok, run} <- decoded, Map.has_key?(config["selection"], run["flow"]), do: run
      drifted = Enum.find(runs, &(&1["definition_sha256"] != Run.digest(flows[&1["flow"]])))

      if drifted do
        {:error, {:definition_changed, drifted["key"]}}
      else
        Enum.reduce_while(runs, {:ok, []}, fn run, {:ok, acc} ->
          case drain(config, run["key"], flows[run["flow"]], now, 32) do
            {:ok, restored} -> {:cont, {:ok, [restored | acc]}}
            error -> {:halt, error}
          end
        end)
      end
    else
      other -> {:error, {:runs_unavailable, other}}
    end
  end

  defp scan(config, flows, now, restored) do
    Enum.reduce_while(config["selection"], {:ok, restored}, fn {name, selection}, {:ok, runs} ->
      case Talk.read(selection["subject"], %{}) do
        %{"facts" => subjects} = answer ->
          subjects =
            Enum.map(
              subjects,
              &Map.put(&1, "position", answer["position"] || &1["position"] || 0)
            )

          result =
            Enum.reduce_while(subjects, {:ok, runs}, fn subject, {:ok, acc} ->
              if Run.holds?(selection["admission"], subject["values"] || %{}) do
                case reconcile_subject(config, name, flows[name], selection, subject, now) do
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

  defp reconcile_subject(config, name, flow, selection, subject, now) do
    key = Run.key(name, flow["subject"], subject["key"], 1)

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
         {:ok, run} <- decode(config, fact),
         true <- run["definition_sha256"] == Run.digest(flow) do
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
          # Fresh Facts snapshot immediately before considering a timeout.
          case Talk.read(run["subject_kind"], %{"key" => run["subject_key"], "plain" => true}) do
            %{"fact" => %{} = subject} = answer ->
              subject =
                Map.put(subject, "position", answer["position"] || subject["position"] || 0)

              with {:ok, updated} <- Run.step(run, flow, subject, now) do
                if updated == run,
                  do: {:ok, run},
                  else: advance(config, fact, run, updated, flow, now, remaining)
              end

            other ->
              {:error, {:subject_unavailable, other}}
          end
      end
    else
      false -> {:error, {:definition_changed, key}}
      other -> {:error, {:invalid_run, key, other}}
    end
  end

  defp advance(config, fact, old, updated, flow, now, remaining) do
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
    case Talk.read(config["kind"], %{"key" => key, "plain" => true}) do
      %{"fact" => fact} -> {:ok, fact}
      other -> {:error, other}
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
