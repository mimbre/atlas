defmodule AtlasRuntimeBoundary.History do
  @moduledoc """
  The Runtime's history contract (design 2026-11-16-runtime-backend §13 S2, §13.1 Q1, Q2,
  Q4; D39): read-only summaries of the turns the Runtime has run, in the Runtime's own
  words.

  A turn is the one native harness run that carries out an attempt; turns from before
  works existed are served as they are, without a work. A summary is never the turn's
  record: it carries the turn's slot (detail only), its state and outcome, its times, and
  the provenance fields where known. A turn's output is read through the work contract's
  `turn_output`; a client may use both contracts.

  A caller is received as an opaque `client` (`id` and `rights`). Without `read_all` a
  client sees only the turns of its own work; turns that belong to no work are seen only
  with `read_all` (Q2). Declarations only: the generator
  (`AtlasRuntimeBoundary.Generator.Schema`) turns them into `__schema__/0`.
  """
  use AtlasRuntimeBoundary.Generator.Schema

  version "0.1.0"

  ## Client (Q4)

  # Who is calling: opaque. read_all widens reading beyond the caller's own work.
  defmodel :client do
    field :id, :string, required: true
    field :rights, {:list, {:enum, [:read, :read_all]}}, required: true
  end

  ## Turn summary (Q1)

  defmodel :turn do
    field :turn_id, :string, required: true
    # Detail only: no slot object, state or naming scheme is public.
    field :slot, :string
    # As the Runtime's turn history records it; unknown: its process may still exist.
    field :state,
          {:enum,
           [:running, :stopping, :killing, :finished, :failed, :stopped, :killed, :unknown]},
          required: true

    field :native_outcome, {:enum, [:finished, :failed, :stopped, :killed]}
    field :started_at, :datetime
    field :ended_at, :datetime
    # Provenance, where known.
    field :harness, :string
    field :configured_model, :string
    field :reported_model, :string
    field :conversation_id, :string
  end

  ## Inputs

  defmodel :list_turns_input do
    # Only this slot's turns.
    field :slot, :string
    # Only turns started at or after this time.
    field :since, :datetime
    # Opaque; from the previous page.
    field :cursor, :string
    # At most this many turns.
    field :limit, :integer
  end

  defmodel :get_turn_input do
    field :turn_id, :string, required: true
  end

  ## Outcomes

  defmodel :turns do
    field :turns, {:list, :turn}, required: true
    # Opaque; pass it back for the next page.
    field :cursor, :string, required: true
    field :more, :boolean, required: true
  end

  defmodel :found do
    field :turn, :turn, required: true
  end

  # No such turn visible to the caller.
  defmodel :not_found do
  end

  ## Capabilities (Q1)

  defcapability :list_turns,
    input: :list_turns_input,
    outcomes: [turns: :turns],
    right: :read

  defcapability :get_turn,
    input: :get_turn_input,
    outcomes: [found: :found, not_found: :not_found],
    right: :read
end
