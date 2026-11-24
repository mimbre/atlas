defmodule Model.Package do
  @moduledoc """
  A bounded part of an issue that becomes one pull request (the Flow Engine plan, §3.1
  and §3.2). It comes from an Architect's plan or is made by hand; Flow names it
  `PK-<issue>-<n>`. It is a child of its issue (`package_of`), and its tasks belong to it
  (`task_of`, in the composition). `published_revision` and `published_fingerprint` come
  with F3. Flow writes every field (`set_by: [:flow]`) but `answer`, which the package's
  supervisor sets.

  It is not a pull request: `in_issue` stays the pull request's relation alone, whose
  limit and the issue's completion read a pull request's `state`.

  Its subflow, `package`, authors it (the plan's §6 F1.4), and reviews and fixes it as
  `AtlasFlow.Ladder` says (F2; F2/F3 plan rev 3 §3.1, §3.3, Main's B-3):

    * `waiting` holds a package until it has its `instructions`, which its author task
      carries; one that has them goes on to `authoring` at once. It presents nothing:
      only Flow writes a package. The packages it waits for (`after`) are not read yet:
      that ordering comes with F4.
    * Every task is a step of the review → fix loop (`ladder: true`), in a state of its
      own: `authoring` (the first author: role developer, profile `deep_coding`, on a base
      of the repository's `develop`, with `bin/check` after the work), `reviewing` (an
      independent review of the latest result, read-only), `fixing` (a fix of the
      reviewed result, with `bin/check`), `diagnosing` (an investigator, read-only),
      `fresh` (a new author on the original base) and `stronger` (one on
      `deep_coding_max`). Its end leads where the ladder's next step says. Its record is
      a `task` linked `task_of` the package. Its supervisor's pickup (of its issue) starts
      it; without a supervisor, it runs only while the package's Assignment is with a
      machinery (E1). It is offered to a Runtime of its issue's human supervisor (the
      issue's span `build`, whose `with:` names this subflow), through Flow's work source.
    * Every task state presents, so the move into each is what is presented; its owner is
      the subflow's, which keeps a person or a machinery someone linked
      (`preserve_kind`), so the machinery stays while the loop runs.
    * `ready`: approved; nothing is expected of anyone until F3 publishes and merges it.
      It is not final; its supervisor may abandon it (`answer: abandon`).
    * `held` (a crash, a refusal, the re-review bound, an abandoned task) and
      `awaiting_decision` (rung (e)) wait for the supervisor. Each has its own owner, the
      configured decider (so the issue's supervisor while the issue is in its span),
      without `preserve_kind`: entering it moves the package from the machinery to the
      supervisor. They set `answer` (one of the question's answers: `fresh`, `stronger`,
      `abandon`, `retry` or a worded option); the answer alone moves it on, on its supervisor's
      Runtime: no hand-back to a machinery.
      `fresh`, and a worded option (a label on the `fresh` branch), go to `fresh`;
      `stronger` to `stronger`; `abandon` to `stuck`; `retry` (held after an abandoned
      task) to the state of the step the held task runs again as, which Flow writes in
      `retry_step`. Flow writes the `question` they answer when it asks.
      At rung (e), when the recommended option is safe to continue on and touches no
      authority, the package does not wait: it goes to `fresh` on that option with its
      machinery, and the supervisor is only asked (`question`); an answer while that work
      runs is followed at once (the running task is cancelled), `abandon` to `stuck`.
      Entering either state resets
      `answer` to `none`, so an earlier answer moves nothing. Flow writes no `decision` (B-4: `follow_through` is not involved).
    * `stuck`: abandoned. A person who takes a stuck package back restarts it or does it
      by hand. A run that ended `authored` or `check_failed` before the loop (F1.4) is
      `stuck` now (the migration below).

  Where the work starts is a base, never a path on the machinery's machine (the
  Runtime's D44): `input` names the Code repository (`github.com/mimbre/atlas`, as Code's
  settings name it) and the reference (`develop`) Flow resolves the base from in Code. No
  URL, and nothing of it but the resolved base reaches the Runtime.
  """
  use RelaDSL

  entity :package,
    label: "Package",
    plural: "packages",
    id_type: :manual,
    id_prefix: "PK-",
    description: """
    A bounded part of an issue that becomes one pull request: from an Architect's plan
    or made by hand. Flow names it PK-<issue>-<n>.
    """ do
    field(:title, :string, required: true, description: "What it builds", set_by: [:flow])

    field(:instructions, :string,
      description: "What its author is to do",
      set_by: [:flow],
      multiline: true
    )

    field(:acceptance, :string,
      description: "When it is done",
      set_by: [:flow],
      multiline: true
    )

    field(:after, :string,
      description: "The keys of the packages it waits for, integrated first",
      set_by: [:flow]
    )

    field(:state, :string, description: "The state of its run, as Flow keeps it", set_by: [:flow])

    # What its subflow's task branches read (Rela checks them against the kind): the
    # run's own result, which Flow never writes on the package.
    field(:task_result, :string,
      description:
        "Flow: how its author task ended (completed, check_failed, stuck, abandoned); the run's own, never written",
      set_by: [:flow],
      label: "Task result"
    )

    # The review → fix loop (F2): what its supervisor is asked, and their answer. Where the
    # loop stands (its rung, its authors) is the run's own (`pending.ladder`), never written
    # on the package.
    field(:question, :string,
      description: "Flow: what its supervisor is asked while it is held or awaits a decision",
      set_by: [:flow],
      multiline: true
    )

    field(:retry_step, :string,
      description:
        "Flow: the step the answer retry goes back to (the held task's), or none when retry is not offered",
      set_by: [:flow]
    )

    field(:answer, :string,
      description:
        "Its supervisor's answer while it is held or awaits a decision: fresh, stronger, abandon, retry or a worded option"
    )

    top(false)
    by_hand(false)
    primary(:title)
  end

  relation(:package_of,
    label: "package of",
    description: "A package belongs to one issue; an issue has its packages.",
    from: [:package],
    to: [:issue],
    max_outgoing: 1,
    inverse: {:packages, "packages"},
    parent: true,
    set_by: [:flow]
  )

  @author_instructions """
  Build the package below in the repository you are given, starting from its base. \
  Keep to the worker rules: the boundary greps that CI runs must stay clean (bin/check \
  runs them, and runs after you), and do no web search. Run the tests of every system \
  you change. End your answer with what you changed, the tests you ran with their \
  results, and what is left open.\
  """

  @review_instructions """
  Review the change set you are given against the package below, on its base, without \
  changing anything. Judge whether it does what the package asks and keeps to the worker \
  rules. End your answer with your verdict block.\
  """

  @fix_instructions """
  Fix the change set you are given, on its base, as the findings below ask; keep what is \
  right. Keep to the worker rules: the boundary greps that CI runs must stay clean \
  (bin/check runs them, and runs after you), and do no web search. Run the tests of every \
  system you change. End your answer with what you changed, the tests you ran with their \
  results, and what is left open.\
  """

  @diagnose_instructions """
  Find out why the work on the package below keeps failing, from the change set you are \
  given and its history below, without changing anything. End your answer with your \
  diagnosis block.\
  """

  # Where each step of the review → fix loop (`AtlasFlow.Ladder`) leads.
  @steps [
    author: :authoring,
    review: :reviewing,
    fix: :fixing,
    diagnose: :diagnosing,
    fresh: :fresh,
    stronger: :stronger,
    ready: :ready,
    held: :held,
    escalate: :awaiting_decision,
    # Main's D1 ruling: abandoned while its task ran on the recommended default.
    abandon: :stuck
  ]

  @fields [:title, :instructions, :acceptance]
  @records [kind: "task", relation: "task_of"]
  @input [repository: "github.com/mimbre/atlas", base: "develop"]

  # A worded option (Main's D3) is a label on the `fresh` branch: any answer but the empty
  # one, `none` (what entering the state resets it to), `stronger`, `abandon` and `retry`
  # (the pinned rela has no `!=`; an absent field is no match).
  @fresh "not (entity.answer == '') and not (entity.answer == 'none') and not (entity.answer == 'stronger') and not (entity.answer == 'abandon') and not (entity.answer == 'retry')"

  subflow :package, label: "Package", subject: :package do
    # The principal its outputs (the reset of `answer`) are written as.
    run_as "system:atlas-flow"

    owner via: :assignment,
          relation: :assigned_to,
          default: {:person, config: :decider},
          preserve_kind: [:person, :machinery]

    start :create
    initial :waiting

    # Nobody is expected to do anything here (Flow alone writes a package), so it
    # presents nothing: its move to `authoring` is then the first thing presented, which
    # keeps the machinery someone handed it to (`AtlasFlow.Runs.Projection`).
    state :waiting, label: "Waiting" do
      # `not (… == '')`: the pinned rela has no `!=`. An absent field is no match either.
      branch to: :authoring, when: "not (entity.instructions == '')"
    end

    state :authoring, label: "Authoring" do
      present(
        expected: "Author it on the machinery",
        why: "it is ready to be built",
        instructions:
          "Its supervisor's Runtime builds it on a fresh base of develop and runs bin/check after the work. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:author,
        ladder: true,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: @input,
        check: ["bin/check"],
        instructions: @author_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    state :reviewing, label: "Reviewing" do
      present(
        expected: "Review it on the machinery",
        why: "its author's work is done",
        instructions:
          "Its supervisor's Runtime reviews the change set, read-only, on the author's base. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:review,
        ladder: true,
        role: :developer,
        profile: :independent_review,
        cost_class: :standard,
        input: [result: :latest, access: :read],
        instructions: @review_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    state :fixing, label: "Fixing" do
      present(
        expected: "Fix it on the machinery",
        why: "its review or check found a problem",
        instructions:
          "Its supervisor's Runtime fixes the reviewed change set on the author's base and runs bin/check after the work. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:fix,
        ladder: true,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [result: :latest, access: :write],
        check: ["bin/check"],
        instructions: @fix_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    state :diagnosing, label: "Diagnosing" do
      present(
        expected: "Diagnose it on the machinery",
        why: "its fixes did not get it through",
        instructions:
          "Its supervisor's Runtime finds out why, read-only, from the latest change set. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:diagnose,
        ladder: true,
        role: :investigator,
        profile: :deep_coding,
        cost_class: :standard,
        input: [result: :latest, access: :read],
        instructions: @diagnose_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    state :fresh, label: "Authoring afresh" do
      present(
        expected: "Author it afresh on the machinery",
        why: "the work so far did not get it through",
        instructions:
          "Its supervisor's Runtime builds it again on the original base and runs bin/check after the work. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:author,
        ladder: true,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: @input,
        check: ["bin/check"],
        instructions: @author_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    state :stronger, label: "Authoring stronger" do
      present(
        expected: "Author it on the machinery with the stronger profile",
        why: "the work so far did not get it through",
        instructions:
          "Its supervisor's Runtime builds it again on the original base with the stronger profile and runs bin/check after the work. Its supervisor's pickup starts the work: nothing is done until then."
      )

      task(:author,
        ladder: true,
        role: :developer,
        profile: :deep_coding_max,
        cost_class: :high,
        input: @input,
        check: ["bin/check"],
        instructions: @author_instructions,
        fields: @fields,
        records: @records,
        machinery: "machinery",
        on: @steps
      )
    end

    # Approved: nothing is expected of anyone until F3 publishes and merges it (F3-M adds
    # its way on). Not final, so that its run stays open for that; until then its
    # supervisor may abandon it.
    state :ready, label: "Ready" do
      branch to: :stuck, when: "entity.answer == 'abandon'"
    end

    state :held, label: "Held" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set(answer: :none)

      present(
        expected: "Answer its question",
        why: "its work was held",
        instructions:
          "Set its answer to one the question offers: its work then goes on, on its supervisor's Runtime."
      )

      branch to: :fresh, when: @fresh
      branch to: :stronger, when: "entity.answer == 'stronger'"
      branch to: :stuck, when: "entity.answer == 'abandon'"

      # D3: retry goes back to the state of the held task's step, as Flow wrote it.
      branch to: :authoring, when: "entity.answer == 'retry' and entity.retry_step == 'author'"
      branch to: :reviewing, when: "entity.answer == 'retry' and entity.retry_step == 'review'"
      branch to: :fixing, when: "entity.answer == 'retry' and entity.retry_step == 'fix'"
      branch to: :diagnosing, when: "entity.answer == 'retry' and entity.retry_step == 'diagnose'"
      branch to: :fresh, when: "entity.answer == 'retry' and entity.retry_step == 'fresh'"
      branch to: :stronger, when: "entity.answer == 'retry' and entity.retry_step == 'stronger'"
    end

    state :awaiting_decision, label: "Awaiting a decision" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}
      set(answer: :none)

      present(
        expected: "Decide how it goes on",
        why: "its work needs a decision",
        instructions:
          "Set its answer to one the question offers: its work then goes on, on its supervisor's Runtime."
      )

      branch to: :fresh, when: @fresh
      branch to: :stronger, when: "entity.answer == 'stronger'"
      branch to: :stuck, when: "entity.answer == 'abandon'"
    end

    final :stuck, label: "Stuck"
  end

  # How the runs of package are selected and presented: on its Assignment, as every
  # assigned item is, whose `assigned_to` names the machinery its task runs for. No
  # package ran before, so nothing is imported: every package starts in `waiting`.
  select(:package,
    choices: [],
    projection: [
      on: :assignment,
      state_field: :flow_state,
      handover_field: :handover,
      owner_relation: :assigned_to,
      field: :expected
    ],
    admission: [],
    imports: []
  )

  # The approved migrations of the runs of package; each from is a digest the base
  # branch recorded (RelaDSL.RunIdentity).
  # M3 A4: the author task's input names a Code repository (no longer a Git URL); its
  # base is resolved by Flow and the task goes through Flow's work source. No state
  # changes, so a live run keeps its state, entry and timers. Prod and test share both
  # digests.
  migrate(:package,
    from: "ed9ae978d163fa3b7d7baf396b8fafab0bebbaf06edfe5028fe4f853d9c99d2c",
    to: "457c90fddd78d1aa85729dee951b6acd6beccdbd9fb109b6adfb89f7686d8747",
    preserve_entry: true,
    states: :same,
    reason: "The author task's input is a Code repository and reference; same states"
  )

  # F2-P: the review → fix loop. Every task is a ladder step; the states of the loop are
  # new, and authored and check_failed are gone (nothing leads to them any more). A run
  # waiting or authoring keeps its state, and is entered again on the new definition (an
  # author task in flight blocks the run until it is moved by hand: no entry is
  # preserved, since two of the states change). A run that ended authored or check_failed
  # ended: a completed run stays in a final state, so it is stuck, which a person takes
  # back to restart it. Prod and test share both digests.
  migrate(:package,
    from: "457c90fddd78d1aa85729dee951b6acd6beccdbd9fb109b6adfb89f7686d8747",
    to: "ff2820a33b527143185cbdac7dea3d4bb4824b22ac4ce690f00bcba26f82f214",
    states: [
      waiting: :waiting,
      authoring: :authoring,
      authored: :stuck,
      check_failed: :stuck,
      stuck: :stuck
    ],
    reason:
      "The review and fix loop: each task is a ladder step; a run that ended authored or check_failed is stuck"
  )

  # Its presentation says its supervisor's pickup starts the work (IS-Atlas-25), and held
  # and awaiting_decision no longer ask to hand it back to its machinery; texts only, so a
  # run keeps its state and entry, also with a task in flight. Prod and test share both
  # digests.
  migrate(:package,
    from: "ff2820a33b527143185cbdac7dea3d4bb4824b22ac4ce690f00bcba26f82f214",
    to: "cff1c8ec60ecf670246f9a4455dbc5be6ddc6eb75aab5877616fbe629203db9c",
    preserve_entry: true,
    states: :same,
    reason:
      "Its supervisor's pickup starts the work; held and awaiting_decision ask no hand-back; texts only"
  )
end
