defmodule Model.Scene do
  @moduledoc """
  A scene, and its two flows. A person supervises a flow, never a step (D-0099): each
  pickup point is a subflow of its own.

    * `break_down_scene`: a person picks it up (its span) and hands it to a machinery:
      one agent on the supervisor's Runtime reads the scene and a checkout of the
      repository and writes the use cases it proposes to a file in its result
      (`creates:`). Flow, the only writer, makes them under the scene, and "Accept it"
      (`accepting`) goes to the supervisor, who looks at them, changes, removes or adds
      any by hand, and accepts the break-down. Its run ends there and hands the scene to
      `accept_scene` (`phase: accept`).
    * `accept_scene`: builds it until none of its use cases is open (`children`,
      `open_children`: the composition's count of the use cases in the scene, and of
      those without a completed `accept_use_case` run), then the configured decider tests
      it and accepts it, or rejects it with a note (`rework`, until a new open use case
      sends it back to building). With no use case under it, it hands the scene back to
      a new round of `break_down_scene` (`phase: break_down`) and waits for it
      (`breaking_down`).

  `phase` says which of the two has the scene: their admissions are disjoint, so one
  writer presents a scene at any moment. A new scene starts in `break_down`; one from
  before the split has none and is the acceptance's, which imports it.
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

  type(:pipeline_phase,
    values: [:break_down, :accept],
    labels: [break_down: "Break down", accept: "Accept"],
    descriptions: [
      break_down: "Its break-down flow has it: it is broken down into what builds it.",
      accept: "Its acceptance flow has it: what is under it is built, then it is accepted."
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

    field(:phase, :pipeline_phase,
      description: "Flow: which flow of its pipeline has it (break down, accept)",
      label: "Phase"
    )

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

    create(ask: [:title, :description], defaults: [status: :refine, phase: :break_down])
    progress(over: :in_scene, own: :status)
    completion(by: :accepted_by)
  end

  subflow :break_down_scene, label: "Break down scene", subject: :scene do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'break_down'")
    initial(:break_down)
    supervise(:break_down, label: "Break down scene", states: [:break_down, :accepting])

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
    # removes or adds any by hand, and accepts the break-down.
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

      branch(to: :broken_down, when: "entity.verdict == 'accept'")
    end

    final :broken_down, label: "Broken down" do
      set(phase: :accept)
    end
  end

  subflow :accept_scene, label: "Build, test and accept", subject: :scene do
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

      branch(to: :breaking_down, by: :atlas, when: "entity.children == 0")
      branch(to: :to_test, by: :atlas, when: "entity.open_children == 0")
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

  # Each round of a scene's break-down is a new generation of its run: started when the
  # scene is handed to it (`phase` becomes `break_down`), never on its own.
  select(:break_down_scene,
    choices: [],
    projection: @projection,
    admission: [phase: [:break_down]],
    imports: [],
    reopen: :new_generation,
    restart_by: [:owner, :decider]
  )

  # A scene from before the split (no `phase`; on prod 9 building, 2 waiting for their
  # break-down, none picked up) is the acceptance's: a completed one is completed history,
  # any other joins `building`, whose count hands one with nothing under it to a new
  # break-down. Their runs of the removed test_and_accept_scene are no longer selected.
  select(:accept_scene,
    choices: [],
    projection: @projection,
    admission: [phase: [:accept, nil]],
    imports: [
      [completed: true, state: :accepted],
      [when: [phase: [nil]], state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )
end
