defmodule Model.Scene do
  @moduledoc """
  A scene, and its two flows: the start and the end of the scene pipeline (`pipeline
  :scene` in `Model.AtlasEyra`). A person supervises a flow, never a step (D-0099): each
  pickup point is a subflow of its own; the pipeline is horseshoe-shaped: it starts with
  the scene, its producer's input, and ends with its producer's acceptance.

    * `break_down_scene` **Design** (Scene → Use cases): a person picks it up (its span) and hands it to a machinery:
      one agent on the supervisor's Runtime reads the scene and a checkout of the
      repository and writes the use cases it proposes to a file in its result
      (`creates:`), each with its Design part, designed within the existing architecture
      (the decisions it reads first) and a note where it would need a new architecture
      choice. Flow, the only writer, makes them under the scene, designed (a use case is
      design, D-0099), and "Accept it"
      (`accepting`) goes to the supervisor, who looks at them, changes, removes or adds
      any by hand, and accepts the break-down. Its run ends there and hands the scene to
      `accept_scene` (`phase: accept`). After a "Not accepted", its agent reads the
      producer's note and proposes only what is missing: nothing under the scene is redone.
    * `accept_scene` **Accept** (Accept the scene): waits until every use case under it is accepted
      (`children`, `open_children`: the composition's count of the use cases in the scene,
      and of those without an accepted `accept_use_case` run), then goes to its producer
      (the configured decider until a scene records who produced it). Accept ends the
      pipeline; Not accepted keeps the producer's note (`note`) and starts a new round of
      `break_down_scene` (`phase: break_down`), which this run waits for
      (`breaking_down`). So does a scene with nothing under it.

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
    values: [:break_down, :accept, :accepted],
    labels: [break_down: "Break down", accept: "Accept", accepted: "Accepted"],
    descriptions: [
      break_down: "Its break-down flow has it: it is broken down into what builds it.",
      accept: "Its acceptance flow has it: what is under it is built, then it is accepted.",
      accepted: "Its acceptance flow accepted it."
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

    field(:note, :string,
      description: "Its producer's note when it was not accepted; its next break-down reads it",
      multiline: true,
      label: "Producer's note"
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

  # A use case has no Accept of its own (D-0099): it is accepted once its issues are done.
  relation(:accepted_by,
    label: "accepted by",
    description: "Who accepted a scene, after testing it; at most one.",
    from: [:scene],
    to: [:person],
    max_outgoing: 1,
    inverse: {:accepted, "accepted"},
    only_target: [error: "only a person accepts", also: [:migration]],
    actions: [set: [label: "Accept", key: "a"], remove: [label: "Reopen", key: "a"]],
    requires_completed_children: "{key} has {children} open",
    closes_parent: "{parent} is accepted; reopen it first, or put this under another {kind}"
  )

  # Design: Scene → Use cases.
  subflow :break_down_scene, label: "Design", subject: :scene do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'break_down'")
    initial(:break_down)
    supervise(:break_down, label: "Design", states: [:break_down, :accepting])

    state :break_down, label: "Break it down into use cases" do
      present(
        expected: "Break it down into use cases",
        why: "it is to be broken down",
        instructions:
          "Its machinery runs one agent on it that proposes its use cases; Flow makes them under it. Nothing is done while it is not assigned to a machinery.",
        section: [field: :note, heading: "Its producer's note"]
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the scene below into the use cases that build it, and design each: a use case is software design. The repository you are given, a Git checkout of develop, is what they build on; the decisions to read first, after the scene, are its architecture. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Each use case is one behaviour of the system that its actor sees, small enough to break into a few issues, in the order given; its description states that behaviour: who does what, and what they see then. Its design says how it is built within the existing architecture: which parts of the system change and how, what is new, the data and the flow through it, and how to tell it works. Never change the architecture: when a use case would need a new architecture choice, say so in its note instead of deciding it. When the scene has a note from its producer, it was built and not accepted: propose only the use cases still missing for what the note asks; those under it stay.",
        fields: [:title, :description, :note],
        read_first: true,
        creates: [kind: :use_case, file: "use_cases.json", fields: [:design, :note]],
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

  # Accept: Accept the scene.
  subflow :accept_scene, label: "Accept", subject: :scene do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'accept'")
    initial(:building)

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "not all under it is accepted",
        instructions:
          "Its use cases are designed, broken down and built; Flow hands it to its producer once all of them are accepted."
      )

      branch(to: :breaking_down, by: :atlas, when: "entity.children == 0")
      branch(to: :to_accept, by: :atlas, when: "entity.open_children == 0")
    end

    # A new round of its break-down has it (nothing under it, or not accepted), and this
    # run waits for it.
    state :breaking_down, label: "Being broken down" do
      set(phase: :break_down)

      present(
        expected: "Wait for its break-down",
        why: "it is broken down again",
        instructions: "Its break-down flow has it; Flow hands it back once that is accepted."
      )

      branch(to: :building, when: "entity.phase == 'accept'")
    end

    state :to_accept, label: "Accept" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept",
        why: "all under it is accepted",
        instructions:
          "Try the scene as its actor would, then accept it, or say why not: its break-down then proposes what is missing, and nothing under it is redone.",
        section: [field: :description, heading: "The scene"],
        answers: [
          [
            key: "a",
            label: "Accept",
            change: %{self: :accepted_by, values: %{verdict: :accept}}
          ],
          [
            key: "f",
            label: "Not accepted",
            note: true,
            change: %{values: %{verdict: :reject, note: "$note"}}
          ]
        ]
      )

      branch(to: :accepted, when: "entity.verdict == 'accept'")
      branch(to: :breaking_down, when: "entity.verdict == 'reject'")
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

  # A scene from before the split has no `phase` and is the acceptance's: a completed one
  # is completed history, any other joins `building`, whose count hands one with nothing
  # under it to a new break-down.
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

  # "Scene → Use cases": its agent designs each use case it proposes, reads the decisions
  # first and the producer's note; a run waiting for its pickup or its supervisor stays
  # where it is.
  migrate(:break_down_scene,
    from: "f3af151326510e0e56885c3e76a3da8e50c061edbb28cededb570791013f21f9",
    to: "22f92911df5dc1f8386533e92dd53367904496f854b86e771c6f84881a4387c1",
    states: :same,
    reason: "Scene → Use cases: designed use cases, decisions read first, the producer's note"
  )

  # "Accept the scene": its test became its producer's acceptance; a rejection now starts
  # a new round of its break-down instead of a rework by hand.
  migrate(:accept_scene,
    from: "95c7c942d555713bab940479905782881b0bcb706efc832d83c8f921519602e4",
    to: "1b85486e82166f7878485e80060bb2afb3f62c9cca9ff8b66f803151e171dbe3",
    states: [
      accepted: :accepted,
      breaking_down: :breaking_down,
      building: :building,
      rework: :building,
      to_test: :to_accept
    ],
    reason: "Accept the scene: its producer accepts it, or a new round of its break-down starts"
  )

  # Design: its label was its signature, Scene → Use cases; nothing else changed.
  migrate(:break_down_scene,
    from: "22f92911df5dc1f8386533e92dd53367904496f854b86e771c6f84881a4387c1",
    to: "bf01ce6f998aa561aeed3447ae41c1bd35bd2df082399358b59a2353a20a9ba9",
    states: :same,
    reason: "Design: renamed from Scene → Use cases"
  )

  # Accept: its label, and what its producer is asked, were Accept the scene.
  migrate(:accept_scene,
    from: "1b85486e82166f7878485e80060bb2afb3f62c9cca9ff8b66f803151e171dbe3",
    to: "0b7d903c06f4bfcc82b632475f3274cb32542868402a7e8959ea5407affe0d10",
    states: :same,
    reason: "Accept: renamed from Accept the scene"
  )

  # Design: the use cases it makes are designed; it no longer writes a design status
  # (D-0099). A run waiting for its pickup or its supervisor stays where it is.
  migrate(:break_down_scene,
    from: "bf01ce6f998aa561aeed3447ae41c1bd35bd2df082399358b59a2353a20a9ba9",
    to: "54483a0d6c36f6d302c5aa85ae64deb5380952192a752dfebd1d55c9f794d4ec",
    states: :same,
    reason: "Design: its use cases carry no design status"
  )
end
