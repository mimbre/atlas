defmodule Model.UseCase do
  @moduledoc """
  A use case is software design: the technical contract for part of a scene, proposed
  with its Design part by the scene's break-down (Design: Scene → Use cases). Its two flows:

    * `break_down_use_case` **Plan** (Use case → Issues): a person picks it up (its span, the whole
      flow) and hands it to a machinery: one agent on the supervisor's Runtime reads the
      use case (its description and Design part), its scene and a checkout of the
      repository, and writes the issues it proposes to a file in its result (`creates:`).
      Flow, the only writer, makes them under the use case, and "Accept it" (`accepting`)
      goes to the supervisor, who changes or removes any by hand (the use case's page
      offers no Create of an issue, which Plan makes) and accepts the break-down. Its run
      ends there and hands the use case on (`phase: accept`).
    * `accept_use_case` "Accept the use case": accepts it by itself once all its issues
      are done (`children`, `open_children`: the composition's count of its issues, and of
      those whose `issue` run did not end `done`: reviewed and merged, or closed with
      nothing to merge). Accepted, it writes `phase: accepted`, which completes the use
      case. With no issue under it, it hands the use case back to a new round of its
      break-down (`phase: break_down`) and waits for it (`breaking_down`).

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

    field(:phase, :pipeline_phase,
      description: "Flow: which flow of its pipeline has it (break down, accept, accepted)",
      label: "Phase"
    )

    field(:children, :integer, description: "Flow: how many issues are in it")
    field(:open_children, :integer, description: "Flow: how many of them are not finished")

    field(:verdict, :string,
      description:
        "Flow: the acceptor's verdict (none, accept, reject), or its supervisor's acceptance of its issues (accept)"
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

    field(:gate_result, :string,
      description:
        "Flow: the last design gate verdict, or a maintainer's choice (none, review, rework, ready, person, close)"
    )

    create(ask: [:title, :description], defaults: [status: :refine, phase: :break_down])
    progress(over: :in_use_case, field: :stage, own: :status)
    completion(field: :phase, value: :accepted)
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
    supervise(:break_down, label: "Plan", states: [:break_down, :accepting])

    state :break_down, label: "Break it down into issues" do
      present(
        expected: "Break it down into issues",
        why: "nothing is under it yet",
        instructions:
          "Its machinery runs one agent on it that proposes its issues; Flow makes them under it. Nothing is done while it is not assigned to a machinery."
      )

      task(:plan,
        role: :architect,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Break the use case below into the issues that build it: its description is the behaviour, its Design part (when it has one) how it is built. Its scene, after it, says why it is to be done; the repository you are given, a Git checkout of develop, is what it builds on. Read what you need, and change none of its files: your only output is your proposal, as asked at the end. Each issue is a vertical slice: it works end to end and can be shown working. The first is the thinnest happy path (a walking skeleton); each later one builds on the ones before it, in the order given. Propose as few issues as possible: split a slice further only when it is too big for one reviewable pull request, what one agent builds and reviews in one go. Never split by layer (model, contract, Control, client): each issue cuts through all the layers it needs. When its scene names its phase, respect it: in Explore, usually only the happy-path slice; edge cases come later as follow-ups.",
        fields: [:title, :description, :design],
        parents: [:title, :description],
        creates: [kind: :issue, file: "issues.json"],
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

    # Its supervisor looks at the issues Flow made from the agent's proposal, changes,
    # removes or adds any by hand, and accepts the break-down.
    state :accepting, label: "Accept it" do
      owner(via: :assignment, relation: :assigned_to, default: {:person, config: :decider})
      set(verdict: :none)

      present(
        expected: "Accept its issues",
        why: "its agent's break-down is done",
        instructions:
          "Read the issues under it, which its agent proposed; change any, or remove one (Remove, under More… on its page), then accept them. They can then be picked up and built.",
        answers: [[key: "a", label: "Accept", change: %{values: %{verdict: :accept}}]]
      )

      branch(to: :broken_down, when: "entity.verdict == 'accept'")
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
  select(:accept_use_case,
    choices: [],
    projection: @projection,
    admission: [phase: [:accept, :accepted, nil]],
    imports: [
      [completed: true, state: :accepted],
      [when: [phase: [nil]], state: :building]
    ],
    reopen: :explicit,
    restart_by: [:owner, :decider]
  )

  # "Accept the use case": it is accepted by itself once all its issues are done; its test
  # and rework by hand are gone. A run that waited for them builds again, and its count
  # moves it on.
  migrate(:accept_use_case,
    from: "151dd750a7eaf0d154c02949d366125d1b30c84c546353c20c3f73b17e1bd578",
    to: "80bad80a42f6b5651f0c5a122fe566de2d6b6af26c344a73ebf30fc131c021ad",
    states: [
      accepted: :accepted,
      breaking_down: :breaking_down,
      building: :building,
      rework: :building,
      to_test: :building
    ],
    reason: "Accept the use case: accepted by itself once all its issues are done"
  )

  # "Use case → Issues": its agent reads the use case's Design part too; a run waiting for
  # its pickup or its supervisor stays where it is.
  migrate(:break_down_use_case,
    from: "d9aebb44c50face4331b072e2f04d14cb556715659784a89fd1366b6a03253d7",
    to: "c373a592ce886b9c8c6cd064df421963f45eebd8ed580d6e58a4f6a020f90e33",
    states: :same,
    reason: "Use case → Issues: its agent reads the use case's Design part"
  )

  # Plan: its label was its signature, Use case → Issues; nothing else changed.
  migrate(:break_down_use_case,
    from: "c373a592ce886b9c8c6cd064df421963f45eebd8ed580d6e58a4f6a020f90e33",
    to: "d082e4d18dd39507a3b42b25a6fd69f4482787230fa18787dd2f2e892f5c21c5",
    states: :same,
    reason: "Plan: renamed from Use case → Issues"
  )

  # Plan: its agent proposes vertical slices, the thinnest happy path first; nothing else changed.
  migrate(:break_down_use_case,
    from: "d082e4d18dd39507a3b42b25a6fd69f4482787230fa18787dd2f2e892f5c21c5",
    to: "258a95da4ce00a62fa8bd1dc4579f11a560b782d971db95599be685c7bba0670",
    states: :same,
    reason: "Plan: its agent proposes vertical slices"
  )

  # Plan: "Accept it" says what the page offers (change, Remove), not delete or add; nothing
  # else changed.
  migrate(:break_down_use_case,
    from: "258a95da4ce00a62fa8bd1dc4579f11a560b782d971db95599be685c7bba0670",
    to: "1588812d8dd96692394964d26fadf06178baee0e5be9307c0f9e2a286c4926f8",
    states: :same,
    reason: "Plan: its accept step says what its page offers"
  )
end
