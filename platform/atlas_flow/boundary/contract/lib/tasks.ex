defmodule AtlasFlowBoundary.Tasks do
  @moduledoc """
  Flow's `tasks` contract (Flow Engine plan §3.3, F5a): what a caller next to Flow may ask
  of it about the tasks Flow defines for machinery, in Flow's own words. Its first caller
  is Control, for people to see where work handed to machinery is.

  A task is one unit of work Flow defines for a subject (a package or an issue); an
  attempt is one try of it, with what actually ran it. A caller sees the safe-to-show part
  of Flow's records (plan §3.2): what the task is, where it is, how it ended, and each
  attempt's provenance. Never a path on a machine, a token or a Runtime address.

  This version carries the reading capabilities only. Cancelling and retrying a task
  (`cancel_task`, `retry_task`, right `steer`) come with F5b, together with Flow's retry
  rules, so that steering and Flow's own recovery are one change. Hand-over itself is no
  capability: it stays an assignment in Facts.

  Declarations only: the generator (`AtlasFlowBoundary.Generator.Schema`) turns them into
  `__schema__/0`.
  """
  use AtlasFlowBoundary.Generator.Schema

  version "0.1.0"

  ## Values

  # The check after an author or fix task (`bin/check`): how it exited, or how it ended
  # when it did not exit, and the tail of its output.
  defmodel :check do
    field :exit_status, :integer
    field :ending, {:enum, [:timed_out, :cancelled, :interrupted]}
    field :output_tail, :string
  end

  # One try of a task, never overwritten: where it is, how it ended, and what ran it.
  defmodel :task_attempt do
    # 1, 2, …: the attempt's number within its task.
    field :attempt, :integer, required: true
    field :state, :string
    field :result_kind, :string
    # The machinery it ran on (its name in Flow's configuration).
    field :machinery, :string
    field :provider, :string
    field :harness, :string
    field :harness_version, :string
    field :configured_model, :string
    # As the harness reported it; kept when it differs from the configured one.
    field :reported_model, :string
    field :selection_reason, :string
    field :conversation_id, :string
    # Detail only: the machine and slot as the machinery names them.
    field :machine, :string
    field :slot, :string
    field :turn_id, :string
    field :started_at, :datetime
    field :ended_at, :datetime
  end

  # One unit of work Flow defines for a subject.
  defmodel :task do
    # TK-<subject>-<n>.
    field :task_id, :string, required: true
    # The key of the package or issue it belongs to.
    field :subject, :string, required: true

    field :kind, {:enum, [:plan, :author, :review, :fix, :diagnose, :native_check]},
      required: true

    field :role, {:enum, [:architect, :developer, :investigator]}
    # The abstract profile it needs, such as deep_coding; never a slot or a model.
    field :profile, :string
    # Where the task is, as Flow keeps it.
    field :state, :string
    # The id of its work on the machinery, once submitted.
    field :work_id, :string
    # The attempt it is on.
    field :attempt, :integer
    # How its current attempt ended, and why.
    field :result_kind, :string
    field :reason, :string
    field :check, :check
    # A review task's verdict.
    field :verdict, {:enum, [:approved, :changes_required]}
    # The worker's answer, at most 8 KB.
    field :answer, :string
    # The fingerprints of its frozen result, and of the result a review reviewed.
    field :result_fingerprints, {:list, :string}, required: true
    field :based_on, {:list, :string}, required: true
    # The base it started from, and the Code snapshot and revision that base was made of.
    field :base_id, :string
    field :base_snapshot, :string
    field :base_revision, :string
    # Oldest first.
    field :attempts, {:list, :task_attempt}, required: true
  end

  # Of one execution profile: whether the machinery takes work for it now.
  defmodel :profile_capacity do
    field :profile, :string, required: true
    field :available, :boolean, required: true
    field :reason, :string
  end

  # What the machinery last said of its capacity.
  defmodel :capacity do
    # False while it is stopping.
    field :accepting, :boolean, required: true
    field :free_slots, :integer, required: true
    field :profiles, {:list, :profile_capacity}, required: true
  end

  # Why Flow could not answer.
  defmodel :problem do
    field :message, :string, required: true
  end

  ## Inputs

  defmodel :list_tasks_input do
    # The key of a package or an issue.
    field :subject, :string, required: true
  end

  defmodel :get_task_input do
    field :task_id, :string, required: true
  end

  defmodel :machinery_status_input do
    # Its name in Flow's configuration, such as mac-mini.
    field :machinery, :string, required: true
  end

  ## Outcomes

  defmodel :task_list do
    field :subject, :string, required: true
    # In the order Flow defined them.
    field :tasks, {:list, :task}, required: true
  end

  defmodel :machinery_status do
    field :machinery, :string, required: true
    # Whether it answered; false too for a machinery Flow has no configuration of.
    field :reachable, :boolean, required: true
    field :last_capacity, :capacity
    # When it last answered.
    field :last_seen, :datetime
  end

  ## Capabilities

  # The tasks of one subject. Facts holds Flow's records: when it does not answer, the
  # outcome is `unavailable`, never an empty list.
  defcapability :list_tasks,
    input: :list_tasks_input,
    outcomes: [tasks: :task_list, unavailable: :problem],
    right: :read

  defcapability :get_task,
    input: :get_task_input,
    outcomes: [found: :task, not_found: nil, unavailable: :problem],
    right: :read

  defcapability :machinery_status,
    input: :machinery_status_input,
    outcomes: [status: :machinery_status],
    right: :read
end
