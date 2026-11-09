# The write rules Facts checks are the model's compiled `check/4`, exercised without
# starting any app; Flow, Gates and Facts are the model's (compile-time) dependencies.
defmodule Model.DeciderTest do
  use ExUnit.Case, async: true
  alias AtlasGates.{Definitions, Request, Rules, Verdict}
  alias AtlasBus.Digest

  @authority Model.AtlasEyra.__rela__(:description).extension["entities"]["decision"][
               "authority"
             ]

  # The model's check of a write on a decision `key`: the fact as stored (`current`), what
  # the write sets, who sends it, the kind each linked actor is, and the newest decider
  # verdict on it (its properties, or nil).
  defp check(op, current, values, links, actor, kind, verdict \\ nil) do
    key = "D-example"

    lookup = %{
      "current" => fn -> current end,
      "fact" => fn of, at -> if of == kind, do: %{key: at, properties: %{}, links: %{}} end,
      "list" => fn
        "gate_verdict" when is_map(verdict) ->
          {:ok,
           [
             %{
               key: "GV-0001",
               links: %{"about" => [key]},
               properties:
                 Map.merge(verdict, %{
                   "gate" => "accept_decision",
                   "subject" => key,
                   "purpose" => "decider"
                 })
             }
           ]}

        _ ->
          {:ok, []}
      end,
      "incoming" => fn _, _, _ -> [] end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }

    case Model.AtlasEyra.check(
           "decision",
           %{"op" => op, "key" => key, "values" => values, "links" => links},
           actor,
           lookup
         ) do
      :ok -> :ok
      {:refuse, reasons} -> {:refused, reasons}
    end
  end

  # The decide subflow as the model compiled it for `env`.
  defp decide(env), do: Enum.find(Model.AtlasEyra.subflows(env), &(&1.name() == "decide"))

  test "slice-1 cursors migrate against both deployed definition digests" do
    alias AtlasFlow.Runs.Run
    now = ~U[2026-11-12 00:00:00Z]
    old_digest = "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c"
    selection = Model.AtlasEyra.selection("decide")
    # Captured from the deployed slice-1 runs in both environments, rather than
    # inferred from a reconstruction of the old declaration.
    assert Enum.count(selection["migrations"], &(&1["from"] == old_digest)) == 2
    assert length(selection["migrations"]) == 6

    for env <- [:prod, :test] do
      definition = decide(env)

      assert Enum.count(
               selection["migrations"],
               &(&1["from"] == old_digest and &1["to"] == definition.digest())
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
          assert migrated["definition_sha256"] == definition.digest()
          assert migrated["pending"]["gate"] == nil
          assert length(migrated["pending"]["migrations"]) == 1

          assert {:ok, ^migrated} =
                   Run.migrate(migrated, definition, selection["migrations"], now)

          # The first slice-3 deploy already blocked the old cursor. Installing
          # the corrected mapping must recover it without a manual store edit.
          blocked = Run.block_definition(old, definition)
          assert blocked["status"] == "blocked"

          assert {:ok, ^migrated} =
                   Run.migrate(blocked, definition, selection["migrations"], now)
        else
          assert migrated == old
        end
      end
    end
  end

  test "only person waits declare person ownership and owner answers" do
    definition = decide(:prod)

    for state <- ~w(for_person for_person_always) do
      assert definition.owner(state) == %{
               "via" => "assignment",
               "relation" => "assigned_to",
               "default" => %{"kind" => "person", "key" => "melle"},
               "preserve_kind" => "person"
             }

      assert [
               %{
                 "key" => "a",
                 "change" => %{
                   "self" => "decided_by",
                   "values" => %{"status" => "accepted", "decided_at" => "$now"}
                 }
               },
               %{
                 "key" => "f",
                 "note" => true,
                 "change" => %{
                   "self" => "decided_by",
                   "values" => %{"status" => "rejected", "decided_at" => "$now"}
                 }
               }
             ] = get_in(definition.present(state, %{}), ["todo", "answers"])
    end

    for state <- ~w(for_agent for_agent_unverified accepted rejected) do
      assert definition.owner(state) == definition.owner()
      assert get_in(definition.present(state, %{}) || %{}, ["todo", "answers"]) == nil
    end

    assert definition.present("for_person", %{})["deadline"] == "no_answer"
    refute definition.present("for_person_always", %{})["deadline"]
  end

  test "the executable decider uses recorded gate results and trusted choices with environment limits" do
    alias AtlasFlow.Runs.Run
    definition = decide(:test)
    assert Run.validate(definition) == :ok

    assert definition.initial() == "deciding"
    assert {:gate, %{"gate" => "accept_decision"}} = definition.mechanism("deciding")

    assert definition.timers("for_person") == [
             %{"name" => "no_answer", "period" => "5m", "to" => "deciding"}
           ]

    assert definition.timers("for_person_always") == []
    assert definition.enter("for_agent_unverified", %{}) == [{:set, %{"unverified" => true}}]

    # Only a role's input moves a waiting decision: a change alone never does.
    for state <- ~w(for_person for_person_always for_agent for_agent_unverified) do
      assert definition.next(state, %{"status" => "accepted"}, nil) == :stay
      [role | _] = definition.waiting_for(state)
      input = %{roles: [role], changed: %{"status" => "accepted"}}
      assert definition.next(state, %{"status" => "accepted"}, input) == {:to, "accepted"}
    end

    assert [%{"period" => "48h"}] = decide(:prod).timers("for_person")

    runs = Model.AtlasEyra.runs()
    assert runs["inputs"]["roles"]["decider"] == "decided_by"

    selected =
      for f <- Model.AtlasEyra.subflows(:prod),
          Model.AtlasEyra.selection(f.name()) != nil,
          do: f.name()

    assert selected == ["decide"]
    selection = Model.AtlasEyra.selection("decide")
    assert selection["subject"] == definition.subject()
    assert Enum.any?(selection["migrations"], &(&1["to"] == definition.digest()))

    for status <- ~w(accepted rejected superseded) do
      subject = %{"key" => "D-history", "values" => %{"status" => status}}
      run = Run.new("decide", definition, subject, selection["imports"], ~U[2026-11-12 00:00:00Z])
      assert run["status"] == "completed"
      assert run["pending"]["writes"] == []
      assert run["state"] == if(status == "rejected", do: "rejected", else: "accepted")
    end
  end

  test "the legacy decide fills what is expected; a field the decision lacks leaves no braces" do
    waiting = Model.AtlasEyra.Legacy.Decide

    {state, vars} =
      waiting.state(
        %{"values" => %{"status" => "accepted", "consequences" => "the ledger changes"}},
        [],
        [],
        ["based_on"]
      )

    assert waiting.expected(state, vars) =~ "the ledger changes"

    # Accepted on the timeout path, without consequences (an agent decided it, unverified).
    {state, vars} =
      waiting.state(%{"values" => %{"status" => "accepted", "unverified" => true}}, [], [], [
        "based_on"
      ])

    assert state == "waiting"
    refute waiting.expected(state, vars) =~ "{"
  end

  test "the frozen rule only permits clearing the unverified flag, and only Flow writes it" do
    current = %{
      "values" => %{"status" => "accepted", "unverified" => true},
      "links" => %{"decided_by" => ["a"]}
    }

    flow = %{"by" => "flow", "sender" => "flow"}

    assert :ok = check("change", current, %{"unverified" => false}, %{}, flow, "person")

    assert {:refused, _} =
             check(
               "change",
               put_in(current, ["values", "unverified"], false),
               %{"unverified" => true},
               %{},
               flow,
               "person"
             )

    assert {:refused, _} =
             check(
               "change",
               current,
               %{"unverified" => false},
               %{},
               %{flow | "sender" => "control/session-1"},
               "person"
             )

    assert {:refused, _} = check("change", current, %{"title" => "edited"}, %{}, flow, "person")
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
    schema = File.read!("../../rela/modules/foundation/schema.yaml")

    values = fn type ->
      [_, items] = Regex.run(~r/  #{type}:\n    values:\n((?:    - .+\n)+)/, schema)
      items |> String.split("\n", trim: true) |> Enum.map(&String.trim_leading(&1, "    - "))
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
      # An accepted write by its named writer, the one decided_by links; a delegation
      # already stored (only its person sets it), and a principle naming its check.
      permitted = fn kind ->
        current = %{
          "values" => %{},
          "links" => if(delegated, do: %{"delegated_by" => ["person"]}, else: %{})
        }

        links = %{"decided_by" => ["writer"]}

        check(
          "change",
          current,
          Map.merge(fields, %{"status" => "accepted", "enforced_by" => "a check"}),
          links,
          %{"by" => "writer"},
          kind,
          %{
            "verdict" => result.outcome,
            "fingerprint" =>
              AtlasBus.SubjectFingerprint.of(
                %{"values" => fields, "links" => links},
                @authority["decider"]["fingerprint"]
              )
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
    authority = @authority
    refute Map.has_key?(authority, "only_kind_when")
    refute Map.has_key?(authority, "delegated_by")
    assert authority["decider"]["fingerprint"] == gate["fingerprint"]
    assert gate["version"] == 1
    assert gate["flavor"] == "rule"
    assert gate["answer_within"] == %{"test" => "5m", "prod" => "48h"}
    assert :ok = Definitions.check_fixed(gate)
  end

  test "each decider verdict and the stale default enforce the acceptance table" do
    fact = %{
      "values" => %{"title" => "Example", "force" => "principle", "enforced_by" => "a check"},
      "links" => %{}
    }

    fingerprint = AtlasBus.SubjectFingerprint.of(fact, @authority["decider"]["fingerprint"])

    for outcome <- [nil, "person_always", "person", "agent", "agent_unverified"],
        actor <- ["person", "agent"],
        fresh <- [true, false] do
      verdict =
        if outcome,
          do: %{"verdict" => outcome, "fingerprint" => if(fresh, do: fingerprint, else: "old")}

      result =
        check(
          "change",
          fact,
          %{"status" => "accepted"},
          %{"decided_by" => ["writer"]},
          %{"by" => "writer"},
          actor,
          verdict
        )

      assert result == :ok ==
               (actor == "person" or (fresh and outcome in ["agent", "agent_unverified"]))
    end
  end
end
