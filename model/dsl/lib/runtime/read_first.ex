defmodule RelaDSL.Runtime.ReadFirst do
  @moduledoc """
  What a compiled `read_first/2` calls while it runs: the text a worker reads before it
  acts on a fact. The rule is the one the model compiled (`RelaDSL.Runtime.Model`), every
  name in it resolved; it knows no kind and no field by name.

  The text is a title, then the groups of standing facts marked `first`, then the facts
  the fact is anchored to (`through`), each followed by those it leads to (`then`), then
  the other standing groups. Each fact is shown once, on one line: its key, its primary
  field, its tags (with their values' labels) and its text, shortened. Nil when nothing
  applies.
  """

  @limit 280

  @doc "The text for `fact`; `lookup.(kind, query)` reads facts, and a failed read is left out."
  def text(rule, fact, lookup) do
    anchors = fetch(rule.anchor, links(fact, rule.through), lookup)
    above = fetch(rule.anchor, Enum.flat_map(anchors, &links(&1, rule.then)), lookup)
    shown = MapSet.new(Enum.map(anchors ++ above, & &1["key"]))

    {groups, _} =
      Enum.map_reduce(rule.standing, shown, fn group, shown ->
        facts = standing(group, rule.anchor, lookup, shown)
        {{group, facts}, MapSet.union(shown, MapSet.new(facts, & &1["key"]))}
      end)

    group_part = fn {group, facts} ->
      if facts != [],
        do: [(group.title || "Standing") <> ":" | Enum.map(facts, &("- " <> line(rule, &1)))]
    end

    {first, later} = Enum.split_with(groups, fn {group, _} -> group.first end)

    based =
      Enum.flat_map(anchors, fn anchor ->
        ["- " <> line(rule, anchor)] ++
          for(
            above_key <- links(anchor, rule.then),
            fact <- Enum.filter(above, &(&1["key"] == above_key)),
            do: "  #{rule.then_label} " <> line(rule, fact)
          )
      end)

    parts =
      (Enum.map(first, group_part) ++
         [if(based != [], do: [String.capitalize(rule.through_label) <> ":" | based])] ++
         Enum.map(later, group_part))
      |> Enum.reject(&is_nil/1)

    if parts == [],
      do: nil,
      else: Enum.join(Enum.reject([rule.title | List.flatten(parts)], &is_nil/1), "\n")
  end

  defp fetch(kind, keys, lookup) do
    for key <- Enum.uniq(keys),
        %{"fact" => %{} = fact} <- [lookup.(kind, %{"key" => key, "plain" => true})],
        do: fact
  end

  defp standing(%{when: %{} = condition}, kind, lookup, shown) when condition != %{} do
    case lookup.(kind, %{"linked" => %{}, "plain" => true}) do
      %{"facts" => facts} ->
        facts
        |> Enum.filter(fn fact ->
          not MapSet.member?(shown, fact["key"]) and
            Enum.all?(condition, fn {name, allowed} ->
              (fact["values"] || %{})[name] in List.wrap(allowed)
            end)
        end)
        |> Enum.sort_by(& &1["key"])

      _ ->
        []
    end
  end

  defp standing(_group, _kind, _lookup, _shown), do: []

  defp line(rule, fact) do
    values = fact["values"] || %{}

    tags =
      for {name, labels} <- rule.tags,
          value = values[name],
          value not in [nil, ""],
          do: labels[value] || to_string(value)

    name = values[rule.primary]

    [
      fact["key"],
      if(name not in [nil, ""], do: " #{name}"),
      if(tags != [], do: " (#{Enum.join(tags, ", ")})"),
      case short(values[rule.text]) do
        nil -> nil
        text -> ": " <> text
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp short(text) when is_binary(text) do
    text = text |> String.split() |> Enum.join(" ")

    cond do
      text == "" -> nil
      String.length(text) > @limit -> String.slice(text, 0, @limit - 1) <> "…"
      true -> text
    end
  end

  defp short(_text), do: nil

  defp links(fact, relation), do: get_in(fact, ["links", relation]) || []
end
