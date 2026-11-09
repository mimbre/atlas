defmodule RelaDSL.Facts.Derived do
  @moduledoc """
  What a store works out about a fact on every read, never stores and nobody sets:
  whether it is completed, how far it is, whether it is to be reviewed and whether it is
  late. Evaluated on the model's compiled description `d` (`RelaDSL.Facts.Model`). Pure;
  knows no kind by name.

  What the rules read, they ask the store for as precisely as the rule reads it, so the
  store can say exactly what an answer depended on (docs/design/page-freshness.md §1.1,
  F10): never every fact of a kind, but the facts that point at the facts worked out
  (`lookup["linked"]`: `fn kind, relation, keys -> {:ok, [fact]} | {:error, reason}`,
  the facts of `kind` that point at one of `keys` through `relation`) and the facts they
  point at (`lookup["facts"]`: `fn kind, keys -> {:ok, [fact]} | {:error, reason}`, those
  of `kind` with one of `keys`). Children are asked for level by level, all facts of a
  level at once.

  **Completion** (`completion` per kind): one way, or a list of ways; the fact is
  completed when one holds:

  - `%{"by" => relation}`: the fact has a link through that association;
  - `%{"over" => relation, "field" => f, "value" => v}`: a fact that points at this one
    through `relation` has `f` = `v`;
  - `%{"through" => relation, "field" => f, "value" => v}`: a fact this one points at
    through `relation` has `f` = `v`.

  Why: `%{"done" => true, "by" => relation, "keys" => keys}`, or `%{"done" => true,
  "over" | "through" => relation, "key" => key, "field" => f, "value" => v}`.

  **Progress** (`progress` per kind): `over` (the relation whose facts point at this one:
  its children), `field` (the children's property that says how far each is, for a child
  kind without a rule of its own), `own` (the fact's own property, shown when it has no
  children) and `while` (what it shows instead while something holds: a list of
  `%{"over" | "through" => relation, "field", "value", "shows"}`, shaped as a completion
  rule). For every kind (top-level `progress`): `order` (least far first),
  `done_label`, and `to_test` (`%{"value", "label"}`: what a fact whose children are all
  completed shows while it is not completed itself). A fact is done only when it is
  completed itself. With children: done when completed; `to_test` when every child is
  completed and it is not; otherwise as far as its least far child. Each with how many
  children are that far, of all: `%{"value", "label", "count", "of"}`, or
  `%{"done" => true, "label", "count", "of"}`. Without children its own value, or done.

  **Review** (`review` on a relation, and the run mapping's `flags` per kind): a fact is to
  be reviewed while a fact it points at through the relation has `field` = `value`, or
  while its own `field` has the flag's `value`: `%{"label", "key", "field", "value"}` and
  the relation.

  **Late** (`late` per kind, `%{"after" => field, "while" => field}`): while the time in
  `after` has passed and `while` is not empty. **Until**: while a fact is not late yet
  but will be by time alone, the first instant it is (a reader re-reads then).
  """

  # Rules that point back at a kind already on the way down end here.
  @depth 8

  @doc """
  What is worked out for each of `facts` (as rela gives them) of `kind`, in order:
  `{:ok, [%{"progress", "completion", "review", "late", "until"}]}` with only what
  applies, or the error a read of `lookup` gave. Without `lookup["linked"]`, only what
  needs no other fact (`late`, `until`).
  """
  def of(d, kind, facts, lookup) do
    now = lookup["now"] || DateTime.utc_now()

    late = fn derived, fact ->
      derived
      |> put("late", late(d, kind, fact.properties, now))
      |> put("until", until(d, kind, fact.properties, now))
    end

    case lookup["linked"] do
      nil ->
        {:ok, Enum.map(facts, &late.(%{}, &1))}

      _ ->
        with {:ok, facts} <- annotate(d, kind, facts, lookup),
             {:ok, facts} <- review(d, kind, facts, lookup) do
          {:ok,
           Enum.map(facts, fn fact ->
             %{}
             |> put("progress", fact[:progress] || nil)
             |> put("completion", fact[:completion] || nil)
             |> put("review", fact[:review] || nil)
             |> late.(fact)
           end)}
        end
    end
  end

  defp put(map, _name, nil), do: map
  defp put(map, name, value), do: Map.put(map, name, value)

  @doc """
  The keys of the facts under the fact `key` of `kind`, through a parent relation, that
  are not completed: `{:ok, keys}`, or the error `lookup["list"]` gave.
  """
  def open_children(d, kind, key, lookup) do
    children =
      for {relation, %{"to" => to, "from" => from} = spec} <- Enum.sort(d["relations"] || %{}),
          spec["parent"] == true and spec["max_outgoing"] == 1,
          kind in to,
          child <- from,
          do: {relation, child}

    Enum.reduce_while(children, {:ok, []}, fn {relation, child}, {:ok, open} ->
      with {:ok, facts} <- lookup["list"].(child),
           under = Enum.filter(facts, &(key in (&1.links[relation] || []))),
           {:ok, lists} <- fetch(d, needs(d, child), lookup["list"]) do
        more = for fact <- under, completion(d, lists, child, fact) == nil, do: fact.key
        {:cont, {:ok, open ++ more}}
      else
        error -> {:halt, error}
      end
    end)
  end

  # -- Completion --------------------------------------------------------------------------

  defp rules(d, kind) do
    case get_in(d, ["entities", kind, "completion"]) do
      rules when is_list(rules) -> Enum.filter(rules, &is_map/1)
      %{} = rule -> [rule]
      _ -> []
    end
  end

  defp needs(d, kind), do: needs_of(d, rules(d, kind))

  defp needs_of(d, rules) do
    for rule <- rules,
        kind <- other_kinds(d, rule),
        uniq: true,
        do: kind
  end

  defp other_kinds(d, %{"over" => relation}),
    do: get_in(d, ["relations", relation, "from"]) || []

  defp other_kinds(d, %{"through" => relation}),
    do: get_in(d, ["relations", relation, "to"]) || []

  defp other_kinds(_d, _rule), do: []

  defp completion(d, lists, kind, fact) do
    Enum.find_value(rules(d, kind), &holds(d, lists, &1, fact))
  end

  defp holds(_d, _lists, %{"by" => relation}, fact) do
    case links(fact, relation) do
      [] -> nil
      keys -> %{"done" => true, "by" => relation, "keys" => keys}
    end
  end

  defp holds(d, lists, %{"over" => relation} = rule, fact) do
    facts =
      for kind <- other_kinds(d, rule),
          other <- lists[kind] || [],
          fact.key in links(other, relation),
          do: other

    found(facts, "over", relation, rule)
  end

  defp holds(d, lists, %{"through" => relation} = rule, fact) do
    keys = links(fact, relation)

    facts =
      for kind <- other_kinds(d, rule),
          other <- lists[kind] || [],
          other.key in keys,
          do: other

    found(facts, "through", relation, rule)
  end

  defp holds(_d, _lists, _rule, _fact), do: nil

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

  # -- Progress ----------------------------------------------------------------------------

  defp rule(d, kind) do
    case get_in(d, ["entities", kind, "progress"]) do
      %{} = rule -> rule
      _ -> nil
    end
  end

  @doc """
  `facts` of `kind` (as rela gives them), each with `:progress` when the kind has a
  progress rule and `:completion` (why it is completed, or nil) when it has a completion
  rule. What the rules read is asked of `lookup` (`"linked"`, `"facts"`), and an error
  it gives is returned.
  """
  def annotate(d, kind, facts, lookup) do
    progress? = rule(d, kind) != nil
    completion? = rules(d, kind) != []

    if progress? or completion? do
      with {:ok, lists} <- progress_reads(d, kind, facts, lookup, @depth) do
        {:ok,
         Enum.map(facts, fn fact ->
           fact
           |> then(
             &if(progress?,
               do: Map.put(&1, :progress, progress(d, lists, kind, &1, @depth)),
               else: &1
             )
           )
           |> then(
             &if(completion?,
               do: Map.put(&1, :completion, completion(d, lists, kind, &1)),
               else: &1
             )
           )
         end)}
      end
    else
      {:ok, facts}
    end
  end

  # What the progress and completion of `facts` of `kind` read: what their completion and
  # `while` rules read, their children, and what those read in turn, `depth` levels
  # down. `{:ok, %{kind => [fact]}}`, each fact once.
  defp progress_reads(_d, _kind, _facts, _lookup, 0), do: {:ok, %{}}
  defp progress_reads(_d, _kind, [], _lookup, _depth), do: {:ok, %{}}

  defp progress_reads(d, kind, facts, lookup, depth) do
    with {:ok, own} <- rule_reads(d, rules(d, kind) ++ while_rules(d, kind), facts, lookup) do
      case child_kind(d, kind) do
        nil ->
          {:ok, own}

        child ->
          over = rule(d, kind)["over"]

          with {:ok, %{^child => children}} <- linked(d, [child], over, facts, lookup),
               {:ok, below} <- progress_reads(d, child, children, lookup, depth - 1) do
            {:ok, own |> merge(%{child => children}) |> merge(below)}
          end
      end
    end
  end

  # What `rules` read for `facts`: through `over`, the facts that point at one of them;
  # through `through`, the facts they point at.
  defp rule_reads(d, rules, facts, lookup) do
    Enum.reduce_while(rules, {:ok, %{}}, fn rule, {:ok, lists} ->
      read =
        case rule do
          %{"over" => relation} -> linked(d, other_kinds(d, rule), relation, facts, lookup)
          %{"through" => relation} -> pointed(d, other_kinds(d, rule), relation, facts, lookup)
          _ -> {:ok, %{}}
        end

      case read do
        {:ok, found} -> {:cont, {:ok, merge(lists, found)}}
        error -> {:halt, error}
      end
    end)
  end

  # The facts of `kinds` that point at one of `facts` through `relation`.
  defp linked(d, kinds, relation, facts, lookup) do
    keys = Enum.map(facts, & &1.key)
    each_kind(d, kinds, keys, &lookup["linked"].(&1, relation, keys))
  end

  # The facts of `kinds` that `facts` point at through `relation`.
  defp pointed(d, kinds, relation, facts, lookup) do
    keys = facts |> Enum.flat_map(&links(&1, relation)) |> Enum.uniq()
    each_kind(d, kinds, keys, &lookup["facts"].(&1, keys))
  end

  # `read.(kind)` for each of `kinds` the store keeps (a kind without a plural holds no
  # facts), none when there is no key to ask for: `{:ok, %{kind => [fact]}}`.
  defp each_kind(d, kinds, keys, read) do
    kept = if keys == [], do: [], else: Enum.filter(kinds, &get_in(d, ["entities", &1, "plural"]))

    Enum.reduce_while(kept, {:ok, Map.new(kinds, &{&1, []})}, fn kind, {:ok, lists} ->
      case read.(kind) do
        {:ok, facts} -> {:cont, {:ok, Map.put(lists, kind, facts)}}
        error -> {:halt, error}
      end
    end)
  end

  defp merge(a, b), do: Map.merge(a, b, fn _kind, x, y -> Enum.uniq_by(x ++ y, & &1.key) end)

  defp child_kind(d, kind) do
    with %{"over" => over} <- rule(d, kind),
         [child] <- get_in(d, ["relations", over, "from"]) do
      child
    else
      _ -> nil
    end
  end

  defp fetch(d, kinds, list) do
    Enum.reduce_while(kinds, {:ok, %{}}, fn kind, {:ok, lists} ->
      plural = get_in(d, ["entities", kind, "plural"])

      case plural && list.(kind) do
        {:ok, facts} -> {:cont, {:ok, Map.put(lists, kind, facts)}}
        nil -> {:cont, {:ok, Map.put(lists, kind, [])}}
        error -> {:halt, error}
      end
    end)
  end

  defp progress(_d, _lists, _kind, _fact, 0), do: nil

  defp progress(d, lists, kind, fact, depth) do
    rule = rule(d, kind) || %{}
    child = child_kind(d, kind)
    completed? = completion(d, lists, kind, fact) != nil

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
        values = Enum.map(children, &child_value(d, lists, child, rule, &1, depth - 1))
        roll_up(d, values, completed?)

      completed? ->
        done(d)

      true ->
        while(d, lists, kind, fact) || own(d, kind, fact, rule["own"])
    end
  end

  defp while_rules(d, kind) do
    case get_in(d, ["entities", kind, "progress", "while"]) do
      rules when is_list(rules) -> Enum.filter(rules, &is_map/1)
      %{} = rule -> [rule]
      _ -> []
    end
  end

  # What the fact shows while one of its `while` rules holds, and why; else nil.
  defp while(d, lists, kind, fact) do
    own = get_in(d, ["entities", kind, "progress", "own"])

    Enum.find_value(while_rules(d, kind), fn rule ->
      case holds(d, lists, rule, fact) do
        nil ->
          nil

        why ->
          value = rule["shows"]
          labels = get_in(d, ["entities", kind, "properties", own, "labels"]) || %{}

          %{
            "value" => value,
            "label" => labels[value] || to_string(value),
            "while" => Map.delete(why, "done")
          }
      end
    end)
  end

  # How far one child is: its own progress when its kind has a rule, else its `field`.
  defp child_value(d, lists, kind, parent_rule, fact, depth) do
    cond do
      rule(d, kind) -> progress(d, lists, kind, fact, depth)
      completion(d, lists, kind, fact) -> done(d)
      true -> own(d, kind, fact, parent_rule["field"])
    end
  end

  defp roll_up(d, values, completed?) do
    of = length(values)
    finished = Enum.count(values, &match?(%{"done" => true}, &1))
    open = Enum.reject(values, &(is_nil(&1) or match?(%{"done" => true}, &1)))

    cond do
      completed? ->
        Map.merge(done(d), %{"count" => finished, "of" => of})

      finished == of ->
        Map.merge(to_test(d), %{"count" => finished, "of" => of})

      open == [] ->
        nil

      true ->
        least = Enum.min_by(open, &rank(d, &1["value"]))
        count = Enum.count(open, &(&1["value"] == least["value"]))
        Map.merge(least, %{"count" => count, "of" => of})
    end
  end

  defp own(_d, _kind, _fact, nil), do: nil

  defp own(d, kind, fact, field) do
    case fact.properties[field] do
      value when value in [nil, ""] ->
        nil

      value ->
        labels = get_in(d, ["entities", kind, "properties", field, "labels"]) || %{}
        %{"value" => value, "label" => labels[value] || to_string(value)}
    end
  end

  defp done(d),
    do: %{"done" => true, "label" => get_in(d, ["progress", "done_label"]) || "Done"}

  defp to_test(d) do
    case get_in(d, ["progress", "to_test"]) do
      %{"value" => value} = to_test -> %{"value" => value, "label" => to_test["label"] || value}
      _ -> %{"value" => "to_test", "label" => "To test"}
    end
  end

  # A value the order does not know counts as the least far.
  defp rank(d, value) do
    Enum.find_index(get_in(d, ["progress", "order"]) || [], &(&1 == value)) || -1
  end

  # -- Review ------------------------------------------------------------------------------

  defp review_rules(d, kind) do
    for {relation, spec} <- Enum.sort(d["relations"] || %{}),
        kind in (spec["from"] || []),
        rule <- List.wrap(spec["review"]),
        is_map(rule) and is_binary(rule["field"]),
        do: Map.put(rule, "through", relation)
  end

  @doc """
  Why `fact` of `kind` is to be reviewed, or nil. `lists` holds every fact of the kinds
  `review_needs/2` names, as rela gives them.
  """
  def review_of(d, lists, kind, fact) do
    flagged(d, kind, fact) ||
      Enum.find_value(review_rules(d, kind), fn rule ->
        case holds(d, lists, rule, fact) do
          %{} = why -> why |> Map.delete("done") |> Map.put("label", rule["label"] || "review")
          _ -> nil
        end
      end)
  end

  defp flagged(d, kind, fact) do
    rule = get_in(d, ["flow_runtime", "flags", kind])

    if rule && fact.properties[rule["field"]] == rule["value"],
      do: Map.put(rule, "key", fact.key)
  end

  @doc "The kinds whose facts the review rules of `kind` read."
  def review_needs(d, kind), do: needs_of(d, review_rules(d, kind))

  @doc """
  `facts` of `kind`, each with `:review` when its kind has a rule (nil when nothing is to
  be reviewed). The facts the rules point at are asked of `lookup` (`"facts"`), and an
  error it gives is returned.
  """
  def review(d, kind, facts, lookup) do
    case {review_rules(d, kind), get_in(d, ["flow_runtime", "flags", kind])} do
      {[], nil} ->
        {:ok, facts}

      {rules, _flag} ->
        with {:ok, lists} <- rule_reads(d, rules, facts, lookup) do
          {:ok, Enum.map(facts, &Map.put(&1, :review, review_of(d, lists, kind, &1)))}
        end
    end
  end

  # -- Late --------------------------------------------------------------------------------

  @doc """
  Whether a fact with `values` of `kind` is late at `now`: true or false when its kind has
  a rule and the fact has a time in `after`; nil otherwise.
  """
  def late(d, kind, values, now \\ DateTime.utc_now()) do
    with %{"after" => after_field, "while" => while}
         when is_binary(after_field) and
                is_binary(while) <-
           get_in(d, ["entities", kind, "late"]),
         text when is_binary(text) and text != "" <- (values || %{})[after_field],
         {:ok, at, _offset} <- DateTime.from_iso8601(text) do
      DateTime.compare(now, at) == :gt and (values[while] || "") not in ["", nil]
    else
      _ -> nil
    end
  end

  @doc """
  The first instant at which a fact with `values` of `kind` turns late by time alone
  (an ISO 8601 text): while it is not late at `now`, has a time in `after` and something
  in `while`. Nil otherwise: late already, never by time, or without a rule.
  """
  def until(d, kind, values, now \\ DateTime.utc_now()) do
    with %{"after" => after_field, "while" => while}
         when is_binary(after_field) and is_binary(while) <-
           get_in(d, ["entities", kind, "late"]),
         text when is_binary(text) and text != "" <- (values || %{})[after_field],
         {:ok, at, _offset} <- DateTime.from_iso8601(text),
         true <- (values[while] || "") not in ["", nil],
         true <- DateTime.compare(now, at) != :gt do
      at |> DateTime.add(1, :microsecond) |> DateTime.to_iso8601()
    else
      _ -> nil
    end
  end
end
