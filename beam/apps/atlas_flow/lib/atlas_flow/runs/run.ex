defmodule AtlasFlow.Runs.Run do
  @moduledoc "The bounded transition machine. No IO; the cursor is always explicit."

  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def key(flow, kind, key, generation), do: digest({flow, kind, key, generation})

  def validate(flow) do
    states = flow["states"] || %{}

    supported =
      map_size(states) <= 3 and flow["start"] == [%{"on" => "create"}] and
        flow["per_subject"] == "one" and Map.has_key?(states, flow["initial"]) and
        Enum.all?(states, fn {_name, s} ->
          not Map.has_key?(s, "kind") and (s["creates"] || []) == [] and
            (s["waiting_for"] || []) == [] and (s["awaits"] || []) == [] and
            is_list(s["set"]) and
            Enum.all?(s["set"], fn
              %{"field" => field, "value" => value} ->
                is_binary(field) and (is_binary(value) or is_number(value) or is_boolean(value))

              _ ->
                false
            end) and
            Enum.all?(s["branches"] || [], fn b ->
              (b["roles"] || []) == [] and equality(b["when"]) != :error and
                Map.has_key?(states, b["to"])
            end) and
            Enum.all?(s["timers"] || [], fn t ->
              t["since"] == nil and duration(t["period"]) != :error and
                is_binary(t["name"]) and Map.has_key?(states, t["to"])
            end) and
            (s["final"] != true or ((s["branches"] || []) == [] and (s["timers"] || []) == []))
        end)

    if supported, do: :ok, else: {:error, :unsupported_definition}
  end

  def equality(text) when is_binary(text) do
    case Regex.run(~r/\Aentity\.([a-zA-Z_][a-zA-Z0-9_]*)\s*==\s*'([^']*)'\z/, text) do
      [_, field, value] -> {:ok, field, value}
      _ -> :error
    end
  end

  def equality(_), do: :error

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

  def holds?(condition, values),
    do:
      Enum.all?(condition, fn {field, allowed} ->
        Map.has_key?(values, field) and values[field] in List.wrap(allowed)
      end)

  def new(name, flow, subject, imports, now) do
    kind = flow["subject"]

    run = %{
      "flow" => name,
      "subject_kind" => kind,
      "subject_key" => subject["key"],
      "generation" => 1,
      "definition_sha256" => digest(flow),
      "entry" => 0,
      "input_cursor" => subject["position"] || 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    run = Map.put(run, "key", key(name, kind, subject["key"], 1))
    import = Enum.find(imports, &holds?(&1["when"], subject["values"] || %{}))

    if import do
      run
      |> enter(flow, import["state"], now, false)
      |> Map.put("status", "completed")
      |> Map.put("last_input", %{"version" => 1, "import" => true})
    else
      enter(run, flow, flow["initial"], now, true)
    end
  end

  def step(run, flow, subject, now) do
    cond do
      run["definition_sha256"] != digest(flow) ->
        {:error, :definition_changed}

      run["status"] != "active" ->
        {:ok, run}

      run["pending"]["writes"] != [] ->
        {:ok, run}

      true ->
        state = flow["states"][run["state"]]

        branch =
          Enum.find(state["branches"], fn b ->
            {:ok, field, value} = equality(b["when"])
            get_in(subject, ["values", field]) == value
          end)

        timer =
          run["deadlines"]["timers"]
          |> Enum.filter(&(DateTime.compare(now, parse!(&1["due"])) != :lt))
          |> Enum.min_by(&DateTime.to_unix(parse!(&1["due"]), :microsecond), fn -> nil end)

        cond do
          branch ->
            {:ok,
             enter(run, flow, branch["to"], now, true)
             |> input(subject, %{
               "branch" => branch["to"],
               "subject_version" => subject["version"]
             })}

          timer ->
            {:ok,
             enter(run, flow, timer["to"], now, true)
             |> input(subject, Map.take(timer, ["name", "entry", "due"]))}

          true ->
            {:ok, run}
        end
    end
  end

  defp input(run, subject, input),
    do:
      run
      |> Map.put("input_cursor", subject["position"] || 0)
      |> Map.put("last_input", Map.put(input, "version", 1))

  defp enter(run, flow, state_name, now, effects?) do
    state = flow["states"][state_name]
    entry = run["entry"] + 1

    writes =
      if effects? and state["set"] != [],
        do: [
          %{
            "id" => digest({run["key"], entry, "set"}),
            "kind" => run["subject_kind"],
            "content" => %{
              "op" => "change",
              "key" => run["subject_key"],
              "values" => Map.new(state["set"], &{&1["field"], &1["value"]}),
              "by" => "flow"
            }
          }
        ],
        else: []

    timers =
      if effects?,
        do:
          Enum.map(state["timers"], fn t ->
            %{
              "name" => t["name"],
              "entry" => entry,
              "to" => t["to"],
              "due" =>
                DateTime.add(now, duration(t["period"]), :millisecond) |> DateTime.to_iso8601()
            }
          end),
        else: []

    Map.merge(run, %{
      "state" => state_name,
      "entry" => entry,
      "entered_at" => DateTime.to_iso8601(now),
      "status" => if(state["final"], do: "completed", else: "active"),
      "pending" => %{"version" => 1, "writes" => writes},
      "deadlines" => %{"version" => 1, "timers" => timers}
    })
  end

  def parse!(time) do
    {:ok, utc, 0} = DateTime.from_iso8601(time)
    utc
  end
end
