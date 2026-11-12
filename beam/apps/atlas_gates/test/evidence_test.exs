defmodule AtlasGates.EvidenceTest do
  use ExUnit.Case, async: true
  alias AtlasGates.{Decider, Evidence, FakeFacts}
  alias AtlasBus.{Digest, SubjectFingerprint}

  @fingerprint %{"fields" => ["title", "weight"], "relations" => ["replaces"]}
  defp gate do
    %{
      "version" => 1,
      "flavor" => "rule",
      "purpose" => "decider",
      "fingerprint" => @fingerprint,
      "evidence" => %{
        "weights" => [["field", "weight"], ["linked", "replaces", "weight"]],
        "weight" => ["field", "weight"],
        "delegated" => ["present", "under"],
        "ready" => ["constant", true],
        "timed_out" => ["flow", "timed_out", %{"default" => false}],
        "count" => ["history", "count", %{"window" => 50, "same" => ["weight"]}],
        "rate" => ["history", "overruled", %{"window" => 50, "same" => ["weight"]}]
      },
      "rule" => %{"all" => [["equals", "delegated", true]]},
      "verdicts" => ["ask", "agent"],
      "decide" => %{
        "pass" => "agent",
        "changes_required" => "ask",
        "uncertain" => "ask",
        "error" => "ask"
      }
    }
  end

  defp create({module, state}, kind, values, links \\ %{}) do
    {:ok, key} = module.create(state, kind, "fixture", values, links)
    key
  end

  defp setup_facts do
    facts = FakeFacts.start()
    old = create(facts, "parcel", %{"weight" => "heavy"})

    key =
      create(facts, "parcel", %{"title" => "A", "weight" => "light"}, %{
        "replaces" => [old],
        "under" => ["J"]
      })

    {facts, key}
  end

  test "all evidence sources read exact facts, empty history, flow defaults and overrides" do
    {facts, key} = setup_facts()
    opts = [gates: %{"allocate" => gate()}, kind: "ruling"]
    assert {:ok, request} = Decider.request("allocate", key, facts, opts)

    assert request.evidence == %{
             "weights" => ["light", "heavy"],
             "weight" => "light",
             "delegated" => true,
             "ready" => true,
             "count" => 0,
             "rate" => 0,
             "timed_out" => false
           }

    assert request.evidence_digest == Digest.of_term(request.evidence)
    assert request.links == %{"about" => key}

    assert {:ok, timed} =
             Decider.request("allocate", key, facts, opts ++ [flow: %{"timed_out" => true}])

    assert timed.evidence["timed_out"]

    assert {:ok, %{outcome: "agent", recorded_as: :new}} =
             Decider.ask("allocate", key, facts, opts)

    assert {:ok, %{outcome: "agent", recorded_as: :again}} =
             Decider.ask("allocate", key, facts, opts)

    assert {:ok, next} = Decider.request("allocate", key, facts, opts)
    assert next.links["follows"]
  end

  test "history uses the newest 50 recorded matching snapshots, including feedback links" do
    {facts, key} = setup_facts()

    for n <- 1..60 do
      create(
        facts,
        "ruling",
        %{
          "gate" => "allocate",
          "purpose" => "decider",
          "subject" => "P-#{n}",
          "evidence" => "weight: light",
          "decided_at" => n |> Integer.to_string() |> String.pad_leading(3, "0")
        },
        if(n > 50, do: %{"overruled_by" => ["J"]}, else: %{})
      )
    end

    for {gate, purpose, evidence} <- [
          {"other", "decider", "weight: light"},
          {"allocate", "flow", "weight: light"},
          {"allocate", "decider", "weight: heavy"}
        ] do
      create(facts, "ruling", %{
        "gate" => gate,
        "purpose" => purpose,
        "evidence" => evidence,
        "decided_at" => "999"
      })
    end

    {module, state} = facts
    {:ok, subject} = module.fetch(state, nil, key)
    assert {:ok, evidence, _} = Evidence.build("allocate", gate(), subject, facts, kind: "ruling")
    assert evidence["count"] == 50
    assert evidence["rate"] == 0.2
  end

  test "fingerprints sort relation keys, ignore status and change with deciding values" do
    a = %{
      "values" => %{"title" => "A", "weight" => "light"},
      "links" => %{"replaces" => ["2", "1"]}
    }

    b = %{a | "links" => %{"replaces" => ["1", "2"]}}
    assert SubjectFingerprint.of(a, @fingerprint) == SubjectFingerprint.of(b, @fingerprint)

    assert SubjectFingerprint.of(a, @fingerprint) ==
             SubjectFingerprint.of(put_in(a, ["values", "status"], "final"), @fingerprint)

    refute SubjectFingerprint.of(a, @fingerprint) ==
             SubjectFingerprint.of(put_in(a, ["values", "title"], "B"), @fingerprint)
  end

  test "missing subjects and failed reads give no authorization" do
    facts = FakeFacts.start()

    assert {:error, "no subject missing"} =
             Decider.ask("allocate", "missing", facts,
               gates: %{"allocate" => gate()},
               kind: "ruling"
             )

    unavailable =
      AtlasGates.Facts.Control.new("test", client: fn _ -> {:error, "Facts unavailable"} end)

    assert {:error, "Facts unavailable"} =
             Decider.ask("allocate", "C-7", unavailable,
               gates: %{"allocate" => gate()},
               kind: "ruling"
             )
  end
end
