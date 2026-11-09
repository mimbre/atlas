defmodule AtlasFacts.Guards do
  @moduledoc """
  The write rules a kind's description can give (`rela/atlas.json`, per kind), which Facts
  checks before it stores a fact, so no client, agent or migration gets past them. Pure;
  knows no kind by name. A condition (`when`, `of`, `only_kind_when`) is shaped as a flow
  state's `values`: `%{property => [value, ...]}`, each property one of its values.

  - `requires`: `[%{"when", "fields", "error"}]`: a fact whose values hold `when` has each
    of `fields`.
  - `only_target`: relation rules collected from the description: only the linked fact
    itself, or a writer named in `also`, changes the relation. Replacing or removing a
    link requires being its old target too; sending the same links changes nothing.
  - `authority`: `%{"when", "by", "kind", "only_kind_when", "delegated_by", "error",
    "writes", "writer_error", "also"}`: a fact that holds `when` links through `by` to one
    fact; of `kind` when any of `only_kind_when` holds, otherwise of `kind` or with a link
    through `delegated_by`. A write that sets a property to one of its values in `writes`
    (shaped as `when`; a value it already has is not set) is the decision itself: it is
    stored only when its writer (the write's `by`) is the fact `by` links to, or one of
    `also`, and that fact may decide it as above (`writer_error` says why not).
  With `decider` instead, `kind` is always allowed and `agent_kind` is allowed only
  by a fresh agent verdict. The `verdict` environment callback looks up the newest
  verdict by gate and subject; the guard binds its fingerprint to the candidate write.

  - `layering`: `%{"relation", "field", "not", "error"}`: a fact whose `field` is a key of
    `not` may not link through `relation` to a fact whose `field` is one of that key's
    values, nor may a fact take a value in `not` while such a fact links to it
    ({key}, {value}, {other}, {other_value}).
  - `frozen`: `%{"when", "only", "error"}`: a fact that holds `when` is never deleted, and a
    change may only set the properties of `only` to one of their values; no links.
  - `replaces`: `%{"relation", "when", "of", "set", "error"}`: a fact stored holding `when`
    sets `set` on every fact it links to through `relation` (`replaced/3`, in the same
    write), and each of those must hold `of`.
  - `sealed`: `%{"once", "links", "error", "once_error"}`: a record, immutable once
    written. A stored fact is never deleted, and a change keeps every property and link it
    has (`error`, with {key} and {field}), except those named in `once` (properties or
    relations, such as outcomes observed afterwards) and, with `"links" => "once"`, every
    relation: each may be set while it is empty, and is then kept too (`once_error`).
    Sending what is there already changes nothing.

  A fact is `%{"values" => %{property => value}, "links" => %{relation => [key]}}`.
  """

  @doc "The rules of `kind` in the description; an empty map when it has none."
  def of(description, kind) do
    spec = get_in(description, ["entities", kind]) || %{}
    rules = Map.take(spec, ["requires", "authority", "frozen", "replaces", "layering", "sealed"])

    rules =
      case description["flow_runtime"] do
        %{"kind" => ^kind, "writer" => writer} -> Map.put(rules, "machine_writer", writer)
        _ -> rules
      end

    only_target =
      for {name, relation} <- description["relations"] || %{},
          kind in List.wrap(relation["from"]),
          is_map(relation["only_target"]),
          into: %{},
          do: {name, relation["only_target"]}

    if only_target == %{}, do: rules, else: Map.put(rules, "only_target", only_target)
  end

  @doc """
  Whether `op` on a fact may be stored: `:ok` or `{:refused, reasons}`. `current` is the
  fact as stored (nil for a new one), `values` and `links` what the write sets,
  `env` what the rules may look up: `"writer"` (who sends the write, as Control says),
  `"kind_of"` (`fn relation, key -> kind`, the kind of a linked fact), `"fetch"`
  (`fn key -> values`, a fact of the same kind, nil when there is none) and `"incoming"`
  (`fn relation -> [key]`, the facts that link to this one through it).
  """
  def check(rules, _op, _key, _current, _values, _links, _env) when rules == %{}, do: :ok

  def check(rules, op, key, current, values, links, env) do
    kind_of = env["kind_of"] || fn _, _ -> nil end
    verdict = env["verdict"] || fn _, _ -> nil end
    authority_rule = rules["authority"]

    authority_rule =
      case authority_rule do
        %{"decider" => config} ->
          # Bind the verdict to the candidate write, so editing a deciding field in the
          # acceptance itself cannot reuse authority for the old subject.
          fact = after_write(current, values, links)
          newest = verdict.(config["gate"], key)

          fresh =
            is_map(newest) and
              newest["fingerprint"] == AtlasBus.SubjectFingerprint.of(fact, config["fingerprint"])

          Map.put(authority_rule, "decider_outcome", if(fresh, do: newest["verdict"]))

        other ->
          other
      end

    fetch = env["fetch"] || fn _ -> nil end

    with :ok <- machine_writer(rules["machine_writer"], env),
         :ok <- sealed(rules["sealed"], op, key, current, values, links),
         :ok <- frozen(rules["frozen"], op, key, current, values, links) do
      if op == "delete" do
        :ok
      else
        fact = after_write(current, values, links)

        reasons =
          only_target(rules["only_target"], current, links, env["writer"]) ++
            requires(rules["requires"], fact) ++
            authority(authority_rule, fact, kind_of) ++
            decides(authority_rule, current, values, fact, env["writer"], kind_of) ++
            replaces(rules["replaces"], key, fact, fetch) ++
            layering(rules["layering"], key, current, fact, fetch, env["incoming"])

        if reasons == [], do: :ok, else: {:refused, reasons}
      end
    end
  end

  @doc """
  The keys of the facts a stored `fact` replaces and that are not yet marked: what Facts
  then sets `replaces.set` on, with that map.
  """
  def replaced(%{"replaces" => %{"relation" => relation, "set" => set} = rule}, fact, fetch)
      when is_map(set) do
    if holds?(rule["when"], fact["values"]) do
      for key <- List.wrap(get_in(fact, ["links", relation])),
          values = fetch.(key),
          is_map(values),
          not Enum.all?(set, fn {name, value} -> loose(values[name]) == loose(value) end),
          do: key
    else
      []
    end
  end

  def replaced(_rules, _fact, _fetch), do: []

  defp machine_writer(nil, _env), do: :ok

  defp machine_writer(rule, env) do
    if env["writer"] == rule["by"] and env["sender"] == rule["sender"],
      do: :ok,
      else: {:refused, ["only the configured machine writer may write this kind"]}
  end

  defp only_target(rules, current, links, writer) do
    for {relation, rule} <- rules || %{},
        Map.has_key?(links, relation),
        was = List.wrap(get_in(current || %{}, ["links", relation])),
        keys = List.wrap(links[relation]),
        Enum.sort(was) != Enum.sort(keys),
        not (is_binary(writer) and
               (writer in List.wrap(rule["also"]) or
                  Enum.all?(was ++ keys, &(&1 == writer)))),
        do: rule["error"] || "only the target sets #{relation}, to themselves"
  end

  defp frozen(%{"when" => condition} = rule, op, key, %{} = current, values, links) do
    if holds?(condition, current["values"]) do
      only = rule["only"] || %{}

      allowed? =
        op != "delete" and
          Enum.all?(values, fn {name, value} ->
            loose(value) == loose(current["values"][name]) or
              (Map.has_key?(only, name) and loose(value) in loose_all(only[name]))
          end) and
          Enum.all?(links, fn {relation, keys} ->
            Enum.sort(keys) == Enum.sort(List.wrap(get_in(current, ["links", relation])))
          end)

      if allowed?, do: :ok, else: {:refused, [fill(rule["error"], key, current, condition)]}
    else
      :ok
    end
  end

  defp frozen(_rule, _op, _key, _current, _values, _links), do: :ok

  # A record keeps what it was written with; a `once` field is set while it is empty, then kept.
  defp sealed(%{} = rule, op, key, %{} = current, values, links) do
    once = List.wrap(rule["once"])
    old_values = current["values"] || %{}
    old_links = current["links"] || %{}

    fields =
      for {name, value} <- values,
          loose(value) != loose(old_values[name]),
          do: {name, loose(old_values[name]) == nil}

    relations =
      for {relation, keys} <- links,
          was = List.wrap(old_links[relation]),
          Enum.sort(List.wrap(keys)) != Enum.sort(was),
          do: {relation, was == []}

    once = if rule["links"] == "once", do: once ++ Enum.map(relations, &elem(&1, 0)), else: once

    reasons =
      if op == "delete" do
        [seal_error(nil, key, "")]
      else
        for {name, empty?} <- fields ++ relations, not (empty? and name in once) do
          if name in once,
            do: seal_error(rule["once_error"] || rule["error"], key, name),
            else: seal_error(rule["error"], key, name)
        end
      end

    if reasons == [], do: :ok, else: {:refused, Enum.uniq(reasons)}
  end

  defp sealed(_rule, _op, _key, _current, _values, _links), do: :ok

  defp seal_error(nil, key, ""), do: "#{key} is a record and is never deleted"
  defp seal_error(nil, key, field), do: "#{key} is a record; #{field} is never changed"

  defp seal_error(text, key, field),
    do: text |> String.replace("{key}", key) |> String.replace("{field}", field)

  defp requires(rules, fact) do
    for rule <- List.wrap(rules),
        is_map(rule),
        holds?(rule["when"], fact["values"]),
        missing = Enum.filter(List.wrap(rule["fields"]), &(loose(fact["values"][&1]) == nil)),
        missing != [],
        do: rule["error"] || "#{Enum.join(missing, ", ")} is required"
  end

  defp authority(%{"when" => condition, "by" => by} = rule, fact, kind_of) do
    if holds?(condition, fact["values"]) and not may_decide?(rule, fact, kind_of),
      do: [rule["error"] || "#{by} may not decide this"],
      else: []
  end

  defp authority(_rule, _fact, _kind_of), do: []

  # The fact `by` links to may decide it: of `kind`, or delegated where nothing leaves it to
  # `kind` alone.
  defp may_decide?(%{"decider" => _, "by" => by, "kind" => kind} = rule, fact, kind_of) do
    case List.wrap(get_in(fact, ["links", by])) do
      [one] ->
        actor_kind = kind_of.(by, one)

        actor_kind == kind or
          (actor_kind in List.wrap(rule["agent_kind"]) and
             rule["decider_outcome"] in ["agent", "agent_unverified"])

      _ ->
        false
    end
  end

  defp may_decide?(%{"by" => by, "kind" => kind} = rule, fact, kind_of) do
    only_kind? = Enum.any?(List.wrap(rule["only_kind_when"]), &holds?(&1, fact["values"]))
    delegated? = List.wrap(get_in(fact, ["links", rule["delegated_by"] || ""])) != []

    case List.wrap(get_in(fact, ["links", by])) do
      [one] ->
        by_kind = kind_of.(by, one)
        by_kind == kind or (by_kind != nil and not only_kind? and delegated?)

      _ ->
        false
    end
  end

  defp may_decide?(_rule, _fact, _kind_of), do: false

  # A write that decides (sets a value of `writes`) comes from the one who decides.
  defp decides(%{"writes" => writes} = rule, current, values, fact, writer, kind_of)
       when is_map(writes) do
    old = (current || %{})["values"] || %{}

    sets? =
      Enum.any?(writes, fn {name, allowed} ->
        Map.has_key?(values, name) and loose(values[name]) != loose(old[name]) and
          loose(values[name]) in loose_all(allowed)
      end)

    decider = List.wrap(get_in(fact, ["links", rule["by"]]))

    cond do
      not sets? ->
        []

      is_binary(writer) and writer in List.wrap(rule["also"]) ->
        []

      is_binary(writer) and decider == [writer] and may_decide?(rule, fact, kind_of) ->
        []

      true ->
        [rule["writer_error"] || "only the one #{rule["by"]} names decides it"]
    end
  end

  defp decides(_rule, _current, _values, _fact, _writer, _kind_of), do: []

  # A fact on one level never follows from one on a level it may not depend on, and a fact
  # does not move to such a level while facts on the first follow from it.
  defp layering(
         %{"relation" => relation, "field" => field, "not" => banned} = rule,
         key,
         current,
         fact,
         fetch,
         incoming
       )
       when is_map(banned) do
    value = loose(fact["values"][field])
    error = rule["error"] || "{key} may not #{relation} {other}"

    outgoing =
      for other <- List.wrap(get_in(fact, ["links", relation])),
          values = fetch.(other),
          is_map(values),
          loose(values[field]) in loose_all(banned[value]),
          do: layer_error(error, key, value, other, loose(values[field]))

    old = loose(get_in(current || %{}, ["values", field]))

    incoming =
      if current != nil and value != old and is_function(incoming, 1) do
        for other <- incoming.(relation),
            values = fetch.(other),
            is_map(values),
            other_value = loose(values[field]),
            value in loose_all(banned[other_value]),
            do: layer_error(error, other, other_value, key, value)
      else
        []
      end

    outgoing ++ incoming
  end

  defp layering(_rule, _key, _current, _fact, _fetch, _incoming), do: []

  defp layer_error(text, key, value, other, other_value) do
    text
    |> String.replace("{key}", key)
    |> String.replace("{value}", value || "")
    |> String.replace("{other}", other)
    |> String.replace("{other_value}", other_value || "")
  end

  defp replaces(%{"relation" => relation} = rule, key, fact, fetch) do
    if holds?(rule["when"], fact["values"]) do
      for old <- List.wrap(get_in(fact, ["links", relation])),
          # A generator, not a match: a fact that is not there must count too.
          values <- [if(old == key, do: nil, else: fetch.(old))],
          not (is_map(values) and holds?(rule["of"], values)),
          do: fill(rule["error"], old, nil, nil)
    else
      []
    end
  end

  defp replaces(_rule, _key, _fact, _fetch), do: []

  # The fact as it is once the write is stored: its values with the given ones over them
  # (nil or "" removes one), and each relation the write names replaced.
  defp after_write(current, values, links) do
    current = current || %{}

    %{
      "values" =>
        (current["values"] || %{})
        |> Map.merge(values)
        |> Map.reject(fn {_, v} -> v in [nil, ""] end),
      "links" => Map.merge(current["links"] || %{}, links)
    }
  end

  defp holds?(condition, values) when is_map(condition) and condition != %{} do
    Enum.all?(condition, fn {name, allowed} ->
      loose((values || %{})[name]) in loose_all(allowed)
    end)
  end

  defp holds?(_condition, _values), do: false

  defp fill(nil, key, _current, _condition), do: "#{key} may not be changed so"

  defp fill(text, key, current, condition) do
    value =
      case condition do
        %{} -> condition |> Map.keys() |> Enum.map_join(", ", &loose(current["values"][&1]))
        _ -> ""
      end

    text |> String.replace("{key}", key) |> String.replace("{value}", value)
  end

  defp loose_all(values), do: values |> List.wrap() |> Enum.map(&loose/1)

  defp loose(value) when value in [nil, ""], do: nil
  defp loose(value), do: to_string(value)
end
