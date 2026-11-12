defmodule Model.FlowRun do
  @moduledoc "The durable runs of the subflows, and the trusted inputs that move them."
  use RelaDSL

  entity :flow_run,
    label: "Flow run",
    plural: "flow_runs",
    id_type: :manual,
    description: "Durable generated state machine cursor, written only by its runner." do
    field(:flow, :string)
    field(:subject_kind, :string)
    field(:subject_key, :string)
    field(:generation, :integer)
    field(:definition_sha256, :string)
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
    top(false)
    by_hand(false)
  end

  # The durable runs are facts of flow_run, their inputs of flow_input; the writer is Flow.
  flow_runtime(runs: :flow_run, writer: [sender: :flow, by: :flow], inputs: :flow_input)
end
