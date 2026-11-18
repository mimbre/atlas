defmodule Model.Job do
  @moduledoc """
  Slice 1 (make it work): a job is one piece of agent work. A person picks it up in the
  Console and becomes its human supervisor; handed to a machinery, it runs one agent
  task on that supervisor's Runtime, and is done when the task ends. No package, check,
  review or pull request. It sits beside the issue flow and changes nothing of it.
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
    supervise :run, label: "Run", states: [:working], with: []

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
        on: [completed: :done, check_failed: :done, stuck: :stuck, abandoned: :stuck]
      )
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
