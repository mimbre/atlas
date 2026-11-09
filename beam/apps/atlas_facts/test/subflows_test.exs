defmodule AtlasFacts.SubflowsTest do
  use ExUnit.Case, async: true

  alias AtlasFacts.Subflows

  # A neutral description: letters, assigned through a desk to a clerk or a team.
  @description %{
    "entities" => %{
      "letter" => %{"properties" => %{"notes" => %{}}},
      "desk" => %{},
      "clerk" => %{},
      "team" => %{}
    },
    "relations" => %{
      "desk_of" => %{"from" => ["letter"], "to" => ["desk"], "max_outgoing" => 1},
      "held_by" => %{"from" => ["desk"], "to" => ["clerk", "team"]},
      "retried_by" => %{"from" => ["letter"], "to" => ["clerk"]}
    }
  }

  @present %{
    "expected" => "Decide on it",
    "todo" => %{
      "section" => %{"field" => "notes", "heading" => "What went wrong"},
      "answers" => [%{"key" => "r", "label" => "Retry", "set" => "retried_by"}]
    }
  }

  defp subflow(owner, present \\ @present) do
    %{
      "letter" => %{
        "subject" => "letter",
        "owner" => owner,
        "states" => %{"stuck" => %{"final" => false, "present" => present}}
      }
    }
  end

  @owner %{
    "via" => "desk_of",
    "relation" => "held_by",
    "default" => %{"kind" => "team", "key" => "post_room"}
  }

  test "the description is answered with the subflows, owners and presentation as generated" do
    described = Subflows.describe(@description, subflow(@owner))
    assert described["subflows"] == subflow(@owner)
    assert described["subflow_problems"] == %{"letter" => []}
    assert described["entities"] == @description["entities"]
  end

  test "a default owner alone names a described kind" do
    assert Subflows.check(
             @description,
             subflow(%{"default" => %{"kind" => "team", "key" => "x"}})
           ) ==
             %{"letter" => []}

    assert Subflows.check(
             @description,
             subflow(%{"default" => %{"kind" => "robot", "key" => "x"}})
           ) ==
             %{"letter" => ["the default owner's kind, robot, is not described"]}
  end

  test "an owner whose relations are not the description's is a problem" do
    problems = fn owner -> Subflows.check(@description, subflow(owner))["letter"] end

    assert problems.(%{@owner | "via" => "retried_by"}) == [
             "owner relation held_by does not start at clerk"
           ]

    assert problems.(%{@owner | "relation" => "desk_of"}) == [
             "owner relation desk_of does not start at desk",
             "owner relation desk_of does not allow the default owner's kind, team"
           ]

    assert problems.(%{@owner | "via" => "nowhere"}) == ["owner via nowhere is not described"]
  end

  test "what a state shows names the kind's properties and described relations" do
    present =
      @present
      |> put_in(["todo", "section", "field"], "body")
      |> put_in(["todo", "answers"], [%{"key" => "x", "label" => "X", "remove" => "gone"}])

    assert Subflows.check(@description, subflow(@owner, present))["letter"] == [
             "stuck: its section shows body, which letter does not have",
             "stuck: its answer x names gone, which is not described"
           ]
  end

  test "a subflow on a kind that is not described" do
    flows = %{"x" => %{"subject" => "parcel", "states" => %{}}}

    assert Subflows.check(@description, flows) == %{
             "x" => ["runs on parcel, which is not described"]
           }
  end

  test "the generated subflows are compiled in, each with its subject, owner and states" do
    assert map_size(Subflows.flows()) > 0

    for {_name, subflow} <- Subflows.flows() do
      assert is_binary(subflow["subject"])
      assert is_map(subflow["states"])
    end

    assert Enum.any?(Subflows.flows(), fn {_, s} ->
             Enum.any?(s["states"], fn {_, st} ->
               is_binary(get_in(st, ["present", "expected"]))
             end)
           end)
  end
end
