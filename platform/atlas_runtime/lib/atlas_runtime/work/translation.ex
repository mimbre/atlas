defmodule AtlasRuntime.Work.Translation do
  @moduledoc false
  # Model ↔ boundary for the work core, until the Boundary target generates the
  # translations from `AtlasRuntimeBoundary.WorkMappings` (design §1.5 (c), A-FAC part 2).
  # Then `from_model/1` becomes the facade's generated one and `to_model/1` its
  # counterpart; nothing else in the core converts between the two, so this module is the
  # one place to swap.
  #
  # Besides renames and dropped private fields (`turn_folder`, `stop_latch`), S1's two
  # schemas also differ in ways a rename cannot cover; they are handled here and reported
  # for the mappings: `work.state` is the current attempt's (derived); a folder's
  # `permissions` values are spelled differently; a result's or selection's `reason` and a
  # skipped option's `why` are free text in the model and enums at the boundary; and a few fields the model leaves optional are required at the boundary
  # (`repository.base`, `result.log` and its `ref`, `resume_point.conversation_id` and
  # `workspace`). `provenance.configured_model` is optional in the model too; the core
  # always sets it (`AtlasRuntime.Work.Server`).

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.Work, as: M

  @folder %{
    read_only: :"read-only",
    workspace_write: :"workspace-write",
    materialized_folder: :"materialized-folder"
  }
  @result_reasons ~w(time_limit quota launch workspace model_changed cancel superseded runtime_stop)a
  @selection_reasons ~w(preferred fallback continuation)a
  @skip_reasons ~w(not_installed quota)a

  @doc false
  # A work record as the boundary's work.
  def from_model(%M.WorkRecord{} = record) do
    attempts = Enum.map(record.attempts, &attempt/1)

    %B.Work{
      work_id: record.work_id,
      client: record.client,
      client_key: record.client_key,
      idempotency_key: record.idempotency_key,
      revision: record.revision,
      sequence: record.sequence,
      request: request(record.request, record.client_key),
      state: List.last(attempts).state,
      attempts: attempts
    }
  end

  @doc false
  # A boundary request as the model's request (the client key belongs to the work).
  def to_model(%B.WorkRequest{} = request) do
    workspace =
      case request.workspace do
        %B.Repository{} = repository ->
          M.Repository.new!(url: repository.url, branch: repository.branch, base: repository.base)

        %B.Folder{} = folder ->
          permissions =
            Enum.find_value(@folder, fn {model, public} ->
              public == folder.permissions && model
            end)

          M.Folder.new!(path: folder.path, permissions: permissions)
      end

    M.Request.new!(
      title: request.title,
      instructions: request.instructions,
      profile: request.profile,
      cost_class: request.cost_class,
      workspace: workspace,
      resume_from: request.resume_from,
      slot: request.slot
    )
  end

  @doc false
  # A policy option (`%{"provider", "harness", "model"}`) as the model's option.
  def model_option(%{"provider" => provider, "harness" => harness, "model" => model}),
    do: M.Option.new!(provider: provider, harness: harness, model: model)

  defp request(%M.Request{} = request, client_key) do
    %B.WorkRequest{
      client_key: client_key,
      title: request.title,
      instructions: request.instructions,
      profile: request.profile,
      cost_class: request.cost_class,
      workspace: workspace(request.workspace),
      resume_from: request.resume_from,
      slot: request.slot
    }
  end

  defp workspace(%M.Repository{} = repository),
    do: %B.Repository{
      url: repository.url,
      branch: repository.branch,
      base: repository.base || "develop"
    }

  defp workspace(%M.Folder{} = folder),
    do: %B.Folder{path: folder.path, permissions: Map.fetch!(@folder, folder.permissions)}

  defp attempt(%M.Attempt{} = attempt) do
    %B.Attempt{
      attempt: attempt.attempt,
      state: attempt.state,
      cancel_stage: attempt.cancel_stage,
      cancel_reason: attempt.cancel_reason,
      timestamps: struct!(B.AttemptTimestamps, Map.from_struct(attempt.timestamps)),
      slot: attempt.slot,
      turn_id: attempt.turn_id,
      provenance: provenance(attempt.provenance),
      resume_point: resume_point(attempt.resume_point),
      quiescent: attempt.quiescent,
      result: result(attempt.result)
    }
  end

  defp resume_point(
         %M.ResumePoint{conversation_id: conversation, workspace: %M.WorkspaceState{} = workspace} =
           point
       )
       when is_binary(conversation) do
    %B.ResumePoint{
      turn_id: point.turn_id,
      conversation_id: conversation,
      workspace: %B.ResumeWorkspace{
        path: workspace.path,
        branch: workspace.branch,
        commit: workspace.commit
      }
    }
  end

  defp resume_point(_), do: nil

  defp result(nil), do: nil

  defp result(%M.Result{} = result) do
    log = result.log

    %B.Result{
      kind: result.kind,
      reason: enum(result.reason, @result_reasons),
      retryable: result.retryable,
      native_outcome: result.native_outcome,
      never_started: result.never_started,
      answer: result.answer,
      work_product: work_product(result.work_product),
      log: %B.OutputLog{
        complete: (log && log.complete) || false,
        missing_bytes: (log && log.missing_bytes) || 0,
        ref: (log && log.ref) || ""
      }
    }
  end

  defp work_product(nil), do: nil

  defp work_product(%M.WorkProduct{workspace: workspace}),
    do: %B.WorkProduct{workspace: struct!(B.WorkProductWorkspace, Map.from_struct(workspace))}

  defp provenance(nil), do: nil

  defp provenance(%M.Provenance{} = provenance) do
    %B.Provenance{
      executor_kind: provenance.executor_kind,
      provider: provenance.provider,
      harness: provenance.harness,
      harness_version: provenance.harness_version,
      runtime_build: provenance.runtime_build,
      machine: provenance.machine,
      slot: provenance.slot,
      configured_model: provenance.configured_model,
      reported_model: provenance.reported_model,
      selection: selection(provenance.selection),
      conversation_id: provenance.conversation_id,
      turn_id: provenance.turn_id,
      continues: provenance.continues,
      started_at: provenance.started_at,
      ended_at: provenance.ended_at
    }
  end

  defp selection(%M.Selection{} = selection) do
    # A skip the contract has no word for (an option that cannot serve the permission) is
    # left out.
    skipped =
      for skipped <- selection.skipped,
          why = enum(skipped.why, @skip_reasons),
          do: %B.SkippedOption{option: public_option(skipped.option), why: why}

    %B.Selection{
      profile: selection.profile,
      policy_version: selection.policy_version,
      option: public_option(selection.option),
      reason: enum(selection.reason, @selection_reasons) || :preferred,
      skipped: skipped
    }
  end

  defp public_option(%M.Option{} = option),
    do: %B.Option{provider: option.provider, harness: option.harness, model: option.model}

  defp enum(nil, _values), do: nil
  defp enum(text, values), do: Enum.find(values, &(Atom.to_string(&1) == text))
end
