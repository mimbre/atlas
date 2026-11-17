defmodule AtlasRuntimeBoundary.Work do
  @moduledoc """
  The Runtime's work contract (design 2026-11-16-runtime-backend §3, slice S1): what a client
  may ask of the Runtime about work, and what it gets back, in the Runtime's own words.

  Clients decide; the Runtime executes. A client submits work that states its needs (an
  execution profile, a cost class, a workspace), never a model; the Runtime queues it,
  picks its own slot and harness under a human-owned policy, runs one attempt at a time,
  and records provenance per turn. A client is received as an opaque `client`
  (`id` and `rights`); every capability names the right it needs.

  Declarations only. The generator (`AtlasRuntimeBoundary.Generator.Schema`) turns them
  into `__schema__/0`, which its targets read. Elements that arrive in a later slice
  (the `packet` workspace, `independence`, a work product's `packet_id`) are not declared
  yet; the result kind `returned` is declared because the attempt state machine names it,
  though only a drain (S2) produces it.
  """
  use AtlasRuntimeBoundary.Generator.Schema

  version "0.1.0"

  # Enumerations used in more than one place (§3.1, §5).
  @rights [:submit, :cancel, :read, :read_all, :choose_slot, :choose_path]
  @attempt_states [
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
  @result_kinds [:completed, :failed, :crashed, :interrupted, :cancelled, :returned]
  @cancel_stages [:requested, :signalled, :forced]
  @availability_reasons [:quota, :no_permitted_option, :not_installed]

  ## Client (§3.1)

  # Who is calling: opaque. `choose_slot` is needed to name a slot, and `choose_path` to
  # name a folder on the Runtime's machine (D44); `read_all` widens reading and subscribing
  # beyond the caller's own work (§3.2 visibility). No capability takes or gives this
  # model: it declares the rights a client can hold, including the three that no
  # capability names as its right.
  defmodel :client do
    field :id, :string, required: true
    field :rights, {:list, {:enum, @rights}}, required: true
  end

  ## Work request (§3.3)

  defmodel :work_request do
    # Within this client it permanently identifies the work (I3, I7); never interpreted.
    field :client_key, :string
    field :title, :string, required: true
    # The text the agent receives.
    field :instructions, :string, required: true
    # An execution profile, such as deep_coding, light_work or independent_review.
    field :profile, :string, required: true
    field :cost_class, {:enum, [:low, :standard, :high]}, required: true
    # The Runtime chooses the folder for every form but folder (D44).
    field :workspace, {:one_of, [:repository, :folder], tag: :kind}, required: true
    # Continues that turn's conversation and workspace.
    field :resume_from, :string
    # Needs the right choose_slot.
    field :slot, :string
  end

  # Permission profile dedicated-repository; the base is resolved when the attempt starts.
  defmodel :repository do
    field :url, :string, required: true
    field :branch, :string, required: true
    field :base, :string, required: true
  end

  # Needs the right choose_path: a client names a path on the Runtime's machine (D44).
  # path: required in a request; in a work it is given only to a client holding
  # choose_path (D44), so the contract leaves it optional.
  defmodel :folder do
    field :path, :string

    field :permissions, {:enum, [:"read-only", :"workspace-write", :"materialized-folder"]},
      required: true
  end

  ## Capacity (§3.4)

  defmodel :capacity do
    field :slots, :slot_counts, required: true
    field :buffer, :buffer_counts, required: true
    # One entry per execution profile.
    field :profiles, {:list, :profile_availability}, required: true
    # False while the Runtime is stopping.
    field :accepting, :boolean, required: true
    field :policy_version, :integer, required: true
    field :runtime_build, :string, required: true
    # New on every boot.
    field :incarnation, :string, required: true
    # Seconds; present only when no new work can be taken.
    field :retry_after, :integer
  end

  defmodel :slot_counts do
    field :total, :integer, required: true
    field :busy, :integer, required: true
    field :free, :integer, required: true
  end

  defmodel :buffer_counts do
    field :size, :integer, required: true
    field :used, :integer, required: true
    field :free, :integer, required: true
  end

  defmodel :profile_availability do
    # The execution profile this entry is about.
    field :profile, :string, required: true
    field :available, :boolean, required: true
    field :reason, {:enum, @availability_reasons}
    field :until, :datetime
  end

  ## Work, attempt, result, provenance (§3.5)

  defmodel :work do
    # Made by the Runtime; opaque.
    field :work_id, :string, required: true
    # The submitting client's id.
    field :client, :string, required: true
    field :client_key, :string
    # Handed to the turn for effects outside the Runtime: the client key, else work_id.
    field :idempotency_key, :string, required: true
    # +1 on every change.
    field :revision, :integer, required: true
    # The change sequence at the last change.
    field :sequence, :integer, required: true
    field :request, :work_request, required: true
    # The current attempt's.
    field :state, {:enum, @attempt_states}, required: true
    field :attempts, {:list, :attempt}, required: true
  end

  defmodel :attempt do
    field :attempt, :integer, required: true
    field :state, {:enum, @attempt_states}, required: true
    field :cancel_stage, {:enum, @cancel_stages}
    field :cancel_reason, {:enum, [:cancel, :superseded, :time_limit]}
    field :timestamps, :attempt_timestamps, required: true
    # Detail only: no slot object, state or naming scheme is public.
    field :slot, :string
    field :turn_id, :string
    field :provenance, :provenance
    field :resume_point, :resume_point
    # No process of the attempt is left and no write is pending (I1).
    field :quiescent, :boolean, required: true
    field :result, :result
  end

  defmodel :attempt_timestamps do
    field :received_at, :datetime, required: true
    field :accepted_at, :datetime
    field :started_at, :datetime
    field :running_at, :datetime
    field :cancel_requested_at, :datetime
    field :signalled_at, :datetime
    field :forced_at, :datetime
    field :ended_at, :datetime
  end

  defmodel :resume_point do
    field :turn_id, :string, required: true
    field :conversation_id, :string, required: true
    field :workspace, :resume_workspace, required: true
  end

  # path: only for a client holding choose_path (D44).
  defmodel :resume_workspace do
    field :path, :string
    field :branch, :string
    field :commit, :string
  end

  defmodel :result do
    field :kind, {:enum, @result_kinds}, required: true
    # failed: absent for a work failure; cancelled: cancel or superseded; interrupted:
    # runtime_stop when the Runtime was stopped (§13.1 Q9).
    field :reason,
          {:enum,
           [
             :time_limit,
             :quota,
             :launch,
             :workspace,
             :model_changed,
             :cancel,
             :superseded,
             :runtime_stop
           ]}

    # Advice to the client; the decision to retry is the client's (I4).
    field :retryable, :boolean, required: true
    field :native_outcome, {:enum, [:finished, :failed, :stopped, :killed]}
    # cancelled or returned before started_at.
    field :never_started, :boolean, required: true
    # The final agent message, at most 8 KB.
    field :answer, :string
    field :work_product, :work_product
    field :log, :output_log, required: true
  end

  defmodel :work_product do
    field :workspace, :work_product_workspace, required: true
  end

  # path: only for a client holding choose_path; paths on the Runtime's machine never
  # leave it otherwise (D44).
  defmodel :work_product_workspace do
    field :path, :string
    field :branch, :string
    field :base_sha, :string
    field :head_sha, :string
    field :changed, :boolean, required: true
  end

  # Whether the turn's output is complete, and where to read it (turn_output).
  defmodel :output_log do
    field :complete, :boolean, required: true
    field :missing_bytes, :integer, required: true
    field :ref, :string, required: true
  end

  # One record per turn; never changed once written.
  defmodel :provenance do
    field :executor_kind, {:enum, [:agent]}, required: true
    # From the selected policy option.
    field :provider, :string, required: true
    field :harness, :string, required: true
    field :harness_version, :string
    field :runtime_build, :string, required: true
    field :machine, :string, required: true
    field :slot, :string, required: true
    field :configured_model, :string, required: true
    # The first model a top-level assistant record reports, normalized; a later top-level
    # record with another model fails the turn with model_changed.
    field :reported_model, :string
    field :selection, :selection, required: true
    field :conversation_id, :string
    field :turn_id, :string, required: true
    # The turn this one continues.
    field :continues, :string
    field :started_at, :datetime, required: true
    field :ended_at, :datetime
  end

  defmodel :selection do
    field :profile, :string, required: true
    field :policy_version, :integer, required: true
    field :option, :option, required: true
    field :reason, {:enum, [:preferred, :fallback, :continuation]}, required: true
    field :skipped, {:list, :skipped_option}, required: true
  end

  # A concrete option of the policy for a profile.
  defmodel :option do
    field :provider, :string, required: true
    field :harness, :string, required: true
    field :model, :string, required: true
  end

  defmodel :skipped_option do
    field :option, :option, required: true
    field :why, {:enum, [:not_installed, :quota]}, required: true
  end

  ## Turn output (§3.2 turn_output)

  defmodel :output_event do
    field :sequence, :integer, required: true
    field :kind, {:enum, [:text, :activity]}, required: true
    field :text, :string, required: true
  end

  ## Notifications (§3.6): signals that something changed; state is read, never acknowledged.

  defmodel :work_changed do
    field :sequence, :integer, required: true
    field :work_id, :string, required: true
    field :revision, :integer, required: true
    field :state, {:enum, @attempt_states}, required: true
  end

  # The Runtime went from taking no new work to taking some.
  defmodel :capacity_available do
    field :sequence, :integer, required: true
    field :capacity, :capacity, required: true
  end

  defmodel :heartbeat do
    field :at, :datetime, required: true
    field :capacity, :capacity, required: true
    field :running, {:list, :running_attempt}, required: true
  end

  # alive: the process group exists. last_progress_at: the last harness event or output
  # byte. Reported separately.
  defmodel :running_attempt do
    field :work_id, :string, required: true
    field :attempt, :integer, required: true
    field :state, {:enum, @attempt_states}, required: true
    field :alive, :boolean, required: true
    field :last_progress_at, :datetime
    field :activity, :string
  end

  ## Inputs (§3.2)

  defmodel :retry_input do
    field :work_id, :string, required: true
    # Continue from the current attempt's resume point.
    field :resume, :boolean
  end

  defmodel :cancel_input do
    field :work_id, :string, required: true
    field :mode, {:enum, [:graceful, :force]}, required: true
    field :reason, :string
  end

  defmodel :get_work_input do
    field :work_id, :string, required: true
  end

  defmodel :find_work_input do
    field :client_key, :string, required: true
  end

  defmodel :list_work_input do
    field :state, {:enum, @attempt_states}
    # A change sequence; only work changed after it.
    field :changed_since, :integer
  end

  defmodel :turn_output_input do
    field :turn_id, :string, required: true
    field :cursor, :string
  end

  defmodel :subscribe_input do
    # A change sequence; notifications after it.
    field :from, :integer
  end

  ## Outcomes (§3.2): one model per outcome, so no two outcomes of a capability share one.

  defmodel :accepted do
    field :work, :work, required: true
  end

  # Same client and client key, same request: the work it already is (I3).
  defmodel :existing do
    field :work, :work, required: true
  end

  defmodel :at_capacity do
    field :reason, {:enum, [:full, :profile_unavailable, :not_accepting]}, required: true
    # Seconds.
    field :retry_after, :integer, required: true
    field :capacity, :capacity, required: true
  end

  # not_permitted (a right is missing) is checked first: a capability's own right is
  # answered before the capability runs, so this reason is for a right the request needs
  # (choose_slot with slot, choose_path with a folder workspace). conflict: same client
  # key, another request; invalid: the input does not fit the contract;
  # no_permitted_option is permanent.
  defmodel :refused do
    field :reason,
          {:enum,
           [
             :not_permitted,
             :conflict,
             :invalid,
             :unsupported_workspace,
             :policy_forbids,
             :no_permitted_option,
             :resume_unavailable
           ]},
          required: true

    field :detail, :string
  end

  # Never seen (I7).
  defmodel :not_found do
  end

  defmodel :cancelling do
    field :stage, {:enum, @cancel_stages}, required: true
    field :work, :work, required: true
  end

  defmodel :ended do
    field :work, :work, required: true
  end

  defmodel :found do
    field :work, :work, required: true
  end

  # Seen, ended with this kind, and its record pruned; the client key is kept (I7).
  defmodel :pruned do
    field :work_id, :string, required: true
    field :kind, {:enum, @result_kinds}, required: true
  end

  defmodel :works do
    field :works, {:list, :work}, required: true
    # The change sequence the list is current at.
    field :sequence, :integer, required: true
  end

  defmodel :page do
    field :events, {:list, :output_event}, required: true
    # Opaque; pass it back for the next page.
    field :cursor, :string, required: true
    field :more, :boolean, required: true
  end

  defmodel :subscribed do
  end

  # Behind the notification window, or across a restart: re-read with
  # list_work(changed_since:).
  defmodel :reset do
    field :current_sequence, :integer, required: true
  end

  ## Capabilities (§3.2)

  # An input that does not fit the contract (an unknown or missing field, a wrong type or
  # enum value) is refused as invalid, by every capability that can answer refused (§1.5).
  invalid_input :refused, set: [reason: :invalid], detail: :detail

  # Naming a slot also needs choose_slot; a folder workspace, choose_path.
  defcapability :submit,
    input: :work_request,
    outcomes: [
      accepted: :accepted,
      existing: :existing,
      at_capacity: :at_capacity,
      refused: :refused
    ],
    right: :submit

  defcapability :retry,
    input: :retry_input,
    outcomes: [
      accepted: :accepted,
      at_capacity: :at_capacity,
      refused: :refused,
      not_found: :not_found
    ],
    right: :submit

  # retry and cancel act only on the caller's own work (§3.2 Ownership): another client's
  # work is not_found to a caller that cannot see it, and refused: not_permitted to one
  # with read_all, which grants reading, never acting.
  defcapability :cancel,
    input: :cancel_input,
    outcomes: [cancelling: :cancelling, ended: :ended, refused: :refused, not_found: :not_found],
    right: :cancel

  # Without read_all, get_work, find_work, list_work, turn_output and subscribe see only
  # the caller's own work.
  defcapability :get_work,
    input: :get_work_input,
    outcomes: [found: :found, pruned: :pruned, not_found: :not_found],
    right: :read

  defcapability :find_work,
    input: :find_work_input,
    outcomes: [found: :found, pruned: :pruned, not_found: :not_found],
    right: :read

  defcapability :list_work,
    input: :list_work_input,
    outcomes: [works: :works],
    right: :read

  # Global: not limited to the caller's work.
  defcapability :capacity,
    input: nil,
    outcomes: [capacity: :capacity],
    right: :read

  defcapability :turn_output,
    input: :turn_output_input,
    outcomes: [page: :page, not_found: :not_found],
    right: :read

  # After subscribed, the subscriber receives work_changed, capacity_available and
  # heartbeat.
  defcapability :subscribe,
    input: :subscribe_input,
    outcomes: [subscribed: :subscribed, reset: :reset],
    right: :read
end
