defmodule AtlasFlow.OwnershipTest do
  use ExUnit.Case, async: true
  alias AtlasFlow.Ownership
  @owner %{"kind" => "clerk", "key" => "ada"}

  test "only a state that declares preservation keeps an assignee of that kind" do
    read = fn "clerk", key -> %{"fact" => if(key == "bob", do: %{"key" => key})} end
    preserving = %{"owner" => @owner, "preserve_kind" => "clerk"}

    assert Ownership.resolve(preserving, ["bob"], read)["owner"] == %{
             "kind" => "clerk",
             "key" => "bob"
           }

    assert Ownership.resolve(preserving, ["machine"], read)["owner"] == @owner
    assert Ownership.resolve(preserving, [], read)["owner"] == @owner
    ordinary = %{"owner" => %{"kind" => "machine", "key" => "sorter"}}
    assert Ownership.resolve(ordinary, ["bob"], read) == ordinary

    assert Ownership.resolve(preserving, ["bob"], fn _, _ -> %{"error" => "offline"} end)[
             "owner_unavailable"
           ]
  end

  test "a list of kinds keeps an assignee of any of them, read in the declared order" do
    facts = %{{"clerk", "bob"} => true, {"robot", "sorter"} => true, {"desk", "front"} => true}

    read = fn kind, key ->
      %{"fact" => if(facts[{kind, key}], do: %{"key" => key})}
    end

    preserving = %{"owner" => @owner, "preserve_kind" => ["clerk", "robot", "desk"]}

    for {kind, key} <- [{"clerk", "bob"}, {"robot", "sorter"}, {"desk", "front"}] do
      assert Ownership.resolve(preserving, [key], read)["owner"] == %{
               "kind" => kind,
               "key" => key
             }
    end

    # An assignee of no listed kind, or none, takes the default.
    assert Ownership.resolve(preserving, ["nobody"], read)["owner"] == @owner
    assert Ownership.resolve(preserving, [], read)["owner"] == @owner

    # A kind that is not listed is not kept.
    only_clerks = %{preserving | "preserve_kind" => ["clerk"]}
    assert Ownership.resolve(only_clerks, ["sorter"], read)["owner"] == @owner

    # Facts not answering before the assignee was found: nothing is moved on a guess.
    flaky = fn
      "clerk", _ -> %{"fact" => nil}
      _, _ -> %{"error" => "offline"}
    end

    assert Ownership.resolve(preserving, ["sorter"], flaky)["owner_unavailable"]
    refute Map.has_key?(Ownership.resolve(preserving, ["bob"], read), "owner_unavailable")
  end
end
