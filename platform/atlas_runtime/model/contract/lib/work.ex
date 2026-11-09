defmodule AtlasRuntimeModel.Work do
  @moduledoc """
  The Runtime's private model of work (design §1.7, §3.5, §6): the records it persists
  under `$ATLAS_RUNTIME_HOME/work/`, never seen by a caller. The innermost layer: it knows
  nothing of the layers that use it (backend → boundary → model).

  - `work_record`: one per work, `work/{work_id}.json`, holding its request and every
    attempt with its result and the provenance of its turn.
  - `key_index_entry`: (client, client key) → `work_id`, all in `work/index.json`. An
    entry outlives its pruned work record as a tombstone (I7): `pruned`, and the final
    result kind.

  The work's state is not stored: it is the current (last) attempt's.

  Rules across records or fields are behaviour, kept by the hand-written store (design
  §1.7, "Hand-written code"), not declared here:
  - a work has at least one attempt;
  - `work/index.json` holds at most one entry per (client, client key);
  - an entry is `pruned` only once its work is final, so a tombstone has its `final_kind`.
  """
  use AtlasRuntimeModel.Generator.Schema

  version "0.1.0"

  type :attempt_state,
    values: [
      :buffered,
      :starting,
      :running,
      :cancelling,
      :completed,
      :failed,
      :crashed,
      :interrupted,
      :cancelled,
      :returned
    ]

  type :result_kind,
    values: [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]

  type :cancel_stage, values: [:requested, :signalled, :forced]
  type :cancel_reason, values: [:cancel, :superseded, :time_limit]
  type :cost_class, values: [:low, :standard, :high]
  type :native_outcome, values: [:finished, :failed, :stopped, :killed]

  # The request, as accepted (§3.3).

  defmodel :repository do
    field :url, :string, required: true
    field :branch, :string, required: true
    # Resolved at start when not given.
    field :base, :string
  end

  defmodel :folder do
    field :path, :string, required: true

    field :permissions, {:enum, [:read_only, :workspace_write, :materialized_folder]},
      required: true
  end

  defmodel :request do
    field :title, :string, required: true
    field :instructions, :string, required: true
    field :profile, :string, required: true
    field :cost_class, :cost_class, required: true
    field :workspace, {:one_of, [:repository, :folder]}, required: true
    field :resume_from, :string
    field :slot, :string
  end

  # An attempt and what it produced (§3.5).

  defmodel :timestamps do
    field :received_at, :datetime, required: true
    field :accepted_at, :datetime
    field :started_at, :datetime
    field :running_at, :datetime
    field :cancel_requested_at, :datetime
    field :signalled_at, :datetime
    field :forced_at, :datetime
    field :ended_at, :datetime
  end

  defmodel :workspace_state do
    field :path, :string, required: true
    field :branch, :string
    field :commit, :string
  end

  defmodel :resume_point do
    field :turn_id, :string, required: true
    field :conversation_id, :string
    field :workspace, :workspace_state
  end

  # A backend option, as the boundary has it; held inside a selection only.
  defmodel :option do
    field :provider, :string, required: true
    field :harness, :string, required: true
    field :model, :string, required: true
  end

  defmodel :skipped_option do
    field :option, :option, required: true
    field :why, :string, required: true
  end

  defmodel :selection do
    field :profile, :string, required: true
    field :policy_version, :integer, required: true
    field :option, :option, required: true
    field :reason, :string, required: true
    field :skipped, {:list, :skipped_option}, required: true
  end

  # One per turn; never changed once written.
  defmodel :provenance do
    field :executor_kind, {:enum, [:agent]}, required: true
    field :provider, :string, required: true
    field :harness, :string, required: true
    field :harness_version, :string
    field :runtime_build, :string, required: true
    field :machine, :string, required: true
    field :slot, :string, required: true
    field :configured_model, :string
    field :reported_model, :string
    field :selection, :selection, required: true
    field :conversation_id, :string
    field :turn_id, :string, required: true
    # The turn this one continues.
    field :continues, :string
    field :started_at, :datetime, required: true
    field :ended_at, :datetime
  end

  defmodel :product_workspace do
    field :path, :string, required: true
    field :branch, :string
    field :base_sha, :string
    field :head_sha, :string
    field :changed, :boolean, required: true
  end

  defmodel :work_product do
    field :workspace, :product_workspace, required: true
  end

  defmodel :log do
    field :complete, :boolean, required: true
    field :missing_bytes, :integer, required: true
    field :ref, :string
  end

  defmodel :result do
    field :kind, :result_kind, required: true
    # Why, for failed (time_limit, quota, launch, workspace, model_changed) and cancelled
    # (superseded).
    field :reason, :string
    field :retryable, :boolean, required: true
    field :native_outcome, :native_outcome
    field :never_started, :boolean, required: true
    # The final agent message, at most 8 KB.
    field :answer, :string
    field :work_product, :work_product
    field :log, :log
  end

  defmodel :attempt do
    field :attempt, :integer, required: true
    field :state, :attempt_state, required: true
    field :cancel_stage, :cancel_stage
    field :cancel_reason, :cancel_reason
    field :timestamps, :timestamps, required: true
    field :slot, :string
    field :turn_id, :string
    field :provenance, :provenance
    field :resume_point, :resume_point
    field :quiescent, :boolean, required: true
    field :result, :result
    # Private: the turn's folder under the Runtime home, and its stop latch.
    field :turn_folder, :string
    field :stop_latch, :string
  end

  # The records.

  defrecord :work_record,
    persist: [form: :json_file, path: "work/{work_id}.json", format_version: 1] do
    field :work_id, :string, required: true
    # The owning client's id; rights are the caller's, per call.
    field :client, :string, required: true
    field :client_key, :string
    # Handed to the turn: the client key when there is one, otherwise work_id.
    field :idempotency_key, :string, required: true
    # +1 on every change.
    field :revision, :integer, required: true
    # The change sequence at the last change.
    field :sequence, :integer, required: true
    field :request, :request, required: true
    # In order; the last is the current one.
    field :attempts, {:list, :attempt}, required: true
  end

  defrecord :key_index_entry,
    # One file for all entries: the path has no {field}.
    persist: [form: :json_file, path: "work/index.json", format_version: 1] do
    field :client, :string, required: true
    field :client_key, :string, required: true
    field :work_id, :string, required: true
    # The result kind of the work's last attempt once it is final.
    field :final_kind, :result_kind
    # The work record is gone; the entry stays (I7).
    field :pruned, :boolean, required: true
  end
end
