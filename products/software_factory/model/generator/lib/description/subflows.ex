defmodule RelaDSL.Description.Subflows do
  @moduledoc """
  The checks between a composition's subflows and its description: every kind, field,
  relation, role and value a subflow, a `link` or `count` or a `select`
  names resolves in the composition. Returns `[{file, line, problem}]`, each problem a
  `RelaDSL.Problem` (what is wrong, and the names it is about).
  """

  alias RelaDSL.Problem

  @writer "atlas-flow"

  @doc "Problems of `flows` (with the composition's `links` and `counts`) against `schema` and the `acl`."
  def check(flows, composition, schema, acl, extension \\ %{}) do
    # Without an acl, Rela knows no role: every role a subflow names is unknown.
    acl = acl || %{roles: %{}, assignments: %{}}

    Enum.flat_map(flows, &flow(&1, schema, acl, extension || %{})) ++
      Enum.flat_map(
        composition.links ++ composition.counts,
        &link(&1, flows, schema, composition.file)
      ) ++
      Enum.flat_map(composition.tallies, &tally(&1, schema, composition.file))
  end

  defp flow(f, schema, acl, extension) do
    kind = to_string(f.subject)
    at = fn line, problem -> {f.file, line, Problem.prefix(problem, "subflow #{f.name}: ")} end

    if not Map.has_key?(schema["entities"], kind) do
      [
        at.(
          f.line,
          problem(
            :subject_kind,
            [f.name, kind],
            "its subject #{kind} is not a kind of the composition"
          )
        )
      ]
    else
      owner(f.owner, kind, schema, &at.(f.line, &1)) ++
        run_as(f, acl, &at.(f.line, &1)) ++
        Enum.flat_map(f.states, fn s ->
          here = &at.(s.line, Problem.prefix(&1, "state #{s.name}: "))

          fields(s, kind, schema, here) ++
            roles(s, acl, here) ++
            creates(s, kind, schema, here) ++ snapshot_types(s, kind, schema, here) ++
            proposal_identity(s, schema, extension, here) ++
            owner(s.owner, kind, schema, here) ++ present(s.present, kind, schema, here)
        end)
    end
  end

  defp problem(tag, names, text), do: Problem.new(tag, Enum.map(names, &to_string/1), text)

  defp field?(schema, kind, name),
    do: Map.has_key?(get_in(schema, ["entities", kind, "properties"]) || %{}, to_string(name))

  defp relation(schema, name), do: schema["relations"][to_string(name)]

  defp from?(schema, name, kind), do: kind in ((relation(schema, name) || %{})["from"] || [])

  # The kinds of the facts made with a fact of `kind` (its components): their associations
  # are the fact's own, so a role may come through one.
  defp parts(schema, extension, kind) do
    for {name, %{"component" => %{}}} <- (extension || %{})["relations"] || %{},
        from?(schema, name, kind),
        part <- (relation(schema, name) || %{})["to"] || [],
        do: part
  end

  defp fields(s, kind, schema, here) do
    read =
      for b <- s.branches,
          b.when != nil,
          [_, name] <- Regex.scan(~r/\bentity\.([a-z][a-z0-9_]*)/, b.when),
          do: name

    written = for {name, _} <- s.set, do: to_string(name)

    findings =
      case s.mechanism do
        {:task, %{} = spec} ->
          for(
            name <- [spec[:findings], spec[:failure], asked_field(spec[:asks])],
            is_atom(name) and name != nil,
            do: to_string(name)
          ) ++ if(is_list(spec[:input]), do: update_field(spec[:input]), else: []) ++
            snapshot_fields(spec[:snapshot])

        _ ->
          []
      end

    for name <-
          Enum.uniq(read ++ written ++ findings ++ Enum.map(s.awaits, &to_string/1)),
        not field?(schema, kind, name),
        do:
          here.(
            problem(
              :unknown_field,
              [kind, name],
              "names #{kind}.#{name}, which the composition does not describe"
            )
          )
  end

  # The subject's field a task's questions go to (`asks:`).
  defp asked_field(asks) when is_list(asks), do: if(Keyword.keyword?(asks), do: asks[:field])
  defp asked_field(_asks), do: nil

  defp snapshot_fields(snapshot) when is_list(snapshot) do
    if Keyword.keyword?(snapshot),
      do: for(name <- Keyword.values(snapshot), is_atom(name) and name != nil, do: to_string(name)),
      else: []
  end

  defp snapshot_fields(_snapshot), do: []

  defp snapshot_types(%{mechanism: {:task, %{snapshot: snapshot}}}, kind, schema, here)
       when is_list(snapshot) do
    if Keyword.keyword?(snapshot) do
      for {key, type} <- [field: "string", into: "string", known: "boolean"],
          name = snapshot[key],
          is_atom(name) and name != nil,
          property = get_in(schema, ["entities", kind, "properties", to_string(name)]),
          is_map(property) and property["type"] != type do
        here.(problem(:snapshot_type, [kind, name], "snapshot names #{kind}.#{name}, which must be #{type}"))
      end
    else
      []
    end
  end

  defp snapshot_types(_state, _kind, _schema, _here), do: []

  defp proposal_identity(%{mechanism: {:task, %{creates: creates}}}, schema, extension, here)
       when is_list(creates) do
    if Keyword.keyword?(creates) and is_atom(creates[:kind]) and
         creates[:kind] != nil and is_atom(creates[:identity]) and creates[:identity] != nil do
      kind = to_string(creates[:kind])
      name = to_string(creates[:identity])
      property = get_in(schema, ["entities", kind, "properties", name])
      writers = get_in(extension, ["entities", kind, "properties", name, "set_by"])

      if is_map(property) and property["type"] == "string" and property["unique"] == true and
           writers == ["flow"],
        do: [],
        else: [here.(problem(:proposal_identity, [kind, name], "proposal identity #{kind}.#{name} must be a unique string field set only by flow"))]
    else
      []
    end
  end

  defp proposal_identity(_state, _schema, _extension, _here), do: []

  defp update_field(input) do
    case Keyword.keyword?(input) && input[:update] do
      name when is_atom(name) and name not in [nil, false] -> [to_string(name)]
      _ -> []
    end
  end

  defp roles(s, acl, here) do
    for role <- Enum.uniq(s.waiting_for ++ Enum.flat_map(s.branches, & &1.roles)),
        role != @writer,
        not Map.has_key?(acl.roles, role),
        do:
          here.(
            problem(
              :unknown_role,
              [role],
              "names the role #{role}, which the composition's acl does not define"
            )
          )
  end

  defp run_as(%{run_as: nil}, _acl, _here), do: []

  defp run_as(f, acl, here) do
    if Map.has_key?(acl.assignments, f.run_as),
      do: [],
      else: [
        here.(
          problem(
            :run_as,
            [f.run_as],
            "run_as #{f.run_as} is not assigned a role in the composition's acl"
          )
        )
      ]
  end

  defp creates(s, kind, schema, here) do
    Enum.flat_map(s.creates, fn c ->
      type = to_string(c.type)

      cond do
        not Map.has_key?(schema["entities"], type) ->
          [
            here.(
              problem(
                :creates_kind,
                [type],
                "creates a #{type}, which is not a kind of the composition"
              )
            )
          ]

        true ->
          for(
            {name, _} <- c.properties,
            not field?(schema, type, name),
            do:
              here.(
                problem(
                  :creates_field,
                  [type, name],
                  "creates a #{type} with #{name}, which #{type} does not have"
                )
              )
          ) ++
            if(
              c.relate == nil or
                (from?(schema, c.relate, type) and
                   kind in (relation(schema, c.relate)["to"] || [])),
              do: [],
              else: [
                here.(
                  problem(
                    :creates_relation,
                    [type, c.relate, kind],
                    "relates the created #{type} by #{c.relate}, which does not lead from #{type} to #{kind}"
                  )
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
      do: [
        here.(
          problem(:owner_via, [via], "owner via #{via}, which is not a kind of the composition")
        )
      ],
      else: []
    ) ++
      if(o[:via] && o[:relation] && not from?(schema, o.relation, via),
        do: [
          here.(
            problem(
              :owner_relation,
              [o.relation, via],
              "owner relation #{o.relation} does not lead from #{via}"
            )
          )
        ],
        else: []
      ) ++
      case o[:default] do
        %{kind: k} ->
          if Map.has_key?(schema["entities"], to_string(k)),
            do: [],
            else: [
              here.(
                problem(
                  :owner_default,
                  [k],
                  "owner default kind #{k} is not a kind of the composition"
                )
              )
            ]

        _ ->
          []
      end ++ producer(o[:default], kind, schema, here)
  end

  # A default that asks the subject's producer: its relation leads from the subject to one
  # fact of the default's kind, or of the kind it names (`producer_kind`).
  defp producer(%{producer: name, kind: k} = default, kind, schema, here) do
    r = relation(schema, name) || %{}
    k = default[:producer_kind] || k

    if kind in (r["from"] || []) and to_string(k) in (r["to"] || []) and r["max_outgoing"] == 1,
      do: [],
      else: [
        here.(
          problem(
            :owner_producer,
            [name, kind, k],
            "owner default's producer #{name} does not lead from #{kind} to one #{k} (max_outgoing 1)"
          )
        )
      ]
  end

  defp producer(_default, _kind, _schema, _here), do: []

  defp present(nil, _kind, _schema, _here), do: []

  defp present(p, kind, schema, here) do
    section =
      if p.section && not field?(schema, kind, p.section.field),
        do: [
          here.(
            problem(
              :section_field,
              [kind, p.section.field],
              "presents the section of #{p.section.field}, which #{kind} does not have"
            )
          )
        ],
        else: []

    answers =
      Enum.flat_map(p.answers, fn a ->
        rel = a[:set] || a[:remove] || (a[:change] && a.change[:self])
        values = (a[:change] && a.change[:values]) || %{}
        appended = (a[:change] && a.change[:append]) || %{}

        Enum.flat_map(Enum.reject([rel, a[:by]], &is_nil/1), fn rel ->
          if from?(schema, rel, kind),
            do: [],
            else: [
              here.(
                problem(
                  :answer_relation,
                  [a[:key], rel],
                  "answer #{a[:key]} names #{rel}, which does not lead from #{kind}"
                )
              )
            ]
        end) ++
          for {name, _} <- Map.to_list(values) ++ Map.to_list(appended),
              not field?(schema, kind, name),
              do:
                here.(
                  problem(
                    :answer_field,
                    [a[:key], kind, name],
                    "answer #{a[:key]} writes #{kind}.#{name}, which #{kind} does not have"
                  )
                )
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
              problem(
                :link_relation,
                [l.child, relation, from, to],
                "#{relation} does not lead from #{from} to #{to}, as the link or count of #{l.child} says"
              )
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
          problem(
            :link_field,
            [l.child, parent, name],
            "the link or count of #{l.child} names #{parent}.#{name}, which #{parent} does not have"
          )
        )
    ) ++
      for name <- by_child,
          not field?(schema, child, name),
          do:
            at.(
              problem(
                :link_field,
                [l.child, child, name],
                "the link of #{l.child} names #{child}.#{name}, which #{child} does not have"
              )
            )
  end

  @doc "Problems of the `select`s of the subflows the composition runs."
  def selects(selects, flows, schema, extension \\ %{}) do
    Enum.flat_map(selects, fn %{value: {name, o}} = i ->
      at = &{i.file, i.line, Problem.prefix(&1, "select #{name}: ")}

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
            do: at.(problem(:choice_field, [kind, c], "choice #{c} is not a field of #{kind}"))
          ) ++
            if(
              (o[:choices] || []) != [] and
                RelaDSL.Description.Build.choice_states(f, o[:choices]) == [],
              do: [
                at.(
                  problem(
                    :choice_unawaited,
                    [name | o[:choices]],
                    "no state of #{name} waits for people to choose #{Enum.join(o[:choices] || [], ", ")}"
                  )
                )
              ],
              else: []
            ) ++
            for(
              {role, rel} <- o[:roles] || [],
              not Enum.any?([kind | parts(schema, extension, kind)], &from?(schema, rel, &1)),
              do:
                at.(
                  problem(
                    :role_not_from_subject,
                    [role, rel],
                    "roles: #{role} names #{rel}, which leads neither from #{kind} nor from a part of it"
                  )
                )
            ) ++
            for(
              {role, _} <- o[:roles] || [],
              to_string(role) not in Enum.flat_map(f.states, & &1.waiting_for),
              do:
                at.(problem(:role_unawaited, [name, role], "roles: #{name} waits for no #{role}"))
            ) ++
            if(projection[:on] && not from?(schema, projection[:on], kind),
              do: [
                at.(
                  problem(
                    :projection_on,
                    [projection[:on], kind],
                    "projection on #{projection[:on]} does not lead from #{kind}"
                  )
                )
              ],
              else: []
            ) ++
            for(
              k <- [:state_field, :deadline_field, :handover_field, :field],
              target,
              projection[k],
              not field?(schema, target, projection[k]),
              do:
                at.(
                  problem(
                    :projection_field,
                    [k, target, projection[k]],
                    "projection #{k} #{projection[k]} is not a field of #{target}"
                  )
                )
            ) ++
            if(
              target && projection[:owner_relation] &&
                not from?(schema, projection[:owner_relation], target),
              do: [
                at.(
                  problem(
                    :projection_owner_relation,
                    [projection[:owner_relation], target],
                    "projection owner_relation #{projection[:owner_relation]} does not lead from #{target}"
                  )
                )
              ],
              else: []
            ) ++
            values(schema, kind, o[:admission], at) ++
            Enum.flat_map(
              List.wrap(o[:imports]) ++ List.wrap(o[:follow_through] && [o[:follow_through]]),
              fn imp ->
                values(schema, kind, imp[:when], at) ++
                  if(to_string(imp[:state]) in states,
                    do: [],
                    else: [
                      at.(
                        problem(
                          :import_state,
                          [name, imp[:state]],
                          "imports state #{imp[:state]}, which #{name} does not have"
                        )
                      )
                    ]
                  ) ++
                  if(Keyword.has_key?(imp, :completed) and not is_boolean(imp[:completed]),
                    do: [
                      at.(
                        problem(
                          :import_completed,
                          [inspect(imp[:completed])],
                          "an import row's completed is true or false"
                        )
                      )
                    ],
                    else: []
                  )
              end
            ) ++
            if(Keyword.has_key?(o, :reopen) and o[:reopen] not in [:explicit, :new_generation],
              do: [
                at.(
                  problem(
                    :reopen_policy,
                    [inspect(o[:reopen])],
                    "reopen: #{inspect(o[:reopen])} is neither :explicit nor :new_generation"
                  )
                )
              ],
              else: []
            ) ++
            restart_by(o, projection, flows, at) ++
            completed(f, kind, o, extension, at) ++
            verification(schema, kind, o[:verification], at) ++
            order(schema, kind, states, o[:order], at)
      end
    end)
  end

  # The final state a run of a completed subject ends in (`completed:`): one the subflow
  # has, on a kind with a completion rule (Facts derives whether its fact is completed).
  defp completed(f, kind, o, extension, at) do
    report = fn message -> [at.(problem(:completed, [kind], "completed: " <> message))] end

    case Keyword.fetch(o, :completed) do
      :error ->
        []

      {:ok, state} ->
        final = for s <- f.states, s.final, do: s.name

        cond do
          not is_atom(state) or state not in final ->
            report.("#{inspect(state)} is no final state of #{f.name}")

          get_in(extension || %{}, ["entities", kind, "completion"]) in [nil, []] ->
            report.("#{kind} has no completion rule, so no #{kind} is ever completed")

          true ->
            []
        end
    end
  end

  # Who may ask for an explicit restart of a completed run: `:owner` (whom the projection's
  # owner relation links) and roles of the configured actors the subflows' owners name.
  defp restart_by(o, projection, flows, at) do
    roles = for {role, _kind} <- RelaDSL.Flow.Model.actors(flows), do: to_string(role)

    report = fn message -> at.(problem(:restart_policy, [inspect(o[:restart_by])], message)) end

    case Keyword.fetch(o, :restart_by) do
      :error ->
        []

      {:ok, [_ | _] = names} ->
        Enum.flat_map(names, fn
          :owner ->
            if projection[:owner_relation],
              do: [],
              else: [report.("restart_by: :owner needs a projection with an owner_relation")]

          name when is_atom(name) ->
            if to_string(name) in roles,
              do: [],
              else: [
                report.("restart_by: #{name} is no configured actor its subflows' owners name")
              ]

          other ->
            [report.("restart_by: #{inspect(other)} is not :owner or an actor's role")]
        end)

      {:ok, other} ->
        [report.("restart_by: #{inspect(other)} is not a nonempty list")]
    end
  end

  defp values(_schema, _kind, nil, _at), do: []

  defp values(schema, kind, mapping, at) do
    Enum.flat_map(mapping, fn {field, allowed} ->
      prop = get_in(schema, ["entities", kind, "properties", to_string(field)])
      enum = prop && get_in(schema, ["types", prop["type"], "values"])

      cond do
        prop == nil ->
          [at.(problem(:unknown_field, [kind, field], "#{field} is not a field of #{kind}"))]

        # nil allows no value: the field empty.
        enum && Enum.any?(List.wrap(allowed), &(&1 != nil and to_string(&1) not in enum)) ->
          [
            at.(
              problem(
                :unknown_value,
                [kind, field],
                "#{kind}.#{field} has no value among #{inspect(allowed)}"
              )
            )
          ]

        true ->
          []
      end
    end)
  end

  # Its subjects are picked up one at a time: `within` leads from the subject to one
  # parent, `by` is a number field of the subject and `done` names states of the subflow.
  defp order(_schema, _kind, _states, nil, _at), do: []

  defp order(schema, kind, states, o, at) do
    report = fn message -> [at.(problem(:order, [kind], "order: " <> message))] end
    within = Keyword.keyword?(o) && o[:within] && relation(schema, o[:within])

    by =
      Keyword.keyword?(o) && get_in(schema, ["entities", kind, "properties", to_string(o[:by])])

    cond do
      not Keyword.keyword?(o) or Keyword.keys(o) -- [:within, :by, :done] != [] ->
        report.("must be [within: relation, by: field, done: [state]]")

      not (is_map(within) and from?(schema, o[:within], kind) and within["max_outgoing"] == 1) ->
        report.("within #{o[:within]} does not lead from #{kind} to one parent")

      not (by && by["type"] == "integer") ->
        report.("by #{o[:by]} is not a number field of #{kind}")

      Enum.any?(o[:done] || [], &(to_string(&1) not in states)) ->
        report.("done #{inspect(o[:done])} names a state the subflow does not have")

      true ->
        []
    end
  end

  # The verdict kind whose relations clear the subject's field.
  defp verification(_schema, _subject, nil, _at), do: []

  defp verification(schema, subject, v, at) do
    kind = to_string(v[:kind])

    if Map.has_key?(schema["entities"], kind) do
      if(field?(schema, subject, v[:field]),
        do: [],
        else: [
          at.(
            problem(
              :verification_field,
              [subject, v[:field]],
              "verification field #{v[:field]} is not a field of #{subject}"
            )
          )
        ]
      ) ++
        for r <- v[:relations] || [],
            not from?(schema, r, kind),
            do:
              at.(
                problem(
                  :verification_relation,
                  [r, kind],
                  "verification relation #{r} does not lead from #{kind}"
                )
              )
    else
      [
        at.(
          problem(
            :verification_kind,
            [kind],
            "verification kind #{kind} is not a kind of the composition"
          )
        )
      ]
    end
  end
end
