defmodule Model.Package do
  @moduledoc """
  A bounded part of an issue that becomes one pull request (the Flow Engine plan, §3.1
  and §3.2). It comes from an Architect's plan or is made by hand; Flow names it
  `PK-<issue>-<n>`. It is a child of its issue (`package_of`), and its tasks belong to it
  (`task_of`, in the composition). `published_revision` and `published_fingerprint` come
  with F3. Flow writes every field (`set_by: [:flow]`).

  It is not a pull request: `in_issue` stays the pull request's relation alone, whose
  limit and the issue's completion read a pull request's `state`.

  Its subflow, `package`, authors it (the plan's §6 F1.4):

    * `waiting` holds a package until it has its `instructions`, which its author task
      carries; one that has them goes on to `authoring` at once. It presents nothing:
      only Flow writes a package. The packages it waits for (`after`) are not read yet:
      that ordering comes with F4.
    * `authoring` is one author task (`AtlasFlow.Activities.Task`): role developer,
      profile `deep_coding`, on a fresh `develop` of the repository, with `bin/check`
      after the work. Its record is a `task` linked `task_of` the package. It runs only
      while the package's Assignment is with a machinery (E1); otherwise nothing is
      done for it.
    * It ends `authored` (the check passed), `check_failed` (the check failed, timed
      out, did not finish or did not run) or `stuck` (any other end of the work, or its
      assignment moved away from the machinery). A person who takes a stuck package
      back restarts it or does it by hand; F2 reviews and fixes the other two.

  The workspace is a repository and its base, never a path on the machinery's machine
  (the Runtime's D44): the Runtime chooses where it is.
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

  subflow :package, label: "Package", subject: :package do
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
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
          "Its machinery builds it on a fresh base of develop and runs bin/check after the work. Nothing is done while it is not assigned to a machinery."
      )

      task(:author,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "https://github.com/mimbre/atlas.git", base: "develop"],
        check: ["bin/check"],
        instructions: @author_instructions,
        fields: [:title, :instructions, :acceptance],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :authored,
          check_failed: :check_failed,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    final :authored, label: "Authored"
    final :check_failed, label: "Check failed"
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
end
