defmodule AtlasFacts.FlowRuntime do
  @moduledoc "Pure validation of the separately deployed run mapping and migration selection."
  @fields ~w(flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason)

  def fields, do: @fields

  def describe(description, %{"flow_runtime" => config} = fragment)
      when map_size(fragment) == 1 do
    config = applicable_annotations(description, config)

    with :ok <- validate(description, config) do
      description =
        Enum.reduce(config["reviews"] || %{}, description, fn {relation, rules}, d ->
          update_in(d, ["relations", relation, "review"], &(List.wrap(&1) ++ rules))
        end)

      {:ok, Map.put(description, "flow_runtime", config)}
    end
  end

  def describe(_description, _fragment), do: {:error, "invalid flow runtime fragment"}

  def validate(description, config) do
    config = applicable_annotations(description, config)
    entities = description["entities"] || %{}
    fields = config["fields"] || %{}
    spec = entities[config["kind"]] || %{}
    writer = config["writer"] || %{}
    selection = config["selection"] || %{}

    valid =
      Map.keys(Map.drop(config, ["inputs", "reviews", "flags"])) |> Enum.sort() ==
        ~w(fields kind selection version writer) and
        config["version"] == 1 and Map.keys(fields) |> Enum.sort() == Enum.sort(@fields)

    valid =
      valid and length(Enum.uniq(Map.values(fields))) == length(@fields) and
        Enum.all?(fields, fn {logical, field} ->
          type = if logical in ~w(generation entry input_cursor), do: "integer", else: "string"
          get_in(spec, ["properties", field, "type"]) == type
        end) and Map.keys(writer) |> Enum.sort() == ~w(by sender) and
        Enum.all?(Map.values(writer), &(is_binary(&1) and &1 != "")) and
        is_map(selection) and
        Enum.all?(selection, fn {name, s} ->
          is_binary(name) and
            Map.keys(Map.drop(s, ["verification", "choices", "choice_states", "migrations"]))
            |> Enum.sort() ==
              ~w(admission follow_through imports legacy projection subject) and
            is_map(entities[s["subject"]]) and is_map(description["flows"][s["legacy"]]) and
            s["subject"] in description["flows"][s["legacy"]]["kinds"] and
            valid_projection?(description, s) and
            valid_choices?(entities[s["subject"]], s) and
            valid_verification?(description, s) and
            valid_migrations?(s["migrations"] || []) and
            valid_follow_through?(entities[s["subject"]], s["follow_through"]) and
            condition?(entities[s["subject"]], s["admission"]) and
            is_list(s["imports"]) and
            Enum.all?(s["imports"], fn row ->
              Map.keys(row) |> Enum.sort() == ~w(state when) and is_binary(row["state"]) and
                condition?(entities[s["subject"]], row["when"])
            end)
        end) and disjoint?(selection) and
        AtlasFacts.FlowInputs.validate(description, config["inputs"]) == :ok and
        is_map(config["reviews"] || %{}) and is_map(config["flags"] || %{}) and
        Enum.all?(config["reviews"] || %{}, fn {relation, rules} ->
          spec = description["relations"][relation]

          is_map(spec) and is_list(rules) and
            Enum.all?(rules, fn rule ->
              Map.keys(rule) |> Enum.sort() == ~w(field label value) and
                is_binary(rule["label"]) and
                Enum.all?(spec["to"], fn kind ->
                  Map.has_key?(entities[kind]["properties"], rule["field"])
                end)
            end)
        end) and
        Enum.all?(config["flags"] || %{}, fn {kind, rule} ->
          is_map(entities[kind]) and Map.keys(rule) |> Enum.sort() == ~w(field label value) and
            Map.has_key?(entities[kind]["properties"], rule["field"]) and is_binary(rule["label"])
        end)

    if valid, do: :ok, else: {:error, "invalid flow runtime mapping or overlapping admission"}
  rescue
    _ -> {:error, "invalid flow runtime mapping"}
  end

  # A shared sidecar may carry presentation rules for several compositions. Only
  # declared targets participate; rules for a present target still validate strictly.
  # Selection and writer/input mappings are never silently discarded.
  defp applicable_annotations(description, config) when is_map(config) do
    Enum.reduce([{"reviews", "relations"}, {"flags", "entities"}], config, fn
      {key, section}, scoped ->
        if Map.has_key?(scoped, key) do
          Map.update!(scoped, key, fn annotations ->
            if is_map(annotations) do
              Map.filter(annotations, fn {target, _} ->
                Map.has_key?(description[section] || %{}, target)
              end)
            else
              annotations
            end
          end)
        else
          scoped
        end
    end)
  end

  defp applicable_annotations(_description, config), do: config

  defp condition?(spec, condition) when is_map(condition) do
    Enum.all?(condition, fn {field, allowed} ->
      Map.has_key?(spec["properties"] || %{}, field) and is_list(allowed) and allowed != []
    end)
  end

  defp condition?(_, _), do: false

  defp valid_choices?(spec, s) do
    (s["choices"] == nil or
       (is_list(s["choices"]) and s["choices"] != [] and
          Enum.all?(s["choices"], &Map.has_key?(spec["properties"], &1)))) and
      (s["choice_states"] == nil or
         (is_list(s["choice_states"]) and s["choice_states"] != [] and
            Enum.all?(s["choice_states"], &is_binary/1)))
  end

  defp valid_migrations?(migrations) when is_list(migrations) do
    Enum.all?(migrations, fn m ->
      Map.keys(Map.delete(m, "reason")) |> Enum.sort() == ~w(from states to) and
        (m["reason"] == nil or (is_binary(m["reason"]) and m["reason"] != "")) and
        Enum.all?(
          [m["from"], m["to"]],
          &(is_binary(&1) and Regex.match?(~r/\A[0-9a-f]{64}\z/, &1))
        ) and
        is_map(m["states"]) and
        Enum.all?(m["states"], fn {a, b} -> is_binary(a) and is_binary(b) end)
    end)
  end

  defp valid_migrations?(_), do: false

  defp valid_verification?(_d, %{"verification" => nil}), do: true

  defp valid_verification?(d, s) do
    case s["verification"] do
      nil ->
        true

      r ->
        Map.keys(r) |> Enum.sort() == ~w(field kind relations) and
          Map.has_key?(d["entities"][s["subject"]]["properties"], r["field"]) and
          is_map(d["entities"][r["kind"]]) and is_list(r["relations"]) and r["relations"] != [] and
          Enum.all?(r["relations"], &(r["kind"] in get_in(d, ["relations", &1, "from"])))
    end
  end

  defp valid_projection?(description, s) do
    legacy = description["flows"][s["legacy"]]
    s["projection"] == Map.take(legacy, ~w(on field state_field handover_field owner_relation))
  end

  defp valid_follow_through?(_spec, nil), do: true

  defp valid_follow_through?(spec, rule),
    do: is_binary(rule["state"]) and condition?(spec, rule["when"])

  defp disjoint?(selection) do
    pairs = Map.to_list(selection)

    Enum.all?(pairs, fn {name, a} ->
      Enum.all?(pairs, fn {other, b} ->
        name == other or a["subject"] != b["subject"] or
          Enum.any?(a["admission"], fn {field, values} ->
            is_list(b["admission"][field]) and
              MapSet.disjoint?(MapSet.new(values), MapSet.new(b["admission"][field]))
          end)
      end)
    end)
  end
end
