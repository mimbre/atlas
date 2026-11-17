defmodule AtlasRuntimeBoundary.WorkMappings do
  @moduledoc """
  How the Runtime's private work model (design §1.7: `work_record`, `key_index_entry`
  and the entities they hold) becomes the work contract's models (`AtlasRuntimeBoundary.Work`),
  and back. Model entities and fields are named as atoms only: this project depends on
  no model, and none of this is in the contract's `__schema__/0` or in `work.json`. The
  Boundary target checks these mappings against the model, and generates
  `from_model`/`to_model`, inside `atlas_runtime` (option `model:`).

  S1 has renames and drops only (§1.3); derived fields come later. So:

  - `work.state` (the current attempt's state) is not stored in the model: the core
    supplies it, `from_model(record, supply: [state: ...])`.
  - `work_request.client_key` is the work's, stored on `work_record`: inside a work it is
    not filled from the model.
  - An attempt's `provenance` is translated as it is: the model's `option` is an entity
    (provider, harness, model) like the contract's. `selection.reason` and
    `skipped_option.why` are strings in the model, cast to the contract's enum values by
    name. `provenance.configured_model` is optional in the model but required in the
    contract, so a provenance without it does not translate (`from_model` refuses it).

  S5a (design §3.9, §3.10) adds the `base` and `from_work` workspaces and `after_check` to
  the request, and the frozen reference, `based_on` and the check to a work product. What
  the core keeps for itself is dropped, never projected: a work's pinned `source` (B4),
  its `base_owner` and `baseline_id` (S5c: whose base and which baseline),
  and an attempt's `checking`/`check_pgid` (the check's sub-stage and process group),
  `folder` (the Runtime-chosen folder), `preparing` and `prepare_pid` (its preparation).
  The frozen result's own record (`frozen_result`) belongs to another model and is
  translated by the core.
  """
  use AtlasRuntimeBoundary.Generator.Mappings

  # The records.

  # Private: the frozen result a from_work work composes from, pinned at accept; a base
  # work's base owner and baseline, resolved at submit (S5c).
  defmapping :work_record, :work, supply: [:state], drop: [:source, :base_owner, :baseline_id]

  # A tombstone (I7): the work it named, and how that ended.
  defmapping :key_index_entry, :pruned,
    direction: :from_model,
    rename: [final_kind: :kind],
    drop: [:client, :client_key, :pruned]

  # The request, as accepted.

  defmapping :request, :work_request, supply: [:client_key]
  defmapping :repository, :repository

  defmapping :folder, :folder,
    values: [
      permissions: [
        read_only: :"read-only",
        workspace_write: :"workspace-write",
        materialized_folder: :"materialized-folder"
      ]
    ]

  defmapping :base, :base,
    values: [permissions: [read_only: :"read-only", workspace_write: :"workspace-write"]]

  defmapping :from_work, :from_work,
    values: [permissions: [read_only: :"read-only", workspace_write: :"workspace-write"]]

  defmapping :after_check, :after_check

  # An attempt and what it produced.

  defmapping :attempt, :attempt,
    # Private: the turn's folder, its stop latch, and who released its slot and when
    # (release_slot, §13.1 Q8).
    # The after-check's sub-stage and process group; the Runtime-chosen folder and its
    # preparation (S5a).
    drop: [
      :turn_folder,
      :stop_latch,
      :released_by,
      :released_at,
      :checking,
      :check_pgid,
      :folder,
      :preparing,
      :prepare_pid
    ]

  defmapping :timestamps, :attempt_timestamps
  defmapping :resume_point, :resume_point
  defmapping :workspace_state, :resume_workspace
  defmapping :result, :result
  defmapping :work_product, :work_product
  defmapping :product_workspace, :work_product_workspace
  defmapping :frozen_ref, :frozen_ref
  defmapping :root_fingerprint, :root_fingerprint
  defmapping :based_on, :based_on
  defmapping :check_result, :check_result
  defmapping :check_output, :check_output
  defmapping :log, :output_log

  # The provenance of a turn, and the policy selection it records.

  defmapping :provenance, :provenance
  defmapping :selection, :selection
  defmapping :option, :option
  defmapping :skipped_option, :skipped_option
end
