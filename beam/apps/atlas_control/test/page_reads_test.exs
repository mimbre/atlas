defmodule AtlasControl.PageReadsTest do
  use ExUnit.Case, async: true
  alias AtlasControl.{PageReads, Pages}

  @description %{
    "entities" => %{"tag" => %{"plural" => "tags"}, "box" => %{"plural" => "boxes"}},
    "relations" => %{
      "held_by" => %{"from" => ["tag"], "to" => ["clerk"]},
      "tagged" => %{"from" => ["box"], "to" => ["tag"], "component" => %{}}
    },
    "start" => %{"assigned" => %{"relation" => "held_by"}, "open" => %{}}
  }

  test "assigned page and header use the same batch as Open work, then select the owner" do
    mine = %{"key" => "T-1", "links" => %{"held_by" => ["K-1"]}}
    other = %{"key" => "T-2", "links" => %{"held_by" => ["K-2"]}}
    box = %{"key" => "B-1", "links" => %{"tagged" => ["T-1"]}}

    ask = fn kind, content, budget ->
      assert kind == "_page"
      assert content == %{"kinds" => ["tag", "box"]}
      assert budget == 2
      send(self(), :batch)
      %{"answers" => [%{"facts" => [mine, other]}, %{"facts" => [box]}]}
    end

    assigned = PageReads.answers({:assigned, "K-1"}, @description, ask)
    assert_receive :batch
    refute_received :batch
    assert assigned == [%{"facts" => [mine]}, %{"facts" => [box]}]
    assert Pages.assigned_facts(@description, assigned) == [{"box", box, mine}]
    assert Pages.assigned_count(@description, assigned) == "1"

    assert PageReads.answers({:list, "tag"}, @description, ask) ==
             [%{"facts" => [mine, other]}, %{"facts" => [box]}]
  end

  test "batch errors occupy every planned answer" do
    assert PageReads.answers({:assigned, "K-1"}, @description, fn _, _, _ ->
             %{"error" => "down"}
           end) ==
             [%{"error" => "down"}, %{"error" => "down"}]
  end
end
