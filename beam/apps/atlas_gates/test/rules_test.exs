defmodule AtlasGates.RulesTest do
  use ExUnit.Case, async: true

  alias AtlasGates.{Fixtures, Rules}

  defp dispatch(evidence), do: Rules.evaluate(Fixtures.gate("dispatch"), evidence)

  test "every condition holds: pass" do
    assert dispatch(Fixtures.evidence()) == {"pass", []}
  end

  test "a condition fails: changes required, saying which" do
    assert {"changes_required", [why]} = dispatch(Fixtures.evidence(%{"seal" => "broken"}))
    assert why =~ "seal"

    assert {"changes_required", [why]} = dispatch(Fixtures.evidence(%{"loaded_hash" => "h-2"}))
    assert why =~ "loaded_hash"
  end

  test "a missing or empty field: uncertain, also when another condition fails" do
    assert {"uncertain", [why]} = dispatch(Map.delete(Fixtures.evidence(), "packed_hash"))
    assert why =~ "packed_hash is missing"

    assert {"uncertain", _} = dispatch(Fixtures.evidence(%{"loaded_hash" => ""}))
    assert {"uncertain", _} = dispatch(Fixtures.evidence(%{"loaded_hash" => nil}))

    assert {"uncertain", _} =
             dispatch(Fixtures.evidence(%{"seal" => "broken"}) |> Map.delete("packed_hash"))
  end

  test "a field the gate does not declare: uncertain, even when it is given" do
    evidence = %{"seal" => "intact", "weight" => "light"}

    assert {"uncertain", [why]} = Rules.evaluate(Fixtures.gate("careless"), evidence)
    assert why =~ "weight is not evidence this gate declares"
  end

  test "evidence the gate does not ask for changes nothing" do
    assert dispatch(Fixtures.evidence(%{"note" => "extra"})) == {"pass", []}
  end

  test "a rule or condition the evaluator does not know: error" do
    gate = Fixtures.gate("dispatch")

    assert {"error", _} = Rules.evaluate(%{gate | "rule" => %{"any" => []}}, Fixtures.evidence())

    assert {"error", _} =
             Rules.evaluate(
               %{gate | "rule" => %{"all" => [["above", "seal", 3]]}},
               Fixtures.evidence()
             )

    assert {"error", _} = Rules.evaluate(Map.delete(gate, "rule"), Fixtures.evidence())
  end

  describe "the generated definitions" do
    test "every rule gate is one the evaluator applies, with a safe verdict" do
      rule_gates =
        for {name, %{"flavor" => "rule"} = g} <- AtlasGates.Definitions.gates(), do: {name, g}

      assert rule_gates != []

      for {name, gate} <- rule_gates do
        assert {"uncertain", _} = Rules.evaluate(gate, %{}), "#{name} without evidence"

        expected =
          case gate["rule"] do
            %{"first" => [first | _]} -> first["then"]
            _ -> "pass"
          end

        assert {^expected, []} = Rules.evaluate(gate, meeting(gate)),
               "#{name} on evidence that meets it"

        assert AtlasGates.Request.safe_verdict(gate) in gate["verdicts"]
      end
    end
  end

  # Evidence that meets a rule gate's conditions, made from the rule itself.
  defp meeting(%{"rule" => %{"first" => [first | _]}}),
    do: meeting(%{"rule" => %{"all" => first["when"]}})

  defp meeting(%{"rule" => %{"all" => conditions}}) do
    Enum.reduce(conditions, %{}, fn
      ["includes", field, value], acc -> Map.put(acc, field, [value])
      ["in", field, [value | _]], acc -> Map.put(acc, field, value)
      ["at_least", field, value], acc -> Map.put(acc, field, value)
      ["equals", field, value], acc -> Map.put(acc, field, value)
      ["same", a, b], acc -> acc |> Map.put(a, "same-#{a}-#{b}") |> Map.put(b, "same-#{a}-#{b}")
    end)
  end
end
