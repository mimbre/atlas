defmodule Model.UseCase do
  @moduledoc """
  The two subflows of a use case: first its design, then building, testing and
  accepting it.

  `design_and_accept`:

    * Slice 9: a person picks up its design (`designing`, the span `design`): one agent
      on the supervisor's Runtime reads the use case, its scene and a checkout of the
      repository, and writes its design to a file in its result (`writes:`). Flow, the
      only writer, puts that text in its Design part (`design`), and "Accept its design"
      (`accepting`) goes to the supervisor, who reads it, changes it by hand if need be,
      and accepts it: `design_status` becomes `approved`, the run ends `accepted`, which
      sets `design_status: accepted` and hands the use case to its break-down (`phase:
      break_down`), which can then be picked up. When the agent writes nothing, or its task ends otherwise, the
      supervisor writes the design by hand in "Accept its design". Nobody sets
      `design_status` by hand on the way.
    * A use case whose design was in review before slice 9 (`in_review`, written by
      hand) is the supervisor's to accept, in "Accept its design"; one sent back
      (`changes_requested`) is designed again by the agent.

  Slice 10 runs it on Flow's durable runs (`select`), for the design phase of the
  legacy flow `design_and_accept`, which keeps the building phase. The parity fixes keep
  it to what runs today, where the Architect writes the design by hand and whoever
  reviews it sets `design_status`:

    * no passes yet (author, review, rework): the pass specs are no pass contract a
      runner accepts (`AtlasFlow.Activities.Pass.valid?/1`: a routing field, a frozen
      request), and a pass needs what does not exist yet: a machine field on the agent
      to route by, Code materializing the target, a packet freeze and review-packet
      contract, another vendor for the review, Runtime's pass receiver configured in an
      environment; a definition a runner refuses would refuse every selected subflow.
      Each state moved on the `design_status` written by hand instead, as the legacy
      flow reads it, and `designing` and `redesign` kept the legacy owner, the
      Architect (the pass was routed to it); slice 9 replaced them with the agent's
      design and its supervisor's acceptance;
    * no `design_gate` yet: `design` is a smart gate, and Gates has no evaluator for
      one, nor its evidence (packet, findings) or advice (the review pass); a gate Gates
      cannot answer would stop every reconcile. The gate stays defined, for when the
      review pass comes back; until then the review's `approved` is the design's
      acceptance, as it is today;
    * no `to_accept` yet: an acceptor's verdict is a person's choice, and Facts takes a
      choice only from the one a relation of the use case names (`roles`); none names
      who accepts its design (`accepted_by` accepts the tested use case and completes
      it), and nothing asks an acceptor for it today;
    * no `needs_person` and no `dropped`: only the failures and timeouts of the pass and
      the gate led to the maintainer's choice, and its `close` to `dropped`; that choice
      would also need a relation that names the maintainer of a use case, which none
      does;
    * no timers: each waited on a pass or the gate.

  `pass_result`, `gate_result` and `verdict` stay on the kind, unwritten, for them.

  `break_down_use_case` and `accept_use_case` follow it, each a flow of its own: a
  person supervises a flow, never a step (D-0099).

    * `break_down_use_case`: once its design is accepted (which hands it on, `phase:
      break_down`), a person picks it up (its span) and hands it to a machinery: one
      agent on the supervisor's Runtime reads the use case, its scene and a checkout of
      the repository, and writes the issues it proposes to a file in its result
      (`creates:`). Flow, the only writer, makes them under the use case, and "Accept it"
      (`accepting`) goes to the supervisor, who looks at them, changes, removes or adds
      any by hand, and accepts the break-down. Its run ends there and hands the use case
      to `accept_use_case` (`phase: accept`).
    * `accept_use_case`: builds it until none of its issues is open (`children`,
      `open_children`: the composition's count of its issues), then the configured
      decider tests it and accepts it, or rejects it with a note (`rework`, until a new
      open issue sends it back to building). An approved use case with no issue under it
      goes back to a new round of `break_down_use_case` (`phase: break_down`), and this
      run waits for it (`breaking_down`).

  `design_status` and `phase` say which of the three has a use case (disjoint
  admissions): the design while it is written or reviewed, then the break-down
  (`phase: break_down`) or the acceptance (`phase: accept`). One from before the split
  has no `phase` and is the acceptance's, which imports it; so is one without a design
  phase (no `design_status`).
  """
  use RelaDSL

  type(:design_status,
    values: [:writing, :in_review, :changes_requested, :approved, :accepted],
    labels: [
      writing: "Writing",
      in_review: "In review",
      changes_requested: "Changes requested",
      approved: "Approved",
      accepted: "Accepted"
    ],
    descriptions: [
      writing: "The Design part is being written.",
      in_review: "The Design part waits for its review pass.",
      changes_requested: "The review sent the Design part back.",
      approved: "The review approved the Design part; it can be broken down and built.",
      accepted: "An acceptor accepted the design (flow design_and_accept); building starts."
    ]
  )

  entity :use_case,
    label: "Use case",
    plural: "use_cases",
    aliases: ["uc"],
    id_type: :manual,
    id_prefix: "UC-",
    description: """
    The technical contract for part of a scene (Flux's meaning). The id is
    its code, e.g. UC-Atlas-01.
    """ do
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:status, :plan_status, description: "Flux group; empty = no group", label: "Flux group")

    field(:design, :string,
      description:
        "The Design part: how it is built, written by its design agent, accepted by its supervisor",
      multiline: true,
      label: "Design"
    )

    field(:design_status, :design_status,
      description: "Where the Design part is; empty for a use case without a design phase",
      label: "Design status"
    )

    field(:phase, :pipeline_phase,
      description:
        "Flow: which flow of its pipeline has it after its design (break down, accept)",
      label: "Phase"
    )

    field(:children, :integer, description: "Flow: how many issues are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")

    field(:verdict, :string,
      description:
        "Flow: the acceptor's verdict (none, accept, reject), or its supervisor's acceptance of its issues (accept)"
    )

    # What its break-down's task branch reads: the run's own result, never written.
    field(:task_result, :string,
      description:
        "Flow: how its break-down's agent task ended (completed, check_failed, stuck, abandoned); the run's own, never written",
      set_by: [:flow],
      label: "Task result"
    )

    field(:pass_result, :string,
      description: "Flow: how the last pass ended (none, delivered, failed)"
    )

    field(:gate_result, :string,
      description:
        "Flow: the last design gate verdict, or a maintainer's choice (none, review, rework, ready, person, close)"
    )

    create(ask: [:title, :description], defaults: [status: :refine, design_status: :writing])
    progress(over: :in_use_case, field: :stage, own: :status)
    completion(by: :accepted_by)
  end

  relation(:in_scene,
    label: "in scene",
    description:
      "A use case belongs to at most one scene (Flux); a scene has zero or more use cases.",
    from: [:use_case],
    to: [:scene],
    max_outgoing: 1,
    inverse: {:use_cases, "use cases"},
    parent: true
  )

  relation(:in_use_case,
    label: "in use case",
    description:
      "An issue belongs to at most one use case (Flux); a use case has zero or more issues.",
    from: [:issue],
    to: [:use_case],
    max_outgoing: 1,
    inverse: {:issues, "issues"},
    parent: true
  )

  relation(:accepted_by,
    label: "accepted by",
    description: "Who accepted a scene or use case, after testing it; at most one.",
    from: [:scene, :use_case],
    to: [:person],
    max_outgoing: 1,
    inverse: {:accepted, "accepted"},
    only_target: [error: "only a person accepts", also: [:migration]],
    actions: [set: [label: "Accept", key: "a"], remove: [label: "Reopen", key: "a"]],
    requires_completed_children: "{key} has {children} open",
    closes_parent: "{parent} is accepted; reopen it first, or put this under another {kind}"
  )

  # After the design review pass: is the design ready for the acceptor? Named by no state
  # while the review pass waits (slice 10); Gates has no evaluator for a smart gate yet.
  defgate(:design,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :design_review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]
  )

  subflow :design_and_accept, label: "Design and accept", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    channel(:work)
    start(:create)
    initial(:designing)
    supervise(:design, label: "Design", states: [:designing, :accepting])

    state :designing, label: "Design pass" do
      owner(via: :assignment, relation: :assigned_to, default: {:agent, :architect})

      present(
        expected: "Write its Design part",
        why: "its design is not written yet",
        instructions:
          "Its machinery runs one agent on it that writes its Design part; Flow puts it on the use case. Nothing is done while it is not assigned to a machinery."
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Write the design of the use case below: how it is built. Its scene, after it, says why it is to be done; the repository you are given, a Git checkout of develop, is what it builds on. Read what you need, and change none of its files: your only output is your design, as asked at the end. Say which parts of the system change and how, what is new, the data and the flow through it, and how to tell it works, so that it can be broken down into small issues that build it.",
        fields: [:title, :description],
        parents: [:title, :description],
        writes: [field: :design, file: "design.md"],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :accepting,
          check_failed: :accepting,
          stuck: :accepting,
          abandoned: :accepting
        ]
      )
    end

    # Its supervisor reads the Design part Flow put on it from the agent's result, changes
    # it by hand if need be, and accepts it: the design is approved, and its break-down
    # can be picked up.
    state :accepting, label: "Accept its design" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})

      present(
        expected: "Accept its design",
        why: "its agent's design is written",
        instructions:
          "Read its Design part, which its agent wrote; change it if need be, then accept it. It can then be broken down into issues.",
        answers: [[key: "a", label: "Accept", change: %{values: %{design_status: :approved}}]]
      )

      branch(
        to: :accepted,
        when: "entity.design_status == 'approved' or entity.design_status == 'accepted'"
      )
    end

    final :accepted, label: "Design accepted" do
      set(design_status: :accepted, phase: :break_down)
    end
  end

  subflow :break_down_use_case, label: "Break down use case", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'break_down'")
    initial(:break_down)
    supervise(:break_down, label: "Break down use case", states: [:break_down, :accepting])

    state :break_down, label: "Break it down into issues" do
      present(
        expected: "Break it down into issues",
        why: "nothing is under it yet",
        instructions:
          "Its machinery runs one agent on it that proposes its issues; Flow makes them under it. Nothing is done while it is not assigned to a machinery."
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the use case below into the issues that build it. Its scene, after it, says why it is to be done; the repository you are given, a Git checkout of develop, is what it builds on. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Each issue is one small change a developer can build, review and merge on its own, in the order given.",
        fields: [:title, :description],
        parents: [:title, :description],
        creates: [kind: :issue, file: "issues.json"],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :accepting,
          check_failed: :accepting,
          stuck: :accepting,
          abandoned: :accepting
        ]
      )
    end

    # Its supervisor looks at the issues Flow made from the agent's proposal, changes,
    # removes or adds any by hand, and accepts the break-down.
    state :accepting, label: "Accept it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept its issues",
        why: "its agent's break-down is done",
        instructions:
          "Read the issues under it, which its agent proposed; change, delete or add any, then accept them. They can then be picked up and built.",
        answers: [[key: "a", label: "Accept", change: %{values: %{verdict: :accept}}]]
      )

      branch(to: :broken_down, when: "entity.verdict == 'accept'")
    end

    final :broken_down, label: "Broken down" do
      set(phase: :accept)
    end
  end

  subflow :accept_use_case, label: "Build, test and accept", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'accept'")
    initial(:building)

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "not all under it is completed",
        instructions:
          "Build what is under it; Flow hands it on for testing once all of it is completed."
      )

      branch(
        to: :breaking_down,
        by: :atlas,
        when:
          "entity.children == 0 and (entity.design_status == 'approved' or entity.design_status == 'accepted')"
      )

      branch(to: :to_test, by: :atlas, when: "entity.children > 0 and entity.open_children == 0")
    end

    # Nothing under it: a new round of its break-down has it, and this run waits for it.
    state :breaking_down, label: "Being broken down" do
      set(phase: :break_down)

      present(
        expected: "Wait for its break-down",
        why: "nothing is under it",
        instructions: "Its break-down flow has it; Flow hands it back once that is accepted."
      )

      branch(to: :building, when: "entity.phase == 'accept'")
    end

    state :to_test, label: "Test it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Test it",
        why: "all under it is completed",
        instructions: "Try the test below, then accept it, or reject it with a note.",
        section: [field: :description, heading: "Melle can test"],
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :accepted_by, values: %{verdict: :accept}}
          ],
          [key: "f", label: "Reject", note: true, change: %{values: %{verdict: :reject}}]
        ]
      )

      branch(to: :accepted, when: "entity.verdict == 'accept'")
      branch(to: :rework, when: "entity.verdict == 'reject'")
      branch(to: :building, by: :atlas, when: "entity.open_children > 0")
    end

    state :rework, label: "Rework it" do
      present(
        expected: "Rework: {note}",
        why: "reopened",
        instructions:
          "Rework it as the note says; Flow hands it back for testing once all under it is completed."
      )

      branch(to: :building, by: :atlas, when: "entity.open_children > 0")
    end

    final(:accepted, label: "Accepted")
  end

  @projection [
    on: :assignment,
    state_field: :flow_state,
    handover_field: :handover,
    owner_relation: :assigned_to,
    field: :expected
  ]

  # How the runs of design_and_accept are selected, imported from the use case as it was
  # before the subflow ran, and presented: on its Assignment, as the legacy flow
  # design_and_accept did. One writer presents a use case at any moment, by its
  # `design_status` (disjoint phase admission): this run while the design is written or
  # reviewed, its break-down's or its acceptance's from its acceptance on (`approved`,
  # or `accepted`, which this run writes as it ends), and for a use case with no design
  # phase (no `design_status`). Such a use case never starts a design run.
  #
  # The first row that holds gives the entry of an admitted use case: one in review (its
  # design written by hand before slice 9) joins `accepting`, writing nothing. Any other
  # (`writing`, or `changes_requested`: sent back before slice 9) matches no row and
  # starts in `designing`, as a new one does, writing nothing. No pass, gate or
  # acceptance ran on one, so there is nothing else to carry.
  #
  # A completed run whose use case is put back in its design phase (a design reopened by
  # hand) is not started again, and nothing presents it until it is restarted: reopened
  # work starts a new generation only by an explicit restart (`reopen`, the design's
  # default, 5.2). No legacy flow takes it back: slice 11 ends its follow-through.
  select(:design_and_accept,
    choices: [],
    projection: @projection,
    admission: [design_status: [:writing, :in_review, :changes_requested]],
    imports: [[when: [design_status: [:in_review]], state: :accepting]],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test, and the only one it ever had. No run
  # had that digest: the subflow was never selected before slice 10. A run that did would
  # move along it as a state migration (re-entering its state, then moving on the
  # `design_status` it finds), never as a re-key: the gate, the acceptor's and the
  # maintainer's waits go to the review, whose branches read where the design is. One
  # with a frozen pass or gate is not quiescent and blocks. A `dropped` run is completed
  # and `designing` is open, so Flow refuses to move it and it blocks: a cancelled design
  # is never taken for an accepted one.
  migrate(:design_and_accept,
    from: "25f57fda40fa0e12d9322c7eb41a9d1829bee934777abe157f5c6a93685e377e",
    to: "57752d31e8065f37845ac886a1e93b6a24dc18d4a5aaeac20707c3c76e0ce571",
    states: [
      accepted: :accepted,
      design_gate: :design_review,
      design_review: :design_review,
      designing: :designing,
      dropped: :designing,
      needs_person: :design_review,
      redesign: :redesign,
      to_accept: :design_review
    ],
    reason: "Slice 10: selected without its passes, design gate and acceptor; designed by hand"
  )

  # Slice 9: its design is written by an agent and accepted by its supervisor; the hand
  # review and rework are gone. A run in `designing` or `redesign` (re-)enters
  # `designing` and waits there for its owner: once a person picks it up, its agent writes
  # its Design part. One in `design_review` has a design written by hand: it enters
  # `accepting`, where its supervisor accepts it. An accepted one stays accepted.
  migrate(:design_and_accept,
    from: "57752d31e8065f37845ac886a1e93b6a24dc18d4a5aaeac20707c3c76e0ce571",
    to: "9432119080804ec9531f365f8c630ebc1482a68825ee3e8dc930725853cd65b4",
    states: [
      accepted: :accepted,
      design_review: :accepting,
      designing: :designing,
      redesign: :designing
    ],
    reason: "Slice 9: an agent writes its design; its supervisor accepts it"
  )

  # Slice "pickup points as flows": its run ends handing the use case to its break-down
  # (`phase: break_down`). An accepted run stays accepted; the others are as they were.
  migrate(:design_and_accept,
    from: "9432119080804ec9531f365f8c630ebc1482a68825ee3e8dc930725853cd65b4",
    to: "49179c2eb7302bf8bd0b2ffee7780b36f6efc7c390cc09ddc171d1c417464829",
    states: :same,
    reason: "Its end hands the use case to its break-down flow (phase: break_down)"
  )

  # Each round of a use case's break-down is a new generation of its run: started when the
  # use case is handed to it (`phase` becomes `break_down`), never on its own.
  select(:break_down_use_case,
    choices: [],
    projection: @projection,
    admission: [design_status: [:approved, :accepted, nil], phase: [:break_down]],
    imports: [],
    reopen: :new_generation,
    restart_by: [:owner, :decider]
  )

  # A use case from before the split (no `phase`; on prod 5 building, 3 waiting for their
  # break-down, none picked up), or one without a design phase, is the acceptance's: a
  # completed one is completed history, any other joins `building`, whose count hands an
  # approved one with nothing under it to a new break-down. Their runs of the removed
  # test_and_accept_use_case are no longer selected.
  select(:accept_use_case,
    choices: [],
    projection: @projection,
    admission: [design_status: [:approved, :accepted, nil], phase: [:accept, nil]],
    imports: [
      [completed: true, state: :accepted],
      [when: [phase: [nil]], state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )
end
