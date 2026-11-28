defmodule ControlFixtures.Scenarios do
  @moduledoc false

  def tabs do
    [
      {"decision", "Decision", "/k/decision/D-7"},
      {"scene", "Scene", "/k/scene/SC-1"},
      {"todo", "To-Do", "/k/todo/TD-12"},
      {"lists", "Scenes", "/k/scene"},
      {"empty", "Empty", "/k/scene/empty"}
    ]
    |> Enum.map(fn {id, label, to} ->
      %{"id" => id, "label" => label, "to" => to, "section" => "work"}
    end)
  end

  def initial(id), do: Enum.find_value(tabs(), fn tab -> if tab["id"] == id, do: tab["to"] end)

  def page("/k/decision/D-7" = path) do
    options = [
      option(1, "files", "Use files", "Keep examples next to the work.", true),
      option(2, "memory", "Use memory", "Keep examples in a running service.", false)
    ]

    page(path, "D-7", [
      block("header", "header", %{"eyebrow" => "YOUR DECISION", "key" => "D-7", "title" => "How do we store examples?"}),
      block("why", "text", %{"text" => "The same examples should be available to each client."})
    ] ++ options ++ [
      block("answers", "answers", %{"answers" => [%{"label" => "Decline all", "key" => "3", "weight" => "decline", "to" => path <> "/answer/decline", "note" => true, "detail" => "None of these fits; say why."}]}),
      item("D-7", [%{"label" => "Status", "value" => "Open"}])
    ], details())
  end

  def page("/k/todo/TD-12" = path) do
    page(path, "TD-12", [
      block("header", "header", %{"eyebrow" => "TO DO FOR YOU", "key" => "TD-12", "title" => "Prepare the local examples"}),
      block("why", "text", %{"text" => "Give each client the same representative content."}),
      block("step-1", "instruction", %{"n" => 1, "lines" => [%{"kind" => "text", "text" => "Open a terminal"}, %{"kind" => "command", "text" => "cd ~/atlas"}]}),
      block("step-2", "instruction", %{"n" => 2, "lines" => [%{"kind" => "text", "text" => "Review the examples in both clients."}, %{"kind" => "route", "parts" => ["Atlas", "Scenes"]}]}),
      block("answers", "answers", %{"answers" => [%{"label" => "Done", "key" => "x", "weight" => "main", "to" => path <> "/answer/done", "note" => true}, %{"label" => "Won't do", "key" => "n", "weight" => "no", "to" => path <> "/answer/no", "note" => true}]}),
      item("TD-12", [%{"label" => "Status", "value" => "Open"}])
    ], details())
  end

  def page("/k/scene/SC-1" = path) do
    page(path, "SC-1", [
      block("header", "header", %{"eyebrow" => "SCENE", "key" => "SC-1", "title" => "Make examples easy to inspect"}),
      block("description", "text", %{"label" => "Description", "text" => "Review the same decision and To-Do across clients.\n\nA second paragraph exercises wrapped layout."}),
      item("SC-1", [%{"label" => "Status", "value" => "Ready to pick up"}, %{"label" => "Owner", "value" => "Example person"}]),
      block("related", "list", %{"title" => "Related work", "rows" => [
        %{"id" => "D-7", "label" => "How do we store examples?", "kind" => "Decision", "to" => "/k/decision/D-7"},
        %{"id" => "TD-12", "label" => "Prepare the local examples", "kind" => "To-Do", "to" => "/k/todo/TD-12"}
      ]})
    ], [%{"kind" => "part", "start" => "item", "end" => "related", "props" => %{"title" => "Details", "role" => "details"}}])
  end

  def page("/k/scene" = path) do
    page(path, "Scenes", [block("list", "list", %{"title" => "Scenes", "rows" => [
      %{"id" => "SC-1", "label" => "Make examples easy to inspect", "detail" => "Ready to pick up", "to" => "/k/scene/SC-1"},
      %{"id" => "D-7", "label" => "How do we store examples?", "detail" => "Open decision", "to" => "/k/decision/D-7"},
      %{"id" => "TD-12", "label" => "Prepare the local examples", "detail" => "Open To-Do", "to" => "/k/todo/TD-12"}
    ]})], [])
  end

  def page("/k/scene/empty" = path), do: page(path, "Empty scenes", [block("list", "list", %{"title" => "Scenes", "rows" => [], "empty" => "No scenes match this view."})], [])
  def page(_), do: nil

  defp page(path, title, blocks, markup), do: %{"op" => "page", "reason" => "open", "path" => path, "title" => title, "blocks" => blocks, "markup" => markup}
  defp block(id, type, props), do: %{"id" => id, "type" => type, "props" => props}
  defp item(title, fields), do: block("item", "item", %{"title" => title, "fields" => fields, "actions" => []})
  defp details, do: [%{"kind" => "part", "start" => "item", "end" => "item", "props" => %{"title" => "Details", "role" => "details"}}]

  defp option(n, id, title, rule, recommended) do
    answer = %{"label" => "Choose", "key" => Integer.to_string(n), "to" => "/k/decision/D-7/answer/option-#{id}", "weight" => if(recommended, do: "main", else: "other"), "submit_to" => %{"endpoint" => "answer", "params" => %{"kind" => "decision", "key" => "D-7", "answer" => "option-#{id}"}}}
    props = %{"n" => n, "text" => title, "fields" => [%{"label" => "Rule", "value" => rule}], "answer" => answer}
    props = if recommended, do: Map.merge(props, %{"badge" => "★ Recommended", "tone" => "success"}), else: props
    block("option-#{n}", "option", props)
  end
end
