defmodule AtlasGates.FirstTest do
  use ExUnit.Case, async: true

  alias AtlasGates.{Definitions, Rules}

  defp gate do
    fixed = %{
      "name" => "sealed",
      "when" => [["includes", "tags", "sealed"]],
      "then" => "hold",
      "cites" => "POL-1"
    }

    %{
      "evidence" => %{
        "tags" => ["field", "tags"],
        "expired" => [],
        "zone" => [],
        "score" => [],
        "permitted" => []
      },
      "fixed" => "hold",
      "fixed_rules" => [fixed],
      "rule" => %{
        "first" => [
          fixed,
          %{"when" => [["equals", "expired", true]], "then" => "late"},
          %{
            "when" => [["in", "zone", ["north", "south"]], ["at_least", "score", 0.2]],
            "then" => "check"
          },
          %{"when" => [["equals", "permitted", true]], "then" => "go"}
        ],
        "otherwise" => "advise"
      }
    }
  end

  defp evidence(changes \\ %{}),
    do:
      Map.merge(
        %{
          "tags" => [],
          "expired" => false,
          "zone" => "north",
          "score" => 0.1,
          "permitted" => true
        },
        changes
      )

  test "ordered cases short circuit and keep their outcomes" do
    assert {"hold", []} = Rules.evaluate(gate(), %{"tags" => ["sealed"]})
    assert {"late", []} = Rules.evaluate(gate(), evidence(%{"expired" => true, "score" => nil}))
    assert {"check", []} = Rules.evaluate(gate(), evidence(%{"score" => 0.2}))
    assert {"go", []} = Rules.evaluate(gate(), evidence())
    assert {"advise", []} = Rules.evaluate(gate(), evidence(%{"permitted" => false}))
  end

  test "membership, inclusion and numeric thresholds use values and types" do
    assert {"check", []} = Rules.evaluate(gate(), evidence(%{"zone" => "south", "score" => 1}))
    assert {"go", []} = Rules.evaluate(gate(), evidence(%{"zone" => "east", "score" => 1}))
    assert {"go", []} = Rules.evaluate(gate(), evidence(%{"tags" => ["open"]}))

    for extra <- [%{"tags" => "sealed"}, %{"score" => "0.3"}, %{"score" => nil}] do
      assert {"uncertain", _} = Rules.evaluate(gate(), evidence(extra))
    end
  end

  test "missing evidence in an earlier case prevents a later case from granting access" do
    for field <- ["tags", "expired", "zone", "score", "permitted"] do
      assert {"uncertain", _} = Rules.evaluate(gate(), Map.delete(evidence(), field))
    end

    # Missing evidence outweighs a false condition in the same case.
    assert {"uncertain", _} =
             Rules.evaluate(gate(), evidence(%{"zone" => "east"}) |> Map.delete("score"))

    changed = put_in(gate(), ["evidence"], ["tags", "expired", "score", "permitted"])
    assert {"uncertain", _} = Rules.evaluate(changed, evidence())
  end

  test "fixed rules cannot be moved, changed, omitted or stripped of their citations" do
    g = gate()
    cases = g["rule"]["first"]

    for changed <- [
          put_in(g, ["rule", "first"], Enum.reverse(cases)),
          put_in(g, ["rule", "first"], tl(cases)),
          put_in(g, ["rule"], %{"all" => [["equals", "permitted", true]]}),
          put_in(g, ["fixed_rules"], []),
          put_in(g, ["fixed_rules"], [Map.delete(hd(cases), "cites")]),
          Map.delete(g, "fixed_rules")
        ] do
      assert {:error, _} = Definitions.check_fixed(changed)
      assert {"error", _} = Rules.evaluate(changed, evidence())
    end
  end

  test "malformed ordered cases and operators return errors" do
    for rule <- [
          %{"first" => [], "otherwise" => "go"},
          %{"first" => [%{"when" => [], "then" => "go"}], "otherwise" => "hold"},
          %{
            "first" => [%{"when" => [["unknown", "zone", 3]], "then" => "go"}],
            "otherwise" => "hold"
          },
          %{
            "first" => [%{"when" => [["at_least", "score", "3"]], "then" => "go"}],
            "otherwise" => "hold"
          }
        ] do
      assert {"error", _} =
               Rules.evaluate(%{"evidence" => ["score", "zone"], "rule" => rule}, evidence())
    end
  end
end
