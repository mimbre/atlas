# Exercise the pure platform evaluators against the contract without starting any apps
# or adding a production dependency from declarations to runtime services.
for file <- ["digest", "definitions", "request", "rules", "verdict"] do
  Code.require_file("../../../beam/apps/atlas_gates/lib/atlas_gates/#{file}.ex", __DIR__)
end

Code.require_file("../../../beam/apps/atlas_facts/lib/atlas_facts/guards.ex", __DIR__)

defmodule AtlasFlowContract.DeciderTest do
  use ExUnit.Case, async: true
  alias AtlasGates.{Definitions, Digest, Request, Rules, Verdict}

  defp evidence(changes \\ %{}) do
    Map.merge(
      %{
        "forces" => ["direction"],
        "category" => "process",
        "reversibility" => "two_way",
        "scope" => "platform",
        "delegated" => true,
        "production_release" => false,
        "rollback_automated" => false,
        "overrule_rate" => 0,
        "verdicts_seen" => 0,
        "timed_out" => false
      },
      changes
    )
  end

  defp ask(evidence) do
    {:ok, r} =
      Request.new("accept_decision", %{
        subject: "D-example",
        fingerprint: "f",
        evidence: evidence,
        evidence_digest: Digest.of_term(evidence)
      })

    Verdict.settle(r, Rules.evaluate(r.definition, evidence), 0)
  end

  test "fixed rules win before timeout, person and agent rules, without reading later fields" do
    assert %{outcome: "person_always", unsettled: nil} =
             ask(%{"forces" => ["direction", "principle"]})

    assert %{outcome: "person_always"} =
             ask(evidence(%{"production_release" => true, "timed_out" => true}))

    assert %{outcome: "agent_unverified"} =
             ask(
               evidence(%{
                 "production_release" => true,
                 "rollback_automated" => true,
                 "timed_out" => true
               })
             )
  end

  test "timeout wins over tunable person rules" do
    assert %{outcome: "agent_unverified"} =
             ask(
               evidence(%{
                 "timed_out" => true,
                 "category" => "product",
                 "reversibility" => "one_way"
               })
             )
  end

  test "person rules win over delegation" do
    for extra <- [
          %{"category" => "product"},
          %{"category" => "security"},
          %{"reversibility" => "one_way"},
          %{"overrule_rate" => 0.2, "verdicts_seen" => 10}
        ] do
      assert %{outcome: "person", unsettled: nil} = ask(evidence(extra))
    end

    for extra <- [
          %{"overrule_rate" => 0.199, "verdicts_seen" => 10},
          %{"overrule_rate" => 0.2, "verdicts_seen" => 9}
        ] do
      assert %{outcome: "agent"} = ask(evidence(extra))
    end
  end

  test "delegation allows an agent after earlier rules" do
    assert %{outcome: "agent", unsettled: nil} = ask(evidence())
  end

  test "otherwise advises and v1 settles advice as person" do
    assert %{outcome: "person", rule_outcome: "advise", unsettled: nil} =
             ask(evidence(%{"delegated" => false}))
  end

  test "a missing field is uncertain and settles as person" do
    for field <- [
          "forces",
          "production_release",
          "rollback_automated",
          "timed_out",
          "category",
          "reversibility",
          "overrule_rate",
          "verdicts_seen",
          "delegated"
        ] do
      assert %{outcome: "person", unsettled: "uncertain"} =
               ask(Map.delete(evidence(), field))
    end
  end

  test "person/agent split matches the existing authority guard for the complete classification matrix" do
    description = JSON.decode!(File.read!("../../rela/atlas.json"))
    authority = get_in(description, ["entities", "decision", "authority"])
    schema = File.read!("../../rela/modules/foundation/schema.yaml")

    values = fn type ->
      [_, csv] = Regex.run(~r/  #{type}:\n    values: \[([^\]]+)\]/, schema)
      String.split(csv, ", ")
    end

    combinations =
      for category <- values.("decision_category"),
          reversibility <- values.("decision_reversibility"),
          force <- values.("decision_force"),
          delegated <- [false, true],
          do: {category, reversibility, force, delegated}

    assert length(combinations) == 128

    for {category, reversibility, force, delegated} = combination <- combinations do
      fields = %{"category" => category, "reversibility" => reversibility, "force" => force}
      # Same write inputs as GuardsTest: create accepted, named writer, singleton
      # decider/delegation links, and kind_of callback for both possible actors.
      permitted = fn kind ->
        links = %{"decided_by" => ["writer"]}
        links = if delegated, do: Map.put(links, "delegated_by", ["person"]), else: links

        AtlasFacts.Guards.check(
          %{"authority" => authority},
          "create",
          "D-example",
          nil,
          Map.put(fields, "status", "accepted"),
          links,
          %{"writer" => "writer", "kind_of" => fn _, _ -> kind end}
        ) == :ok
      end

      assert permitted.("person")
      result = ask(evidence(Map.merge(fields, %{"forces" => [force], "delegated" => delegated})))

      assert result.outcome in ["agent", "agent_unverified"] == permitted.("agent"),
             "authority parity: #{inspect(combination)}"
    end
  end

  test "the gate declares the decided limits, v1 and fixed prefix" do
    {:ok, gate} = Definitions.fetch("accept_decision")
    assert gate["version"] == 1
    assert gate["flavor"] == "rule"
    assert gate["answer_within"] == %{"test" => "5m", "prod" => "48h"}
    assert :ok = Definitions.check_fixed(gate)
  end
end
