defmodule Model.UseCase do
  @moduledoc """
  The two subflows of a use case: first its design, then building, testing and
  accepting it.

  `design_and_accept`:

    * `designing` → `design_review` → `design_gate` → `to_accept` is the happy path:
      an architect's design pass, a review pass on another vendor, the design gate,
      and an acceptor who accepts the design.
    * A gate or an acceptor that asks for changes sends it to `redesign`, which goes
      back through `design_review`.
    * Anything that fails, times out or is uncertain lands in `needs_person`, where
      a maintainer chooses how to go on.
    * The accepted design sets `design_status: accepted`, which starts the second
      subflow. (`design` itself is the Architect's text of the design; the subflow
      never writes it.)

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

  subflow :design_and_accept, label: "Design and accept", subject: :use_case do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :work
    start :create
    initial :designing

    state :designing, label: "Design pass" do
      present(
        expected: "Write its Design part",
        why: "its design is not reviewed yet",
        instructions:
          "Write the Design part (design), then set design_status to in_review; when the review requested changes, make them first."
      )

      pass :architect,
        mode: :author,
        folder: {:materialize, :target},
        permissions: :materialized_folder,
        freeze: :packet,
        on: [delivered: :design_review, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the pass"
    end

    state :design_review, label: "Design review pass" do
      present(
        expected: "Have its design reviewed",
        why: "its Design part waits for review",
        instructions:
          "Run a review pass on the Design part: set design_status to approved to go on to break it down and build it, or to changes_requested, with why in the note, to send it back."
      )

      pass :architect,
        mode: :review,
        folder: {:packet, :last},
        permissions: :review_packet,
        diversity: :other_vendor,
        findings: :required,
        on: [delivered: :design_gate, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the review"
    end

    state :design_gate, label: "Design gate" do
      gate :design, ready: :to_accept, rework: :redesign, person: :needs_person
      timer :no_decision, "1h", to: :needs_person, label: "No gate decision within an hour"
    end

    state :redesign, label: "Design rework pass" do
      present(
        expected: "Write its Design part",
        why: "its design is not reviewed yet",
        instructions:
          "Write the Design part (design), then set design_status to in_review; when the review requested changes, make them first."
      )

      pass :architect,
        mode: :rework,
        folder: {:continue, :designing},
        permissions: :materialized_folder,
        input: {:channel, :newest_since_last_pass},
        freeze: :packet,
        on: [delivered: :design_review, failed: :needs_person]

      timer :runtime_wait, "2d",
        to: :needs_person,
        label: "The owner's Runtime did not finish the rework"
    end

    state :to_accept, label: "Accept the design" do
      wait_for [:acceptor], on: :verdict, accept: :accepted, reject: :redesign
    end

    state :needs_person, label: "A person decides" do
      wait_for [:maintainer],
        on: :gate_result,
        review: :design_review,
        rework: :redesign,
        ready: :to_accept,
        close: :dropped
    end

    final :accepted, label: "Design accepted" do
      set design_status: :accepted
    end

    final :dropped, label: "Dropped", status: :cancelled
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
end
