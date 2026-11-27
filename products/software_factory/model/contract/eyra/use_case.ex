defmodule Model.UseCase do
  @moduledoc """
  A use case is software design: the technical contract for part of a scene, proposed
  with its Design part by the scene's break-down (Design: Scene → Use cases). Its two flows:

    * `break_down_use_case` **Plan** (Use case → Issues): a person picks it up (its span, the whole
      flow), and that pickup alone starts its work: one agent on the supervisor's Runtime reads the
      use case (its description and Design part), its scene and a checkout of the
      repository, and writes the issues it proposes to a file in its result (`creates:`).
      Flow, the only writer, makes them under the use case, numbered in the order proposed
      (`order`: they are built in that order), and "Accept it" (`accepting`) goes to the
      supervisor, who changes or removes any by hand (the use case's page offers no Create
      of an issue, which Plan makes) and accepts the break-down. Its run ends there and
      hands the use case on (`phase: accept`). "Not accepted", with a note
      (`supervisor_note`), throws the proposal away: Flow deletes the issues it made (those
      added by hand stay; `creates: [discard: true]`) and the run goes back to its
      break-down, whose agent reads the note.
      A use case too vague to break down is not guessed at (UC-Atlas-24): its agent writes
      its questions instead (`asks:`), Flow puts them in the use case's `questions`, and
      "Answer its questions" (`clarifying`) goes to its producer: the person who
      supervised the Design run that made it (`produced_by`), or who made it by hand (the
      person at the TUI, or whom the agent that creates it assists; `create(producer:)`,
      UC-Atlas-23), or the configured decider for one from before producers were
      recorded. They
      may rewrite the use case and answer with a note (`answers`); a fresh pass of its
      agent then reads the questions, the answers and the use case as they are now. The
      run keeps its supervisor.
    * `accept_use_case` "Accept the use case": accepts it by itself once all its issues
      are done (`children`, `open_children`: the composition's count of its issues, and of
      those whose `issue` run did not end `done`: reviewed and merged, or closed with
      nothing to merge). Accepted, it writes `phase: accepted`, which completes the use
      case. With no issue under it, it hands the use case back to a new round of its
      break-down (`phase: break_down`) and waits for it (`breaking_down`). A use case
      accepted by hand (`phase: accepted`) ends its run in `accepted` from any open state,
      as this run's own acceptance does, and its scene counts it accepted.

  `phase` says which of the two has a use case (disjoint admissions). A new one starts in
  `break_down`. One from before (no `phase`, among them those whose design flow, now
  gone, had not ended) is the acceptance's, which imports it: with issues under it, it
  builds on; with none, it goes to Plan, whose agent breaks it down from
  its description (and its Design part when it has one).
  """
  use RelaDSL

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
    icon(:route)
    field(:title, :string, required: true, description: "Without the code (Flux: name)")
    field(:description, :string, description: "The text (Flux: description)", multiline: true)

    field(:flux_id, :string,
      unique: true,
      description: "Flux (Basecamp) id, set by a later Flux sync",
      set_by: :connector
    )

    field(:status, :plan_status, description: "Flux group; empty = no group", label: "Flux group")

    field(:design, :string,
      description:
        "The Design part: how it is built, proposed with it by its scene's break-down and accepted by its supervisor",
      multiline: true,
      label: "Design"
    )

    field(:note, :string,
      description:
        "Its proposer's note: an architecture choice it needs that is not decided, said instead of decided",
      multiline: true,
      label: "Proposer's note"
    )

    field(:supervisor_note, :string,
      description:
        "Its supervisor's note when Plan's proposal was not accepted; Plan's next round reads it",
      multiline: true,
      label: "Supervisor's note"
    )

    field(:questions, :string,
      description:
        "Flow: what Plan's agent asked its producer, because it was too vague to break down into issues",
      multiline: true,
      set_by: [:flow],
      label: "Its agent's questions"
    )

    field(:answers, :string,
      description: "Its producer's answers to its agent's questions; Plan's next pass reads them",
      multiline: true,
      label: "Its producer's answers"
    )

    field(:phase, :pipeline_phase,
      description: "Flow: which flow of its pipeline has it (break down, accept, accepted)",
      label: "Phase"
    )

    field(:children, :integer, description: "Flow: how many issues are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")

    field(:verdict, :string,
      description:
        "Flow: the acceptor's verdict (none, accept, reject), its supervisor's acceptance of its issues (accept), or its producer's answer to its agent's questions (answered)"
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

    field(:gate_result, :string,
      description:
        "Flow: the last design gate verdict, or a maintainer's choice (none, review, rework, ready, person, close)"
    )

    # One made by hand records who made it, as a scene does (UC-Atlas-23); Design's are
    # Flow's, for the run's supervisor.
    create(
      ask: [:title, :description],
      defaults: [status: :refine, phase: :break_down],
      producer: :produced_by
    )

    progress(over: :in_use_case, field: :stage, own: :status)
    completion(field: :phase, value: :accepted)

    # Accept its issues, as a panel: Plan's proposal, the issues it made in the order they
    # are built, each with what it does, when it is done and the ones before it.
    panel(
      accepting: [
        heading: "TO ACCEPT",
        title: "Plan for {key} · {title}",
        records: [proposal: [relation: :task_of, where: [kind: :plan]]],
        byline: ["Proposed by {proposal}", [age: ""], "built in this order"],
        items: [
          relation: :in_use_case,
          order: :order,
          count: ["issue", "issues"],
          details: [
            [label: "What", field: :description, before: "Done when:"],
            [label: "Done", field: :description, after: "Done when:"],
            [label: "Needs", earlier: true]
          ]
        ],
        actions: [[key: "i", label: "Full proposal", record: :proposal]]
      ]
    )
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

  # Plan: Use case → Issues.
  subflow :break_down_use_case, label: "Plan", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'break_down'")
    initial(:break_down)
    supervise(:break_down, label: "Plan", states: [:break_down, :accepting, :clarifying])

    state :break_down, label: "Break it down" do
      present(
        expected: "Break it down into issues",
        why: "nothing is under it yet",
        instructions:
          "Its supervisor's Runtime runs one agent on it that proposes its issues; Flow makes them under it. Its supervisor's pickup starts the work: nothing is done until then.",
        section: [field: :supervisor_note, label: "Its supervisor's note"]
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the use case below into the issues that build it: its description is the behaviour, its Design part (when it has one) how it is built. Its scene, after it, says why it is to be done; the repository you are given, a Git checkout of develop, is what it builds on. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Before you propose anything that stores, syncs, schedules or queries data, ask rela what it offers and use that (D-0100): Atlas builds nothing beside rela, and what rela lacks is a request to the rela project, not a workaround in Atlas. Ask the pinned rela itself (docs/guides/rela.md): rela --help, rela <command> --help, or its MCP server, rela mcp. Each issue is a vertical slice: it works end to end and can be shown working. The first is the thinnest happy path (a walking skeleton); each later one builds on the ones before it, in the order given. Propose as few issues as possible: split a slice further only when it is too big for one reviewable pull request, what one agent builds and reviews in one go. Never split by layer (model, contract, Control, client): each issue cuts through all the layers it needs. When its scene names its phase, respect it: in Explore, usually only the happy-path slice; edge cases come later as follow-ups. The issues already under the use case, if any, are listed after its scene under \"Already under it\": they stay, so propose only the issues that are missing, never one of those again. When it has a note from its supervisor, your earlier proposal was not accepted and is gone: propose again, as the note asks. When the use case is too vague to break down into issues, do not guess: write your questions to questions.md and nothing else; its producer answers them, or rewrites the use case, and you get it again. When the use case has questions and answers, they are what you asked before and what its producer answered; its description and Design part are as its producer left them.",
        fields: [:title, :description, :design, :questions, :answers],
        parents: [:title, :description],
        children: [:title, :description],
        note: [field: :supervisor_note, heading: "Its supervisor's note"],
        creates: [kind: :issue, file: "issues.json", order: :order, discard: true],
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

    # Its agent found it too vague to break down and asked (UC-Atlas-24): its producer, the
    # person who supervised the Design run that made it (`produced_by`), answers, after
    # rewriting it by hand if they like; a fresh pass of its agent then reads the
    # questions, the answers and the use case. A use case that records no producer (made
    # by hand, or before producers were recorded) asks the configured decider. The run
    # keeps its supervisor, though this state is its producer's, never the supervisor's.
    state :clarifying, label: "Answer its questions" do
      owner(
        via: :assignment,
        relation: :assigned_to,
        default: {:person, config: :decider, producer: :produced_by}
      )

      set(verdict: :none)

      present(
        expected: "Answer its questions",
        why: "its agent cannot break it down into issues yet",
        instructions:
          "Its agent found the use case too vague to break down into issues, and asks you the questions below. Read them with its description and Design part; rewrite those by hand if that answers them, then answer, with a note of your answers. A fresh pass of its agent reads the questions, your answers and the use case as it is then.",
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

    # Its supervisor looks at the issues Flow made from the agent's proposal, changes,
    # removes or adds any by hand, and accepts the break-down; or sends it back with a note:
    # Flow deletes the issues the proposal made (those added by hand stay), and its agent
    # proposes again, reading the note.
    state :accepting, label: "Accept it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept its issues",
        why: "its agent's break-down is done",
        instructions:
          "Read the issues under it, which its agent proposed; change any, or remove one (Remove, on its page), then accept them. They can then be picked up and built. Or say why not: the issues its agent proposed are removed, and it proposes again with your note; issues you added stay.",
        answers: [
          [key: "a", label: "Accept", change: %{values: %{verdict: :accept}}],
          [
            key: "n",
            label: "Not accepted",
            note: true,
            change: %{values: %{verdict: :reject, supervisor_note: "$note"}}
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

  subflow :accept_use_case, label: "Accept the use case", subject: :use_case do
    run_as("system:sf-flow")
    owner(via: :assignment, relation: :assigned_to, default: {:agent, :coordinator})
    start(:predicate, when: "entity.phase == 'accept'")
    initial(:building)

    state :building, label: "Build it" do
      present(
        expected: "Build it",
        why: "not all under it is done",
        instructions:
          "Its issues are built, reviewed and merged; Flow accepts it once all of them are done."
      )

      branch(to: :breaking_down, by: :atlas, when: "entity.children == 0")

      branch(to: :accepted, by: :atlas, when: "entity.children > 0 and entity.open_children == 0")
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

    final :accepted, label: "Accepted" do
      set(phase: :accepted)
    end
  end

  @projection [
    on: :assignment,
    state_field: :flow_state,
    handover_field: :handover,
    owner_relation: :assigned_to,
    field: :expected
  ]

  # Each round of a use case's break-down is a new generation of its run: started when the
  # use case is handed to it (`phase` becomes `break_down`), never on its own.
  select(:break_down_use_case,
    choices: [],
    projection: @projection,
    admission: [phase: [:break_down]],
    imports: [],
    reopen: :new_generation,
    restart_by: [:owner, :decider]
  )

  # A use case from before (no `phase`) is the acceptance's: a completed one is completed
  # history, any other joins `building`, whose count hands one with nothing under it to
  # "Use case → Issues". So do the 32 whose design flow (removed, D-0099) had not ended:
  # their runs are no longer selected.
  # A use case completed meanwhile (`completed`), its `phase: accepted` written by hand as
  # this run would: its run goes to `accepted` from any open state, as if it had accepted
  # it, so its scene counts it accepted (Flows are not magical).
  select(:accept_use_case,
    choices: [],
    projection: @projection,
    admission: [phase: [:accept, :accepted, nil]],
    imports: [
      [completed: true, state: :accepted],
      [when: [phase: [nil]], state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider],
    completed: :accepted
  )
end
