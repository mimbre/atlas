defmodule AtlasFacts.Subflows do
  @moduledoc """
  The subflows Atlas runs, as the Flow DSL generated them (`flows` of
  `model/targets/atlas/flows.json`, read when Facts compiles): per subflow the kind it
  runs on (`subject`), its `owner` (`via` the relation to the fact that is assigned,
  `relation` to the assignee, and `default`, `{kind, key}`, who owns it while no one
  is assigned), and per state what its owner sees (`present`: `expected`, `why` and
  `todo`, in the shape the description's `flows` give it).

  Facts answers them with the description (`subflows`), so every client reads owners
  and presentation from one place, and checks them against the description
  (`subflow_problems`, per subflow): the generator cannot see the description, Facts
  can. Knows no kind by name.
  """
  defmodule Prod do
    use RelaDSL.Runtime, target: "../../../../../model/targets/atlas/flows.json"
  end

  defmodule Test do
    use RelaDSL.Runtime, target: "../../../../../model/targets/test/atlas/flows.json"
  end

  defp target, do: if(AtlasBus.environment() == "test", do: Test, else: Prod)
  def flows, do: target().flows()
  def gates, do: target().gates()
  def rela_flows_sha256, do: target().rela_flows_sha256()
  def check_rela_flows(bytes), do: target().check_rela_flows(bytes)

  @doc "`description` with `subflows` (default: the generated ones) and their problems."
  def describe(description, subflows \\ flows()) do
    description
    |> Map.put("subflows", subflows)
    |> Map.put("subflow_problems", check(description, subflows))
  end

  @doc "The problems of every subflow against `description`: `%{name => [problem]}`."
  def check(description, subflows) do
    for {name, subflow} <- subflows, into: %{}, do: {name, problems(description, subflow)}
  end

  defp problems(description, subflow) do
    kind = subflow["subject"]

    if Map.has_key?(description["entities"] || %{}, kind) do
      owner(description, kind, subflow["owner"] || %{}) ++ shown(description, kind, subflow)
    else
      ["runs on #{kind}, which is not described"]
    end
  end

  # The owner: `via` starts at the kind and points at one kind (the fact that is
  # assigned); `relation` starts there, or at the kind, and allows the default's kind.
  defp owner(description, kind, owner) do
    {via, at} = via(description, kind, owner["via"])
    {assignee, allowed} = assignee(description, at, owner["relation"])
    via ++ assignee ++ default(description, owner, allowed)
  end

  defp via(_description, kind, nil), do: {[], kind}

  defp via(description, kind, via) do
    case relation(description, via) do
      nil ->
        {["owner via #{via} is not described"], nil}

      spec ->
        problems =
          unless_true(kind in (spec["from"] || []), "owner via #{via} does not start at #{kind}") ++
            unless_true(match?([_], spec["to"]), "owner via #{via} must point at one kind")

        {problems, List.first(spec["to"] || [])}
    end
  end

  defp assignee(_description, _at, nil), do: {[], nil}

  defp assignee(description, at, rel) do
    case relation(description, rel) do
      nil ->
        {["owner relation #{rel} is not described"], []}

      spec ->
        starts = at == nil or at in (spec["from"] || [])
        {unless_true(starts, "owner relation #{rel} does not start at #{at}"), spec["to"] || []}
    end
  end

  defp default(description, %{"default" => %{"kind" => kind}} = owner, allowed) do
    if is_list(allowed),
      do:
        unless_true(
          kind in allowed,
          "owner relation #{owner["relation"]} does not allow the default owner's kind, #{kind}"
        ),
      else:
        unless_true(
          Map.has_key?(description["entities"] || %{}, kind),
          "the default owner's kind, #{kind}, is not described"
        )
  end

  defp default(_description, _owner, _allowed), do: []

  defp unless_true(true, _problem), do: []
  defp unless_true(_, problem), do: [problem]

  # What a state shows: its section is a property of the kind; each answer sets or removes
  # a relation that is described.
  defp shown(description, kind, subflow) do
    for {state, %{"present" => present}} <- Enum.sort(subflow["states"] || %{}),
        problem <- section(description, kind, present) ++ answers(description, present),
        do: "#{state}: #{problem}"
  end

  defp section(description, kind, present) do
    case get_in(present, ["todo", "section", "field"]) do
      nil ->
        []

      field ->
        if get_in(description, ["entities", kind, "properties", field]) == nil,
          do: ["its section shows #{field}, which #{kind} does not have"],
          else: []
    end
  end

  defp answers(description, present) do
    for answer <- get_in(present, ["todo", "answers"]) || [],
        rel = answer["set"] || answer["remove"] || get_in(answer, ["change", "self"]),
        relation(description, rel) == nil,
        do: "its answer #{answer["key"]} names #{rel}, which is not described"
  end

  defp relation(description, name), do: get_in(description, ["relations", name])
end
