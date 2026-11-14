defmodule Model.Scene do
  @moduledoc """
  The scene subflow: a scene is broken down into use cases (`children`), built until
  none is open (`open_children`), then tested by the configured decider and accepted.
  `children` and `open_children` are the composition's count of the use cases in the
  scene: how many relate to it (`in_scene`), and how many of them have no completed run
  of `test_and_accept_use_case`. A rejection sends it to its rework; a new open use case
  sends it back to building.

  Slice 12 runs it on Flow's durable runs (`select`), for every scene, which the legacy
  flow `test_and_accept` then drives none of. The parity fixes keep it to what runs today:

    * no passes (break it down, rework): their specs are no pass contract a runner
      accepts (`AtlasFlow.Activities.Pass.valid?/1`: a routing field, a frozen request),
      and a pass needs what does not exist yet: a machine field on the agent to route by,
      a packet freeze and review-packet contract, Runtime's pass receiver configured in
      an environment; a definition a runner refuses would refuse every selected subflow.
      The coordinator breaks it down and reworks it by hand, as today; `pass_result`
      stays on the kind, unwritten, for them;
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
    field(:verdict, :string, description: "Flow: the acceptor's verdict (none, accept, reject)")

    field(:pass_result, :string,
      description: "Flow: how the last pass ended (none, delivered, failed)"
    )

    create(ask: [:title, :description], defaults: [status: :refine])
    progress(over: :in_scene, own: :status)
    completion(by: :accepted_by)
  end

  subflow :test_and_accept_scene, label: "Build, test and accept", subject: :scene do
    run_as "system:sf-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    start :create
    initial :break_down

    state :break_down, label: "Break it down into use cases" do
      present(
        expected: "Break it down into use cases and issues",
        why: "nothing is under it yet",
        instructions:
          "Add the use cases under it, and their issues; Flow hands it on to build once something is under it."
      )

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
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set verdict: :none

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

      branch to: :accepted, when: "entity.verdict == 'accept'"
      branch to: :rework, when: "entity.verdict == 'reject'"
      branch to: :building, by: :atlas, when: "entity.open_children > 0"
    end

    state :rework, label: "Rework it" do
      present(
        expected: "Rework: {note}",
        why: "reopened",
        instructions:
          "Rework it as the note says; Flow hands it back for testing once all under it is completed."
      )

      branch to: :building, by: :atlas, when: "entity.open_children > 0"
    end

    final :accepted, label: "Accepted"
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
    reopen: :explicit
  )

  # The approved migration of its runs, from the digest the base branch recorded
  # (RelaDSL.RunIdentity); the same in prod and test, and the only one it ever had. No run
  # had that digest: the subflow was never selected before slice 12. A run that did would
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
end
