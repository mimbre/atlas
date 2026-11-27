defmodule Model.SceneItemsFailureTest do
  use ExUnit.Case, async: true

  alias AtlasControl.Pages
  alias Model.AtlasEyra

  test "unreadable use cases show the read error and cannot be answered" do
    model = AtlasControl.Model.catalog(AtlasEyra)
    key = "SC-Atlas-90"
    route = {:item, "scene", key}
    fact = %{
      "key" => key,
      "values" => %{"title" => "A scene", "phase" => "break_down", "status" => "refine"},
      "links" => %{"produced_by" => ["melle"], "assignment" => ["AS-" <> key]}
    }

    flow = Enum.find(AtlasEyra.subflows(:test), &(&1.name() == "break_down_scene"))
    presentation =
      flow.present("accepting", fact["values"])
      |> Map.merge(%{
        "flow" => "break_down_scene", "state" => "accepting", "run" => "run-1",
        "status" => "active", "actionable" => true, "owner" => ["bo"],
        "supervisor" => ["bo"]
      })

    assignment = %{
      "key" => "AS-" <> key,
      "values" => %{"of" => key},
      "links" => %{"assigned_to" => ["bo"]},
      "presentation" => presentation
    }

    answers =
      for {kind, read} <- Pages.reads(route, model) do
        case {kind, read} do
          {"scene", %{"key" => _}} -> %{"fact" => fact}
          {"assignment", %{"key" => _}} -> %{"fact" => assignment}
          {"use_case", %{"linked" => %{"in_scene" => _}}} -> %{"error" => "Use cases unavailable"}
          _ -> %{"facts" => []}
        end
      end

    form = %{by: "bo", by_kind: "person", client: "tui"}
    page = Pages.render(route, model, answers, form)
    items = Enum.find(page.blocks, &(&1["id"] == "items"))["props"]
    assert items["empty"] == "Use cases unavailable."
    assert items["rows"] == []
    refute Enum.any?(page.blocks, &(&1["id"] == "answers"))
    assert Pages.declared_answer(model, "scene", "a", answers, form) == nil
    assert Pages.items_problem(model, "scene", answers) != nil

    readable = Enum.map(answers, fn
      %{"error" => "Use cases unavailable"} -> %{"facts" => []}
      answer -> answer
    end)

    page = Pages.render(route, model, readable, form)
    items = Enum.find(page.blocks, &(&1["id"] == "items"))["props"]
    assert items["empty"] == "Design proposed no use cases: decline it with a note to try again."
    assert Pages.items_problem(model, "scene", readable) == nil
    assert %{label: "Accept"} = Pages.declared_answer(model, "scene", "a", readable, form)
  end
end
