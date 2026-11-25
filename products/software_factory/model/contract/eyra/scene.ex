defmodule Model.Scene do
  @moduledoc """
  A scene, and its two flows: the start and the end of the scene pipeline (`pipeline
  :scene` in `Model.AtlasEyra`). A person supervises a flow, never a step (D-0099): each
  pickup point is a subflow of its own; the pipeline is horseshoe-shaped: it starts with
  the scene, its producer's input, and ends with its producer's acceptance.

    * `break_down_scene` **Design** (Scene → Use cases): a person picks it up (its span), and that pickup
      alone starts its work: one agent on the supervisor's Runtime reads the scene and a checkout of the
      repository and writes the use cases it proposes to a file in its result
      (`creates:`), each with its Design part, designed within the existing architecture
      (the decisions it reads first) and a note where it would need a new architecture
      choice. Flow, the only writer, makes them under the scene, designed (a use case is
      design, D-0099), and "Accept it"
      (`accepting`) goes to the supervisor, who looks at them, changes, removes or adds
      any by hand, and accepts the break-down. Its run ends there and hands the scene to
      `accept_scene` (`phase: accept`). After a "Not accepted", its agent reads the
      producer's note and proposes only what is missing: nothing under the scene is redone.
      When the scene is too vague to design use cases from, its agent does not guess: it
      writes its questions instead (`asks:`), Flow puts them in the scene's `questions` and
      makes nothing, and "Answer its questions" (`clarifying`) goes to the scene's producer
      (the configured decider until a scene records who produced it). They may rewrite the
      description by hand first; their "Answered" note goes into `answers`, and the scene goes
      back to `break_down`, whose next pass of its agent reads the questions, the answers and
      the current description, on the same supervisor's Runtimes (UC-Atlas-24).
    * `accept_scene` **Accept** (Accept the scene): waits until every use case under it is accepted
      (`children`, `open_children`: the composition's count of the use cases in the scene,
      and of those without an accepted `accept_use_case` run), then asks its producer (the
      configured decider until a scene records who produced it). While it waits
      (`building`) it is its producer's, with no to-do: nothing is built on the scene and
      nobody has anything to do on it. Accept ends the
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

    field(:questions, :string,
      description:
        "Flow: its Design agent's questions, when it was too vague to design use cases from; written by Flow alone",
      multiline: true,
      set_by: [:flow],
      label: "Its agent's questions"
    )

    field(:answers, :string,
      description:
        "Its producer's answers to its agent's questions; its next break-down reads them",
      multiline: true,
      label: "Producer's answers"
    )

    field(:children, :integer, description: "Flow: how many use cases are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")

    field(:verdict, :string,
      description:
        "Flow: the acceptor's verdict (none, accept, reject), its supervisor's acceptance of its use cases (accept), or its producer's answer to its agent's questions (answered)"
    )

    # What its break-down's task branch reads: the run's own result, never written.
    field(:task_result, :string,
      description:
        "Flow: how its break-down's agent task ended (completed, check_failed, stuck, abandoned, asked); the run's own, never written",
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
  # Nor is a scene accepted by hand: its producer's answer in Accept sets it.
  relation(:accepted_by,
    label: "accepted by",
    description: "Who accepted a scene, after testing it; at most one.",
    from: [:scene],
    to: [:person],
    max_outgoing: 1,
    inverse: {:accepted, "accepted"},
    only_target: [error: "only a person accepts", also: [:migration]],
    requires_completed_children: "{key} has {children} open",
    closes_parent: "{parent} is accepted; put this under another {kind}"
  )

  # Design: Scene → Use cases.
  subflow :break_down_scene, label: "Design", subject: :scene do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'break_down'")
    initial(:break_down)
    supervise(:break_down, label: "Design", states: [:break_down, :clarifying, :accepting])

    state :break_down, label: "Break it down into use cases" do
      present(
        expected: "Break it down into use cases",
        why: "it is to be broken down",
        instructions:
          "Its supervisor's Runtime runs one agent on it that proposes its use cases; Flow makes them under it. Its supervisor's pickup starts the work: nothing is done until then.",
        section: [field: :note, heading: "Its producer's note"]
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the scene below into the use cases that build it, and design each: a use case is software design. The repository you are given, a Git checkout of develop, is what they build on; the decisions to read first, after the scene, are its architecture. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Before you propose anything that stores, syncs, schedules or queries data, ask rela what it offers and use that (D-0100): Atlas builds nothing beside rela, and what rela lacks is a request to the rela project, not a workaround in Atlas. Ask the pinned rela itself (docs/guides/rela.md): rela --help, rela <command> --help, or its MCP server, rela mcp. Each use case is one behaviour of the system that its actor sees, small enough to break into a few issues, in the order given; its description states that behaviour: who does what, and what they see then. Its design says how it is built within the existing architecture: which parts of the system change and how, what is new, the data and the flow through it, and how to tell it works. Never change the architecture: when a use case would need a new architecture choice, say so in its note instead of deciding it. When the scene has a note from its producer, it was built and not accepted: propose only the use cases still missing for what the note asks; those under it stay. When the scene is too vague to design use cases from, do not guess: write your questions to questions.md and nothing else; its producer answers them, or rewrites the scene, and you are asked again. When the scene has questions and its producer's answers, they were asked and answered before: design from the current description and the answers.",
        fields: [:title, :description, :note, :questions, :answers],
        read_first: true,
        creates: [kind: :use_case, file: "use_cases.json", fields: [:design, :note]],
        asks: [field: :questions, file: "questions.md"],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :accepting,
          check_failed: :accepting,
          stuck: :accepting,
          abandoned: :accepting,
          asked: :clarifying
        ]
      )
    end

    # Its agent could not design use cases from it without guessing, and asked: its
    # producer answers, or rewrites the scene by hand first, and Design continues with a
    # fresh pass of its agent, on the same supervisor's Runtimes.
    state :clarifying, label: "Answer its questions" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Answer its questions",
        why: "its agent cannot design use cases from it without guessing",
        instructions:
          "Read its agent's questions below, and the scene's description. Answer them in your note; you may first rewrite the description by hand, and say so. Answered gives it back to Design: a fresh pass of its agent reads the questions, your answers and the current description.",
        section: [field: :questions, label: "Its agent's questions"],
        answers: [
          [
            key: "a",
            label: "Answered",
            note: true,
            change: %{values: %{verdict: :answered, answers: "$note"}}
          ]
        ]
      )

      branch(to: :break_down, when: "entity.verdict == 'answered'")
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

    # Nothing is built on the scene itself, and nobody has anything to do on it: it is its
    # producer's, as Accept is next, and it gives no to-do (no instructions, no answers).
    state :building, label: "Waiting for its use cases" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})

      present(
        expected: "Waiting for its use cases",
        why: "not all of its use cases are accepted"
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

  # Accept: while its use cases are not all accepted, the scene waits with its producer,
  # with no to-do; it said Build it, assigned to the coordinator. Every run stays where it is.
  migrate(:accept_scene,
    from: "0b7d903c06f4bfcc82b632475f3274cb32542868402a7e8959ea5407affe0d10",
    to: "6665318f148389f993ac80245461a63666bfa50507b6071a2ab3db4e6563b77e",
    states: :same,
    reason: "Accept: a scene waiting for its use cases is its producer's, with nothing to do"
  )

  # Design: its agent asks rela what it offers before it proposes anything that stores,
  # syncs, schedules or queries data (D-0100); nothing else changed.
  migrate(:break_down_scene,
    from: "54483a0d6c36f6d302c5aa85ae64deb5380952192a752dfebd1d55c9f794d4ec",
    to: "f52ee753f148fefc1ae12ce899968a99b9e2cf7671950223340de423aa356ae6",
    states: :same,
    preserve_entry: true,
    reason: "Design: its agent asks rela first (D-0100)"
  )

  # Design: its presentation says its supervisor's pickup starts the work (IS-Atlas-25), no
  # longer that it waits for a machinery; texts only, so a run keeps its state and entry.
  migrate(:break_down_scene,
    from: "f52ee753f148fefc1ae12ce899968a99b9e2cf7671950223340de423aa356ae6",
    to: "1fa161740e21d0c8055aafd3a24ef417993671d1057e14762aa4064aad1249c0",
    preserve_entry: true,
    states: :same,
    reason: "Design: its supervisor's pickup starts the work; texts only"
  )

  # Design: when the scene is too vague to design use cases from, its agent asks instead of
  # guessing, and its producer answers (`clarifying`, UC-Atlas-24). A new state, and two
  # fields its agent reads; every run stays where it is.
  migrate(:break_down_scene,
    from: "1fa161740e21d0c8055aafd3a24ef417993671d1057e14762aa4064aad1249c0",
    to: "d24a5161505bc0d53dd50b52437996c2b537d2fbed7b081437551120d78d1e15",
    states: :same,
    reason: "Design: its agent asks its producer instead of guessing (UC-Atlas-24)"
  )
end
