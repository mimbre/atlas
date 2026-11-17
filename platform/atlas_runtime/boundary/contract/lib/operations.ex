defmodule AtlasRuntimeBoundary.Operations do
  @moduledoc """
  The Runtime's operations contract (design 2026-11-16-runtime-backend §13 S2, §13.1
  Q4–Q9, Q12, Q13; D39): what an operator may ask of the Runtime itself, rather than of
  its work, in the Runtime's own words.

  An operator inspects the Runtime (its runtime info and the policy view) and operates it:
  pauses, resumes or drains it, stops it, releases a slot and clears a quota mark. A caller
  is received as an opaque `client` (`id` and `rights`); `inspect` covers inspection,
  `operate` everything that changes the Runtime. Only the machine's own operator holds
  `operate`.

  The contract stands on its own: it names no model of another contract, and declares its
  own `runtime_info`, which overlaps a little with the work contract's capacity (Q13). The
  policy is shown as a declared view, never as its file (§1.6, Q7); setting the policy
  stays a hand edit. Declarations only: the generator
  (`AtlasRuntimeBoundary.Generator.Schema`) turns them into `__schema__/0`.
  """
  use AtlasRuntimeBoundary.Generator.Schema

  version "0.1.0"

  @rights [:inspect, :operate]
  @cost_classes [:low, :standard, :high]
  @permission_profiles [
    :"dedicated-repository",
    :"materialized-folder",
    :"workspace-write",
    :"read-only"
  ]

  ## Client (Q4)

  # Who is calling: opaque. No capability takes or gives this model: it declares the rights
  # a client can hold.
  defmodel :client do
    field :id, :string, required: true
    field :rights, {:list, {:enum, @rights}}, required: true
  end

  ## Runtime info (Q13)

  defmodel :runtime_info do
    field :runtime_build, :string, required: true
    # New on every boot.
    field :incarnation, :string, required: true
    # open: taking work. paused: no new work and no new starts (Q5). draining: no new work,
    # buffered work is returned (Q5). stopping: on its way out (Q9).
    field :mode, {:enum, [:open, :paused, :draining, :stopping]}, required: true
    field :policy_version, :integer, required: true
    field :slots, {:list, :slot}, required: true
  end

  # A slot by its public name (detail only); its state, latches and registry stay private.
  defmodel :slot do
    field :name, :string, required: true
    field :busy, :boolean, required: true
  end

  ## Policy view (Q7): the declared view of the human-owned policy, never its file.

  defmodel :policy do
    # Goes up on every change.
    field :version, :integer, required: true
    field :changed_by, :string
    field :changed_at, :datetime
    # Accepted work that may wait for a slot.
    field :buffer_size, :integer, required: true
    field :independence, :independence
    # One entry per execution profile.
    field :profiles, {:list, :profile_policy}, required: true
  end

  # How strict "different" is (§7).
  defmodel :independence do
    field :different_from, {:enum, [:conversation, :model, :provider]}, required: true
  end

  defmodel :profile_policy do
    # The execution profile this entry is about.
    field :profile, :string, required: true
    field :permissions, {:list, {:enum, @permission_profiles}}, required: true
    field :cost_classes, {:list, {:enum, @cost_classes}}, required: true
    field :limits, :profile_limits, required: true
    # In order: the first available one is preferred, a later one a fallback.
    field :options, {:list, :policy_option}, required: true
  end

  defmodel :profile_limits do
    # Seconds.
    field :max_duration, :integer
  end

  # A concrete option of a profile, with its availability now.
  defmodel :policy_option do
    field :provider, :string, required: true
    field :harness, :string, required: true
    field :model, :string, required: true
    field :availability, :option_availability, required: true
  end

  defmodel :option_availability do
    field :available, :boolean, required: true
    field :reason, {:enum, [:quota, :not_installed]}
    field :until, :datetime
  end

  ## Inputs

  defmodel :stop_input do
    # Kill running attempts at once, instead of going through the cancel stages (Q9).
    field :force, :boolean
  end

  defmodel :release_slot_input do
    # A public slot name, given only by the machine's own operator (Q8).
    field :slot, :string, required: true
  end

  defmodel :clear_quota_mark_input do
    field :harness, :string, required: true
  end

  ## Outcomes

  # A slot that has nothing to release is released too: releasing is idempotent (Q8).
  defmodel :released do
    field :slot, :string, required: true
  end

  # slot_busy: the probe shows the slot's process alive (Q8). invalid: the input does not
  # fit the contract.
  defmodel :refused do
    field :reason, {:enum, [:slot_busy, :invalid]}, required: true
    field :detail, :string
  end

  # No such slot, or no such harness.
  defmodel :not_found do
  end

  defmodel :cleared do
  end

  ## Capabilities (§13 S2, Q4)

  # An input that does not fit the contract is refused as invalid, by every capability that
  # can answer refused (§1.5).
  invalid_input :refused, set: [reason: :invalid], detail: :detail

  defcapability :runtime_info,
    input: nil,
    outcomes: [runtime_info: :runtime_info],
    right: :inspect

  defcapability :policy,
    input: nil,
    outcomes: [policy: :policy],
    right: :inspect

  # pause, resume and drain answer the runtime info, also when the Runtime is already in
  # that mode. resume returns to open; draining lasts until resume (Q5). The mode outlasts
  # a restart (Q6).
  defcapability :pause,
    input: nil,
    outcomes: [runtime_info: :runtime_info],
    right: :operate

  defcapability :resume,
    input: nil,
    outcomes: [runtime_info: :runtime_info],
    right: :operate

  defcapability :drain,
    input: nil,
    outcomes: [runtime_info: :runtime_info],
    right: :operate

  # No new work; buffered work stays stored; running attempts end interrupted, retryable;
  # then the process exits (Q9). A repeated stop answers the same. stop does not change the
  # mode that outlasts a restart (Q6).
  defcapability :stop,
    input: :stop_input,
    outcomes: [stopping: :runtime_info],
    right: :operate

  # Clears the slot's admission latch and, if its turn is unknown, marks the turn gone and
  # the attempt quiescent (I1, Q8).
  defcapability :release_slot,
    input: :release_slot_input,
    outcomes: [released: :released, refused: :refused, not_found: :not_found],
    right: :operate

  # An operational act, not a policy change (Q7).
  defcapability :clear_quota_mark,
    input: :clear_quota_mark_input,
    outcomes: [cleared: :cleared, not_found: :not_found],
    right: :operate
end
