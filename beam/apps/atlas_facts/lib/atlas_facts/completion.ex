defmodule AtlasFacts.Completion do
  @moduledoc """
  Whether a fact is completed, worked out from the description on every read; nothing
  stores it and nobody sets it. Knows no kind by name.

  The rule is data (`entities.<kind>.completion` in `rela/atlas.json`): one way, or a list
  of ways, and the fact is completed when one holds:

  - `%{"by" => relation}`: the fact has a link through that association (someone
    accepted it);
  - `%{"over" => relation, "field" => f, "value" => v}`: a fact that points at this one
    through `relation` has `f` = `v` (something that points at it is merged);
  - `%{"through" => relation, "field" => f, "value" => v}`: a fact this one points at
    through `relation` has `f` = `v`.

  `of/4` answers why, or nil: `%{"done" => true, "by" => relation, "keys" => keys}`, or
  `%{"done" => true, "over" | "through" => relation, "key" => key, "field" => f,
  "value" => v}`.
  """

  @doc "The ways a fact of `kind` is completed: a list, empty when it has no rule."
  def rules(description, kind) do
    case get_in(description, ["entities", kind, "completion"]) do
      rules when is_list(rules) -> Enum.filter(rules, &is_map/1)
      %{} = rule -> [rule]
      _ -> []
    end
  end

  @doc """
  The kinds whose facts a `kind`'s completion reads, besides its own; with `rules`, the
  kinds those rules read.
  """
  def needs(description, kind), do: needs_of(description, rules(description, kind))

  def needs_of(description, rules) do
    for rule <- rules,
        kind <- other_kinds(description, rule),
        uniq: true,
        do: kind
  end

  @doc """
  Whether one rule of the same shape (`over` or `through`, with `field` and `value`)
  holds for `fact`: why, or nil. Progress uses it for what a fact shows while something
  else holds (`progress.while`).
  """
  def matches(description, lists, rule, fact), do: holds(description, lists, rule, fact)

  defp other_kinds(description, %{"over" => relation}),
    do: get_in(description, ["relations", relation, "from"]) || []

  defp other_kinds(description, %{"through" => relation}),
    do: get_in(description, ["relations", relation, "to"]) || []

  defp other_kinds(_description, _rule), do: []

  @doc """
  Why `fact` of `kind` is completed, or nil. `lists` holds every fact of the kinds
  `needs/2` names (`%{kind => [fact]}`), as rela gives them.
  """
  def of(description, lists, kind, fact) do
    Enum.find_value(rules(description, kind), &holds(description, lists, &1, fact))
  end

  defp holds(_description, _lists, %{"by" => relation}, fact) do
    case links(fact, relation) do
      [] -> nil
      keys -> %{"done" => true, "by" => relation, "keys" => keys}
    end
  end

  defp holds(description, lists, %{"over" => relation} = rule, fact) do
    facts =
      for kind <- other_kinds(description, rule),
          other <- lists[kind] || [],
          fact.key in links(other, relation),
          do: other

    found(facts, "over", relation, rule)
  end

  defp holds(description, lists, %{"through" => relation} = rule, fact) do
    keys = links(fact, relation)

    facts =
      for kind <- other_kinds(description, rule),
          other <- lists[kind] || [],
          other.key in keys,
          do: other

    found(facts, "through", relation, rule)
  end

  defp holds(_description, _lists, _rule, _fact), do: nil

  defp found(facts, way, relation, %{"field" => field, "value" => value}) do
    case facts |> Enum.sort_by(& &1.key) |> Enum.find(&(&1.properties[field] == value)) do
      nil ->
        nil

      other ->
        %{
          "done" => true,
          way => relation,
          "key" => other.key,
          "field" => field,
          "value" => value
        }
    end
  end

  defp found(_facts, _way, _relation, _rule), do: nil

  defp links(fact, relation), do: (fact[:links] || %{})[relation] || []
end
