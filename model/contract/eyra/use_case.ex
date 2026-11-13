defmodule Model.UseCase do
  @moduledoc """
  The two subflows of a use case: first its design, then building, testing and
  accepting it.

  `design_and_accept`:

    * `designing` → `design_review` → `accepted`: the Architect writes the Design part
      and sets `design_status` to `in_review`; its review sets it to `approved`, which
      accepts the design, or to `changes_requested` (or back to `writing`), which sends
      it to `redesign` and back through `design_review`.
    * The accepted design sets `design_status: accepted`, which starts the second
      subflow. (`design` itself is the Architect's text of the design; the subflow
      never writes it.)

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
      Each state moves on the `design_status` written by hand instead, as the legacy
      flow reads it, and `designing` and `redesign` keep the legacy owner, the
      Architect (the pass was routed to it);
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
      (`open_children`), then tested by an acceptor. `children` and `open_children`
      are the composition's count of the issues in the use case.
    * A rejection goes to a rework pass; a new open issue sends it back to building,
      and a rework that ends either way returns to the acceptor.
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
      description: "The Design part: how it is built, written by the Architect",
      multiline: true,
      label: "Design"
    )

    field(:design_status, :design_status,
      description: "Where the Design part is; empty for a use case without a design phase",
      label: "Design status"
    )

    field(:children, :integer, description: "Flow: how many issues are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")
    field(:verdict, :string, description: "Flow: the acceptor's verdict (none, accept, reject)")

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
  defgate :design,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :design_review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]

  subflow :design_and_accept, label: "Design and accept", subject: :use_case do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :work
    start :create
    initial :designing

    state :designing, label: "Design pass" do
      owner via: :assignment, relation: :assigned_to, default: {:agent, :architect}

      present(
        expected: "Write its Design part",
        why: "its design is not reviewed yet",
        instructions:
          "Write the Design part (design), then set design_status to in_review; when the review requested changes, make them first."
      )

      branch to: :accepted,
             when: "entity.design_status == 'approved' or entity.design_status == 'accepted'"

      branch to: :design_review, when: "entity.design_status == 'in_review'"
    end

    state :design_review, label: "Design review pass" do
      present(
        expected: "Have its design reviewed",
        why: "its Design part waits for review",
        instructions:
          "Run a review pass on the Design part: set design_status to approved to go on to break it down and build it, or to changes_requested, with why in the note, to send it back."
      )

      branch to: :accepted,
             when: "entity.design_status == 'approved' or entity.design_status == 'accepted'"

      branch to: :redesign,
             when:
               "entity.design_status == 'changes_requested' or entity.design_status == 'writing'"
    end

    state :redesign, label: "Design rework pass" do
      owner via: :assignment, relation: :assigned_to, default: {:agent, :architect}

      present(
        expected: "Write its Design part",
        why: "its design is not reviewed yet",
        instructions:
          "Write the Design part (design), then set design_status to in_review; when the review requested changes, make them first."
      )

      branch to: :accepted,
             when: "entity.design_status == 'approved' or entity.design_status == 'accepted'"

      branch to: :design_review, when: "entity.design_status == 'in_review'"
    end

    final :accepted, label: "Design accepted" do
      set design_status: :accepted
    end
  end

  subflow :test_and_accept_use_case, label: "Build, test and accept", subject: :use_case do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    start :predicate, when: "entity.design_status == 'accepted'"
    initial :break_down

    state :break_down, label: "Break it down into issues" do
      present(
        expected: "Break it down into issues",
        why: "nothing is under it yet",
        instructions:
          "Add the issues under it; Flow hands it on to build once something is under it."
      )

      pass :architect, mode: :author, writes: :none
      branch to: :building, by: :atlas, when: "entity.children > 0"
    end

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "not all under it is completed",
        instructions:
          "Build what is under it; Flow hands it on for testing once all of it is completed."
      )

      branch to: :break_down, by: :atlas, when: "entity.children == 0"
      branch to: :to_test, by: :atlas, when: "entity.open_children == 0"
    end

    state :to_test, label: "Test it" do
      present(
        expected: "Test it",
        why: "all under it is completed",
        instructions: "Try the test below, then accept it, or reject it with a note.",
        section: [field: :description, heading: "Melle can test"],
        answers: [
          [key: "a", label: "Accept", set: :accepted_by],
          [key: "f", label: "Reject", remove: :accepted_by]
        ]
      )

      wait_for [:acceptor], on: :verdict, accept: :accepted, reject: :rework
    end

    state :rework, label: "Rework it" do
      present(
        expected: "Rework: {note}",
        why: "reopened",
        instructions:
          "Rework it as the note says; Flow hands it back for testing once all under it is completed."
      )

      branch to: :building, by: :atlas, when: "entity.open_children > 0"

      pass :architect,
        mode: :rework,
        input: {:channel, :newest_since_last_pass},
        on: [delivered: :to_test, failed: {:to_test, "Rework failed; the acceptor decides"}]
    end

    final :accepted, label: "Accepted"
  end

  # How the runs of design_and_accept are selected, imported from the use case as it was
  # before the subflow ran, and presented: on its Assignment, as the legacy flow
  # design_and_accept did. One writer presents a use case at any moment, by its
  # `design_status` (disjoint phase admission): the run while the design is written or
  # reviewed, the legacy flow, which keeps the building phase, from its acceptance on
  # (`approved`, or `accepted`, which the run writes as it ends), and for a use case with
  # no design phase (no `design_status`). Such a use case never starts a run: none is
  # imported, and nothing is written or rerun for it.
  #
  # The first row that holds gives the entry of an admitted use case: one in review joins
  # the review, one whose review asked for changes the rework, each writing nothing. Any
  # other (`writing`: every admitted use case on test and prod today) matches no row and
  # starts in `designing`, as a new one does, writing nothing: what it showed and its owner
  # stay. No pass, gate or acceptance ran on one, so there is nothing else to carry.
  #
  # A completed run whose use case is put back in its design phase (a design reopened by
  # hand) is not started again (a new generation is an explicit restart, design 5.2): the
  # legacy flow presents it, as it does today (`follow_through`).
  select(:design_and_accept,
    legacy: :design_and_accept,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [design_status: [:writing, :in_review, :changes_requested]],
    imports: [
      [when: [design_status: [:in_review]], state: :design_review],
      [when: [design_status: [:changes_requested]], state: :redesign]
    ],
    follow_through: [
      state: :accepted,
      when: [design_status: [:writing, :in_review, :changes_requested]]
    ]
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
end
