defmodule AtlasFlowContract.GatesTest do
  use ExUnit.Case, async: true

  test "the gates, in the order written" do
    assert Enum.map(AtlasFlowContract.Gates.__gates__(), & &1.name) ==
             [:delivery_evidence, :review, :design, :integrate]
  end

  # Named by the pull request's integrate effect, applied by hand until Code applies it:
  # integrate only when CI is green on the exact head being
  # integrated and the fingerprint approved at review is the one sent at integration.
  test "integrate is a rule gate over named evidence; what it cannot settle goes to a person" do
    gate = Enum.find(AtlasFlowContract.Gates.__gates__(), &(&1.name == :integrate))

    assert Map.drop(gate, [:file]) == %{
             name: :integrate,
             version: 1,
             flavor: :rule,
             purpose: :flow,
             advice: nil,
             evidence: [
               :ci_conclusion,
               :ci_head,
               :integration_head,
               :review_fingerprint,
               :integration_fingerprint
             ],
             rule: [
               all: [
                 {:equals, :ci_conclusion, "success"},
                 {:same, :ci_head, :integration_head},
                 {:same, :review_fingerprint, :integration_fingerprint}
               ]
             ],
             verdicts: [:integrate, :refuse, :person],
             person: :person,
             decide: [
               pass: :integrate,
               changes_required: :refuse,
               uncertain: :person,
               error: :person
             ],
             policy: []
           }
  end

  test "no subflow names integrate yet" do
    named =
      for f <- AtlasFlowContract.Issue.__flows__(),
          %{mechanism: {:gate, %{gate: g}}} <- f.states,
          do: g

    refute :integrate in named
  end
end
