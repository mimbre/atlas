defmodule Model.Task do
  @moduledoc """
  One unit of work Flow defines for an assignee (the Flow Engine plan, §3.1 and §3.2).
  Flow names it `TK-<package>-<n>`; that key is also the Runtime work's client key. It
  belongs to a package or an issue (`task_of`, in the composition, since both are
  software's) and has its attempts (`task_attempt`, `attempt_of`). It is done for the
  human supervisor of its flow (`done_for`), whom Flow copies onto it.

  A record: Flow writes every field (`set_by: [:flow]`), and no state of a subflow reads
  it; branches read the run's own task results. The fields Code adds from F3 on (change
  id, review id, `fpr_`, PR URL) come with F3.
  """
  use RelaDSL

  type(:task_kind,
    values: [:plan, :author, :review, :fix],
    labels: [plan: "Plan", author: "Author", review: "Review", fix: "Fix"]
  )

  type(:task_role,
    values: [:architect, :developer],
    labels: [architect: "Architect", developer: "Developer"]
  )

  type(:task_verdict,
    values: [:approved, :changes_required],
    labels: [approved: "Approved", changes_required: "Changes required"]
  )

  entity :task,
    label: "Task",
    plural: "tasks",
    id_type: :manual,
    id_prefix: "TK-",
    description: """
    One unit of work Flow defines for an assignee and submits to its machinery as
    Runtime work. Flow names it TK-<package>-<n>; the key is the work's client key.
    """ do
    field(:kind, :task_kind,
      required: true,
      description: "Plan, author, review or fix",
      set_by: [:flow]
    )

    field(:role, :task_role, description: "Architect or developer", set_by: [:flow])

    field(:profile, :string,
      description: "The abstract profile it needs: deep_coding or independent_review",
      set_by: [:flow]
    )

    field(:input, :string,
      description: "What it starts from: the base, or the result of a task, read or write (JSON)",
      set_by: [:flow],
      multiline: true
    )

    field(:client_key, :string,
      description: "The Runtime work's client key: the task's own key",
      set_by: [:flow],
      label: "Client key"
    )

    field(:work_id, :string,
      description: "The Runtime's id of its work",
      set_by: [:flow],
      label: "Work id"
    )

    field(:attempt, :integer, description: "The Runtime attempt it is on", set_by: [:flow])
    field(:state, :string, description: "Where the task is, as Flow keeps it", set_by: [:flow])

    field(:result_kind, :string,
      description: "How its work ended, as the Runtime says",
      set_by: [:flow],
      label: "Result kind"
    )

    field(:reason, :string, description: "Why it ended so", set_by: [:flow])

    field(:check_exit_status, :integer,
      description: "The check's exit status",
      set_by: [:flow],
      label: "Check exit status"
    )

    field(:check_ending, :string,
      description:
        "How the check ended when it did not exit: timed out, cancelled or interrupted",
      set_by: [:flow],
      label: "Check ending"
    )

    field(:check_output_tail, :string,
      description: "The tail of the check's output",
      set_by: [:flow],
      multiline: true,
      label: "Check output"
    )

    field(:verdict, :task_verdict,
      description: "A review task's verdict: approved or changes required",
      set_by: [:flow]
    )

    field(:answer, :string,
      description: "The worker's answer, at most 8 KB",
      set_by: [:flow],
      multiline: true
    )

    field(:result_fingerprints, :string,
      description: "The fingerprints of its frozen result (JSON)",
      set_by: [:flow],
      label: "Result fingerprints"
    )

    field(:based_on, :string,
      description: "The fingerprint of the result a review task reviewed",
      set_by: [:flow],
      label: "Based on"
    )

    field(:base_id, :string,
      description: "The Runtime base it started from",
      set_by: [:flow],
      label: "Base id"
    )

    field(:base_snapshot, :string,
      description: "The Code snapshot its base was made from",
      set_by: [:flow],
      label: "Base snapshot"
    )

    field(:base_revision, :string,
      description: "The revision of that snapshot",
      set_by: [:flow],
      label: "Base revision"
    )

    # The lease Flow, as the Runtime's work source, holds the task under (decision
    # 2026-11-17 §6.2 and §5.3): the current lease, who holds it and where it is, the
    # last report recorded on it and the result it brought. Dispatch and Delivery write
    # them as a fenced change on `lease_id`.
    field(:lease_id, :string,
      description: "The current lease of its work: opaque to the Runtime, never reused",
      set_by: [:flow],
      label: "Lease id"
    )

    field(:runtime, :string,
      description: "The Runtime that holds the current lease",
      set_by: [:flow]
    )

    field(:expires_at, :datetime,
      description: "When the current lease expires, as granted; renewals are not written",
      set_by: [:flow],
      label: "Expires at"
    )

    field(:granted_at, :datetime,
      description: "When the current lease was granted",
      set_by: [:flow],
      label: "Granted at"
    )

    field(:lease_state, :string,
      description:
        "Where the current lease is: offered, accepted, started, ended, done, expired, lost or cancel requested",
      set_by: [:flow],
      label: "Lease state"
    )

    field(:lease_end_cause, :string,
      description: "Why Flow ended the lease: supervision, expired or late accept",
      set_by: [:flow],
      label: "Lease end cause"
    )

    field(:lease_revision, :integer,
      description: "The revision of the last report recorded on the lease",
      set_by: [:flow],
      label: "Lease revision"
    )

    field(:lease_report, :string,
      description: "The sha256 of the last recorded report",
      set_by: [:flow],
      label: "Lease report"
    )

    field(:result_manifest, :string,
      description: "The sha256 of its result's stored manifest",
      set_by: [:flow],
      label: "Result manifest"
    )

    field(:result_state, :string,
      description: "Whether its result is stored: incomplete, complete, too large or invalid",
      set_by: [:flow],
      label: "Result state"
    )

    top(false)
    by_hand(false)
    order(:newest)
  end

  # Whom the work is done for (decision 2026-11-17 §5.6): Flow copies the human
  # supervisor of the task's flow onto it, for audit and subscription; only Flow sets it.
  relation(:done_for,
    label: "done for",
    description:
      "The human supervisor of its flow when Flow offered it, copied for audit. Only Flow sets it.",
    from: [:task],
    to: [:person],
    max_outgoing: 1,
    inverse: {:tasks_done_for, "tasks done for"},
    set_by: [:flow]
  )
end
