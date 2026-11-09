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

  test "a page asks its reads in one _page read, and takes the answers in order" do
    mine = %{"key" => "T-1", "links" => %{"held_by" => ["K-1"]}}
    other = %{"key" => "T-2", "links" => %{"held_by" => ["K-2"]}}
    box = %{"key" => "B-1", "links" => %{"tagged" => ["T-1"]}}

    ask = fn kind, content, budget ->
      assert kind == "_page"
      send(self(), {:page, content, budget})

      case content["reads"] do
        [["tag", %{"linked" => %{"held_by" => "K-1"}}], ["box", %{}]] ->
          %{
            "answers" => [
              %{"facts" => [mine], "position" => 4},
              %{"facts" => [box], "position" => 4}
            ]
          }

        [["tag", %{}], ["box", %{}]] ->
          %{"answers" => [%{"facts" => [mine, other]}, %{"facts" => [box]}]}
      end
    end

    assigned = PageReads.answers({:assigned, "K-1"}, @description, ask)
    # One read for two: it waits as long as the two would.
    assert_receive {:page, _, 2}
    refute_received {:page, _, _}
    assert Pages.assigned_facts(@description, assigned) == [{"box", box, mine}]
    assert Pages.assigned_count(@description, assigned) == "1"

    assert PageReads.answers({:list, "tag"}, @description, ask) ==
             [%{"facts" => [mine, other]}, %{"facts" => [box]}]

    # The Assignments are the rows; their owners only resolve them.
    assert PageReads.roles({:assigned, "K-1"}, @description) == [{"tag", :rows}, {"box", :lookup}]
    assert PageReads.roles({:list, "box"}, @description) == [{"box", :rows}]
  end

  test "a page without reads asks nothing" do
    assert PageReads.answers({:new, "box"}, @description, fn _, _, _ -> flunk("asked") end) == []
  end

  test "a failed page read is the answer of each of its reads" do
    assert PageReads.answers({:assigned, "K-1"}, @description, fn _, _, _ ->
             %{"error" => "down"}
           end) ==
             [%{"error" => "down"}, %{"error" => "down"}]

    assert PageReads.answers({:assigned, "K-1"}, @description, fn _, _, _ ->
             %{"answers" => [%{"facts" => []}]}
           end) ==
             List.duplicate(%{"error" => "Facts returned invalid page reads"}, 2)
  end
end
