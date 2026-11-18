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
          "Do the job below in the repository you are given, starting from its base. End your answer with what you did and what is left open.",
        fields: [:title, :description],
        records: [kind: "task", relation: "task_of"],
        machinery: "machinery",
        on: [completed: :done, check_failed: :done, stuck: :stuck, abandoned: :stuck]
      )
    end

    final :done, label: "Done"
    final :stuck, label: "Stuck"
  end

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
