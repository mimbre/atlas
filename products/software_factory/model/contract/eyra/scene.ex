defmodule Model.Scene do
  @moduledoc """
  The scene subflow: a scene is broken down into use cases (`children`), built until
  none is open (`open_children`), then tested by the configured decider and accepted.
  `children` and `open_children` are the composition's count of the use cases in the
  scene: how many relate to it (`in_scene`), and how many of them have no completed run
  of `test_and_accept_use_case`. Slice 8: a person picks up its break-down
  (`break_down`, the span `break_down`) and hands it to a machinery: one agent on the
  supervisor's Runtime reads the scene and a checkout of the repository and writes the
  use cases it proposes to a file in its result (`creates:`, as slice 7 breaks a use case
  into issues). Flow, the only writer, makes them under the scene, and "Accept it"
  (`accepting`) goes to the supervisor, who looks at them and accepts the break-down.
  When the agent proposes nothing, or the scene is taken from the machinery, the
  supervisor breaks it down by hand in "Accept it". A rejection sends it to its rework;
  a new open use case sends it back to building.

  Slice 12 runs it on Flow's durable runs (`select`), for every scene, which the legacy
  flow `test_and_accept` then drives none of. The parity fixes keep it to what runs today:

    * no passes (rework): its spec is no pass contract a runner accepts
      (`AtlasFlow.Activities.Pass.valid?/1`: a routing field, a frozen request), and a
      pass needs what does not exist yet: a machine field on the agent to route by, a
      packet freeze and review-packet contract, Runtime's pass receiver configured in an
      environment; a definition a runner refuses would refuse every selected subflow.
      The coordinator reworks it by hand, as today; `pass_result` stays on the kind,
      unwritten, for it;
    * `to_test` is the configured decider's (`{:person, config: :decider}`), as the
      legacy flow's `to_test` is, and moves on `verdict`, which its two answers write, no
      longer on an acceptor's typed choice (`wait_for [:acceptor]`): Facts takes a choice
      only from one a relation of the scene names, and none names who rejects
      (`accepted_by` names the one who accepted, and naming oneself there accepts and
      completes the scene). Accept writes `verdict: accept` with `accepted_by` set to the
      one who answers, in one change, so Facts' rules on `accepted_by` (only a person,
      only themselves, nothing under it open) guard it as today; Reject writes
      `verdict: reject` with a note. Its entry resets `verdict` to `none`, so an older
      verdict moves nothing;
    * a new open use case sends it back from `to_test` to building, as the legacy flow's
      `progress: to_test` stops holding then.
  """
  use RelaDSL

  type(:plan_status,
    values: [:refine, :ready_to_pick_up],
    labels: [refine: "Refine", ready_to_pick_up: "Ready to pick up"],
    descriptions: [
      refine: "Being written and negotiated; not ready to build from.",
      ready_to_pick_up: "Agreed; the next level can be derived and built."
    ]
  )

  entity :scene,
    label: "Scene",
    plural: "scenes",
    aliases: ["sc"],
    id_type: :manual,
    id_prefix: "SC-",
    description: """
    An actor-centred view of the system, with one angle and one zoom level
    (Flux's meaning). The id is its code, e.g. SC-Atlas-01.
    """ do
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:status, :plan_status, description: "Flux group; empty = no group", label: "Flux group")
    field(:children, :integer, description: "Flow: how many use cases are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")

    field(:verdict, :string,
      description:
        "Flow: the acceptor's verdict (none, accept, reject), or its supervisor's acceptance of its use cases (accept)"
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

    create(ask: [:title, :description], defaults: [status: :refine])
    progress(over: :in_scene, own: :status)
    completion(by: :accepted_by)
  end

  subflow :test_and_accept_scene, label: "Build, test and accept", subject: :scene do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:create)
    initial(:break_down)
    supervise(:break_down, label: "Break down", states: [:break_down, :accepting])

    state :break_down, label: "Break it down into use cases" do
      present(
        expected: "Break it down into use cases",
        why: "nothing is under it yet",
        instructions:
          "Its machinery runs one agent on it that proposes its use cases; Flow makes them under it. Nothing is done while it is not assigned to a machinery."
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the scene below into the use cases that build it. The repository you are given, a Git checkout of develop, is what they build on. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Each use case is one behaviour of the system that its actor sees, small enough to break into a few issues, in the order given; its description states that behaviour: who does what, and what they see then.",
        fields: [:title, :description],
        creates: [kind: :use_case, file: "use_cases.json"],
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

    # Its supervisor looks at the use cases Flow made from the agent's proposal, changes,
    # removes or adds any by hand, and accepts the break-down. Without use cases under
    # it, building sends it back to break it down again.
    state :accepting, label: "Accept it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept its use cases",
        why: "its agent's break-down is done",
        instructions:
          "Read the use cases under it, which its agent proposed; change, delete or add any, then accept them. They can then be designed, broken down and built.",
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

      branch(to: :break_down, by: :atlas, when: "entity.children == 0")
      branch(to: :to_test, by: :atlas, when: "entity.open_children == 0")
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

  # How the runs of test_and_accept_scene are selected, imported from the scene as it was
  # before the subflow ran, and presented: on its Assignment, as the legacy flow
  # test_and_accept did, which then drives no scene. It admits every scene (no admission
  # condition): the one subflow on the kind, so each scene has one writer at any moment.
  #
  # The first row that holds gives the entry, writing nothing and rerunning nothing:
  #
  #   * a completed scene (accepted, `completion` as Facts derives it) is completed
  #     history, `accepted` (none on test or prod today);
  #   * any other (every scene on test and prod: 11 "Build it" and test's SC-Atlas-02
  #     "Break it down into use cases and issues", all for the coordinator) joins
  #     `building`. The count of its use cases, given to the run on its first entry (no
  #     scene holds one yet: nothing counted them while no subflow ran on a scene), moves
  #     one with none under it to `break_down`, and one whose use cases all completed to
  #     `to_test`, as the legacy flow presents them. A row cannot read the use cases under
  #     a scene, only its values; the count can.
  #
  # A scene created later matches the second row too, and its count moves it to
  # `break_down` at once, as the legacy flow presents a new one.
  #
  # A completed run is not started again when its scene is reopened (`accepted_by`
  # removed), nor when a use case under it reopens: only an explicit restart makes a new
  # generation (`reopen: :explicit`, the design's default, 5.2). Until one, nothing
  # presents a reopened scene; its count is still written.
  select(:test_and_accept_scene,
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
      [completed: true, state: :accepted],
      [completed: false, state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )

  # The approved migrations of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test. Slice 12's first: no run had its
  # `from`, the subflow was never selected before slice 12. A run that did would
  # move along it as a state migration (re-entering its state, then moving on the counts
  # and the verdict it finds), never as a re-key: its states are the same, but its passes
  # went, and the acceptor's choice became the decider's verdict. One with a frozen pass
  # is not quiescent and blocks.
  migrate(:test_and_accept_scene,
    from: "79141c9da4b0fe990b2add3265ce542b546a0a68f9922e0128c502aa5ae1b444",
    to: "c29dfcb9a206681c88eaf60343ac2f05841fccb39e86b8b8530373584afa8a8f",
    states: :same,
    reason: "Slice 12: selected without its passes; the decider's verdict ends to_test"
  )

  # Slice 8: its break-down is an agent's proposal, accepted by its supervisor. A run in
  # `break_down` re-enters it and waits there, as before, for its owner: once a person
  # picks it up and hands it to a machinery, its agent proposes its use cases. Every other
  # state stays as it is.
  migrate(:test_and_accept_scene,
    from: "c29dfcb9a206681c88eaf60343ac2f05841fccb39e86b8b8530373584afa8a8f",
    to: "95d5d0981bc11f7e9f6544c1f2c06c57d3063d6117d668877e48b84abe78c104",
    states: [
      accepted: :accepted,
      break_down: :break_down,
      building: :building,
      rework: :rework,
      to_test: :to_test
    ],
    reason: "Slice 8: an agent proposes its use cases; its supervisor accepts them"
  )
end
