defmodule RelaDSL.PresentationTest do
  @moduledoc """
  Who presents the work on a fact (`RelaDSL.Presentation`), as the neutral compositions
  compile it: the office's selected subflow presents letters on their desk; the
  workshop's two subflows present boxes on their card and crates on themselves.
  """
  use ExUnit.Case, async: true

  test "a selected subflow presents its subject on its projection" do
    assert [presenter] = RelaDSL.Office.presentation()

    assert %{
             "subject" => "letter",
             "kind" => "desk",
             "on" => "desk",
             "field" => "expected",
             "state_field" => "flow_state",
             "handover_field" => nil,
             "owner_relation" => "held_by",
             "flows" => [%{"name" => "letter"}]
           } = presenter

    refute Map.has_key?(presenter, "legacy")
    # The letter's states present nothing of their own.
    assert presenter["states"] == %{}
  end

  test "a presenter writes on the component its projection is on, or on the subject" do
    presenters = RelaDSL.Workshop.presentation()

    assert Enum.map(presenters, &{&1["subject"], &1["kind"], &1["flows"]}) == [
             {"box", "card", [%{"name" => "pack", "reopen" => nil, "admission" => []}]},
             {"crate", "crate", [%{"name" => "stack", "reopen" => nil, "admission" => []}]}
           ]

    assert RelaDSL.Presentation.owned(presenters) == RelaDSL.Workshop.turn()["items"]
  end
end
