defmodule Model.Scene do
  @moduledoc """
  The scene subflow: a scene is broken down into use cases (`children`), built until
  none is open (`open_children`), then tested and accepted by an acceptor.
  `children` and `open_children` are the composition's count of the use cases in
  the scene. A rejection goes to a rework pass; a new open use case sends it back to
  building, and a rework that ends either way returns to the acceptor.
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
