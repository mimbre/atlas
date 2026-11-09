defmodule RelaDSL.Flow.LegacyTest do
  use ExUnit.Case, async: true

  # The office's legacy flow, as its composition compiled it.
  @post RelaDSL.Office.Legacy.Post

  test "a composition compiles each legacy flow it declares, from its data" do
    assert RelaDSL.Office.legacy() == [@post]
    assert @post.name() == "post"
    assert @post.kinds() == ["letter"]

    assert @post.writes() == %{
             "on" => "desk",
             "field" => "expected",
             "state_field" => "flow_state",
             "handover_field" => "handover",
             "owner_relation" => "held_by"
           }
  end

  defmodule Approval do
    use RelaDSL.Flow.Legacy,
      name: :approval,
      flow: [
        kinds: [:letter],
        field: :expected,
        states: [
          [name: :done, when: [values: [state: [:sent]]], done: true],
          [name: :open, owner: [kind: :clerk, config: :approver], expected: "Approve it"]
        ]
      ]
  end

  test "a state's owner may name the role of a configured actor instead of a key" do
    assert Approval.owner("open") == %{"kind" => "clerk", "config" => "approver"}
    assert Approval.owner("done") == nil
  end

  test "a fact is in the first state that holds, the last when none other does" do
    assert {"done", _} = @post.state(%{"values" => %{"state" => "sent"}}, [], [], [])

    assert {"open", vars} =
             @post.state(%{"values" => %{"state" => "draft", "n" => 2}}, [], [], [])

    assert vars == %{"state" => "draft", "n" => 2}
    assert @post.done?("done") and not @post.done?("open")
    assert @post.owner("open") == %{"kind" => "clerk", "key" => "post_room"}
    assert @post.owner("done") == nil
    assert @post.expected("open", vars) == "Post it"
    assert @post.expected("done", vars) == nil
  end
end
