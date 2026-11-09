defmodule AtlasFlowContract.Gates do
  @moduledoc """
  The gates of Atlas's flows. A gate is defined once, as data, for the shared Gates
  framework (`atlas_gates`), which records each verdict with the gate's name and
  version. This holds every gate the subflows name: `delivery_evidence` and `review`
  (Issue), `design` (the use case's design), and the rule gate `integrate` (Code
  applies it in the pull request's integrate effect).

  `decide` maps each evaluator outcome to a verdict; an uncertain outcome or an
  error always goes to a person.
  """
  use AtlasFlowGenerator.Schema

  # After an author or rework pass: is the evidence good enough to review?
  defgate :delivery_evidence,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: :jev,
    evidence: [:assignment, :turn, :packet, :tests, :limits],
    verdicts: [:review, :rework, :person],
    decide: [pass: :review, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, execution_failed: :person]

  # After the review pass: is the work ready to publish as a pull request?
  defgate :review,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]

  # After the design review pass: is the design ready for the acceptor?
  defgate :design,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :design_review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]

  # Before Code integrates a pull request: CI is green on the exact head being
  # integrated, and the fingerprint approved at review is the one sent at integration.
  # The pull request subflow's integrate effect names it; Code applies it before it
  # integrates (by hand until then). A missing or null field is uncertain, so it goes
  # to a person.
  defgate :integrate,
    version: 1,
    flavor: :rule,
    purpose: :flow,
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
    decide: [pass: :integrate, changes_required: :refuse, uncertain: :person, error: :person]
end
