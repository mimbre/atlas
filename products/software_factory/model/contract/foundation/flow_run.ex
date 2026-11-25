defmodule Model.FlowRun do
  @moduledoc """
  The durable runs of the subflows, and the trusted inputs that move them.

  Supervision (decision 2026-11-17 §5.6, "you supervise a flow; you never own an
  item"): a run inside a supervised span of its subflow (`supervise`) may have one
  human supervisor (`supervised_by`, run → person). Only the run's writer, Flow, sets
  it: from a checked pickup input (`operation` `pickup`, from a person at the TUI, for
  themselves alone) and clears it from a hand-over (`hand_over`, naming in `hand_to`
  the person who is given a To-Do to pick it up), and in the same write as the run
  leaves the span. A new run generation starts without one. A retry (`retry`, from its
  supervisor) takes the run back to the first step of its span, where its agent work is
  offered again, fresh. A choice input
  (`operation` empty or `choice`) is the subject write it always was. The flow's agent
  work runs only on its supervisor's Runtimes, and its agents and smart gates ask them.
  """
  use RelaDSL

  type(:flow_input_operation,
    values: [:choice, :pickup, :hand_over, :retry],
    labels: [choice: "Choice", pickup: "Pick up", hand_over: "Hand over", retry: "Retry"],
    descriptions: [
      choice: "A choice its owner makes, written on the subject (the default when empty)",
      pickup: "Makes the person who sends it the run's human supervisor",
      hand_over: "Clears the run's human supervisor and gives hand_to a To-Do to pick it up",
      retry:
        "Its supervisor takes the run back to the first step of its span, with fresh agent work"
    ]
  )

  entity :flow_run,
    label: "Flow run",
    plural: "flow_runs",
    id_type: :manual,
    description: "Durable generated state machine cursor, written only by its runner." do
    field(:flow, :string)
    field(:subject_kind, :string)
    field(:subject_key, :string)
    field(:generation, :integer)

    field(:definition_sha256, :string,
      description:
        "History only: the digest of the subflow definition an older run started under; " <>
          "Flow sets it on no run and decides nothing by it (D-0102)"
    )

    field(:state, :string)
    field(:entry, :integer)
    field(:entered_at, :string)
    field(:status, :string)
    field(:deadlines, :string)
    field(:pending, :string)
    field(:input_cursor, :integer)
    field(:last_input, :string)
    field(:blocked_reason, :string)
    top(false)
    by_hand(false)
  end

  entity :flow_input,
    label: "Flow input",
    plural: "flow_inputs",
    id_type: :manual,
    description: "Typed trusted choice operation, prepared before its subject write." do
    field(:request_id, :string)
    field(:run, :string)
    field(:flow, :string)
    field(:subject_kind, :string)
    field(:subject_key, :string)
    field(:generation, :integer)
    field(:entry, :integer)
    field(:source_version, :string)
    field(:subject_version, :string)
    field(:actor, :string)
    field(:roles, :string)
    field(:changed_fields, :string)
    field(:links, :string)
    field(:payload_digest, :string)
    field(:status, :string)
    field(:position, :integer)
    field(:prepared_at, :string)
    field(:applied_at, :string)

    field(:operation, :flow_input_operation,
      description: "What it asks of the run: a choice (when empty), a pickup or a hand-over"
    )

    field(:hand_to, :string,
      description: "A hand-over's person, who is given a To-Do to pick the run up"
    )

    top(false)
    by_hand(false)
  end

  # The human supervisor of a run inside a supervised span: Flow alone sets and clears it.
  relation(:supervised_by,
    label: "supervised by",
    description:
      "The human supervisor of a run in a supervised span: who picked it up. Only Flow sets it.",
    from: [:flow_run],
    to: [:person],
    max_outgoing: 1,
    inverse: {:supervises, "supervises"},
    set_by: [:flow]
  )

  # The durable runs are facts of flow_run, their inputs of flow_input; the writer is Flow.
  # A run's human supervisor is its supervised_by, moved by pickup and hand-over inputs.
  # Flow's work source leaser and its report receiver (decision 2026-11-17 §6.4, Flow plan
  # decision 11) are the same writer from their own endpoints: they may write Flow's own
  # task fields (the leaser and the receiver) and task_attempt fields (the receiver),
  # nothing else, and never a run. Flow's Landing (F3-L) is too: Flow's own task fields
  # only (what it published, CI, ready), never a run. The work source's poll steps, run by
  # the receiver, write a Runtime's machinery (what it did with its configuration,
  # IS-Atlas-27) and its upgrade (IS-Atlas-26).
  flow_runtime(
    runs: :flow_run,
    writer: [sender: :flow, by: :flow],
    inputs: :flow_input,
    supervision: [relation: :supervised_by, operation: :operation, hand_to: :hand_to],
    senders: [
      task: [:"flow/dispatch", :"flow/delivery", :"flow/landing"],
      task_attempt: [:"flow/delivery"],
      machinery: [:"flow/delivery"],
      runtime_upgrade: [:"flow/delivery"]
    ]
  )
end
