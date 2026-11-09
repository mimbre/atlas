Code.require_file("../../../beam/apps/atlas_bus/lib/atlas_bus/digest.ex", __DIR__)
Code.require_file("../../../beam/apps/atlas_bus/lib/atlas_bus/subject_fingerprint.ex", __DIR__)
# Exercise the pure platform evaluators against the contract without starting any apps
# or adding a production dependency from declarations to runtime services.
for file <- ["definitions", "request", "rules", "verdict"] do
  Code.require_file("../../../beam/apps/atlas_gates/lib/atlas_gates/#{file}.ex", __DIR__)
end

Code.require_file("../../../beam/apps/atlas_facts/lib/atlas_facts/guards.ex", __DIR__)

for file <- ~w(conditions inputs run) do
  Code.require_file("../../../beam/apps/atlas_flow/lib/atlas_flow/runs/#{file}.ex", __DIR__)
end

Code.require_file("../../../beam/apps/atlas_flow/lib/atlas_flow/activities/gate.ex", __DIR__)

defmodule AtlasFlowContract.DeciderTest do
  use ExUnit.Case, async: true
  alias AtlasGates.{Definitions, Request, Rules, Verdict}
  alias AtlasBus.Digest

  test "slice-1 cursors migrate against both deployed definition digests" do
    alias AtlasFlow.Runs.Run
    now = ~U[2026-11-12 00:00:00Z]
    old_digest = "e59a6880bf210d104ff7231f6e354a59b27caf01b9207e7522eb647edc523054"
    config = JSON.decode!(File.read!("../../rela/flow-runtime.json"))["flow_runtime"]
    selection = config["selection"]["decide"]

    for path <- ["../targets/atlas/flows.json", "../targets/test/atlas/flows.json"] do
      definition = JSON.decode!(File.read!(path))["flows"]["decide"]

      assert Enum.count(
               selection["migrations"],
               &(&1["from"] == old_digest and &1["to"] == Run.digest(definition))
             ) == 1

      for state <- ~w(proposed accepted rejected) do
        subject = %{"key" => "D-old", "values" => %{"status" => state}}
        old = Run.new("decide", definition, subject, selection["imports"], now)

        old =
          Map.merge(old, %{
            "definition_sha256" => old_digest,
            "state" => state,
            "pending" => %{"version" => 1, "writes" => []}
          })

        assert {:ok, migrated} = Run.migrate(old, definition, selection["migrations"], now)

        if state == "proposed" do
          assert migrated["state"] == "deciding"
          assert migrated["entry"] == old["entry"] + 1
          assert migrated["definition_sha256"] == Run.digest(definition)
          assert migrated["pending"]["gate"] == nil
          assert length(migrated["pending"]["migrations"]) == 1

          assert {:ok, ^migrated} =
                   Run.migrate(migrated, definition, selection["migrations"], now)
        else
          assert migrated == old
        end
      end
    end
  end

  test "the executable decider uses recorded gate results and trusted choices with environment limits" do
    [flow] = AtlasFlowContract.Decision.__flows__()
    gates = AtlasFlowContract.Gates.__gates__()
    [resolved] = AtlasFlowGenerator.Limits.resolve([flow], gates, :test)
    json = AtlasFlowGenerator.Atlas.flows_json([resolved], gates, "test") |> JSON.decode!()
    definition = json["flows"]["decide"]
    assert AtlasFlow.Runs.Run.validate(definition) == :ok

    assert definition["initial"] == "deciding"
    assert definition["states"]["deciding"]["kind"] == "gate"

    assert definition["states"]["for_person"]["timers"] == [
             %{"name" => "no_answer", "period" => "5m", "to" => "deciding"}
           ]

    assert definition["states"]["for_person_always"]["timers"] == []

    assert definition["states"]["for_agent_unverified"]["set"] == [
             %{"field" => "unverified", "value" => true}
           ]

    for state <- ~w(for_person for_person_always for_agent for_agent_unverified),
        branch <- definition["states"][state]["branches"],
        do: assert(branch["roles"] != [])

    [prod] = AtlasFlowGenerator.Limits.resolve([flow], gates, :prod)

    assert Enum.find(prod.states, &(&1.name == :for_person)).timers |> hd() |> Map.fetch!(:period) ==
             "48h"

    config = File.read!("../../rela/flow-runtime.json") |> JSON.decode!()
    assert Map.keys(config["flow_runtime"]["selection"]) == ["decide"]
    assert config["flow_runtime"]["inputs"]["roles"]["decider"] == "decided_by"
    selection = config["flow_runtime"]["selection"]["decide"]
    assert selection["subject"] == definition["subject"]

    assert Enum.any?(
             selection["migrations"],
             &(&1["to"] == AtlasFlow.Runs.Run.digest(definition))
           )

    for status <- ~w(accepted rejected superseded) do
      subject = %{"key" => "D-history", "values" => %{"status" => status}}

      run =
        AtlasFlow.Runs.Run.new(
          "decide",
          definition,
          subject,
          selection["imports"],
          ~U[2026-11-12 00:00:00Z]
        )

      assert run["status"] == "completed"
      assert run["pending"]["writes"] == []
      assert run["state"] == if(status == "rejected", do: "rejected", else: "accepted")
    end
  end

  test "the frozen rule only permits clearing the unverified flag, and only Flow writes it" do
    extra = JSON.decode!(File.read!("../../rela/atlas.json"))
    extra = Map.merge(extra, JSON.decode!(File.read!("../../rela/flow-runtime.json")))
    rules = AtlasFacts.Guards.of(extra, "decision")

    current = %{
      "values" => %{"status" => "accepted", "unverified" => true},
      "links" => %{"decided_by" => ["a"]}
    }

    env = %{"writer" => "flow", "sender" => "flow", "kind_of" => fn _, _ -> "person" end}

    assert :ok =
             AtlasFacts.Guards.check(
               rules,
               "change",
               "D-test",
               current,
               %{"unverified" => false},
               %{},
               env
             )

    assert {:refused, _} =
             AtlasFacts.Guards.check(
               rules,
               "change",
               "D-test",
               put_in(current, ["values", "unverified"], false),
               %{"unverified" => true},
               %{},
               env
             )

    assert {:refused, _} =
             AtlasFacts.Guards.check(
               rules,
               "change",
               "D-test",
               current,
               %{"unverified" => false},
               %{},
               %{env | "sender" => "control/session-1"}
             )

    assert {:refused, _} =
             AtlasFacts.Guards.check(
               rules,
               "change",
               "D-test",
               current,
               %{"title" => "edited"},
               %{},
               env
             )
  end

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

  test "fresh verdict enforcement preserves the prior split for the complete classification matrix" do
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
      result = ask(evidence(Map.merge(fields, %{"forces" => [force], "delegated" => delegated})))

      expected_agent =
        category not in ["product", "security"] and reversibility != "one_way" and
          force != "principle" and delegated

      assert result.outcome == "agent" == expected_agent
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
          %{
            "writer" => "writer",
            "kind_of" => fn _, _ -> kind end,
            "verdict" => fn "accept_decision", "D-example" ->
              %{
                "verdict" => result.outcome,
                "fingerprint" =>
                  AtlasBus.SubjectFingerprint.of(
                    %{"values" => fields, "links" => links},
                    authority["decider"]["fingerprint"]
                  )
              }
            end
          }
        ) == :ok
      end

      assert permitted.("person")

      assert result.outcome in ["agent", "agent_unverified"] == permitted.("agent"),
             "authority parity: #{inspect(combination)}"
    end
  end

  test "the gate declares the decided limits, v1 and fixed prefix" do
    {:ok, gate} = Definitions.fetch("accept_decision")
    description = JSON.decode!(File.read!("../../rela/atlas.json"))
    authority = get_in(description, ["entities", "decision", "authority"])
    refute Map.has_key?(authority, "only_kind_when")
    refute Map.has_key?(authority, "delegated_by")
    assert authority["decider"]["fingerprint"] == gate["fingerprint"]
    assert gate["version"] == 1
    assert gate["flavor"] == "rule"
    assert gate["answer_within"] == %{"test" => "5m", "prod" => "48h"}
    assert :ok = Definitions.check_fixed(gate)
  end

  test "each decider verdict and the stale default enforce the acceptance table" do
    authority =
      JSON.decode!(File.read!("../../rela/atlas.json"))["entities"]["decision"]["authority"]

    fact = %{"values" => %{"title" => "Example", "force" => "principle"}, "links" => %{}}
    fingerprint = AtlasBus.SubjectFingerprint.of(fact, authority["decider"]["fingerprint"])

    for outcome <- [nil, "person_always", "person", "agent", "agent_unverified"],
        actor <- ["person", "agent"],
        fresh <- [true, false] do
      verdict =
        if outcome,
          do: %{"verdict" => outcome, "fingerprint" => if(fresh, do: fingerprint, else: "old")}

      result =
        AtlasFacts.Guards.check(
          %{"authority" => authority},
          "change",
          "D-example",
          fact,
          %{"status" => "accepted"},
          %{"decided_by" => ["writer"]},
          %{
            "writer" => "writer",
            "kind_of" => fn _, _ -> actor end,
            "verdict" => fn _, _ -> verdict end
          }
        )

      assert result == :ok ==
               (actor == "person" or (fresh and outcome in ["agent", "agent_unverified"]))
    end
  end
end
