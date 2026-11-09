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

  defrules :person_always do
    rule(:amends_principle, when: [{:includes, :forces, "principle"}], decision: "D-0024")

    rule(:production_release,
      when: [{:equals, :production_release, true}, {:equals, :rollback_automated, false}],
      decision: "D-0028"
    )
  end

  # Who accepts or rejects a proposed decision in the ledger.
  defgate :accept_decision,
    version: 1,
    # slice 4 makes it :smart (a version change, data only)
    flavor: :rule,
    purpose: :decider,
    fixed: :person_always,
    evidence: [
      forces: [{:field, :force}, {:linked, :supersedes, :force}],
      category: {:field, :category},
      reversibility: {:field, :reversibility},
      scope: {:field, :scope},
      delegated: {:present, :delegated_by},
      # a ledger entry is not a release
      production_release: {:constant, false},
      # D-0028: not yet; changing it is a gate version a person reviews
      rollback_automated: {:constant, false},
      overrule_rate: {:history, :overruled, window: 50, same: [:category]},
      verdicts_seen: {:history, :count, window: 50, same: [:category]},
      timed_out: {:flow, :timed_out, default: false}
    ],
    rule: [
      first: [
        [when: [{:equals, :timed_out, true}], then: :agent_unverified],
        [when: [{:in, :category, ["product", "security"]}], then: :person],
        [when: [{:equals, :reversibility, "one_way"}], then: :person],
        [
          when: [{:at_least, :overrule_rate, 0.2}, {:at_least, :verdicts_seen, 10}],
          then: :person
        ],
        [when: [{:equals, :delegated, true}], then: :agent]
      ],
      otherwise: :advise
    ],
    verdicts: [:person_always, :person, :agent, :agent_unverified],
    decide: [
      person_always: :person_always,
      person: :person,
      agent: :agent,
      agent_unverified: :agent_unverified,
      advise: :person,
      uncertain: :person,
      error: :person
    ],
    answer_within: [test: "5m", prod: "48h"]
end
