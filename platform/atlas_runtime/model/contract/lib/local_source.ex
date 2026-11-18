defmodule AtlasRuntimeModel.LocalSource do
  @moduledoc """
  The private model of the Runtime's built-in local work source (decision §5.4, M2 plan
  W7/C5): its queue, persisted under `$ATLAS_RUNTIME_HOME/local-source/` and denied to
  every worker sandbox (I8, F4). Never seen by a caller.

  - `queued_work`: one per work added through the CLI, `local-source/queue/{work_id}.json`:
    its request as accepted, the adder's priority, when and in which order it was added,
    its state, the lease it was handed out under, the attempt that lease runs and a
    reference to its result.
  - `queue_key_entry`: (client, client key) → `work_id`, all in `local-source/index.json`.
    An entry outlives its pruned queued work as a tombstone (I3, I7 move here): `pruned`,
    and the final result kind. A work added without a client key gets a tombstone too, with
    no `client_key`.

  Rules across records or fields are behaviour, kept by the hand-written store
  (`AtlasRuntime.Sources.Local.Store`), not declared here:
  - the order is priority (a lower number first), then FIFO by `position`;
  - `position` grows with every add;
  - `local-source/index.json` holds at most one entry per (client, client key);
  - a `leased` work has its `lease_id`; an `ended` work has its `result`;
  - an entry is `pruned` only once its work is `ended`, so a tombstone has its `final_kind`;
  - an entry without a `client_key` is a pruned keyless work's tombstone, never a live entry.
  """
  use AtlasRuntimeModel.Generator.Schema

  version "0.1.0"

  type :queue_state, values: [:queued, :leased, :ended]

  type :result_kind,
    values: [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]

  type :cost_class, values: [:low, :standard, :high]

  # The request, as the CLI added it: the work contract's request (§3.3), held by the
  # source until it hands the work out under a lease.

  defmodel :repository do
    field :url, :string, required: true
    field :branch, :string, required: true
    field :base, :string
  end

  defmodel :folder do
    field :path, :string, required: true

    field :permissions, {:enum, [:read_only, :workspace_write, :materialized_folder]},
      required: true
  end

  defmodel :base do
    field :base_id, :string, required: true
    field :permissions, {:enum, [:read_only, :workspace_write]}, required: true
  end

  defmodel :from_work do
    field :work_id, :string, required: true
    field :attempt, :integer
    field :permissions, {:enum, [:read_only, :workspace_write]}, required: true
  end

  defmodel :after_check do
    field :command, {:list, :string}, required: true
    field :timeout, :integer
  end

  defmodel :request do
    field :title, :string, required: true
    field :instructions, :string, required: true
    field :profile, :string, required: true
    field :cost_class, :cost_class, required: true
    field :workspace, {:one_of, [:repository, :folder, :base, :from_work]}, required: true
    field :resume_from, :string
    field :slot, :string
    field :after_check, :after_check
  end

  # Where the work's result is: reported by the executor and uploaded to this source
  # (C6), so the source serves it after the executor pruned its own copy.
  defmodel :result_ref do
    field :kind, :result_kind, required: true
    field :attempt, :integer, required: true
    # The frozen result in this source's store, for a completed attempt with one.
    field :frozen_id, :string
    field :ended_at, :datetime, required: true
  end

  # A retry asked for while the work's leased attempt had not ended here yet (its `ended`
  # still on its way): the work is queued again for the next attempt once that one ends.
  defmodel :retry_request do
    field :resume, :boolean, required: true
  end

  # The records.

  defrecord :queued_work,
    persist: [form: :json_file, path: "local-source/queue/{work_id}.json", format_version: 1] do
    field :work_id, :string, required: true
    # The adding client's id.
    field :client, :string, required: true
    field :client_key, :string
    field :request, :request, required: true
    # Set by the adder; a lower number goes first.
    field :priority, :integer, required: true
    field :added_at, :datetime, required: true
    # The add order: FIFO within a priority.
    field :position, :integer, required: true
    field :state, :queue_state, required: true
    # The lease the work is (or was last) handed out under.
    field :lease_id, :string
    field :result, :result_ref
    # The attempt its lease runs (Main's round 2: a retry queues the work again for the
    # next one); absent is 1.
    field :attempt, :integer
    # That retry continues the last attempt's conversation.
    field :resume, :boolean
    field :retry, :retry_request
  end

  defrecord :queue_key_entry,
    # One file for all entries: the path has no {field}.
    persist: [form: :json_file, path: "local-source/index.json", format_version: 1] do
    field :client, :string, required: true
    # Absent only on the tombstone of a work added without a client key.
    field :client_key, :string
    field :work_id, :string, required: true
    # The result kind once the work ended.
    field :final_kind, :result_kind
    # The queued work is gone; the entry stays (I7).
    field :pruned, :boolean, required: true
  end
end
