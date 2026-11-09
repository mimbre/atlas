defmodule AtlasControl.ReadFirst do
  @moduledoc """
  What a worker reads before it acts on an item, as short plain text: the records the item
  is anchored to, what those follow from, and the standing rules that apply to all work.
  Named entirely by the description (`read_first` in `rela/atlas.json`); knows no kind.

      "read_first": {
        "title": <text>,                  the first line
        "through": <relation>,            from the item to its anchors (one kind)
        "then": <relation>,               from an anchor to what it follows from
        "standing": [{"title": <text>,    groups of the anchors' kind that apply to all work,
                      "first": true,      in order, each fact once ("first": before the
                      "when": {<property>: [<value>, ...]}}],  anchors): each property has one
        "tags": [<property>, ...],        shown in brackets after a fact's name
        "text": <property>                its text, shortened
      }

  Each fact is one line: key, its primary field, its tags, its text. Nil when nothing
  applies, or the description has no `read_first`.
  """

  @limit 280

  @doc """
  The text for the item `key` of `kind`. `read` asks Facts, as `read.(kind, content)`; a
  read that fails leaves its part out.
  """
  def text(description, kind, key, read) do
    with %{"through" => through} = rule <- description["read_first"],
         [anchor_kind] <- get_in(description, ["relations", through, "to"]) do
      spec = get_in(description, ["entities", anchor_kind]) || %{}

      anchors =
        case read.(kind, %{"key" => key, "plain" => true}) do
          %{"fact" => %{} = item} -> fetch(anchor_kind, links(item, through), read)
          _ -> []
        end

      above = fetch(anchor_kind, Enum.flat_map(anchors, &links(&1, rule["then"])), read)
      shown = MapSet.new(Enum.map(anchors ++ above, & &1["key"]))
      # Standing groups in order, each fact once; a group with "first" comes before the anchors.
      {groups, _} =
        rule["standing"]
        |> List.wrap()
        |> Enum.filter(&is_map/1)
        |> Enum.map_reduce(shown, fn group, shown ->
          facts = standing(group, anchor_kind, read, shown)
          {{group, facts}, MapSet.union(shown, MapSet.new(facts, & &1["key"]))}
        end)

      group_part = fn {group, facts} ->
        if facts != [],
          do: [
            (group["title"] || "Standing") <> ":"
            | Enum.map(facts, &("- " <> line(spec, rule, &1)))
          ]
      end

      {first, later} = Enum.split_with(groups, fn {group, _} -> group["first"] == true end)
      then = get_in(description, ["relations", rule["then"], "label"]) || rule["then"]

      based =
        Enum.flat_map(anchors, fn anchor ->
          ["- " <> line(spec, rule, anchor)] ++
            for(
              above_key <- links(anchor, rule["then"]),
              fact <- Enum.filter(above, &(&1["key"] == above_key)),
              do: "  #{then} " <> line(spec, rule, fact)
            )
        end)

      label = get_in(description, ["relations", through, "label"]) || through

      parts =
        (Enum.map(first, group_part) ++
           [if(based != [], do: [String.capitalize(label) <> ":" | based])] ++
           Enum.map(later, group_part))
        |> Enum.reject(&is_nil/1)

      if parts == [],
        do: nil,
        else: Enum.join([rule["title"] | List.flatten(parts)] |> Enum.reject(&is_nil/1), "\n")
    else
      _ -> nil
    end
  end

  defp fetch(kind, keys, read) do
    for key <- Enum.uniq(keys),
        %{"fact" => %{} = fact} <- [read.(kind, %{"key" => key, "plain" => true})],
        do: fact
  end

  defp standing(%{"when" => %{} = condition}, kind, read, shown) when condition != %{} do
    case read.(kind, %{"linked" => %{}, "plain" => true}) do
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

  defp standing(_rule, _kind, _read, _shown), do: []

  defp line(spec, rule, fact) do
    values = fact["values"] || %{}

    tags =
      for name <- rule["tags"] || [],
          value = values[name],
          value not in [nil, ""],
          do: label(spec, name, value)

    name = values[spec["primary"]]

    [
      fact["key"],
      if(name not in [nil, ""], do: " #{name}"),
      if(tags != [], do: " (#{Enum.join(tags, ", ")})"),
      case short(values[rule["text"]]) do
        nil -> nil
        text -> ": " <> text
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  defp label(spec, name, value),
    do: get_in(spec, ["properties", name, "labels", value]) || to_string(value)

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
