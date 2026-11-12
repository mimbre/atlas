defmodule Model.GateVerdict do
  @moduledoc "One gate decision, recorded in full and sealed once written."
  use RelaDSL

  type(:gate_flavor,
    values: [:rule, :smart],
    descriptions: [
      rule: "Deterministic rules alone decide",
      smart: "Jev advises; deterministic rules on top decide"
    ]
  )

  type(:gate_purpose,
    values: [:flow, :decider],
    descriptions: [
      flow: "Decides the next step of a flow",
      decider: "Decides whether a person or an agent makes a decision"
    ]
  )

  type(:gate_unsettled,
    values: [:uncertain, :error],
    descriptions: [
      uncertain: "The gate could not tell; its policy took the safe outcome",
      error: "The evaluation failed or timed out; never a pass"
    ]
  )

  entity :gate_verdict,
    label: "Gate verdict",
    plural: "gate_verdicts",
    id_type: :manual,
    id_prefix: "GV-",
    description: """
    One gate decision, recorded in full: what the gate saw, what it chose, what
    it could have chosen and, later, how good that turned out. Immutable once written;
    each later outcome is set once. The id is GV- and a number, e.g. GV-0001.
    """ do
    field(:gate, :string, required: true, description: "Which gate decided, e.g. integrate")

    field(:gate_version, :string,
      required: true,
      description: "The version of the gate's definition that decided",
      label: "Gate version"
    )

    field(:activity_id, :string,
      description: "Durable caller activity identity, when asked by Flow"
    )

    field(:activity_digest, :string,
      description: "Frozen activity payload digest; reuse with another payload is refused"
    )

    field(:flavor, :gate_flavor, required: true, description: "Rule or smart")
    field(:purpose, :gate_purpose, required: true, description: "Flow or decider")

    field(:subject, :string,
      required: true,
      description: "What it decided on, the key or reference of the fact or change"
    )

    field(:fingerprint, :string,
      required: true,
      description: "The exact version of the subject it decided on"
    )

    field(:evidence, :string,
      description: "References to the evidence it decided on, one per line",
      multiline: true
    )

    field(:evidence_digest, :string,
      required: true,
      description: "The content digest of the immutable evidence snapshot, e.g. sha256:...",
      label: "Evidence digest"
    )

    field(:rule_outcome, :string,
      description: "What the deterministic rules said",
      label: "Rule outcome"
    )

    field(:rule_version, :string,
      description: "The version of those rules",
      label: "Rule version"
    )

    field(:advisor, :string, description: "Who advised a smart gate, e.g. jev")

    field(:model, :string,
      description: "The model, prompt and evaluator settings the advice came from"
    )

    field(:rationale, :string, description: "Why the advice is what it is", multiline: true)

    field(:scores, :string,
      description: "The advice per outcome, as text, e.g. pass 0.7, changes_required 0.3",
      multiline: true
    )

    field(:verdict, :string,
      required: true,
      description: "The outcome the gate chose; one of allowed_outcomes"
    )

    field(:allowed_outcomes, :string,
      required: true,
      description: "The outcomes it could choose, separated by commas",
      label: "Allowed outcomes"
    )

    field(:unsettled, :gate_unsettled,
      description: "Uncertain or error, when the gate could not decide on its own"
    )

    field(:cost, :string, description: "What the evaluation cost, e.g. 0.012 USD")

    field(:duration_ms, :integer,
      description: "How long the evaluation took, in milliseconds",
      label: "Duration (ms)"
    )

    field(:decided_at, :datetime,
      required: true,
      description: "When it decided",
      label: "Decided at"
    )

    field(:overrule_reason, :string,
      description: "Later, why a person overruled it",
      label: "Overrule reason",
      multiline: true
    )

    field(:rework_after, :string,
      description: "Later, the rework needed after all, and what showed it",
      label: "Rework after",
      multiline: true
    )

    field(:defect_after, :string,
      description: "Later, a problem found afterwards, and where",
      label: "Defect after",
      multiline: true
    )

    field(:effort, :string,
      description: "Later, the time and human effort spent after it",
      multiline: true
    )

    top(false)
    primary(:gate)
    order(:newest)

    create(
      ask: [
        :gate,
        :gate_version,
        :activity_id,
        :activity_digest,
        :flavor,
        :purpose,
        :subject,
        :fingerprint,
        :evidence,
        :evidence_digest,
        :rule_outcome,
        :rule_version,
        :advisor,
        :model,
        :rationale,
        :scores,
        :verdict,
        :allowed_outcomes,
        :unsettled,
        :cost,
        :duration_ms,
        :decided_at
      ],
      id: [prefix: "GV-", digits: 4]
    )

    requires(
      when: [flavor: [:rule]],
      fields: [:rule_outcome, :rule_version],
      error: "a rule gate's verdict names its rule_outcome and rule_version"
    )

    requires(
      when: [flavor: [:smart]],
      fields: [:rule_outcome, :rule_version, :advisor, :model, :rationale],
      error:
        "a smart gate's verdict names its rule_outcome, rule_version and the advice: advisor, model and rationale"
    )

    sealed(
      once: [:overrule_reason, :rework_after, :defect_after, :effort],
      links: :once,
      error:
        "{key} is a gate verdict and is never edited ({field}); record a new verdict that follows it",
      once_error: "{key}: {field} is set once and never changed"
    )
  end

  relation(:follows,
    label: "follows",
    description: "The previous verdict on the same subject; verdicts so form an episode.",
    from: [:gate_verdict],
    to: [:gate_verdict],
    max_outgoing: 1,
    inverse: {:followed_by, "followed by"}
  )

  relation(:overruled_by,
    label: "overruled by",
    description: "Later, the person who overruled the verdict; at most one.",
    from: [:gate_verdict],
    to: [:person],
    max_outgoing: 1,
    inverse: {:overruled, "overruled"},
    only_target: [
      error: "only the person who overrules a verdict sets overruled_by, to themselves",
      also: [:migration]
    ]
  )

  relation(:reviewed_by,
    label: "confirmed by",
    description: "The person who confirms an unverified verdict; set once to themselves.",
    from: [:gate_verdict],
    to: [:person],
    max_outgoing: 1,
    inverse: {:reviewed_verdicts, "confirmed verdicts"},
    only_target: [error: "only the person who confirms a verdict sets reviewed_by, to themselves"]
  )
end
