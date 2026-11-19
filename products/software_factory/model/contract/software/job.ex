defmodule Model.Job do
  @moduledoc """
  A job is one piece of agent work. A person picks it up in the Console and becomes its
  human supervisor; handed to a machinery, it runs one agent task on that supervisor's
  Runtime. When the task ends, Code opens a pull request from its result (the effect
  `publish`, `AtlasCode.Effects`), and the job waits for its supervisor to merge it on
  GitHub: the GitHub connector copies the pull's state, and merged is done. No package,
  check or review. It sits beside the issue flow and changes nothing of it.
  """
  use RelaDSL

  entity :job,
    label: "Job",
    plural: "jobs",
    id_type: :manual,
    id_prefix: "JB-",
    description: """
    One piece of agent work: one agent does it on its supervisor's Runtime.
    The id is its Atlas code, e.g. JB-Atlas-01.
    """ do
    field(:title, :string, required: true, description: "What to do")
    field(:description, :string, description: "The details", multiline: true)

    # What its subflow's task branch reads: the run's own result, never written.
    field(:task_result, :string,
      description:
        "Flow: how its agent task ended (completed, check_failed, stuck, abandoned); the run's own, never written",
      set_by: [:flow],
      label: "Task result"
    )

    field(:publication, :string,
      description: "Flow: how opening its pull request ended (done, refused)",
      set_by: [:flow],
      label: "Publication"
    )

    field(:pr_url, :github_pull_url,
      description:
        "Flow: the pull request Code opened from its result, which its supervisor merges",
      set_by: [:flow],
      label: "Pull request"
    )

    field(:pr_state, :pull_request_state,
      description: "GitHub: its pull request's state",
      set_by: :connector,
      label: "Pull request state"
    )

    connector(
      system: :github,
      address: :pr_url,
      fields: [pr_state: :state],
      until: [pr_state: [:merged, :closed]]
    )

    create(ask: [:title, :description])
  end

  subflow :job, label: "Job", subject: :job do
    run_as "system:sf-flow"

    owner via: :assignment,
          relation: :assigned_to,
          default: {:agent, :coordinator},
          preserve_kind: [:agent, :person, :machinery]

    channel :work
    start :create
    initial :working
    # Its pull request is its supervisor's to merge: the span holds until it is merged.
    supervise :run, label: "Run", states: [:working, :publishing, :merging], with: []

    state :working, label: "Working" do
      present(
        expected: "Do it",
        why: "it is not done",
        instructions:
          "Its machinery runs one agent on it, on a fresh base of develop. Nothing is done while it is not assigned to a machinery."
      )

      task(:author,
        role: :developer,
        profile: :deep_coding,
        cost_class: :standard,
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        instructions:
          "Do the job below in the repository you are given, a Git checkout of its base. End your answer with what you did and what is left open.",
        fields: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [
          completed: :publishing,
          check_failed: :publishing,
          stuck: :stuck,
          abandoned: :stuck
        ]
      )
    end

    # Code pushes the task's result to a branch and opens a pull request from it onto the
    # base; Flow names the result by its ref only. It presents what happens meanwhile, so
    # the step to `merging` is a move (`AtlasFlow.Runs.Projection`): its owner, the
    # supervisor, takes the job from the machinery someone handed it to.
    state :publishing, label: "Opening its pull request" do
      present(
        expected: "Let Code open its pull request",
        why: "its agent's work is done",
        instructions:
          "Code pushes its result to a branch on GitHub and opens a pull request from it onto develop; nothing is asked of anyone meanwhile."
      )

      effect(:publish,
        contract: 1,
        name: "publish",
        service: "code",
        operation: "publish",
        field: :publication,
        fingerprint: [fields: ["title"], relations: []],
        payload: ["title", "description"],
        input: [repository: "github.com/mimbre/atlas", base: "develop"],
        outputs: [url: "pr_url"],
        on: [done: :merging, refused: :stuck]
      )
    end

    state :merging, label: "Merge it" do
      owner via: :assignment, relation: :assigned_to, default: {:person, config: :decider}

      present(
        expected: "Review and merge its pull request",
        why: "its agent's work is done",
        instructions:
          "Open its pull request and merge it on GitHub; the job is done once GitHub says it is merged."
      )

      branch to: :done, when: "entity.pr_state == 'merged'"
    end

    final :done, label: "Done"
    final :stuck, label: "Stuck"
  end

  # The job's instruction says it works in a folder without git, and runs no bin/check.
  migrate(:job,
    from: "9d3344521082b52910d3a4e637a7e2278746a9e76dae06a2ffcbfc5c376e202b",
    to: "3fcbc03eccf0397972a0eaf8fb5cb2322b739439436d705a88d7258efd26ec59",
    states: :same,
    reason: "Only the agent's instruction changed"
  )

  # The job's instruction is only the job again: the folder is a Git checkout with the
  # base's dependencies, so the agent uses Git and runs bin/check like any author.
  migrate(:job,
    from: "3fcbc03eccf0397972a0eaf8fb5cb2322b739439436d705a88d7258efd26ec59",
    to: "46dcb856c580ab03df187129d68206411c478b47af9466b767f32c9d6ba90b55",
    states: :same,
    reason: "Only the agent's instruction changed"
  )

  # Slice 3: a completed task leads to Code opening its pull request (`publishing`), then
  # to its supervisor merging it (`merging`). Every state is kept with its entry: a task in
  # flight goes on, and leads to `publishing` when it completes; a finished job stays as
  # it ended.
  migrate(:job,
    from: "46dcb856c580ab03df187129d68206411c478b47af9466b767f32c9d6ba90b55",
    to: "afc6e600959b0f07a3f9ebadf9442c235b6c9e0a0cdabfc300ffa832a02f8939",
    preserve_entry: true,
    states: [working: :working, done: :done, stuck: :stuck],
    reason: "Its result becomes a pull request its supervisor merges; the same entries"
  )

  # IS-Atlas-15: `publishing` presents what happens, so entering `merging` hands the job to
  # its supervisor. Every state and entry is kept; a job already in `merging` keeps its owner.
  migrate(:job,
    from: "afc6e600959b0f07a3f9ebadf9442c235b6c9e0a0cdabfc300ffa832a02f8939",
    to: "4e09f905e40c89b644787131690d3ecb917e9321eb6536abf66a3b7f1bad025e",
    preserve_entry: true,
    states: :same,
    reason: "Opening its pull request is presented; the same states and entries"
  )

  select(:job,
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
