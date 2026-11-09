defmodule AtlasGates.DecideTest do
  @moduledoc "A request → a verdict, recorded once through a fake Facts."
  use ExUnit.Case, async: true

  alias AtlasGates.{FakeFacts, Fixtures, Request}

  @opts [kind: "ruling", now: Fixtures.now()]

  defp decide(request, facts), do: AtlasGates.decide(request, facts, @opts)

  test "a pass gives the decide map's verdict and is recorded with what it decided on" do
    facts = FakeFacts.start()
    request = Fixtures.request()

    assert {:ok, verdict} = decide(request, facts)
    assert verdict.outcome == "ship"
    assert verdict.rule_outcome == "pass"
    assert verdict.unsettled == nil
    assert verdict.recorded == "R-1" and verdict.recorded_as == :new
    assert is_integer(verdict.duration_ms)

    assert [%{kind: "ruling", request: id, values: values}] = FakeFacts.facts(facts)
    assert id == request.id

    assert values["gate"] == "dispatch"
    assert values["gate_version"] == "2"
    assert values["flavor"] == "rule" and values["purpose"] == "flow"
    assert values["subject"] == "C-7" and values["fingerprint"] == "f-1"
    assert values["evidence_digest"] == Fixtures.digest(Fixtures.evidence())
    assert values["evidence"] == "loaded_hash: h-1\npacked_hash: h-1\nseal: intact"
    assert values["rule_outcome"] == "pass"
    assert values["rule_version"] == request.rule_version
    assert values["verdict"] == "ship"
    assert values["allowed_outcomes"] == "ship,repack,ask"
    assert values["decided_at"] == "2026-11-11T14:05:07Z"
    refute Map.has_key?(values, "unsettled")
  end

  test "a failed condition gives the verdict for changes required" do
    facts = FakeFacts.start()
    request = Fixtures.request("dispatch", Fixtures.evidence(%{"seal" => "broken"}))

    assert {:ok, %{outcome: "repack", rule_outcome: "changes_required", unsettled: nil}} =
             decide(request, facts)
  end

  test "missing evidence is uncertain: the safe verdict, recorded as unsettled" do
    facts = FakeFacts.start()
    request = Fixtures.request("dispatch", Map.delete(Fixtures.evidence(), "seal"))

    assert {:ok, %{outcome: "ask", rule_outcome: "uncertain", unsettled: "uncertain"}} =
             decide(request, facts)

    assert [%{values: %{"verdict" => "ask", "unsettled" => "uncertain"}}] = FakeFacts.facts(facts)
  end

  test "a field the gate does not declare is uncertain" do
    facts = FakeFacts.start()
    request = Fixtures.request("careless", %{"seal" => "intact", "weight" => "light"})

    assert {:ok, %{outcome: "ask", unsettled: "uncertain"}} = decide(request, facts)
  end

  test "a verdict the request does not allow becomes the safe one, as an error" do
    facts = FakeFacts.start()

    request =
      Fixtures.request("dispatch", Fixtures.evidence(), %{"allowed_outcomes" => ["repack"]})

    assert request.allowed_outcomes == ["repack", "ask"]

    assert {:ok, %{outcome: "ask", rule_outcome: "pass", unsettled: "error"}} =
             decide(request, facts)
  end

  test "the same request again is answered with the first verdict and records nothing" do
    facts = FakeFacts.start()

    assert {:ok, %{recorded: "R-1", recorded_as: :new}} = decide(Fixtures.request(), facts)
    assert {:ok, again} = decide(Fixtures.request(), facts)
    assert again.recorded == "R-1" and again.recorded_as == :again
    assert again.outcome == "ship"
    assert length(FakeFacts.facts(facts)) == 1

    # Other evidence, or the subject at another version, is another decision.
    changed = Fixtures.evidence(%{"loaded_hash" => "h-2"})
    assert {:ok, %{recorded: "R-2"}} = decide(Fixtures.request("dispatch", changed), facts)

    assert {:ok, %{recorded: "R-3"}} =
             decide(
               Fixtures.request("dispatch", Fixtures.evidence(), %{"fingerprint" => "f-2"}),
               facts
             )
  end

  test "a recording Facts refuses is an error with the safe verdict, never a pass" do
    facts = FakeFacts.start(fail: :create)

    assert {:error, verdict, why} = decide(Fixtures.request(), facts)
    assert why =~ "refused"
    assert verdict.outcome == "ask" and verdict.unsettled == "error"
    assert verdict.rule_outcome == "pass"
    assert verdict.recorded == nil
  end

  test "Facts that cannot be read is an error, and nothing is created" do
    facts = FakeFacts.start(fail: :find)

    assert {:error, %{outcome: "ask", unsettled: "error", recorded: nil}, _} =
             decide(Fixtures.request(), facts)
  end

  test "a gate without an evaluator is an error with the safe verdict, not recorded" do
    facts = FakeFacts.start()
    request = Fixtures.request("taste", %{"sample" => "sweet"})

    assert {:error, %{outcome: "ask", unsettled: "error", recorded: nil}, why} =
             decide(request, facts)

    assert why =~ "smart"
    assert FakeFacts.facts(facts) == []
  end

  test "links go with the recorded verdict" do
    facts = FakeFacts.start()
    request = Fixtures.request("dispatch", Fixtures.evidence(), %{"links" => %{"about" => "C-7"}})

    assert {:ok, _} = decide(request, facts)
    assert [%{links: %{"about" => "C-7"}}] = FakeFacts.facts(facts)
  end

  describe "a request" do
    test "its id is the decision's identity" do
      assert Fixtures.request().id == Fixtures.request().id
      assert Fixtures.request().id =~ ~r/^GR-[0-9a-f]{32}$/

      refute Fixtures.request().id ==
               Fixtures.request("dispatch", Fixtures.evidence(), %{"subject" => "C-8"}).id
    end

    test "that cannot be asked gets no verdict" do
      gates = Fixtures.gates()

      attrs = %{
        "subject" => "C-7",
        "fingerprint" => "f-1",
        "evidence" => %{},
        "evidence_digest" => Fixtures.digest(%{})
      }

      assert {:error, _} = Request.new("unknown", attrs, gates)
      assert {:error, _} = Request.new("dispatch", Map.put(attrs, "gate_version", "1"), gates)
      assert {:ok, _} = Request.new("dispatch", Map.put(attrs, "gate_version", "2"), gates)
      assert {:error, _} = Request.new("dispatch", Map.delete(attrs, "fingerprint"), gates)
      assert {:error, _} = Request.new("dispatch", %{attrs | "evidence_digest" => "md5:x"}, gates)

      assert {:error, _} =
               Request.new("dispatch", Map.put(attrs, "allowed_outcomes", ["launch"]), gates)

      no_safe = put_in(gates, ["dispatch", "decide"], %{"pass" => "ship"})
      assert {:error, _} = Request.new("dispatch", attrs, no_safe)
    end
  end
end
