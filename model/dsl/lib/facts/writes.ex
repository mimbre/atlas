defmodule RelaDSL.Facts.Writes do
  @moduledoc """
  The write rules a model gives its kinds and relations, which a store checks before it
  stores a fact (`check/5`), and what a write brings along (`with_change/4`): evaluated
  on the model's compiled description `d` (rela's schema as served, with the model's
  additions over it; `RelaDSL.Facts.Model`). Pure; knows no kind by name. A condition
  (`when`, `of`, `only_kind_when`) is shaped as a flow state's `values`:
  `%{property => [value, ...]}`, each property one of its values.

  Per kind:

  - `requires`: `[%{"when", "fields", "error"}]`: a fact whose values hold `when` has each
    of `fields`.
  - `authority`: `%{"when", "by", "kind", "only_kind_when", "delegated_by", "error",
    "writes", "writer_error", "also"}`: a fact that holds `when` links through `by` to one
    fact; of `kind` when any of `only_kind_when` holds, otherwise of `kind` or with a link
    through `delegated_by`. A write that sets a property to one of its values in `writes`
    (shaped as `when`; a value it already has is not set) decides: it is stored only when
    its writer (the write's `by`) is the fact `by` links to, or one of `also`, and that
    fact may decide it as above (`writer_error` says why not). With `decider` instead,
    `kind` is always allowed and `agent_kind` only by a fresh verdict of the decider
    gate (`decider.gate`, of `decider.kind`, linked through `decider.relation`), bound
    to the write by its fingerprint. A change that decides and does not link its writer
    through `by` yet gets that link (`with_change/4`).
  - `layering`: `%{"relation", "field", "not", "error"}`: a fact whose `field` is a key of
    `not` may not link through `relation` to a fact whose `field` is one of that key's
    values, nor may a fact take a value in `not` while such a fact links to it
    ({key}, {value}, {other}, {other_value}).
  - `frozen`: `%{"when", "only", "error"}`: a fact that holds `when` is never deleted, and a
    change may only set the properties of `only` to one of their values; no links.
  - `replaces`: `%{"relation", "when", "of", "set", "error"}`: a fact stored holding `when`
    sets `set` on every fact it links to through `relation` (in the same write,
    `with_change/4`), and each of those must hold `of`.
  - `sealed`: `%{"once", "links", "error", "once_error"}`: a record, immutable once
    written. A stored fact is never deleted, and a change keeps every property and link it
    has (`error`, with {key} and {field}), except those named in `once` (properties or
    relations) and, with `"links" => "once"`, every relation: each may be set while it is
    empty, and is then kept too (`once_error`). Sending what is there already changes
    nothing.
  - `delete_error`: a fact of the kind is never deleted; the text says why.
  - fields `set_by` the run writer only (`flow_runtime.writer.by`) are written by it alone;
    the kind runs are kept in (`flow_runtime.kind`) too.

  Per relation:

  - `only_target`: only the linked fact itself, or a writer named in `also`, changes the
    relation. Replacing or removing a link requires being its old target too; sending the
    same links changes nothing.
  - `set_by`: only a writer named there (or `<name>/…`, a connector of a system) changes it.
  - `limit`: `%{"max", "field", "values", "error"}`: a new link to a parent through it is
    refused while `max` facts of the kind whose `field` is one of `values` point at that
    parent already ({parent}, {child}, {value}).
  - `closes_parent` (text): on a relation that starts at a parent kind, a fact with a link
    through it is closed: no fact goes under it through a parent relation ({parent},
    {kind}, {child}).
  - `requires_completed_children` (text): a new link through it is refused while a fact
    under the linking fact is not completed ({key}, {children}).
  - `component`: `%{"key", "values"}` with `{key}`: the one fact of the kind it points at
    that is made with a fact of a kind it starts at, before it, and deleted with it; it
    is never deleted alone while that fact exists.

  `lookup` is the store's reader, as `RelaDSL.Facts.Model` describes it.
  """

  @doc "Whether the change of a fact of `kind` may be stored: `:ok` or `{:refuse, reasons}`."
  def check(d, kind, change, actor, lookup) do
    op = change["op"]
    key = change["key"]
    links = change["links"] || %{}

    result =
      with :ok <- relations(d, kind, op, key, links, actor, lookup),
           :ok <- not_a_part(d, kind, op, key, lookup) do
        guarded(d, kind, op, key, change["values"] || %{}, links, actor, lookup)
      end

    case result do
      :ok -> :ok
      {:refused, reasons} -> {:refuse, reasons}
    end
  end

  @doc """
  The changes one write of a fact of `kind` makes, in order: on a create its components
  (`"as" => "component"`, each with the `relation` that links the fact to it), the fact's
  own change (`"as" => "fact"`, with the link to its writer when it decides) and the
  facts it replaces (`"as" => "replaced"`, the values to set); on a delete the fact's own
  change, then its components.
  """
  def with_change(d, kind, change, lookup) do
    op = change["op"]
    key = change["key"]
    own = change |> decider_link(d, kind, lookup) |> Map.merge(%{"as" => "fact", "kind" => kind})

    parts =
      for {relation, to, part, values} <- components(d, kind, key),
          do: %{
            "as" => "component",
            "relation" => relation,
            "kind" => to,
            "key" => part,
            "op" => if(op == "delete", do: "delete", else: "create"),
            "values" => values
          }

    case op do
      "create" -> parts ++ [own] ++ replaced(d, kind, own, lookup)
      "change" -> [own] ++ replaced(d, kind, own, lookup)
      "delete" -> [own | parts]
      _ -> [own]
    end
  end

  # -- What a write brings along ----------------------------------------------------------

  defp components(d, kind, key) do
    for {relation, %{"component" => %{"key" => template} = component} = spec} <-
          Enum.sort(d["relations"] || %{}),
        kind in (spec["from"] || []),
        [to] <- [spec["to"]] do
      values = Map.new(component["values"] || %{}, fn {name, text} -> {name, fill(text, key)} end)
      {relation, to, fill(template, key), values}
    end
  end

  defp component_owners(d, kind) do
    for {relation, %{"component" => %{}, "to" => [^kind]} = spec} <-
          Enum.sort(d["relations"] || %{}),
        do: {relation, spec["from"] || []}
  end

  defp fill(text, key) when is_binary(text), do: String.replace(text, "{key}", key)
  defp fill(value, _key), do: value

  # A change that sets a value that decides (one it does not have yet) links its writer as
  # the one who decides through `by`, unless it links them already.
  defp decider_link(%{"op" => "change"} = change, d, kind, lookup) do
    by = change["by"]

    with %{"by" => relation, "writes" => %{} = writes} <-
           get_in(d, ["entities", kind, "authority"]),
         true <- is_binary(by) and by != "",
         values = normalized(change["values"] || %{}),
         true <- Enum.any?(writes, fn {field, _} -> Map.has_key?(values, field) end),
         current = lookup["current"].() || %{},
         old = current["values"] || %{},
         true <-
           Enum.any?(writes, fn {field, allowed} ->
             Map.has_key?(values, field) and loose(values[field]) != loose(old[field]) and
               loose(values[field]) in loose_all(allowed)
           end),
         true <- List.wrap(get_in(current, ["links", relation])) != [by] do
      Map.update(change, "links", %{relation => [by]}, &Map.put(&1 || %{}, relation, [by]))
    else
      _ -> change
    end
  end

  defp decider_link(change, _d, _kind, _lookup), do: change

  # The facts a stored fact replaces and that are not marked yet, with what to set.
  defp replaced(d, kind, %{"op" => op} = own, lookup) when op in ["create", "change"] do
    case rules(d, kind) do
      %{"replaces" => %{"set" => set}} = rules when is_map(set) ->
        current = if op == "create", do: nil, else: lookup["current"].()
        fact = after_write(current, normalized(own["values"] || %{}), own["links"] || %{})

        for old <- replaced(rules, fact, fetch(kind, lookup)),
            do: %{
              "as" => "replaced",
              "kind" => kind,
              "op" => "change",
              "key" => old,
              "values" => set
            }

      _ ->
        []
    end
  end

  defp replaced(_d, _kind, _own, _lookup), do: []

  @doc """
  The keys of the facts a stored `fact` (`%{"values", "links"}`) replaces by `rules`
  (`rules/2`) and that are not marked yet; `fetch.(key)` gives one's values, or nil.
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

  # -- The rules of the relations a write links through ------------------------------------

  defp relations(d, kind, op, key, links, actor, lookup) when op in ["create", "change"] do
    rels = d["relations"] || %{}
    by = actor["by"]

    current = fn ->
      if op == "create", do: %{}, else: lookup["current"].() || %{}
    end

    new = fn relation ->
      List.wrap(links[relation]) -- List.wrap(get_in(current.(), ["links", relation]))
    end

    set_by =
      for {relation, keys} <- Enum.sort(links),
          %{"set_by" => names} <- [rels[relation]],
          names = List.wrap(names),
          Enum.sort(List.wrap(keys)) !=
            Enum.sort(List.wrap(get_in(current.(), ["links", relation]))),
          not named?(by, names),
          do: "only a #{Enum.join(names, " or ")} sets #{relation}"

    reasons =
      if set_by != [] do
        set_by
      else
        closed(d, kind, links, new, lookup) ++
          limits(d, kind, key, links, new, lookup) ++
          completed_children(d, kind, key, links, new, lookup)
      end

    if reasons == [], do: :ok, else: {:refused, reasons}
  end

  defp relations(_d, _kind, _op, _key, _links, _actor, _lookup), do: :ok

  defp named?(by, names),
    do: is_binary(by) and Enum.any?(names, &(by == &1 or String.starts_with?(by, &1 <> "/")))

  defp parent?(spec), do: spec["parent"] == true and spec["max_outgoing"] == 1

  # A new fact under a parent that is closed to it: an association of the parent marked
  # `closes_parent` has a link.
  defp closed(d, kind, links, new, lookup) do
    rels = d["relations"] || %{}

    for {relation, _} <- Enum.sort(links),
        %{"to" => [parent_kind]} = spec <- [rels[relation]],
        parent?(spec),
        kind in (spec["from"] || []),
        parent <- new.(relation),
        %{} = fact <- [lookup["fact"].(parent_kind, parent)],
        problem =
          Enum.find_value(Enum.sort(rels), fn {name, r} ->
            if not parent?(r) and parent_kind in (r["from"] || []) and
                 is_binary(r["closes_parent"]) and (fact.links[name] || []) != [] do
              r["closes_parent"]
              |> String.replace("{parent}", parent)
              |> String.replace("{kind}", String.downcase(label(d, parent_kind)))
              |> String.replace("{child}", String.downcase(label(d, kind)))
            end
          end),
        do: problem
  end

  # A new link to a parent that has as many counted facts of the kind as allowed.
  defp limits(d, kind, key, links, new, lookup) do
    for {relation, _} <- Enum.sort(links),
        %{"limit" => %{} = limit} <- [get_in(d, ["relations", relation])],
        parent <- new.(relation),
        problem = over_limit(d, kind, key, relation, limit, parent, lookup),
        problem != nil,
        do: problem
  end

  defp over_limit(d, kind, key, relation, limit, parent, lookup) do
    case lookup["list"].(kind) do
      {:ok, facts} ->
        field = limit["field"]
        allowed = limit["values"] || []

        counted =
          for fact <- facts,
              parent in (fact.links[relation] || []),
              fact.key != key,
              fact.properties[field] in allowed,
              do: fact

        if is_integer(limit["max"]) and length(counted) >= limit["max"] do
          [first | _] = Enum.sort_by(counted, & &1.key)
          value = first.properties[field]
          labels = get_in(d, ["entities", kind, "properties", field, "labels"]) || %{}

          (limit["error"] || "{parent} already has {child} ({value})")
          |> String.replace("{parent}", parent)
          |> String.replace("{child}", first.key)
          |> String.replace("{value}", labels[value] || to_string(value))
        end

      {:error, reason} ->
        "#{inspect(reason)}; could not check how many #{parent} has"
    end
  end

  # A new link through a relation that requires the facts under this one to be completed.
  defp completed_children(d, kind, key, links, new, lookup) do
    for {relation, _} <- Enum.sort(links),
        %{"requires_completed_children" => text} <- [get_in(d, ["relations", relation])],
        is_binary(text),
        kind in (get_in(d, ["relations", relation, "from"]) || []),
        new.(relation) != [],
        problem =
          (case RelaDSL.Facts.Derived.open_children(d, kind, key, lookup) do
             {:ok, []} ->
               nil

             {:ok, open} ->
               text
               |> String.replace("{key}", key)
               |> String.replace("{children}", Enum.join(Enum.sort(open), ", "))

             {:error, reason} ->
               "#{inspect(reason)}; could not check what is under #{key}"
           end),
        problem != nil,
        do: problem
  end

  defp label(d, kind) do
    get_in(d, ["entities", kind, "label"]) ||
      kind |> String.replace("_", " ") |> String.capitalize()
  end

  # A component goes with its fact, never alone while that fact exists.
  defp not_a_part(d, kind, "delete", key, lookup) do
    owners =
      for {relation, _from} <- component_owners(d, kind),
          owner <- lookup["incoming"].(kind, key, relation),
          do: owner

    case owners do
      [] -> :ok
      _ -> {:refused, ["#{key} goes with #{Enum.join(owners, ", ")}; delete that instead"]}
    end
  end

  defp not_a_part(_d, _kind, _op, _key, _lookup), do: :ok

  # -- The kind's rules --------------------------------------------------------------------

  defp guarded(d, kind, op, key, values, links, actor, lookup) do
    case rules(d, kind) do
      rules when rules == %{} ->
        :ok

      rules ->
        current = if op == "create", do: nil, else: lookup["current"].()
        values = normalized(values)

        check_rules(rules, op, key, current, values, links, %{
          "writer" => actor["by"],
          "sender" => actor["sender"],
          "kind_of" => fn relation, linked ->
            Enum.find(
              get_in(d, ["relations", relation, "to"]) || [],
              &(lookup["fact"].(&1, linked) != nil)
            )
          end,
          "verdict" => fn gate, subject ->
            config = get_in(rules, ["authority", "decider"]) || %{}
            verdict(d, config, gate, subject, lookup)
          end,
          "fetch" => fetch(kind, lookup),
          "fingerprint" => lookup["fingerprint"],
          "incoming" => fn relation -> lookup["incoming"].(kind, key, relation) end
        })
    end
  end

  defp normalized(values),
    do: Map.new(values, fn {k, v} -> {k, if(v == "", do: nil, else: v)} end)

  defp fetch(kind, lookup) do
    fn old ->
      case lookup["fact"].(kind, old) do
        %{properties: properties} -> properties
        _ -> nil
      end
    end
  end

  # The newest verdict of `gate` on `key`, read from the store.
  defp verdict(d, config, gate, key, lookup) do
    if is_binary(get_in(d, ["entities", config["kind"], "plural"])) do
      case lookup["list"].(config["kind"]) do
        {:ok, facts} -> newest(facts, gate, key, config["relation"])
        _ -> nil
      end
    end
  end

  @doc "The newest decider verdict of `gate` on `key` among `facts` (as rela gives them), or nil."
  def newest(facts, gate, key, relation) do
    facts
    |> Enum.filter(fn fact ->
      values = fact.properties

      values["gate"] == gate and values["subject"] == key and values["purpose"] == "decider" and
        key in List.wrap(get_in(fact, [:links, relation]))
    end)
    |> Enum.max_by(&{&1.properties["decided_at"] || "", &1.key}, fn -> nil end)
    |> case do
      nil -> nil
      fact -> fact.properties
    end
  end

  @doc "The rules of `kind` in `d`; an empty map when it has none."
  def rules(d, kind) do
    spec = get_in(d, ["entities", kind]) || %{}

    rules =
      Map.take(spec, [
        "requires",
        "authority",
        "frozen",
        "replaces",
        "layering",
        "sealed",
        "delete_error"
      ])

    machine = get_in(d, ["flow_runtime", "writer"])

    writers =
      for {field, p} <- spec["properties"] || %{},
          machine != nil and p["set_by"] == [machine["by"]],
          into: %{},
          do: {field, machine}

    rules = if writers == %{}, do: rules, else: Map.put(rules, "field_writers", writers)

    rules =
      case d["flow_runtime"] do
        %{"kind" => ^kind, "writer" => writer} -> Map.put(rules, "machine_writer", writer)
        _ -> rules
      end

    only_target =
      for {name, relation} <- d["relations"] || %{},
          kind in List.wrap(relation["from"]),
          is_map(relation["only_target"]),
          into: %{},
          do: {name, relation["only_target"]}

    if only_target == %{}, do: rules, else: Map.put(rules, "only_target", only_target)
  end

  @doc """
  Whether `op` on the fact `key` may be stored by a kind's `rules` (`rules/2`): `:ok` or
  `{:refused, reasons}`. `current` is the fact as stored (nil for a new one), `values` and
  `links` what the write sets, `env` what the rules may look up: `"writer"` (who sends
  the write), `"sender"` (its endpoint), `"kind_of"` (`fn relation, key -> kind`),
  `"fetch"` (`fn key -> values`, a fact of the same kind), `"incoming"` (`fn relation ->
  [key]`), `"verdict"` (`fn gate, key -> verdict`, the newest decider verdict) and
  `"fingerprint"` (`fn fact, spec -> digest`).
  """
  def check_rules(rules, _op, _key, _current, _values, _links, _env) when rules == %{}, do: :ok

  def check_rules(rules, op, key, current, values, links, env) do
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
              newest["fingerprint"] == env["fingerprint"].(fact, config["fingerprint"])

          Map.put(authority_rule, "decider_outcome", if(fresh, do: newest["verdict"]))

        other ->
          other
      end

    fetch = env["fetch"] || fn _ -> nil end

    with :ok <- deletable(rules["delete_error"], op),
         :ok <- field_writers(rules["field_writers"] || %{}, values, env),
         :ok <- machine_writer(rules["machine_writer"], env),
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

  defp deletable(message, "delete") when is_binary(message), do: {:refused, [message]}
  defp deletable(_, _), do: :ok

  defp field_writers(writers, values, env) do
    refused =
      for {field, writer} <- writers,
          Map.has_key?(values, field),
          machine_writer(writer, env) != :ok,
          do: field

    if refused == [], do: :ok, else: {:refused, ["protected fields: #{Enum.join(refused, ", ")}"]}
  end

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
