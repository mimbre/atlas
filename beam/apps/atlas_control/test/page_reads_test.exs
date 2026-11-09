defmodule AtlasControl.PageReadsTest do
  use ExUnit.Case, async: true
  alias AtlasControl.{PageReads, Pages}

  # Tags are held by a clerk, and a box has its tag as a component; a client opens on
  # what it holds, and the tags' list is open work.
  defmodule Held do
    @moduledoc false
    use RelaDSL

    entity :clerk, label: "Clerk", plural: "clerks", id_type: :manual do
      field(:name, :string)
    end

    entity :tag, label: "Tag", plural: "tags", id_type: :manual do
      field(:name, :string)
    end

    entity :box, label: "Box", plural: "boxes", id_type: :manual do
      field(:name, :string)
    end

    relation(:held_by, label: "held by", from: [:tag], to: [:clerk], max_outgoing: 1)

    relation(:tagged,
      label: "tagged",
      from: [:box],
      to: [:tag],
      max_outgoing: 1,
      component: [key: "T-{key}", values: [name: "{key}"]]
    )
  end

  defmodule Model do
    @moduledoc false
    use AtlasControl.Shop.Composition, name: "held", concepts: [AtlasControl.PageReadsTest.Held]
    start_page(assigned: [relation: :held_by, count: "{count}"], open: [title: "Held"])
  end

  @description AtlasControl.Model.catalog(Model)

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
