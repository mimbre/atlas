defmodule AtlasFacts.Progress do
  @moduledoc """
  How far a fact is, worked out from the facts under it on every read; never stored.
  The rule is data in the description (`progress` in `rela/atlas.json`). Knows no kind
  by name.

  Per kind (`entities.<kind>.progress`):

  - `over`: the relation whose facts point at this one: its children;
  - `field`: the children's property that says how far each is, for a child kind
    without a rule of its own (a child with a rule gives its own progress);
  - `own`: the fact's own property, shown when it has no children;
  - `while`: what it shows instead of its own property while something holds: a list of
    `%{"over" | "through" => relation, "field", "value", "shows"}` (development while a
    fact under it is open), shaped as a completion rule
    (`AtlasFacts.Completion`). The progress then says why (`"while"`: the fact that holds).

  For every kind (top-level `progress`): `order` (the values, least far first),
  `done_label`, and `to_test` (`%{"value", "label"}`: what a fact whose children are all
  completed shows while it is not completed itself; its value belongs in `order`).

  A fact is done only when it is completed itself (`AtlasFacts.Completion`), never
  because its children are. With children: done when completed; "to test" when every
  child is completed and it is not; otherwise as far as its least far child. Each with
  how many children are that far, of all of them: `%{"value", "label", "count", "of"}`,
  or `%{"done" => true, "label", "count", "of"}`. Without children it shows its own
  value (no count), or done. Nil when there is none.
  """

  alias AtlasFacts.Completion

  # Rules that point back at a kind already on the way down end here.
  @depth 8

  @doc "The progress rule of `kind`, or nil."
  def rule(description, kind) do
    case get_in(description, ["entities", kind, "progress"]) do
      %{} = rule -> rule
      _ -> nil
    end
  end

  @doc """
  `facts` of `kind` (as rela gives them), each with `:progress` when the kind has a
  progress rule and `:completion` (why it is completed, or nil) when it has a completion
  rule. `list` reads every fact of a kind: `list.(kind)` is `{:ok, facts}` or an error,
  which is returned as it is.
  """
  def annotate(description, kind, facts, list) do
    progress? = rule(description, kind) != nil
    completion? = Completion.rules(description, kind) != []

    if progress? or completion? do
      with {:ok, lists} <- fetch(description, needs(description, kind, @depth), list) do
        {:ok,
         Enum.map(facts, fn fact ->
           fact
           |> then(
             &if(progress?,
               do: Map.put(&1, :progress, progress(description, lists, kind, &1, @depth)),
               else: &1
             )
           )
           |> then(
             &if(completion?,
               do: Map.put(&1, :completion, Completion.of(description, lists, kind, &1)),
               else: &1
             )
           )
         end)}
      end
    else
      {:ok, facts}
    end
  end

  # The kinds to read: the children, at any depth, and what each one's completion and
  # `while` rules read.
  defp needs(_description, _kind, 0), do: MapSet.new()

  defp needs(description, kind, depth) do
    own =
      MapSet.new(
        Completion.needs(description, kind) ++
          Completion.needs_of(description, while_rules(description, kind))
      )

    case child_kind(description, kind) do
      nil -> own
      child -> own |> MapSet.union(needs(description, child, depth - 1)) |> MapSet.put(child)
    end
  end

  defp child_kind(description, kind) do
    with %{"over" => over} <- rule(description, kind),
         [child] <- get_in(description, ["relations", over, "from"]) do
      child
    else
      _ -> nil
    end
  end

  defp fetch(description, kinds, list) do
    Enum.reduce_while(kinds, {:ok, %{}}, fn kind, {:ok, lists} ->
      plural = get_in(description, ["entities", kind, "plural"])

      case plural && list.(kind) do
        {:ok, facts} -> {:cont, {:ok, Map.put(lists, kind, facts)}}
        nil -> {:cont, {:ok, Map.put(lists, kind, [])}}
        error -> {:halt, error}
      end
    end)
  end

  defp progress(_description, _lists, _kind, _fact, 0), do: nil

  defp progress(description, lists, kind, fact, depth) do
    rule = rule(description, kind) || %{}
    child = child_kind(description, kind)
    completed? = Completion.of(description, lists, kind, fact) != nil

    children =
      if child,
        do:
          Enum.filter(
            lists[child] || [],
            &(fact.key in (get_in(&1, [:links, rule["over"]]) || []))
          ),
        else: []

    cond do
      children != [] ->
        values = Enum.map(children, &child_value(description, lists, child, rule, &1, depth - 1))
        roll_up(description, values, completed?)

      completed? ->
        done(description)

      true ->
        while(description, lists, kind, fact) || own(description, kind, fact, rule["own"])
    end
  end

  defp while_rules(description, kind) do
    case get_in(description, ["entities", kind, "progress", "while"]) do
      rules when is_list(rules) -> Enum.filter(rules, &is_map/1)
      %{} = rule -> [rule]
      _ -> []
    end
  end

  # What the fact shows while one of its `while` rules holds, and why; else nil.
  defp while(description, lists, kind, fact) do
    own = get_in(description, ["entities", kind, "progress", "own"])

    Enum.find_value(while_rules(description, kind), fn rule ->
      case Completion.matches(description, lists, rule, fact) do
        nil ->
          nil

        why ->
          value = rule["shows"]
          labels = get_in(description, ["entities", kind, "properties", own, "labels"]) || %{}

          %{
            "value" => value,
            "label" => labels[value] || to_string(value),
            "while" => Map.delete(why, "done")
          }
      end
    end)
  end

  # How far one child is: its own progress when its kind has a rule, else its `field`.
  defp child_value(description, lists, kind, parent_rule, fact, depth) do
    cond do
      rule(description, kind) -> progress(description, lists, kind, fact, depth)
      Completion.of(description, lists, kind, fact) -> done(description)
      true -> own(description, kind, fact, parent_rule["field"])
    end
  end

  defp roll_up(description, values, completed?) do
    of = length(values)
    finished = Enum.count(values, &match?(%{"done" => true}, &1))
    open = Enum.reject(values, &(is_nil(&1) or match?(%{"done" => true}, &1)))

    cond do
      completed? ->
        Map.merge(done(description), %{"count" => finished, "of" => of})

      finished == of ->
        Map.merge(to_test(description), %{"count" => finished, "of" => of})

      open == [] ->
        nil

      true ->
        least = Enum.min_by(open, &rank(description, &1["value"]))
        count = Enum.count(open, &(&1["value"] == least["value"]))
        Map.merge(least, %{"count" => count, "of" => of})
    end
  end

  defp own(_description, _kind, _fact, nil), do: nil

  defp own(description, kind, fact, field) do
    case fact.properties[field] do
      value when value in [nil, ""] ->
        nil

      value ->
        labels = get_in(description, ["entities", kind, "properties", field, "labels"]) || %{}
        %{"value" => value, "label" => labels[value] || to_string(value)}
    end
  end

  defp done(description),
    do: %{"done" => true, "label" => get_in(description, ["progress", "done_label"]) || "Done"}

  defp to_test(description) do
    case get_in(description, ["progress", "to_test"]) do
      %{"value" => value} = to_test -> %{"value" => value, "label" => to_test["label"] || value}
      _ -> %{"value" => "to_test", "label" => "To test"}
    end
  end

  # A value the order does not know counts as the least far.
  defp rank(description, value) do
    Enum.find_index(get_in(description, ["progress", "order"]) || [], &(&1 == value)) || -1
  end
end
