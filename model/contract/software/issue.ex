defmodule Model.Issue do
  @moduledoc """
  The Issue subflow. An issue is built in one pull request and done when that is merged.

  How it reads:

    * `author` presents "Build it" to the issue's owner (the coordinator, unless someone
      assigned it by hand) from the moment the issue exists, as the legacy flow
      `build_and_merge` did; the owner's Runtime works on it through the handover, as
      today.
    * Whoever builds it opens the pull request and links it to the issue (`in_issue`).
      The pull request's own subflow reports back through the composition's link
      (`pr_outcome`): `integrated` ends it as `done`. Changes requested on it, or a
      closed one, leave the issue to be built, as today: the pull request presents
      the changes, and a closed one is followed by another.

  Slice 9 runs it on Flow's durable runs (`select`), in place of the legacy flow
  `build_and_merge`. The parity fixes keep it to what runs today, where an agent builds
  an issue through its Runtime turns and opens and links its pull request by hand:

    * no passes yet (author, review, rework): the pass specs are no pass contract a
      runner accepts (`AtlasFlow.Activities.Pass.valid?/1`: a routing field, a frozen
      request), and a pass needs what does not exist yet: a machine field on the agent
      to route by, Code materializing the target, a packet freeze and review-packet
      contract, another vendor for the review, Runtime's pass receiver configured in an
      environment; a definition a runner refuses would refuse every selected subflow;
    * no gates in the subflow yet (`delivery_evidence`, `review`): both are smart gates,
      and Gates has no evaluator for one, nor their evidence (packet, tests, findings)
      or advice (Jev, the review pass); a gate Gates cannot answer would stop every
      reconcile on its run. The gates stay defined, for when the passes come back;
    * no publish effect yet: Code has no receiver that passed the effect contract (as
      slice 8 found for integrate), so the pull request is opened and linked by hand;
    * no timers: each waited on a pass, a gate or the effect; with them gone, a timer
      would only move a waiting issue to a person after a fixed time, which nothing does
      today;
    * no `needs_person` and no `closed`: only the failures and timeouts above led to the
      person's choice, and its choices led to the states that went; a person's choice
      would also need a relation that names the maintainer of an issue, which none
      does; and a closed pull request does not close its issue today;
    * it starts when the issue is created, not at `stage == 'development'`: the legacy
      flow presents every open issue whatever its stage, and a run that has not started
      presents nothing. The stage start belongs with the passes.

  `pass_result`, `gate_result` and `effect_result` stay on the kind, unwritten, for them.
  """
  use RelaDSL

  type(:issue_stage,
    values: [:specification, :design, :development],
    labels: [specification: "Specification", design: "Design", development: "Development"]
  )

  entity :issue,
    label: "Issue",
    plural: "issues",
    aliases: ["is"],
    id_type: :manual,
    id_prefix: "IS-",
    description: """
    Small, independently testable work, normally one pull request (Flux's
    meaning). The id is its Atlas code, e.g. IS-Atlas-01.
    """ do
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:stage, :issue_stage, description: "Flux: stage")

    field(:flux_ref, :string,
      unique: true,
      description: "Flux's own issue code (ref), e.g. NEXT-240, set by a later Flux sync",
      set_by: :connector
    )

    field(:pass_result, :string,
      description: "Flow: how the last pass ended (none, delivered, failed)"
    )

    field(:gate_result, :string,
      description:
        "Flow: the last gate verdict, or a maintainer's choice (none, review, rework, ready, person, close)"
    )

    field(:effect_result, :string,
      description: "Flow: how publishing the pull request ended (none, done, refused)"
    )

    field(:pr_outcome, :string,
      description:
        "Flow: where its pull request is (none, open, changes_requested, integrated, closed)"
    )

    create(ask: [:title, :description])
  end

  # After an author or rework pass: is the evidence good enough to review? Named by no
  # state while the passes wait (slice 9); Gates has no evaluator for a smart gate yet.
  defgate :delivery_evidence,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: :jev,
    evidence: [:assignment, :turn, :packet, :tests, :limits],
    verdicts: [:review, :rework, :person],
    decide: [pass: :review, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, execution_failed: :person]

  # After the review pass: is the work ready to publish as a pull request? Named by no
  # state while the review pass waits (slice 9).
  defgate :review,
    version: 1,
    flavor: :smart,
    purpose: :flow,
    advice: {:review_pass, :review},
    evidence: [:packet, :findings, :guidelines, :guardrails],
    verdicts: [:ready, :rework, :person],
    decide: [pass: :ready, changes_required: :rework, uncertain: :person, error: :person],
    policy: [max_rounds: 3, binds: :fingerprint]

  subflow :issue, label: "Issue", subject: :issue do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :work
    start :create
    initial :author

    state :author, label: "Building" do
      present(
        expected: "Build it",
        why: "its pull request is not merged",
        instructions:
          "Build it in one pull request and get that merged; link the pull request to it."
      )

      # Changes requested on its pull request, or a closed one: it is built again, as
      # today (a new entry of the same state, nothing written); merged: done.
      await :pr_outcome, changes_requested: :author, integrated: :done, closed: :author
    end

    final :done, label: "Integrated"
  end

  # How the runs of issue are selected, imported from the issue as it was before the
  # subflow ran, and presented: on its Assignment, as the legacy flow build_and_merge did,
  # which no longer drives an issue. The first row that holds gives the entry. An issue
  # whose pull request already reported its merge is completed history (no entry writes,
  # nothing rerun). Any other issue (every one today: no flow wrote pr_outcome, and no pass,
  # gate or effect ever ran on one, so there is no private work, packet or review round to
  # carry) matches no row and starts in `author`, as a new one does, writing nothing: what
  # it showed and its owner stay. Its pull requests, open or merged, are already linked to
  # it; their runs report to it through the composition's link.
  select(:issue,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [],
    imports: [
      [when: [pr_outcome: [:integrated]], state: :done]
    ]
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test. No run had that digest: the
  # subflow was never selected before slice 9. A run that did would move along it as a
  # state migration (re-entering its state), never as a re-key: every open state goes to
  # `author`, the one open state left, and a quiescent run there waits for the merge;
  # one with a frozen pass, gate or effect is not quiescent and blocks. A `closed` run
  # is completed and `author` is open, so Flow refuses to move it and it blocks: a
  # cancelled run is never taken for an integrated one.
  migrate(:issue,
    from: "99b406f1da0c908d703acd82c37c2bd07ec5c103e352809afed37b676693ed5e",
    to: "6dcb5eefa0dd0aec97748b7280249678cb64d759808b81e2104b3992c7b38052",
    states: [
      author: :author,
      closed: :author,
      delivery_gate: :author,
      done: :done,
      in_pr: :author,
      needs_person: :author,
      publish: :author,
      review: :author,
      review_gate: :author,
      rework: :author
    ],
    reason: "Slice 9: selected without its passes, gates and publish effect; built by hand"
  )
end
