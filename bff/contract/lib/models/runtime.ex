defmodule AtlasBFFContract.Models.Runtime do
  @moduledoc """
  First shared Runtime control vocabulary. Data contracts only: services bind identity,
  permissions, capability truth, correlation, deadlines and lifecycle behavior.

  A viewer attachment does not start or stop a worker. Conversation and harness output
  are not control messages. Guidance/evidence remain the existing adapter contracts.
  """
  use AtlasBFF.Schema
  version "0.1.0"

  # Node lifecycle is machine-scoped; it never invents a worker identity.
  defmodel :runtime_machine do
    field :environment, :string, required: true
    field :machine, :string, required: true
  end

  defmodel :runtime_machine_status_options do
    field :machine, :string
    field :json, :boolean
  end

  defmodel :runtime_discovery_options do
    field :machine, :string, required: true
  end

  defmodel :runtime_machine_availability do
    field :target, :runtime_machine, required: true
    field :registered, :boolean, required: true
    field :basis, :string, required: true
  end

  defmodel :runtime_machine_boot do
    field :environment, :string, required: true
    field :machine, :string, required: true
    field :configuration, :string, required: true
    field :directory, :string, required: true
    field :instance, :string, required: true
  end

  defmodel :runtime_machine_boot_receipt do
    field :target, :runtime_machine, required: true
    field :instance, :string, required: true
    field :pid, :integer, required: true
  end

  defmodel :runtime_machine_capabilities do
    field :local_status, :boolean, required: true
    field :local_start, :boolean, required: true
    field :local_stop, :boolean, required: true
    field :remote_status, :boolean, required: true
  end

  defmodel :runtime_machine_status do
    field :target, :runtime_machine, required: true
    field :state, :string, required: true
    field :basis, :string, required: true
    field :message, :string, required: true
    field :capabilities, :runtime_machine_capabilities, required: true
    field :pid, :integer
    field :process_present, :boolean
    field :log, :string
  end

  defmodel :runtime_worker do
    field :environment, :string, required: true
    field :machine, :string, required: true
    field :worker, :string, required: true
  end

  defmodel :runtime_execution do
    field :worker, :runtime_worker, required: true
    field :turn, :string, required: true
    # Existing unfenced turns omit this; adapters must never invent an attempt.
    field :attempt, :string
  end

  # Ephemeral output is exact-attempt scoped; it never uses a Facts position.
  defmodel :runtime_output_stream do
    field :execution, :runtime_execution, required: true
    field :epoch, :string, required: true
    field :first_sequence, :integer, required: true
    field :watermark, :integer, required: true
    # Producer closure, not authoritative completion of the worker.
    field :ended, :boolean, required: true
  end

  defmodel :runtime_output_event do
    field :sequence, :integer, required: true
    field :kind, :string, required: true
    field :text, :string
    field :tool_name, :string
    field :status, :string
  end

  defmodel :runtime_output_reset do
    field :reason, :string, required: true
    # Inclusive known loss interval; omitted when a previous epoch's tail is unknown.
    field :from_sequence, :integer
    field :to_sequence, :integer
  end

  defmodel :runtime_controls do
    field :status, :boolean, required: true
    field :start, :boolean, required: true
    field :stop, :boolean, required: true
    field :stub_mode, :boolean, required: true
  end

  defmodel :runtime_harness_capabilities do
    # Same proven capability slots as execution registration; not a second pipeline.
    field :harness, :string, required: true
    field :harness_version, :string, required: true
    field :capability_version, :string, required: true
    field :configured_model, :string
    field :reported_model, :string
    field :queued_input, :boolean, required: true
    field :durable_accept_query, :boolean, required: true
    field :consumption_evidence, :boolean, required: true
    field :literal_text, :boolean, required: true
  end

  defmodel :runtime_capabilities do
    field :controls, :runtime_controls, required: true
    # Absent means no registered/proven harness capability, not implied support.
    field :harness, :runtime_harness_capabilities
  end

  defmodel :runtime_turn do
    field :execution, :runtime_execution, required: true
    field :item, :string, required: true
    field :state, :string, required: true
    field :activity, :string
    field :lease_until, :string
    field :outcome, :string
    field :reason, :string
  end

  defmodel :runtime_status do
    field :target, :runtime_worker, required: true
    field :engine_running, :boolean, required: true
    field :capabilities, :runtime_capabilities, required: true
    field :item, :string
    field :owner, :string
    field :expected, :string
    field :handover, :string
    field :mode, :string
    field :cannot_run, :string
    field :turns, {:list, :runtime_turn}, required: true
  end

  defmodel :runtime_error do
    field :code, :string, required: true
    field :message, :string, required: true
    field :retryable, :boolean, required: true
  end

  defmodel :runtime_attachment_options do
    field :turn, :string, required: true
    field :attempt, :string, required: true
  end

  # Private snapshot profile: no lifecycle, guidance, output or replay admission.
  defmodel :runtime_attachment_capabilities do
    field :snapshot, :boolean, required: true
    field :control, :boolean, required: true
    field :guidance, :boolean, required: true
    field :output, :boolean, required: true
    field :replay, :boolean, required: true
  end
end
