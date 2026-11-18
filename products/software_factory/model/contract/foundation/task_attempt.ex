defmodule Model.TaskAttempt do
  @moduledoc """
  One Runtime attempt of a task, with what actually ran (the Flow Engine plan, §3.2,
  client obligation 7). Flow names it `TA-<task>-<n>` and writes one per attempt, never
  overwriting an earlier one; every field is Flow's (`set_by: [:flow]`).

  It is not the `turn` kind, which Runtime keeps (`TU-…`, `set_by: [:runtime]`) and which
  stays as it is: two writers never own one fact.
  """
  use RelaDSL

  entity :task_attempt,
    label: "Task attempt",
    plural: "task_attempts",
    id_type: :manual,
    id_prefix: "TA-",
    description: """
    One Runtime attempt of a task and what ran it: provider, harness, model and the
    reason they were chosen. Flow names it TA-<task>-<n> and never overwrites one.
    """ do
    field(:turn_id, :string,
      description: "The Runtime turn of the attempt",
      set_by: [:flow],
      label: "Turn id"
    )

    field(:state, :string,
      description: "Where the attempt is, as the Runtime says",
      set_by: [:flow]
    )

    field(:result_kind, :string,
      description: "How the attempt ended",
      set_by: [:flow],
      label: "Result kind"
    )

    field(:provider, :string, description: "The vendor that ran it", set_by: [:flow])
    field(:harness, :string, description: "The harness that ran it", set_by: [:flow])

    field(:harness_version, :string,
      description: "The harness's version",
      set_by: [:flow],
      label: "Harness version"
    )

    field(:configured_model, :string,
      description: "The model the Runtime asked for",
      set_by: [:flow],
      label: "Configured model"
    )

    field(:reported_model, :string,
      description: "The model the harness reports it ran; kept when it differs",
      set_by: [:flow],
      label: "Reported model"
    )

    field(:selection_reason, :string,
      description: "Why the Runtime chose this slot, harness and model",
      set_by: [:flow],
      label: "Selection reason"
    )

    field(:conversation_id, :string,
      description: "The harness's conversation",
      set_by: [:flow],
      label: "Conversation id"
    )

    field(:machine, :string, description: "The machine it ran on (detail)", set_by: [:flow])
    field(:slot, :string, description: "The slot it ran in (detail)", set_by: [:flow])

    field(:started_at, :datetime,
      description: "When it started",
      set_by: [:flow],
      label: "Started at"
    )

    field(:ended_at, :datetime, description: "When it ended", set_by: [:flow], label: "Ended at")

    field(:lease_id, :string,
      description: "The lease of its task the attempt ran under",
      set_by: [:flow],
      label: "Lease id"
    )

    top(false)
    by_hand(false)
    order(:newest)
  end

  relation(:attempt_of,
    label: "attempt of",
    description: "An attempt belongs to one task; a task has its attempts.",
    from: [:task_attempt],
    to: [:task],
    max_outgoing: 1,
    inverse: {:attempts, "attempts"},
    parent: true,
    set_by: [:flow]
  )

  relation(:ran_on,
    label: "ran on",
    description: "The machinery the attempt ran on.",
    from: [:task_attempt],
    to: [:machinery],
    max_outgoing: 1,
    inverse: {:attempts_run, "attempts run"},
    set_by: [:flow]
  )
end
