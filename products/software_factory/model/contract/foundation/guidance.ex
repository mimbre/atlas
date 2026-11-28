defmodule Model.Guidance do
  @moduledoc "The durable records of guidance: executions, interactions and their receipts."
  use RelaDSL

  entity :worker_execution,
    label: "Worker execution",
    plural: "worker_executions",
    id_type: :manual,
    description:
      "Immutable durable execution; only the Facts guidance operation writes this record." do
    field(:environment, :string, required: true)
    field(:worker, :string, required: true)
    field(:turn, :string, required: true)
    field(:attempt, :string, required: true)
    field(:machine, :string, required: true)
    field(:harness, :string, required: true)
    field(:harness_version, :string, required: true)
    field(:configured_model, :string, required: true)
    field(:reported_model, :string)
    field(:capability_version, :string, required: true)
    field(:queued_input, :boolean, required: true)
    field(:durable_accept_query, :boolean, required: true)
    field(:consumption_evidence, :boolean, required: true)
    field(:recorded_position, :integer, required: true)
    field(:recorded_at, :datetime, required: true)
    top(false)
    by_hand(false)
  end

  entity :interaction,
    label: "Interaction",
    plural: "interactions",
    id_type: :manual,
    description:
      "Immutable durable interaction; only the Facts guidance operation writes this record." do
    field(:environment, :string, required: true)
    field(:actor, :string, required: true)
    field(:client_key, :string, required: true)
    field(:body, :string, required: true)
    field(:body_digest, :string, required: true)
    field(:worker, :string, required: true)
    field(:turn, :string, required: true)
    field(:attempt, :string, required: true)
    field(:mode, :string, required: true)
    field(:execution, :string, required: true)
    field(:cause, :string, required: true)
    field(:recorded_position, :integer, required: true)
    field(:recorded_at, :datetime, required: true)
    top(false)
    by_hand(false)
  end

  entity :interaction_receipt,
    label: "Interaction receipt",
    plural: "interaction_receipts",
    id_type: :manual,
    description:
      "Immutable durable receipt; only the Facts guidance operation writes this record." do
    field(:environment, :string, required: true)
    field(:interaction, :string, required: true)
    field(:worker, :string, required: true)
    field(:turn, :string, required: true)
    field(:attempt, :string, required: true)
    field(:execution, :string, required: true)
    field(:stage, :string, required: true)
    field(:evidence_id, :string, required: true)
    field(:admission_id, :string)
    field(:consumption_id, :string)
    field(:reason, :string)
    field(:writer, :string, required: true)
    field(:cause, :string, required: true)
    field(:recorded_position, :integer, required: true)
    field(:recorded_at, :datetime, required: true)
    top(false)
    by_hand(false)
  end

  guidance(
    execution: [
      kind: :worker_execution,
      fields: [
        environment: :environment,
        worker: :worker,
        turn: :turn,
        attempt: :attempt,
        machine: :machine,
        harness: :harness,
        harness_version: :harness_version,
        configured_model: :configured_model,
        reported_model: :reported_model,
        capability_version: :capability_version,
        queued_input: :queued_input,
        durable_accept_query: :durable_accept_query,
        consumption_evidence: :consumption_evidence,
        recorded_at: :recorded_at,
        recorded_position: :recorded_position
      ]
    ],
    interaction: [
      kind: :interaction,
      fields: [
        environment: :environment,
        actor: :actor,
        client_key: :client_key,
        body: :body,
        body_digest: :body_digest,
        worker: :worker,
        turn: :turn,
        attempt: :attempt,
        mode: :mode,
        execution: :execution,
        cause: "cause",
        recorded_at: :recorded_at,
        recorded_position: :recorded_position
      ]
    ],
    receipt: [
      kind: :interaction_receipt,
      fields: [
        environment: :environment,
        interaction: :interaction,
        worker: :worker,
        turn: :turn,
        attempt: :attempt,
        execution: :execution,
        stage: :stage,
        evidence_id: :evidence_id,
        admission_id: :admission_id,
        consumption_id: :consumption_id,
        reason: "reason",
        writer: :writer,
        cause: "cause",
        recorded_at: :recorded_at,
        recorded_position: :recorded_position
      ]
    ]
  )
end
