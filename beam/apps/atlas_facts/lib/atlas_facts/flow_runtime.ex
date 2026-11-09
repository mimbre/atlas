defmodule AtlasFacts.FlowRuntime do
  @moduledoc "Pure validation of the separately deployed run mapping and migration selection."
  @fields ~w(flow subject_kind subject_key generation definition_sha256 state entry entered_at status deadlines pending input_cursor last_input blocked_reason)

  def fields, do: @fields

  def describe(description, %{"flow_runtime" => config} = fragment)
      when map_size(fragment) == 1 do
    with :ok <- validate(description, config) do
      {:ok, Map.put(description, "flow_runtime", config)}
    end
  end

  def describe(_description, _fragment), do: {:error, "invalid flow runtime fragment"}

  def validate(description, config) do
    entities = description["entities"] || %{}
    fields = config["fields"] || %{}
    spec = entities[config["kind"]] || %{}
    writer = config["writer"] || %{}
    selection = config["selection"] || %{}

    valid =
      Map.keys(config) |> Enum.sort() == ~w(fields kind selection version writer) and
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
            Map.keys(s) |> Enum.sort() ==
              ~w(admission follow_through imports legacy projection subject) and
            is_map(entities[s["subject"]]) and is_map(description["flows"][s["legacy"]]) and
            s["subject"] in description["flows"][s["legacy"]]["kinds"] and
            valid_projection?(description, s) and
            valid_follow_through?(entities[s["subject"]], s["follow_through"]) and
            condition?(entities[s["subject"]], s["admission"]) and
            is_list(s["imports"]) and
            Enum.all?(s["imports"], fn row ->
              Map.keys(row) |> Enum.sort() == ~w(state when) and is_binary(row["state"]) and
                condition?(entities[s["subject"]], row["when"])
            end)
        end) and disjoint?(selection)

    if valid, do: :ok, else: {:error, "invalid flow runtime mapping or overlapping admission"}
  rescue
    _ -> {:error, "invalid flow runtime mapping"}
  end

  defp condition?(spec, condition) when is_map(condition) do
    Enum.all?(condition, fn {field, allowed} ->
      Map.has_key?(spec["properties"] || %{}, field) and is_list(allowed) and allowed != []
    end)
  end

  defp condition?(_, _), do: false

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
