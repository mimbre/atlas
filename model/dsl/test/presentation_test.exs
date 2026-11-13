defmodule RelaDSL.PresentationTest do
  @moduledoc """
  Who presents the work on a fact (`RelaDSL.Presentation`), as the neutral compositions
  compile it: the office's selected subflow presents letters on their desk in place of
  the legacy flow it takes over; the workshop's legacy flow, selected by nothing,
  presents its own.
  """
  use ExUnit.Case, async: true

  test "a selected subflow presents its subject on its projection, instead of its legacy flow" do
    assert [presenter] = RelaDSL.Office.presentation()

    assert %{
             "subject" => "letter",
             "kind" => "desk",
             "on" => "desk",
             "field" => "expected",
             "state_field" => "flow_state",
             "handover_field" => nil,
             "owner_relation" => "held_by",
             "legacy" => nil,
             "flows" => [%{"name" => "letter", "follow_through" => nil}]
           } = presenter

    # The legacy flow's open states stay presentable (a follow-through presents them); a
    # done state presents nothing.
    assert %{"expected" => "Post it"} = presenter["states"]["open"]
    refute Map.has_key?(presenter["states"], "done")
  end

  test "a legacy flow no subflow takes over presents its own, where it writes" do
    assert [_ | _] = presenters = RelaDSL.Workshop.presentation()

    for p <- presenters do
      assert p["flows"] == [] and is_binary(p["legacy"])
    end

    assert RelaDSL.Presentation.owned(presenters) == RelaDSL.Workshop.turn()["items"]
  end
end
