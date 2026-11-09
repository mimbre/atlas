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
end
