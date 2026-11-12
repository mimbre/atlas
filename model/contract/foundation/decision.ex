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

  type(:decision_status,
    values: [:proposed, :accepted, :rejected, :superseded],
    labels: [
      proposed: "Proposed",
      accepted: "Accepted",
      rejected: "Rejected",
      superseded: "Superseded"
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
    field(:title, :string, required: true, description: "The decision in a few words")

    field(:decision, :string,
      required: true,
      description: "The rule, in one or two sentences",
      multiline: true
    )

    field(:context, :string, description: "Why it was decided", multiline: true)
    field(:consequences, :string, description: "What changes because of it", multiline: true)
    field(:category, :decision_category, description: "What it is about")
    field(:scope, :decision_scope, description: "How widely it holds")
    field(:reversibility, :decision_reversibility, description: "How costly undoing it is")
    field(:force, :decision_force, description: "How it acts on work")

    field(:enforced_by, :string,
      description: "The test, check or gate that enforces it; required for a principle",
      label: "Enforced by"
    )

    field(:status, :decision_status, description: "Proposed, accepted, rejected or superseded")

    field(:decided_at, :datetime,
      description: "When it was accepted or rejected",
      label: "Decided at"
    )

    field(:no_work, :boolean,
      description: "True when carrying it out needs no work; it then waits for none",
      label: "No work needed"
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
      defaults: [status: :proposed]
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
          fields: [:title, :decision, :category, :scope, :reversibility, :force],
          relations: [:supersedes]
        ]
      ]
    )

    frozen(
      when: [status: [:accepted, :superseded]],
      only: [unverified: [false], status: [:superseded], no_work: [true]],
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
    only_target: [
      error: "only the one who decides sets decided_by, to themselves",
      also: [:migration]
    ]
  )

  relation(:delegated_by,
    label: "delegated by",
    description: "The person whose delegated authority an agent decided under; at most one.",
    from: [:decision],
    to: [:person],
    max_outgoing: 1,
    inverse: {:delegated, "delegated"},
    only_target: [
      error: "only the person who delegates sets delegated_by, to themselves",
      also: [:migration]
    ]
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

  # Who accepts or rejects a proposed decision in the ledger.
  defgate :accept_decision,
    version: 1,
    # slice 4 makes it :smart (a version change, data only)
    flavor: :rule,
    purpose: :decider,
    fixed: :person_always,
    fingerprint: [
      fields: [:title, :decision, :category, :scope, :reversibility, :force],
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

  subflow :decide, label: "Decide", subject: :decision do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :deciding

    state :deciding, label: "Who decides" do
      gate :accept_decision,
        person_always: :for_person_always,
        person: :for_person,
        agent: :for_agent,
        agent_unverified: :for_agent_unverified
    end

    state :for_person_always, label: "A person decides" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, config: :decider},
            preserve_kind: :person

      wait_for [:principle_authority, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have a person decide",
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :decided_by, values: %{status: :accepted, decided_at: "$now"}}
          ],
          [
            key: "f",
            label: "Reject",
            note: true,
            change: %{self: :decided_by, values: %{status: :rejected, decided_at: "$now"}}
          ]
        ],
        why: "a fixed person rule holds",
        instructions:
          "A person accepts or rejects with decided_by and decided_at. A principle names enforced_by. This wait never times out."
      )
    end

    state :for_person, label: "Waiting for a person" do
      owner via: :assignment,
            relation: :assigned_to,
            default: {:person, config: :decider},
            preserve_kind: :person

      wait_for :decider, on: :status, reset: false, accepted: :accepted, rejected: :rejected
      timer :no_answer, {:gate_limit, :accept_decision}, to: :deciding

      present(
        expected: "Have a person decide",
        deadline: :no_answer,
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :decided_by, values: %{status: :accepted, decided_at: "$now"}}
          ],
          [
            key: "f",
            label: "Reject",
            note: true,
            change: %{self: :decided_by, values: %{status: :rejected, decided_at: "$now"}}
          ]
        ],
        why: "the decider gate requires a person",
        instructions:
          "Accept or reject with decided_by and decided_at. After the answer limit Flow asks the gate again."
      )
    end

    state :for_agent, label: "An agent may decide" do
      wait_for [:delegate, :decider],
        on: :status,
        reset: false,
        accepted: :accepted,
        rejected: :rejected

      present(
        expected: "Have it decided",
        why: "the recorded gate permits an agent",
        instructions: "Accept or reject with decided_by and decided_at."
      )
    end

    state :for_agent_unverified, label: "Unverified agent decision" do
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

    final :accepted, label: "Accepted"
    final :rejected, label: "Rejected"
  end

  # How the runs of decide are selected from the decisions, and imported from the status a
  # decision had before the subflow ran.
  select(:decide,
    legacy: :decide,
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
    admission: [status: [:proposed, :accepted, :rejected, :superseded]],
    imports: [
      [when: [status: [:accepted]], state: :accepted],
      [when: [status: [:rejected]], state: :rejected],
      [when: [status: [:superseded]], state: :accepted]
    ],
    follow_through: [state: :accepted, when: [status: [:accepted]]],
    verification: [
      kind: :gate_verdict,
      field: :unverified,
      relations: [:reviewed_by, :overruled_by]
    ]
  )

  # The approved migrations of the runs of decide, oldest last; each from is a digest the
  # base branch recorded (RelaDSL.RunIdentity).
  # Slice 7: the deciding person is the environment's configured decider, no longer a
  # name in the model. Only the owner data changes, so live runs keep their state, entry
  # and deadlines (rekey).
  migrate(:decide,
    from: "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042",
    to: "06d957cd558f2e2957c4b0542bbef040876a5d426b245537eeedcf4aaa1a04b6",
    rekey: true,
    states: :same,
    reason: "The person deciding is the configured decider; unchanged prod subflow behaviour"
  )

  migrate(:decide,
    from: "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8",
    to: "ab9c1bdf9b947e32b98bd41dd0ddf3341101f2b4aeab76a3960d0a5ebd5104ae",
    rekey: true,
    states: :same,
    reason: "The person deciding is the configured decider; unchanged test subflow behaviour"
  )

  # Imported final runs keep slice 1's digest: they stay evidence under the new one.
  migrate(:decide,
    from: "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c",
    reason: "Slice 1 to slice 7: enter the decider gate once; preserve final history",
    states: [accepted: :accepted, proposed: :deciding, rejected: :rejected],
    to: "06d957cd558f2e2957c4b0542bbef040876a5d426b245537eeedcf4aaa1a04b6"
  )

  migrate(:decide,
    from: "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c",
    reason: "Slice 1 to slice 7: enter the decider gate once; preserve final history",
    states: [accepted: :accepted, proposed: :deciding, rejected: :rejected],
    to: "ab9c1bdf9b947e32b98bd41dd0ddf3341101f2b4aeab76a3960d0a5ebd5104ae"
  )

  migrate(:decide,
    from: "e2d4c41b758cb858aa40b2835c703f2c42f60039471f855fa7e2df0dbf171b4b",
    to: "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8",
    preserve_entry: true,
    states: :same,
    reason: "Owner answers and deadline presentation; preserve live entries and timers"
  )

  migrate(:decide,
    from: "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa",
    to: "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042",
    preserve_entry: true,
    states: :same,
    reason: "Owner answers and deadline presentation; preserve live entries and timers"
  )

  migrate(:decide,
    from: "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c",
    reason: "Slice 1 to slice 3: enter the decider gate once; preserve final history",
    states: [accepted: :accepted, proposed: :deciding, rejected: :rejected],
    to: "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042"
  )

  migrate(:decide,
    from: "8ca16b332a083209e6e44ffc3feeca0f152c632caa4d5206ab24fe540ab3770c",
    reason: "Slice 1 to slice 3: enter the decider gate once; preserve final history",
    states: [accepted: :accepted, proposed: :deciding, rejected: :rejected],
    to: "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8"
  )

  migrate(:decide,
    from: "118c1cf31028979df064344d708a59f8ee19ad97493b47d66ac2d66cbb8dbb00",
    reason: "Canonical JSON identity; unchanged prod subflow data",
    rekey: true,
    states: :same,
    to: "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa"
  )

  migrate(:decide,
    from: "77f00aa4ea2f8ec4ff3620b590794b6aabeedd8ce435a9e4a635e909d7d40b93",
    reason: "Canonical JSON identity; unchanged test subflow data",
    rekey: true,
    states: :same,
    to: "e2d4c41b758cb858aa40b2835c703f2c42f60039471f855fa7e2df0dbf171b4b"
  )
end
