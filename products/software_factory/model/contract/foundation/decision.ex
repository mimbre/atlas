defmodule Model.Decision do
  @moduledoc "A recorded decider verdict selects who may decide and whether the wait has a limit."
  use RelaDSL

  type(:decision_category,
    values: [
      :product,
      :process,
      :domain,
      :architecture,
      :interface,
      :technology,
      :security,
      :operations
    ],
    descriptions: [
      product: "What is built, for whom, what is in or out",
      process: "How work moves: phases, passes, gates, roles, release",
      domain: "Concepts, entities, relations and vocabulary",
      architecture: "Components, their responsibilities, boundaries and contracts",
      interface: "What people and clients see and call: UI, CLI, API and wire",
      technology: "Choice of tool, platform, library or version",
      security: "Trust boundaries, permissions, credentials and data access",
      operations: "Environments, deployment, backups, machines"
    ]
  )

  type(:decision_scope,
    values: [:platform, :software, :instance],
    labels: [platform: "Platform", software: "Software", instance: "Instance"],
    descriptions: [
      platform: "The generic mechanisms, whatever workflow runs on them",
      software: "How software gets built here: issues, pull requests and their flows",
      instance: "One installation: its environments, machines, accounts"
    ]
  )

  type(:decision_reversibility,
    values: [:one_way, :two_way],
    labels: [one_way: "One-way", two_way: "Two-way"],
    descriptions: [
      one_way: "Costly or impossible to undo; always accepted by a person",
      two_way: "Cheap to undo; may be accepted with delegated authority"
    ]
  )

  type(:decision_force,
    values: [:direction, :guideline, :guardrail, :principle],
    descriptions: [
      direction: "Where we go; future work is based on it",
      guideline: "How work should be done; deviation is allowed with a reason",
      guardrail: "What work must or must not do; a violation blocks",
      principle: "What never happens, by anyone; enforced by the system"
    ]
  )

  # A decision is never declined into an end (D-0106): declining gives an alternative and
  # sends it back to its proposer (`revising`), as a question does (`answering`); both
  # return it to its decider as `proposed`. `rejected` stays for the decisions that ended
  # so before.
  type(:decision_status,
    values: [:proposed, :accepted, :rejected, :superseded, :revising, :answering],
    labels: [
      proposed: "Proposed",
      accepted: "Accepted",
      rejected: "Rejected",
      superseded: "Superseded",
      revising: "Revising",
      answering: "Answering a question"
    ]
  )

  entity :decision,
    label: "Decision",
    plural: "decisions",
    aliases: ["dr"],
    id_type: :manual,
    id_prefix: "D-",
    description: """
    One decision record in the append-only ledger: the rule, why, and what follows
    from it. An accepted decision is never edited; a newer decision supersedes it. The id
    is D- and a number, e.g. D-0024.
    """ do
    icon(:scales)
    field(:title, :string, required: true, description: "The decision in a few words")

    field(:decision, :string,
      required: true,
      description: "The rule, in one or two sentences",
      multiline: true
    )

    field(:context, :string, description: "Why it was decided", multiline: true)

    field(:options, :string,
      description:
        "Single-choice JSON: question, options (id, text, details, effect, rule, consequences), recommended ID and rationale",
      multiline: true
    )

    field(:selected_option, :string, description: "The selected semantic option ID")

    field(:selected_definition, :string,
      description: "The exact offered definition selected",
      multiline: true
    )

    field(:selected_revision, :string,
      description: "The displayed offer and authorization content revision"
    )

    field(:option_history, :string,
      description: "Prior complete offered revisions, maintained by Facts",
      multiline: true
    )

    # The DSL's single-choice mechanism, in this kind's fields and words.
    decision_options(
      definition: :options,
      selected: :selected_option,
      snapshot: :selected_definition,
      revision: :selected_revision,
      history: :option_history,
      answered_at: :decided_at,
      answered_by: :decided_by,
      status: [
        field: :status,
        open: :proposed,
        adopt: :accepted,
        decline: :rejected,
        superseded: :superseded,
        replaceable: [:accepted, :superseded],
        # Unanswered, back with its proposer (D-0106).
        returned: [:revising, :answering]
      ],
      # An adopted option's rule and consequences become the decision's; a decline sets neither.
      adopt: [rule: :decision, consequences: :consequences],
      # Declining gives an alternative: written with `revising`, it becomes an adopt option.
      alternative: [field: :alternative, status: :revising],
      # Who left it to its proposer (Leave it to the proposer, D-0106).
      delegated: :delegated_by,
      # What one offered revision covers, besides the definition itself.
      content: [
        :title,
        :decision,
        :consequences,
        :category,
        :scope,
        :reversibility,
        :force,
        :enforced_by,
        :context,
        :no_work
      ],
      content_links: [:supersedes, :follows_from, :delegated_by],
      # Pending decisions had this exact fingerprint scope before options existed; a
      # decision without options (historical or created without them) still matches it.
      # No offered decision may use it.
      legacy_fingerprint: [
        fields: [:title, :decision, :category, :scope, :reversibility, :force],
        relations: [:supersedes]
      ],
      errors: [
        invalid:
          "a decision needs a question, rationale, distinct complete options (at least one to adopt), and the recommended option first",
        not_json: "decision options must be a JSON definition",
        removed: "decision options cannot be removed or answered without their definition",
        unselected: "select an offered option to decide this decision",
        changed: "the offered decision options changed; open the decision again",
        selection: "selection must apply exactly one offered option with its decision time"
      ]
    )

    field(:consequences, :string, description: "What changes because of it", multiline: true)
    field(:category, :decision_category, description: "What it is about")
    field(:scope, :decision_scope, description: "How widely it holds")
    field(:reversibility, :decision_reversibility, description: "How costly undoing it is")
    field(:force, :decision_force, description: "How it acts on work")

    field(:enforced_by, :string,
      description: "The test, check or gate that enforces it; required for a principle",
      label: "Enforced by"
    )

    field(:status, :decision_status,
      description:
        "Proposed, accepted, superseded, back with its proposer (revising, answering a question), or rejected (before D-0106)"
    )

    field(:decided_at, :datetime,
      description: "When it was accepted or rejected",
      label: "Decided at"
    )

    field(:alternative, :string,
      description:
        "Its decider's alternative, given when declining (D-0106); it is among the options since",
      multiline: true
    )

    field(:question, :string,
      description: "What its decider needs to know before deciding",
      multiline: true
    )

    field(:answer, :string,
      description: "Its proposer's answer to its decider's question",
      multiline: true
    )

    field(:left_to_proposer, :boolean,
      description:
        "Its decider left it to its proposer (Leave it to the proposer, D-0106); Flow clears it when it asks who decides",
      label: "Left to its proposer"
    )

    field(:returned, :boolean,
      description:
        "Its proposer returned it to its decider, revised or answered (D-0106); Flow then proposes it again and clears it",
      label: "Returned"
    )

    field(:no_work, :boolean,
      description: "True when carrying it out needs no work; it then waits for none",
      label: "No work needed"
    )

    field(:work, :integer,
      description: "Flow: how many facts carry it out (based on it)",
      label: "Work based on it",
      set_by: [:flow]
    )

    field(:unverified, :boolean,
      description: "An agent decided after the person answer limit; cleared by review",
      label: "Unverified",
      set_by: [:flow]
    )

    field(:gate_result, :string,
      description: "Flow: gate activity result; the durable run holds its trusted source",
      label: "Gate result",
      set_by: [:flow]
    )

    field(:verdict, :string,
      description: "Flow: the verdict of whoever may decide it (none, accept, reject)"
    )

    delete_error(
      "Decisions are an append-only ledger; a decision is never deleted. Record a new one that supersedes it instead."
    )

    primary(:title)
    order(:newest)

    create(
      ask: [
        :title,
        :decision,
        :options,
        :context,
        :consequences,
        :category,
        :scope,
        :reversibility,
        :force,
        :enforced_by,
        :no_work
      ],
      id: [prefix: "D-", digits: 4, first: 24],
      defaults: [status: :proposed],
      # The person who puts it in proposes it; an agent's proposal names none (D-0106).
      proposer: :proposed_by
    )

    requires(
      when: [force: [:principle]],
      fields: [:enforced_by],
      error: "a principle names the check that enforces it (enforced_by)"
    )

    authority(
      when: [status: [:accepted]],
      by: :decided_by,
      kind: :person,
      error: "a person decides unless a fresh accept_decision verdict permits an agent",
      writes: [status: [:accepted, :rejected]],
      writer_error:
        "only the one decided_by names accepts or rejects it, as themselves and under a fresh decider verdict",
      agent_kind: :agent,
      decider: [
        gate: :accept_decision,
        relation: :about,
        kind: :gate_verdict,
        fingerprint: [
          fields: [
            :title,
            :decision,
            :consequences,
            :options,
            :category,
            :scope,
            :reversibility,
            :force
          ],
          relations: [:supersedes]
        ]
      ]
    )

    frozen(
      when: [status: [:accepted, :superseded]],
      only: [unverified: [false], status: [:superseded], no_work: [true]],
      tallied: [:work],
      error: "{key} is {value} and is never edited; a newer decision supersedes it"
    )

    replaces(
      relation: :supersedes,
      when: [status: [:accepted]],
      of: [status: [:accepted, :superseded]],
      set: [status: :superseded],
      error: "{key} is not accepted; only an accepted decision is superseded"
    )

    layering(
      relation: :follows_from,
      field: :scope,
      not: [platform: [:software, :instance]],
      error:
        "{key} ({value}) may not follow from {other} ({other_value}): a platform decision never depends on a software or instance one"
    )

    flag(:unverified, value: true, label: "🔴 Unverified decision")
  end

  relation(:decided_by,
    label: "decided by",
    description: "Who accepted or rejected the decision; one, a person or an agent.",
    from: [:decision],
    to: [:person, :agent],
    max_outgoing: 1,
    inverse: {:decided, "decided"},
    # Its decider left it to its proposer (D-0106): the proposer it is assigned to then
    # takes their place, deciding on their behalf (`only_target.delegated`, where the
    # assignment is: `Model.AtlasEyra`).
    only_target: [
      error:
        "only the one who decides sets decided_by, to themselves; another only once its decider left it to them, its proposer",
      also: [:migration]
    ]
  )

  relation(:delegated_by,
    label: "delegated by",
    description:
      "The person who left it to its proposer (Leave it to the proposer, D-0106), the one way an agent decides; at most one.",
    from: [:decision],
    to: [:person],
    max_outgoing: 1,
    inverse: {:delegated, "delegated"},
    only_target: [
      error: "only the person who delegates sets delegated_by, to themselves",
      also: [:migration]
    ]
  )

  # Who proposed it (D-0106): the person who put it in, whom a decline or a question sends
  # it back to; none when an agent put it in, and its coordinator answers instead.
  relation(:proposed_by,
    label: "proposed by",
    description:
      "The person who put it in, whom it goes back to when declined or asked about; none when an agent did (its coordinator then). Set by its create only.",
    from: [:decision],
    to: [:person],
    max_outgoing: 1,
    inverse: {:proposed, "proposed"},
    set_by: [:flow]
  )

  relation(:supersedes,
    label: "supersedes",
    description:
      "The accepted decisions this one replaces; they become superseded when it is accepted.",
    from: [:decision],
    to: [:decision],
    inverse: {:superseded_by, "superseded by"}
  )

  relation(:follows_from,
    label: "follows from",
    description: "The higher-level decisions this one elaborates.",
    from: [:decision],
    to: [:decision],
    inverse: {:elaborated_by, "elaborated by"}
  )

  defrules :person_always do
    rule(:amends_principle, when: [{:includes, :forces, "principle"}], cites: "D-0024")

    rule(:production_release,
      when: [{:equals, :production_release, true}, {:equals, :rollback_automated, false}],
      cites: "D-0028"
    )
  end

  # Who accepts a proposed decision in the ledger. An agent only when its decider left it to
  # its proposer (D-0106): that explicit choice, per decision, is the one way, after the
  # fixed person rules; nothing else, a timeout neither, hands a decision to an agent.
  defgate :accept_decision,
    version: 2,
    # slice 4 makes it :smart (a version change, data only)
    flavor: :rule,
    purpose: :decider,
    fixed: :person_always,
    fingerprint: [
      fields: [
        :title,
        :decision,
        :consequences,
        :options,
        :category,
        :scope,
        :reversibility,
        :force
      ],
      relations: [:supersedes]
    ],
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
      timed_out: {:flow, :timed_out, default: false},
      waited_from: {:flow, :waited_from, default: nil},
      due: {:flow, :due, default: nil}
    ],
    rule: [
      first: [
        [when: [{:equals, :delegated, true}], then: :agent],
        [when: [{:in, :category, ["product", "security"]}], then: :person],
        [when: [{:equals, :reversibility, "one_way"}], then: :person],
        [
          when: [{:at_least, :overrule_rate, 0.2}, {:at_least, :verdicts_seen, 10}],
          then: :person
        ]
      ],
      otherwise: :advise
    ],
    # agent_unverified stays a verdict for the runs and verdicts recorded with it (D-0102);
    # no outcome gives it any more.
    verdicts: [:person_always, :person, :agent, :agent_unverified],
    decide: [
      person_always: :person_always,
      person: :person,
      agent: :agent,
      advise: :person,
      uncertain: :person,
      error: :person
    ],
    answer_within: [test: "5m", prod: "48h"]

  # Its decider's answers (D-0106), in both person states: Accept (or Choose an option),
  # Decline with an alternative, Ask a question, Hand over and, unless a fixed person rule
  # holds, Leave it to the proposer. Nothing ends declined: a decline or a question goes
  # back to its proposer (`revising`, `answering`), who returns it to its decider; the
  # one who declined or asked is its decider then (`decided_by`).
  @accept [
    key: "a",
    label: "Accept",
    weight: :main,
    change: %{self: :decided_by, values: %{status: :accepted, decided_at: "$now"}}
  ]

  @decline [
    key: "f",
    label: "Decline",
    note: true,
    prompt: "What is your alternative?",
    cause: "declined, with an alternative: {note}",
    weight: :decline,
    change: %{self: :decided_by, values: %{status: :revising, alternative: "$note"}}
  ]

  @ask [
    key: "q",
    label: "Ask a question",
    note: true,
    prompt: "What do you need to know?",
    cause: "asked: {note}",
    weight: :other,
    icon: :question,
    change: %{self: :decided_by, values: %{status: :answering, question: "$note"}}
  ]

  @hand_over [key: "h", label: "Hand over", hand_over: true, weight: :other, icon: :hand_over]

  @leave [
    key: "l",
    label: "Leave it to the proposer",
    weight: :other,
    icon: :delegate,
    change: %{self: :delegated_by, values: %{left_to_proposer: true}}
  ]

  # Its proposer: the person who put it in, else (an agent did, or nobody is recorded) the
  # coordinator, which answers through Control; never a worker agent (D-0106).
  @proposer {:agent, :coordinator, producer: :proposed_by, producer_kind: :person}

  subflow :decide, label: "Decide", subject: :decision do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :deciding

    # Who decides comes from the gate, which sees a delegation; a leave is asked once. A
    # decision its proposer returns is proposed again here (a status is its decider's
    # choice, so Flow writes it, not the proposer).
    state :deciding, label: "Who decides" do
      set left_to_proposer: false, returned: false, status: :proposed

      gate :accept_decision,
        person_always: :for_person_always,
        person: :for_person,
        agent: :for_agent,
        agent_unverified: :for_agent_unverified
    end

    state :for_person_always, label: "Decide it" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, config: :decider, producer: :decided_by},
            preserve_kind: :person

      wait_for [:principle_authority, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected,
        revising: :revising,
        answering: :answering

      present(
        expected: "Have a person decide",
        answers: [@accept, @decline, @ask, @hand_over],
        why: "a fixed person rule holds",
        instructions:
          "A person accepts it, or declines with an alternative or asks a question: it then goes back to its proposer, and returns. A principle names enforced_by. This wait never times out."
      )
    end

    state :for_person, label: "Decide it" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, config: :decider, producer: :decided_by},
            preserve_kind: :person

      wait_for :decider,
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected,
        revising: :revising,
        answering: :answering

      timer :no_answer, {:gate_limit, :accept_decision}, to: :deciding
      branch to: :deciding, when: "entity.left_to_proposer == true"

      present(
        expected: "Have a person decide",
        deadline: :no_answer,
        answers: [@accept, @decline, @ask, @hand_over, @leave],
        why: "the decider gate requires a person",
        instructions:
          "Accept it, or decline with an alternative or ask a question: it then goes back to its proposer, and returns. Hand it over to another person, or leave it to its proposer, who then decides on your behalf. After the answer limit Flow asks the gate again."
      )
    end

    # Left to its proposer (D-0106): the person who put it in, else the coordinator, decides
    # on behalf of the one who left it.
    state :for_agent, label: "Left to its proposer" do
      owner via: :assignment, relation: :assigned_to, default: @proposer

      wait_for [:delegate, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Decide it: its decider left it to you",
        answers: [@accept],
        why: "its decider left it to its proposer",
        instructions:
          "Its decider left it to you, its proposer: choose, and it is decided by you on their behalf, delegated."
      )
    end

    state :for_agent_unverified, label: "Unverified decision" do
      set unverified: true

      wait_for [:delegate, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have it decided (unverified)",
        why: "a person did not answer in time",
        instructions:
          "Accept or reject with decided_by and decided_at. The decision carries a red flag until a person confirms or overrules its gate verdict."
      )
    end

    # Declined with an alternative: its proposer words it among the options and proposes
    # it again; it returns to its decider.
    state :revising, label: "Revise it" do
      owner via: :assignment, relation: :assigned_to, default: @proposer

      present(
        expected: "Revise it with its decider's alternative",
        why: "its decider declined it, with an alternative",
        instructions:
          "Its decider declined it and gave the alternative below; it is among its options now, as theirs. Word it as you like and set the recommendation (the recommended option first) with Update, then propose it again: it returns to its decider.",
        section: [field: :alternative, label: "Their alternative"],
        answers: [
          [
            key: "p",
            label: "Propose again",
            weight: :main,
            change: %{values: %{returned: true}}
          ]
        ]
      )

      branch to: :deciding, when: "entity.returned == true"
    end

    # Asked a question: its proposer answers, adding what answers it to the decision (its
    # context, or an option's details) if they like; it returns to its decider.
    state :answering, label: "Answer its question" do
      owner via: :assignment, relation: :assigned_to, default: @proposer

      present(
        expected: "Answer its decider's question",
        why: "its decider asked a question before deciding",
        instructions:
          "Its decider asks the question below. Add what answers it to the decision (its context, or an option's details) with Update if you like, then answer: it returns to its decider.",
        section: [field: :question, label: "Their question"],
        answers: [
          [
            key: "a",
            label: "Answer",
            note: true,
            prompt: "Your answer",
            cause: "answered: {note}",
            weight: :main,
            change: %{values: %{returned: true, answer: "$note"}}
          ]
        ]
      )

      branch to: :deciding, when: "entity.returned == true"
    end

    final :accepted, label: "Accepted"
    final :rejected, label: "Rejected"
  end

  # How the runs of decide are selected from the decisions, and imported from the status a
  # decision had before the subflow ran. An accepted decision is follow_through's
  # (`Model.FollowThrough`), which presents it until work carries it out: the two admit
  # disjoint statuses, so one run presents a decision at any moment. A decision decide
  # runs on keeps its run when it is accepted; the run reaches `accepted` and presents
  # nothing more.
  select(:decide,
    choices: [:status],
    roles: [decider: :decided_by, principle_authority: :decided_by, delegate: :decided_by],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      deadline_field: :deadline,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [status: [:proposed, :rejected, :superseded, :revising, :answering]],
    imports: [
      [when: [status: [:rejected]], state: :rejected],
      [when: [status: [:superseded]], state: :accepted],
      [when: [status: [:revising]], state: :revising],
      [when: [status: [:answering]], state: :answering]
    ],
    verification: [
      kind: :gate_verdict,
      field: :unverified,
      relations: [:reviewed_by, :overruled_by]
    ]
  )
end
