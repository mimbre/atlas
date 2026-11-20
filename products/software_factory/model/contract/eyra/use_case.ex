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
      sets `design_status: accepted` and starts the second subflow, whose break-down can
      then be picked up. When the agent writes nothing, or its task ends otherwise, the
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

  `test_and_accept_use_case`:

    * The use case is broken down into issues (`children`), built until none is open
      (`open_children`), then tested by the configured decider. `children` and
      `open_children` are the composition's count of the issues in the use case.
    * Slice 7: a person picks up its break-down (`break_down`, the span `break_down`) and
      hands it to a machinery: one agent on the supervisor's Runtime reads the use case,
      its scene and a checkout of the repository, and writes the issues it proposes to a
      file in its result (`creates:`). Flow, the only writer, makes them under the use
      case, and "Accept it" (`accepting`) goes to the supervisor, who looks at them and
      accepts the break-down; the issues can then be picked up and built. When the agent
      proposes nothing, or the use case is taken from the machinery, the supervisor
      breaks it down by hand in "Accept it".
    * A rejection sends it to its rework; a new open issue sends it back to building.

  Slice 11 runs it on Flow's durable runs (`select`) for the building phase of the legacy
  flow `design_and_accept`, which then drives no use case at all: its design run owns a
  use case while the design is written or reviewed, its build run from the design's
  acceptance on, and for a use case with no design phase. The parity fixes keep it to
  what runs today:

    * no passes (rework): its spec is no pass contract a runner accepts
      (`AtlasFlow.Activities.Pass.valid?/1`), for the reasons the design's passes wait
      (slice 10); a definition a runner refuses would refuse every selected subflow. The
      coordinator reworks it by hand, as today;
    * `to_test` is the configured decider's (`{:person, config: :decider}`), as the
      legacy flow's `to_test` is, and moves on `verdict`, which its two answers write,
      no longer on an acceptor's typed choice: Facts takes a choice only from one a
      relation of the use case names, and none names who rejects (`accepted_by` names
      the one who accepted, and naming oneself there accepts and completes the use case).
      Accept writes `verdict: accept` with `accepted_by` set to the one who answers, in one
      change, so Facts' rules on `accepted_by` (only a person, only themselves, nothing
      under it open) guard it as today; Reject writes `verdict: reject` with a note. Its
      entry resets `verdict` to `none`, so an older verdict moves nothing;
    * a new open issue sends it back from `to_test` to building, and a use case with no
      design phase is not broken down while nothing is under it, nor tested: the legacy
      flow builds it (`building`) until something under it is; with issues it is tested
      once all are completed, as the legacy flow's `progress: to_test` says.
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
      set(design_status: :accepted)
    end
  end

  subflow :test_and_accept_use_case, label: "Build, test and accept", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.design_status == 'accepted'")
    initial(:break_down)
    supervise(:break_down, label: "Break down", states: [:break_down, :accepting])

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
    # removes or adds any by hand, and accepts the break-down. Without issues under it,
    # building sends it back to break it down again.
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

      branch(to: :building, when: "entity.verdict == 'accept'")
    end

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "not all under it is completed",
        instructions:
          "Build what is under it; Flow hands it on for testing once all of it is completed."
      )

      branch(
        to: :break_down,
        by: :atlas,
        when:
          "entity.children == 0 and (entity.design_status == 'approved' or entity.design_status == 'accepted')"
      )

      branch(to: :to_test, by: :atlas, when: "entity.children > 0 and entity.open_children == 0")
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

  # How the runs of design_and_accept are selected, imported from the use case as it was
  # before the subflow ran, and presented: on its Assignment, as the legacy flow
  # design_and_accept did. One writer presents a use case at any moment, by its
  # `design_status` (disjoint phase admission): this run while the design is written or
  # reviewed, the build run (test_and_accept_use_case) from its acceptance on (`approved`,
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
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
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

  # How the runs of test_and_accept_use_case are selected, imported from the use case as
  # it was before the subflow ran, and presented: on its Assignment, where the legacy flow
  # design_and_accept presented its building phase, which no longer drives a use case. It
  # admits a use case from its design's acceptance on (`approved`, `accepted`) and one with
  # no design phase (nil: no `design_status`): every one the design run does not, so each
  # use case has one writer at any moment, and none is left to the legacy flow.
  #
  # The first row that holds gives the entry, writing nothing and rerunning nothing:
  #
  #   * a completed use case (accepted, `completion` as Facts derives it) is completed
  #     history, `accepted`;
  #   * an approved one (prod: 5 "Build it" and 3 "Break it down into issues", for the
  #     coordinator), approved before this subflow ran, joins `building`; the count of its
  #     issues, given to the run on its first entry, moves one with none under it to
  #     `break_down`, and one whose issues are all completed to `to_test`, as the legacy
  #     flow presents them;
  #   * one with no design phase (test: 2 "Build it", for the coordinator) joins
  #     `building`, where it stays while nothing is under it, as in the legacy flow.
  #
  # Any other matches no row: one whose design run accepted it (`accepted`) starts on its
  # predicate, in `break_down`, once. Its design run's cursor is its own; the two share
  # only the use case's count of its issues, which the composition gives both.
  #
  # A completed run is not started again when its use case is reopened (`accepted_by`
  # removed, its design put back and accepted again): only an explicit restart makes a new
  # generation (`reopen: :explicit`, the design's default, 5.2). Until one, nothing
  # presents a reopened use case.
  select(:test_and_accept_use_case,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [design_status: [:approved, :accepted, nil]],
    imports: [
      [completed: true, state: :accepted],
      [when: [design_status: [:approved]], state: :building],
      [when: [design_status: [nil]], state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test, and the only one it ever had. No run
  # had that digest: the subflow was never selected before slice 11. A run that did would
  # move along it as a state migration (re-entering its state, then moving on the counts
  # and the verdict it finds), never as a re-key: its states are the same, but its passes
  # went, and the acceptor's choice became the decider's verdict. One with a frozen pass
  # is not quiescent and blocks.
  migrate(:test_and_accept_use_case,
    from: "439466529c0f51d0f91d8ace07c9f5fa6ca2cfb04bfcc4557b6ba57342b2e0f1",
    to: "d4222657ad88e5d0310136893bd47f89e9a447874ede4d0c21067622728d1b04",
    states: :same,
    reason: "Slice 11: selected without its passes; the decider's verdict ends to_test"
  )

  # Slice 7: its break-down is an agent's proposal, accepted by its supervisor. A run in
  # `break_down` re-enters it and waits there, as before, for its owner: once a person
  # picks it up and hands it to a machinery, its agent proposes its issues. Every other
  # state stays as it is.
  migrate(:test_and_accept_use_case,
    from: "d4222657ad88e5d0310136893bd47f89e9a447874ede4d0c21067622728d1b04",
    to: "ec6cdede1bc4a90a80e6f4dfae1d390ad1538f9c99ab67f40f7842a23c004cf9",
    states: [
      accepted: :accepted,
      break_down: :break_down,
      building: :building,
      rework: :rework,
      to_test: :to_test
    ],
    reason: "Slice 7: an agent proposes its issues; its supervisor accepts them"
  )
end
