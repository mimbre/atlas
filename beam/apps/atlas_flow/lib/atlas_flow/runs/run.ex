defmodule AtlasFlow.Runs.Run do
  @moduledoc "The bounded transition machine. No IO; the cursor is always explicit."

  alias AtlasFlow.Runs.{Conditions, Inputs}

  def digest(term),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(term)) |> Base.encode16(case: :lower)

  def key(flow, kind, key, generation), do: digest({flow, kind, key, generation})

  def validate(flow) do
    states = flow["states"] || %{}

    supported =
      valid_starts?(flow["start"]) and
        flow["per_subject"] == "one" and Map.has_key?(states, flow["initial"]) and
        Enum.all?(states, fn {_name, s} ->
          not Map.has_key?(s, "kind") and valid_creates?(s["creates"] || []) and
            is_list(s["set"]) and
            Enum.all?(s["set"], fn
              %{"field" => field, "value" => value} ->
                is_binary(field) and (is_binary(value) or is_number(value) or is_boolean(value))

              _ ->
                false
            end) and
            Enum.all?(s["branches"] || [], fn b ->
              is_list(b["roles"] || []) and match?({:ok, _}, Conditions.compile(b["when"])) and
                Map.has_key?(states, b["to"])
            end) and
            Enum.all?(s["timers"] || [], fn t ->
              (t["since"] == nil or is_binary(t["since"])) and duration(t["period"]) != :error and
                is_binary(t["name"]) and Map.has_key?(states, t["to"])
            end) and
            (s["final"] != true or ((s["branches"] || []) == [] and (s["timers"] || []) == []))
        end)

    if supported, do: :ok, else: {:error, :unsupported_definition}
  end

  defp valid_starts?(starts) when is_list(starts) and starts != [] do
    Enum.all?(starts, fn
      %{"on" => "create"} = s ->
        map_size(s) == 1

      %{"on" => "predicate", "when" => text} = s ->
        map_size(s) == 2 and match?({:ok, _}, Conditions.compile(text))

      _ ->
        false
    end)
  end

  defp valid_starts?(_), do: false

  defp valid_creates?(creates) do
    Enum.all?(creates, fn c ->
      is_binary(c["type"]) and is_map(c["properties"]) and
        Enum.all?(c["properties"], fn {_, v} -> is_binary(v) or is_number(v) or is_boolean(v) end) and
        (c["relate"] == nil or is_binary(c["relate"]))
    end)
  end

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

  def new(name, flow, subject, imports, now, generation \\ 1) do
    kind = flow["subject"]

    run = %{
      "flow" => name,
      "subject_kind" => kind,
      "subject_key" => subject["key"],
      "generation" => generation,
      "definition_sha256" => digest(flow),
      "entry" => 0,
      "input_cursor" => 0,
      "last_input" => %{"version" => 1},
      "blocked_reason" => ""
    }

    run = Map.put(run, "key", key(name, kind, subject["key"], generation))
    import = Enum.find(imports, &holds?(&1["when"], subject["values"] || %{}))

    if import do
      run
      |> enter(flow, import["state"], now, false)
      |> Map.put("status", "completed")
      |> Map.put("last_input", %{"version" => 1, "import" => true})
    else
      if starts?(flow, subject),
        do: enter(run, flow, flow["initial"], now, true, subject),
        else: idle(run, now)
    end
  end

  def starts?(flow, subject),
    do:
      Enum.any?(flow["start"], fn s ->
        s["on"] == "create" or Conditions.matches?(s["when"], subject["values"])
      end)

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

  def step(run, flow, subject, now, inputs \\ []) do
    cond do
      run["definition_sha256"] != digest(flow) ->
        {:error, :definition_changed}

      run["status"] == "idle" and starts?(flow, subject) ->
        {:ok, enter(run, flow, flow["initial"], now, true, subject)}

      run["status"] == "completed" and not Enum.any?(flow["start"], &(&1["on"] == "create")) ->
        edge = starts?(flow, subject)
        previous = Map.get(run["last_input"], "start_edge", true)

        if edge and not previous do
          {:ok, new(run["flow"], flow, subject, [], now, run["generation"] + 1)}
        else
          {:ok, put_in(run, ["last_input", "start_edge"], edge)}
        end

      run["status"] != "active" ->
        {:ok, run}

      run["pending"]["writes"] != [] ->
        {:ok, run}

      true ->
        state = flow["states"][run["state"]]

        timer =
          run["deadlines"]["timers"]
          |> Enum.filter(&(DateTime.compare(now, parse!(&1["due"])) != :lt))
          |> Enum.min_by(&DateTime.to_unix(parse!(&1["due"]), :microsecond), fn -> nil end)

        choice =
          for input <- Enum.sort_by(inputs, & &1["position"]),
              b <- state["branches"],
              (b["roles"] || []) != [],
              Inputs.eligible?(input, run, subject, b),
              timer == nil or
                DateTime.compare(parse!(input["prepared_at"]), parse!(timer["due"])) != :gt,
              do: {b, input}

        branch =
          Enum.find(state["branches"], fn b ->
            (b["roles"] || []) == [] and Conditions.matches?(b["when"], subject["values"] || %{})
          end)

        unconsumed =
          Enum.find(Enum.sort_by(inputs, & &1["position"]), fn i ->
            i["status"] == "applied" and i["run"] == run["key"] and
              i["entry"] == run["entry"] and i["position"] > run["input_cursor"] and
              (timer == nil or
                 DateTime.compare(parse!(i["prepared_at"]), parse!(timer["due"])) != :gt)
          end)

        cond do
          choice != [] ->
            {b, accepted} = hd(choice)

            {:ok,
             enter(run, flow, b["to"], now, true, subject)
             |> Map.put("input_cursor", accepted["position"])
             |> Map.put("last_input", %{
               "version" => 1,
               "input" => accepted["key"],
               "subject_version" => accepted["subject_version"]
             })}

          branch ->
            {:ok,
             enter(run, flow, branch["to"], now, true, subject)
             |> input(subject, %{
               "branch" => branch["to"],
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

  defp enter(run, flow, state_name, now, effects?, subject \\ %{"values" => %{}}) do
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

    creates =
      if effects?,
        do:
          Enum.with_index(state["creates"] || [])
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
      if effects?,
        do:
          Enum.map(state["timers"], fn t ->
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
      "status" => if(state["final"], do: "completed", else: "active"),
      "pending" => %{"version" => 1, "writes" => writes ++ creates},
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
