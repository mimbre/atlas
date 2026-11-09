defmodule AtlasFlowContract.Gates do
  @moduledoc """
  The gates the subflows name. A gate is defined once, as data, for
  the shared Gates framework (`atlas_gates`), which records each verdict with the
  gate's name and version. This slice holds only the two gates Issue names.

  Both are smart gates: Jev (or a review pass) advises, the policy on top decides,
  and the gate writes one of its `verdicts` on the subject. `decide` maps each
  advice outcome to a verdict; an uncertain advice or an error always goes to a
  person.
  """
  use AtlasFlowGenerator.Schema

  # After an author or rework pass: is the evidence good enough to review?
  defgate :delivery_evidence,
    version: 1,
    flavor: :smart,
    advice: :jev,
    evidence: [:assignment, :turn, :packet, :tests, :limits],
    verdicts: [:review, :rework, :person],
    decide: [pass: :review, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, execution_failed: :person]

  # After the review pass: is the work ready to publish as a pull request?
  defgate :review,
    version: 1,
    flavor: :smart,
    advice: {:review_pass, :review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]
end
