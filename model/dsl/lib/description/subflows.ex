defmodule RelaDSL.Description.Subflows do
  @moduledoc """
  The checks between a composition's subflows and its description: every kind, field,
  relation, role and value a subflow, a `link` or `count`, a `select` or a `migrate`
  names resolves in the composition. Returns `[{file, line, message}]`.
  """

  @writer "atlas-flow"

  @doc "Problems of `flows` (with the composition's `links` and `counts`) against `schema` and the `acl`."
  def check(flows, composition, schema, acl) do
    # Without an acl, Rela knows no role: every role a subflow names is unknown.
    acl = acl || %{roles: %{}, assignments: %{}}

    Enum.flat_map(flows, &flow(&1, schema, acl)) ++
      Enum.flat_map(
        composition.links ++ composition.counts,
        &link(&1, flows, schema, composition.file)
      ) ++
      Enum.flat_map(composition.tallies, &tally(&1, schema, composition.file))
  end

  defp flow(f, schema, acl) do
    kind = to_string(f.subject)
    at = fn line, message -> {f.file, line, "subflow #{f.name}: " <> message} end

    if not Map.has_key?(schema["entities"], kind) do
      [at.(f.line, "its subject #{kind} is not a kind of the composition")]
    else
      owner(f.owner, kind, schema, &at.(f.line, &1)) ++
        run_as(f, acl, &at.(f.line, &1)) ++
        Enum.flat_map(f.states, fn s ->
          here = &at.(s.line, "state #{s.name}: " <> &1)

          fields(s, kind, schema, here) ++
            roles(s, acl, here) ++
            creates(s, kind, schema, here) ++
            owner(s.owner, kind, schema, here) ++ present(s.present, kind, schema, here)
        end)
    end
  end

  defp field?(schema, kind, name),
    do: Map.has_key?(get_in(schema, ["entities", kind, "properties"]) || %{}, to_string(name))

  defp relation(schema, name), do: schema["relations"][to_string(name)]

  defp from?(schema, name, kind), do: kind in ((relation(schema, name) || %{})["from"] || [])

  defp fields(s, kind, schema, here) do
    read =
      for b <- s.branches,
          b.when != nil,
          [_, name] <- Regex.scan(~r/\bentity\.([a-z][a-z0-9_]*)/, b.when),
          do: name

    written = for {name, _} <- s.set, do: to_string(name)

    for name <- Enum.uniq(read ++ written ++ Enum.map(s.awaits, &to_string/1)),
        not field?(schema, kind, name),
        do: here.("names #{kind}.#{name}, which the composition does not describe")
  end

  defp roles(s, acl, here) do
    for role <- Enum.uniq(s.waiting_for ++ Enum.flat_map(s.branches, & &1.roles)),
        role != @writer,
        not Map.has_key?(acl.roles, role),
        do: here.("names the role #{role}, which the composition's acl does not define")
  end

  defp run_as(%{run_as: nil}, _acl, _here), do: []

  defp run_as(f, acl, here) do
    if Map.has_key?(acl.assignments, f.run_as),
      do: [],
      else: [here.("run_as #{f.run_as} is not assigned a role in the composition's acl")]
  end

  defp creates(s, kind, schema, here) do
    Enum.flat_map(s.creates, fn c ->
      type = to_string(c.type)

      cond do
        not Map.has_key?(schema["entities"], type) ->
          [here.("creates a #{type}, which is not a kind of the composition")]

        true ->
          for(
            {name, _} <- c.properties,
            not field?(schema, type, name),
            do: here.("creates a #{type} with #{name}, which #{type} does not have")
          ) ++
            if(
              c.relate == nil or
                (from?(schema, c.relate, type) and
                   kind in (relation(schema, c.relate)["to"] || [])),
              do: [],
              else: [
                here.(
                  "relates the created #{type} by #{c.relate}, which does not lead from #{type} to #{kind}"
                )
              ]
            )
      end
    end)
  end

  defp owner(nil, _kind, _schema, _here), do: []

  defp owner(o, kind, schema, here) do
    via = if o[:via], do: to_string(o.via), else: kind

    if(o[:via] && not Map.has_key?(schema["entities"], via),
      do: [here.("owner via #{via}, which is not a kind of the composition")],
      else: []
    ) ++
      if(o[:via] && o[:relation] && not from?(schema, o.relation, via),
        do: [here.("owner relation #{o.relation} does not lead from #{via}")],
        else: []
      ) ++
      case o[:default] do
        %{kind: k} ->
          if Map.has_key?(schema["entities"], to_string(k)),
            do: [],
            else: [here.("owner default kind #{k} is not a kind of the composition")]

        _ ->
          []
      end
  end

  defp present(nil, _kind, _schema, _here), do: []

  defp present(p, kind, schema, here) do
    section =
      if p.section && not field?(schema, kind, p.section.field),
        do: [here.("presents the section of #{p.section.field}, which #{kind} does not have")],
        else: []

    answers =
      Enum.flat_map(p.answers, fn a ->
        rel = a[:set] || a[:remove] || (a[:change] && a.change[:self])
        values = (a[:change] && a.change[:values]) || %{}

        if(rel && not from?(schema, rel, kind),
          do: [here.("answer #{a[:key]} names #{rel}, which does not lead from #{kind}")],
          else: []
        ) ++
          for {name, _} <- values,
              not field?(schema, kind, name),
              do: here.("answer #{a[:key]} writes #{kind}.#{name}, which #{kind} does not have")
      end)

    section ++ answers
  end

  defp link(l, flows, schema, file) do
    child = Enum.find(flows, &(&1.name == l.child))

    case {child, l.relation} do
      {nil, _} ->
        []

      {_, nil} ->
        []

      {child, relation} ->
        from = to_string(child.subject)
        to = to_string(l.subject)
        at = &{file, l[:line] || 1, &1}

        if(
          from?(schema, relation, from) and
            to in ((relation(schema, relation) || %{})["to"] || []),
          do: [],
          else: [
            at.(
              "#{relation} does not lead from #{from} to #{to}, as the link or count of #{l.child} says"
            )
          ]
        ) ++ link_fields(l, from, to, schema, at)
    end
  end

  defp tally(t, schema, file) do
    for problem <- tally_problems(t, schema), do: {file, t[:line] || 1, tally_message(problem)}
  end

  @doc """
  The problems of tally `t` (`%{relation, subject, all}`) against `schema`: its relation
  ends at its parent (`{:not_to_parent, relation, parent}`), and the field it writes is
  the parent's (`{:no_field, relation, parent, field}`).
  """
  def tally_problems(%{relation: relation, subject: subject} = t, schema)
      when relation != nil and subject != nil do
    parent = to_string(subject)

    if(parent in ((relation(schema, relation) || %{})["to"] || []),
      do: [],
      else: [{:not_to_parent, relation, parent}]
    ) ++
      if(t.all == nil or field?(schema, parent, t.all),
        do: [],
        else: [{:no_field, relation, parent, t.all}]
      )
  end

  def tally_problems(_t, _schema), do: []

  defp tally_message({:not_to_parent, relation, parent}),
    do: "tally #{relation}: #{relation} does not lead to #{parent}"

  defp tally_message({:no_field, relation, parent, field}),
    do: "tally #{relation} names #{parent}.#{field}, which #{parent} does not have"

  # The fields a link or count writes on the parent, and those that say which child is
  # current, exist on their kinds.
  defp link_fields(l, child, parent, schema, at) do
    written = for k <- [:field, :all, :open], is_atom(l[k]) and l[k] != nil, do: l[k]

    {by_child, by_parent} =
      case l[:current] do
        {c, p} when is_atom(c) and is_atom(p) -> {[c], [p]}
        _ -> {[], []}
      end

    for(
      name <- written ++ by_parent,
      not field?(schema, parent, name),
      do:
        at.(
          "the link or count of #{l.child} names #{parent}.#{name}, which #{parent} does not have"
        )
    ) ++
      for name <- by_child,
          not field?(schema, child, name),
          do: at.("the link of #{l.child} names #{child}.#{name}, which #{child} does not have")
  end

  @doc "Problems of the `select`s of the subflows the composition runs."
  def selects(selects, flows, schema) do
    Enum.flat_map(selects, fn %{value: {name, o}} = i ->
      at = &{i.file, i.line, "select #{name}: " <> &1}

      case Enum.find(flows, &(&1.name == name)) do
        nil ->
          []

        f ->
          kind = to_string(f.subject)
          states = Enum.map(f.states, &to_string(&1.name))
          projection = o[:projection] || []
          on = projection[:on] && relation(schema, projection[:on])
          target = on && List.first(on["to"] || [])

          for(
            c <- o[:choices] || [],
            not field?(schema, kind, c),
            do: at.("choice #{c} is not a field of #{kind}")
          ) ++
            if(
              (o[:choices] || []) != [] and
                RelaDSL.Description.Build.choice_states(f, o[:choices]) == [],
              do: [
                at.(
                  "no state of #{name} waits for people to choose #{Enum.join(o[:choices] || [], ", ")}"
                )
              ],
              else: []
            ) ++
            for(
              {role, rel} <- o[:roles] || [],
              not from?(schema, rel, kind),
              do: at.("roles: #{role} names #{rel}, which does not lead from #{kind}")
            ) ++
            for(
              {role, _} <- o[:roles] || [],
              to_string(role) not in Enum.flat_map(f.states, & &1.waiting_for),
              do: at.("roles: #{name} waits for no #{role}")
            ) ++
            if(projection[:on] && not from?(schema, projection[:on], kind),
              do: [at.("projection on #{projection[:on]} does not lead from #{kind}")],
              else: []
            ) ++
            for(
              k <- [:state_field, :deadline_field, :handover_field, :field],
              target,
              projection[k],
              not field?(schema, target, projection[k]),
              do: at.("projection #{k} #{projection[k]} is not a field of #{target}")
            ) ++
            if(
              target && projection[:owner_relation] &&
                not from?(schema, projection[:owner_relation], target),
              do: [
                at.(
                  "projection owner_relation #{projection[:owner_relation]} does not lead from #{target}"
                )
              ],
              else: []
            ) ++
            values(schema, kind, o[:admission], at) ++
            Enum.flat_map(
              List.wrap(o[:imports]),
              fn imp ->
                values(schema, kind, imp[:when], at) ++
                  if(to_string(imp[:state]) in states,
                    do: [],
                    else: [at.("imports state #{imp[:state]}, which #{name} does not have")]
                  ) ++
                  if(Keyword.has_key?(imp, :completed) and not is_boolean(imp[:completed]),
                    do: [at.("an import row's completed is true or false")],
                    else: []
                  )
              end
            ) ++
            if(Keyword.has_key?(o, :reopen) and o[:reopen] not in [:explicit, :new_generation],
              do: [at.("reopen: #{inspect(o[:reopen])} is neither :explicit nor :new_generation")],
              else: []
            ) ++ verification(schema, kind, o[:verification], at)
      end
    end)
  end

  defp values(_schema, _kind, nil, _at), do: []

  defp values(schema, kind, mapping, at) do
    Enum.flat_map(mapping, fn {field, allowed} ->
      prop = get_in(schema, ["entities", kind, "properties", to_string(field)])
      enum = prop && get_in(schema, ["types", prop["type"], "values"])

      cond do
        prop == nil ->
          [at.("#{field} is not a field of #{kind}")]

        # nil allows no value: the field empty.
        enum && Enum.any?(List.wrap(allowed), &(&1 != nil and to_string(&1) not in enum)) ->
          [at.("#{kind}.#{field} has no value among #{inspect(allowed)}")]

        true ->
          []
      end
    end)
  end

  # The verdict kind whose relations clear the subject's field.
  defp verification(_schema, _subject, nil, _at), do: []

  defp verification(schema, subject, v, at) do
    kind = to_string(v[:kind])

    if Map.has_key?(schema["entities"], kind) do
      if(field?(schema, subject, v[:field]),
        do: [],
        else: [at.("verification field #{v[:field]} is not a field of #{subject}")]
      ) ++
        for r <- v[:relations] || [],
            not from?(schema, r, kind),
            do: at.("verification relation #{r} does not lead from #{kind}")
    else
      [at.("verification kind #{kind} is not a kind of the composition")]
    end
  end
end
