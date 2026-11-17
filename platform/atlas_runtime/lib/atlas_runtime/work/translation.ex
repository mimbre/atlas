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
  #
  # S5a (I-B5): the `base` and `from_work` workspaces (their `permissions` spelled as a
  # folder's), `after_check`, the check timestamps and a work product's `frozen`,
  # `based_on` and `check`. What the core keeps for itself is never projected: the work's
  # pinned `source` and an attempt's `checking`, `check_pgid`, `folder`, `preparing` and
  # `prepare_pid`. `frozen/1` gives a frozen result's own record (another model) as the
  # contract's `frozen`, without its `frozen_id`, `frozen_at` and `pruned`.
  #
  # `from_model/2` takes the caller's rights: `request.workspace.path` (a folder),
  # `work_product.workspace.path` and `resume_point.workspace.path` are paths on the
  # Runtime's machine, kept only for a client holding `choose_path` (D44). There is no
  # translation without the rights.
  #
  # S5a P10a (§3.10): a live attempt has no result at the boundary. While it is `checking`
  # (private) its agent's result is persisted, but the attempt is `running` until the
  # `completed` write that carries the check (I2), so that result is not projected.
  # `from_model_redacting/3`'s `redact` is applied to a check's output tail, the one free text
  # of a work product (designer decision 2026-11-17, (A)): the core passes the D44 path
  # redaction for a client without choose_path, the identity otherwise. It takes the rights
  # as `from_model/2` does and has no default, so neither the rights nor the redaction can be
  # forgotten; every reply of the core goes through it. `from_model/2` (I-D44) is the same
  # projection with the tail as stored.

  alias AtlasRuntime.Boundary.Work, as: B
  alias AtlasRuntime.Model.FrozenResult, as: F
  alias AtlasRuntime.Model.Work, as: M
  alias AtlasRuntime.Work.Queue

  @folder %{
    read_only: :"read-only",
    workspace_write: :"workspace-write",
    materialized_folder: :"materialized-folder"
  }
  # A change entry's mode is a string in the model and an enum in the contract.
  @modes %{"100644" => :"100644", "100755" => :"100755", "120000" => :"120000"}
  @result_reasons ~w(time_limit quota launch workspace model_changed cancel superseded runtime_stop)a
  @selection_reasons ~w(preferred fallback continuation)a
  @skip_reasons ~w(not_installed quota)a

  @doc false
  # A work record as the boundary's work, as a client with these rights sees it; a check's
  # output tail as stored.
  def from_model(%M.WorkRecord{} = record, rights) when is_list(rights),
    do: from_model_redacting(record, rights, & &1)

  @doc false
  # As `from_model/2`; `redact` rewrites a check's output tail.
  def from_model_redacting(%M.WorkRecord{} = record, rights, redact)
      when is_list(rights) and is_function(redact, 1) do
    paths? = :choose_path in rights
    attempts = Enum.map(record.attempts, &attempt(&1, paths?, redact))

    %B.Work{
      work_id: record.work_id,
      client: record.client,
      client_key: record.client_key,
      idempotency_key: record.idempotency_key,
      revision: record.revision,
      sequence: record.sequence,
      request: request(record.request, record.client_key, paths?),
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

        %B.Base{} = base ->
          M.Base.new!(base_id: base.base_id, permissions: model_permissions(base.permissions))

        %B.FromWork{} = from ->
          M.FromWork.new!(
            work_id: from.work_id,
            attempt: from.attempt,
            permissions: model_permissions(from.permissions)
          )
      end

    after_check =
      case request.after_check do
        nil ->
          nil

        %B.AfterCheck{} = check ->
          M.AfterCheck.new!(command: check.command, timeout: check.timeout)
      end

    M.Request.new!(
      title: request.title,
      instructions: request.instructions,
      profile: request.profile,
      cost_class: request.cost_class,
      workspace: workspace,
      resume_from: request.resume_from,
      slot: request.slot,
      after_check: after_check
    )
  end

  @doc false
  # A frozen result's record as the contract's frozen (§3.9). A tombstone (pruned) is not
  # a frozen result a caller can read: the core answers pruned for it. `redact` is applied
  # to every symlink `target` (the one free-text path a change set carries): the core passes
  # the D44 path redaction for a client without choose_path, the identity otherwise.
  def frozen(%F.FrozenResult{pruned: false} = frozen, redact \\ & &1) do
    %B.Frozen{
      work_id: frozen.work_id,
      attempt: frozen.attempt,
      base: frozen.base,
      roots:
        for root <- frozen.roots do
          %B.FrozenRoot{
            root: root.root,
            fingerprint: root.fingerprint,
            entries: Enum.map(root.entries, &change_entry(&1, redact))
          }
        end
    }
  end

  defp change_entry(%F.ChangeEntry{} = entry, redact) do
    %B.ChangeEntry{
      path: entry.path,
      op: entry.op,
      kind: entry.kind,
      mode: entry.mode && Map.fetch!(@modes, entry.mode),
      size: entry.size,
      sha256: entry.sha256,
      target: entry.target && redact.(entry.target)
    }
  end

  @doc false
  # A policy option (`%{"provider", "harness", "model"}`) as the model's option.
  def model_option(%{"provider" => provider, "harness" => harness, "model" => model}),
    do: M.Option.new!(provider: provider, harness: harness, model: model)

  defp request(%M.Request{} = request, client_key, paths?) do
    %B.WorkRequest{
      client_key: client_key,
      title: request.title,
      instructions: request.instructions,
      profile: request.profile,
      cost_class: request.cost_class,
      workspace: workspace(request.workspace, paths?),
      resume_from: request.resume_from,
      slot: request.slot,
      after_check: after_check(request.after_check)
    }
  end

  defp after_check(nil), do: nil

  defp after_check(%M.AfterCheck{} = check),
    do: %B.AfterCheck{command: check.command, timeout: check.timeout}

  defp workspace(%M.Repository{} = repository, _paths?),
    do: %B.Repository{
      url: repository.url,
      branch: repository.branch,
      base: repository.base || "develop"
    }

  defp workspace(%M.Folder{} = folder, paths?),
    do: %B.Folder{
      path: if(paths?, do: folder.path),
      permissions: Map.fetch!(@folder, folder.permissions)
    }

  defp workspace(%M.Base{} = base, _paths?),
    do: %B.Base{base_id: base.base_id, permissions: Map.fetch!(@folder, base.permissions)}

  defp workspace(%M.FromWork{} = from, _paths?),
    do: %B.FromWork{
      work_id: from.work_id,
      attempt: from.attempt,
      permissions: Map.fetch!(@folder, from.permissions)
    }

  # base and from_work have read-only and workspace-write only (the contract's enum).
  defp model_permissions(:"read-only"), do: :read_only
  defp model_permissions(:"workspace-write"), do: :workspace_write

  defp attempt(%M.Attempt{} = attempt, paths?, redact) do
    %B.Attempt{
      attempt: attempt.attempt,
      state: attempt.state,
      cancel_stage: attempt.cancel_stage,
      cancel_reason: attempt.cancel_reason,
      timestamps: struct!(B.AttemptTimestamps, Map.from_struct(attempt.timestamps)),
      slot: attempt.slot,
      turn_id: attempt.turn_id,
      provenance: provenance(attempt.provenance),
      resume_point: resume_point(attempt.resume_point, paths?),
      quiescent: attempt.quiescent,
      result: if(Queue.live?(attempt), do: nil, else: result(attempt.result, paths?, redact))
    }
  end

  defp resume_point(
         %M.ResumePoint{conversation_id: conversation, workspace: %M.WorkspaceState{} = workspace} =
           point,
         paths?
       )
       when is_binary(conversation) do
    %B.ResumePoint{
      turn_id: point.turn_id,
      conversation_id: conversation,
      workspace: %B.ResumeWorkspace{
        path: if(paths?, do: workspace.path),
        branch: workspace.branch,
        commit: workspace.commit
      }
    }
  end

  defp resume_point(_, _paths?), do: nil

  defp result(nil, _paths?, _redact), do: nil

  defp result(%M.Result{} = result, paths?, redact) do
    log = result.log

    %B.Result{
      kind: result.kind,
      reason: enum(result.reason, @result_reasons),
      retryable: result.retryable,
      native_outcome: result.native_outcome,
      never_started: result.never_started,
      answer: result.answer,
      work_product: work_product(result.work_product, paths?, redact),
      log: %B.OutputLog{
        complete: (log && log.complete) || false,
        missing_bytes: (log && log.missing_bytes) || 0,
        ref: (log && log.ref) || ""
      }
    }
  end

  defp work_product(nil, _paths?, _redact), do: nil

  defp work_product(%M.WorkProduct{workspace: workspace} = product, paths?, redact) do
    workspace = struct!(B.WorkProductWorkspace, Map.from_struct(workspace))

    %B.WorkProduct{
      workspace: if(paths?, do: workspace, else: %{workspace | path: nil}),
      frozen: frozen_ref(product.frozen),
      based_on: based_on(product.based_on),
      check: check(product.check, redact)
    }
  end

  defp frozen_ref(nil), do: nil

  defp frozen_ref(%M.FrozenRef{} = ref),
    do: %B.FrozenRef{base: ref.base, fingerprints: fingerprints(ref.fingerprints)}

  defp based_on(nil), do: nil

  defp based_on(%M.BasedOn{} = based_on),
    do: %B.BasedOn{
      work_id: based_on.work_id,
      attempt: based_on.attempt,
      fingerprints: fingerprints(based_on.fingerprints)
    }

  defp fingerprints(list),
    do: for(f <- list, do: %B.RootFingerprint{root: f.root, fingerprint: f.fingerprint})

  defp check(nil, _redact), do: nil

  defp check(%M.CheckResult{} = check, redact),
    do: %B.CheckResult{
      command: check.command,
      exit_status: check.exit_status,
      signal: check.signal,
      error: check.error,
      timed_out: check.timed_out,
      cancelled: check.cancelled,
      interrupted: check.interrupted,
      duration_ms: check.duration_ms,
      output: %B.CheckOutput{tail: redact.(check.output.tail), complete: check.output.complete}
    }

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
