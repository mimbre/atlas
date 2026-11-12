defmodule AtlasFacts.Review do
  @moduledoc """
  Whether a fact is to be reviewed, worked out from the description on every read; nothing
  stores it and nobody sets it. Knows no kind by name.

  The rule is data, kept with the relation it follows (`relations.<name>.review` in
  `rela/atlas.json`): `%{"field" => f, "value" => v, "label" => text}`. A fact of a kind the
  relation starts at is to be reviewed while a fact it points at through the relation has
  `f` = `v`: work based on a record that was replaced since, say. Worked out as a completion
  rule through that relation (`AtlasFacts.Completion`). Nothing else changes; pages and lists show `label`.
  """

  alias AtlasFacts.Completion

  @doc """
  The rule for `kind`, as a completion rule through its relation with a label, or nil: the
  first relation (by name) that starts at `kind` and has a review rule.
  """
  def rule(description, kind) do
    List.first(rules(description, kind))
  end

  defp rules(description, kind) do
    for {relation, spec} <- Enum.sort(description["relations"] || %{}),
        kind in (spec["from"] || []),
        rule <- List.wrap(spec["review"]),
        is_map(rule) and is_binary(rule["field"]),
        do: Map.put(rule, "through", relation)
  end

  @doc "The kinds whose facts the rule of `kind` reads."
  def needs(description, kind) do
    Completion.needs_of(description, rules(description, kind))
  end

  @doc """
  Why `fact` of `kind` is to be reviewed, or nil: `%{"label", "key", "field", "value"}` and
  the relation (`"through"` or `"over"`). `lists` holds every fact of the kinds `needs/2`
  names, as rela gives them.
  """
  def of(description, lists, kind, fact) do
    own(description, kind, fact) ||
      Enum.find_value(rules(description, kind), fn rule ->
        case Completion.matches(description, lists, rule, fact) do
          %{} = why -> why |> Map.delete("done") |> Map.put("label", rule["label"] || "review")
          _ -> nil
        end
      end)
  end

  defp own(description, kind, fact) do
    rule = get_in(description, ["flow_runtime", "flags", kind])

    if rule && fact.properties[rule["field"]] == rule["value"],
      do: Map.put(rule, "key", fact.key)
  end

  @doc """
  `facts` of `kind`, each with `:review` when its kind has a rule (nil when nothing is to
  be reviewed). `list.(kind)` reads every fact of a kind; an error is returned as it is.
  """
  def annotate(description, kind, facts, list) do
    case {rules(description, kind), get_in(description, ["flow_runtime", "flags", kind])} do
      {[], nil} ->
        {:ok, facts}

      _rule ->
        with {:ok, lists} <- fetch(description, needs(description, kind), list) do
          {:ok, Enum.map(facts, &Map.put(&1, :review, of(description, lists, kind, &1)))}
        end
    end
  end

  defp fetch(description, kinds, list) do
    Enum.reduce_while(kinds, {:ok, %{}}, fn kind, {:ok, lists} ->
      case get_in(description, ["entities", kind, "plural"]) && list.(kind) do
        {:ok, facts} -> {:cont, {:ok, Map.put(lists, kind, facts)}}
        nil -> {:cont, {:ok, Map.put(lists, kind, [])}}
        error -> {:halt, error}
      end
    end)
  end
end
