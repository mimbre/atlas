defmodule AtlasControl.Presented do
  @moduledoc """
  What Facts answers as a fact's presentation (`"presentation"`, on a read that asks for
  it), for Control's tests: from the model's presenters (`presentation/0`) and the fact's
  fields, as Facts presents the work of a legacy flow. For a presenter of selected
  subflows a fixture holds no runs: the state written stands for the active run's own. A
  fixture that gives its own `"presentation"` (a run that ended, say) keeps it.
  """

  @doc "The answers to `reads` (`[{kind, content}]`), each fact presented where its read asks."
  def answers(m, reads, answers) do
    for {{kind, content}, answer} <- Enum.zip(reads, answers),
        do: answer(m, kind, content, answer)
  end

  @doc "One read's answer, its facts presented when `content` asks for it."
  def answer(m, kind, %{"presentation" => true}, answer) do
    case answer do
      %{"fact" => %{} = fact} ->
        Map.put(answer, "fact", of(m, kind, fact))

      %{"facts" => facts} when is_list(facts) ->
        Map.put(answer, "facts", Enum.map(facts, &of(m, kind, &1)))

      _ ->
        answer
    end
  end

  def answer(_m, _kind, _content, answer), do: answer

  @doc "`fact` of `kind` with its presentation, when a presenter writes on its kind."
  def of(_m, _kind, %{"presentation" => _} = fact), do: fact

  def of(m, kind, fact) do
    module = if is_map(m), do: m.module, else: m

    case Enum.find(module.presentation(), &(&1["kind"] == kind)) do
      nil -> fact
      p -> Map.put(fact, "presentation", view(p, fact))
    end
  end

  defp view(p, fact) do
    values = fact["values"] || %{}
    stored = blank(p["state_field"] && values[p["state_field"]])
    actionable = p["state_field"] == nil or stored != nil
    shown = (stored && p["states"][stored]) || %{}
    origin = get_in(fact, ["origins", p["owner_relation"] || ""]) || %{}

    %{
      "state" => stored,
      "status" => if(p["legacy"], do: nil, else: "active"),
      "flow" => nil,
      "legacy" => p["legacy"],
      "follow_through" => false,
      "reopened" => false,
      "actionable" => actionable,
      "expected" => if(actionable, do: blank(p["field"] && values[p["field"]])),
      "why" => shown["why"],
      "todo" => if(actionable, do: shown["todo"]),
      "owner" => (p["owner_relation"] && get_in(fact, ["links", p["owner_relation"]])) || [],
      "manual" => origin["by"] not in [nil, "flow", "migration"],
      "handover" => if(blank(p["handover_field"] && values[p["handover_field"]]), do: %{}),
      "deadline" => blank(p["deadline_field"] && values[p["deadline_field"]])
    }
  end

  defp blank(value) when value in [nil, "", false], do: nil
  defp blank(value), do: value
end
