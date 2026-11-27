defmodule Model.Scene do
  @moduledoc """
  A scene, and its two flows: the start and the end of the scene pipeline (`pipeline
  :scene` in `Model.AtlasEyra`). A person supervises a flow, never a step (D-0099): each
  pickup point is a subflow of its own; the pipeline is horseshoe-shaped: it starts with
  the scene, its producer's input, and ends with its producer's acceptance.

  A scene records who put it in (`produced_by`, SC-Atlas-09, IS-Atlas-70), in the write
  that creates it (`create(producer: :produced_by)`): the person who creates it (in the
  TUI), or the person an agent that creates it assists (`assists` in the environment's
  settings). Control takes it from who the client is, never from the form; Facts takes
  the link on that create only, and from nobody else after.

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
      A scene too vague to design use cases from is not guessed at (UC-Atlas-24): its agent
      writes its questions instead (`asks:`), Flow puts them in the scene's `questions`,
      and "Answer its questions" (`clarifying`) goes to its producer (`produced_by`; the
      configured decider for a scene that records none, one from before producers were
      recorded), who may rewrite the description and
      answers with a note (`answers`); a fresh pass of its agent then reads the questions,
      the answers and the description as they are now. The run keeps its supervisor.
      Its supervisor's "Not accepted", with a note (the scene's `note`), throws the proposal
      away: Flow deletes the use cases it made (those added by hand stay; `creates:
      [discard: true]`) and the run goes back to its break-down, whose agent reads the note.
    * `accept_scene` **Accept** (Accept the scene): waits until every use case under it is accepted
      (`children`, `open_children`: the composition's count of the use cases in the scene,
      and of those without an accepted `accept_use_case` run), then asks its producer
      (`produced_by`: who put it in; the configured decider for a scene that records none). While it waits
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
    icon(:frame)
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
        "Flow: what its break-down's agent asked its producer, because it was too vague to design use cases from",
      multiline: true,
      set_by: [:flow],
      label: "Its agent's questions"
    )

    field(:answers, :string,
      description:
        "Its producer's answers to its agent's questions; its next break-down reads them",
      multiline: true,
      label: "Its producer's answers"
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

    # Who puts it in is its producer, linked in the create itself (IS-Atlas-70).
    create(
      ask: [:title, :description],
      defaults: [status: :refine, phase: :break_down],
      producer: :produced_by
    )

    progress(over: :in_scene, own: :status)
    completion(by: :accepted_by)

    # Accept its use cases, as a panel: Design's proposal, the use cases it made, each
    # with what it does and when it is done.
    panel(
      accepting: [
        heading: "TO ACCEPT",
        title: "Design for {key} · {title}",
        records: [proposal: [relation: :task_of, where: [kind: :plan]]],
        byline: ["Proposed by {proposal}", [age: ""]],
        items: [
          relation: :in_scene,
          count: ["use case", "use cases"],
          details: [
            [label: "What", field: :description, before: "Done when:"],
            [label: "Done", field: :description, after: "Done when:"]
          ]
        ],
        actions: [
          [
            key: "i",
            label: "Full proposal",
            help: "Open the agent's full proposal for this break-down",
            record: :proposal
          ]
        ]
      ]
    )

    page(
      state: [:phase, :status],
      intro: [field: :description],
      sections: [:questions, :answers, :note],
      items: [
        relation: :in_scene,
        empty: [
          pick_up: "Once someone picks up its Design, its agent proposes the use cases here.",
          break_down:
            "Design's agent is working out the use cases; they show here once it proposes them.",
          clarifying:
            "Design's agent asked its producer questions first; once they are answered, it proposes the use cases.",
          accepting: "Design proposed no use cases: decline it with a note to try again.",
          building: "Design starts again to propose its use cases."
        ]
      ]
    )
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
    supervise(:break_down, label: "Design", states: [:break_down, :accepting, :clarifying])

    state :break_down, label: "Break it down" do
      present(
        expected: "Break it down into use cases",
        why: "it is to be broken down",
        instructions:
          "Its supervisor's Runtime runs one agent on it that proposes its use cases; Flow makes them under it. Its supervisor's pickup starts the work: nothing is done until then.",
        section: [field: :note, label: "Its producer's or supervisor's note"]
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the scene below into the use cases that build it, and design each: a use case is software design. The repository you are given, a Git checkout of develop, is what they build on; the decisions to read first, after the scene, are its architecture. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Before you propose anything that stores, syncs, schedules or queries data, ask rela what it offers and use that (D-0100): Atlas builds nothing beside rela, and what rela lacks is a request to the rela project, not a workaround in Atlas. Ask the pinned rela itself (docs/guides/rela.md): rela --help, rela <command> --help, or its MCP server, rela mcp. Each use case is one behaviour of the system that its actor sees, small enough to break into a few issues, in the order given; its description states that behaviour: who does what, and what they see then. Its design says how it is built within the existing architecture: which parts of the system change and how, what is new, the data and the flow through it, and how to tell it works. Never change the architecture: when a use case would need a new architecture choice, say so in its note instead of deciding it. The use cases already under the scene, if any, are listed after it under \"Already under it\": they stay, so propose only the use cases that are missing, never one of those again. When the scene has a note, it was sent back: by its producer, once built and not accepted, or by its supervisor, who did not accept your earlier proposal, which is gone. Propose only the use cases still missing for what the note asks. When the scene is too vague to design use cases from, do not guess: write your questions to questions.md and nothing else; its producer answers them, or rewrites the scene, and you get it again. When the scene has questions and answers, they are what you asked before and what its producer answered; its description is as its producer left it.",
        fields: [:title, :description, :questions, :answers],
        children: [:title, :description],
        read_first: true,
        note: [field: :note, heading: "Its producer's or supervisor's note"],
        creates: [
          kind: :use_case,
          file: "use_cases.json",
          fields: [:design, :note],
          discard: true
        ],
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

    # Its agent found it too vague to design use cases from and asked (UC-Atlas-24): its
    # producer (`produced_by`, who put it in; the configured decider for a scene that
    # records none, from before producers were recorded) answers, after rewriting its description by hand if they like; a
    # fresh pass of its agent then reads the questions, the answers and the description.
    # The run keeps its supervisor. Its producer, not its supervisor, though it lies in the span.
    state :clarifying, label: "Answer its questions" do
      owner(
        via: :assignment,
        relation: :assigned_to,
        default: {:person, config: :decider, producer: :produced_by}
      )

      set(verdict: :none)

      present(
        expected: "Answer its questions",
        why: "its agent cannot design use cases from it yet",
        instructions:
          "Its agent found the scene too vague to design use cases from, and asks you the questions below. Read them with its description; rewrite the description by hand if that answers them, then answer, with a note of your answers. A fresh pass of its agent reads the questions, your answers and the description as it is then.",
        section: [field: :questions, label: "Its agent's questions"],
        answers: [
          [
            key: "a",
            label: "Answered",
            help:
              "Say you answered its questions, with a note of your answers: its agent tries again",
            note: true,
            change: %{values: %{verdict: :answered, answers: "$note"}}
          ]
        ]
      )

      branch(to: :break_down, when: "entity.verdict == 'answered'")
    end

    # Its supervisor looks at the use cases Flow made from the agent's proposal, changes,
    # removes or adds any by hand, and accepts the break-down; or sends it back with a note
    # (the scene's `note`): Flow deletes the use cases the proposal made (those added by
    # hand stay), and its agent proposes again, reading the note.
    state :accepting, label: "Accept it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept its use cases",
        why: "its agent's break-down is done",
        instructions:
          "Read the use cases under it, which its agent proposed; change, delete or add any, then accept them. They can then be designed, broken down and built. Or say why not: the use cases its agent proposed are removed, and it proposes again with your note; use cases you added stay.",
        answers: [
          [
            key: "a",
            label: "Accept",
            help: "Accept its use cases: they can be designed, broken down and built",
            change: %{values: %{verdict: :accept}}
          ],
          [
            key: "n",
            label: "Not accepted",
            help: "Say why not: its agent's use cases are removed and it proposes again",
            note: true,
            change: %{values: %{verdict: :reject, note: "$note"}}
          ]
        ]
      )

      branch(to: :broken_down, when: "entity.verdict == 'accept'")
      branch(to: :break_down, when: "entity.verdict == 'reject'")
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

    # Nothing is built on the scene itself, and nobody has anything to do on it: it is
    # assigned to nobody (no default, so Flow removes the owner it gave), and it gives no
    # to-do (no instructions, no answers). Its producer gets it once Accept is next.
    state :building, label: "Waiting for use cases" do
      owner(via: :assignment, relation: :assigned_to)

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

    # Its producer accepts it: who put it in (`produced_by`). A scene that records none,
    # from before producers were recorded, asks the configured decider (IS-Atlas-164).
    state :to_accept, label: "Accept" do
      owner(
        via: :assignment,
        relation: :assigned_to,
        default: {:person, config: :decider, producer: :produced_by}
      )

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
            help: "Accept the scene as done, after trying it",
            change: %{self: :accepted_by, values: %{verdict: :accept}}
          ],
          [
            key: "n",
            label: "Not accepted",
            help: "Say why not: its break-down proposes what is missing",
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
end
