defmodule AtlasCodeBoundary.Code do
  @moduledoc """
  Code's boundary contract (Flow Engine plan §5, C1.0): what a caller next to Code may ask
  of it, in Code's own words. It starts with resolving a reference and creating a
  snapshot; reading snapshots, changes and reviews join it later.

  A caller sees repository names, reference names, `sha256:` snapshot IDs and opaque
  `rev_<64 hex>` revision handles; commits, remotes and Git output stay inside Code. A
  refusal is an outcome of its own, named after its reason, with a message and the values
  it concerns. Declarations only: the generator (`AtlasCodeBoundary.Generator.Schema`)
  turns them into `__schema__/0`.
  """
  use AtlasCodeBoundary.Generator.Schema

  version "0.1.0"

  ## Values

  # One repository of a snapshot: a revision handle of it, placed at a relative path.
  defmodel :snapshot_repository do
    field :repository, :string, required: true
    field :revision, :string, required: true
    field :path, :string, required: true
  end

  # Content of a revision that Code does not snapshot.
  defmodel :unsupported_entry do
    field :repository, :string, required: true
    field :path, :string, required: true

    field :reason, {:enum, [:unsafe_path, :symlink_target, :submodule, :unsupported_mode]},
      required: true
  end

  # Why Code refuses, and the values the refusal concerns (those that apply).
  defmodel :problem do
    field :message, :string, required: true
    field :repository, :string
    field :reference, :string
    field :revision, :string
    field :path, :string
    field :paths, {:list, :string}
    field :entries, {:list, :unsupported_entry}
  end

  ## Inputs

  defmodel :resolve_reference_input do
    field :repository, :string, required: true
    # A branch name.
    field :reference, :string, required: true
  end

  defmodel :create_snapshot_input do
    # At least one; paths unique and none inside another.
    field :repositories, {:list, :snapshot_repository}, required: true
  end

  ## Outcomes

  defmodel :resolved_reference do
    field :repository, :string, required: true
    field :reference, :string, required: true
    # The handle of the branch's current commit; it never changes.
    field :revision, :string, required: true
  end

  defmodel :snapshot do
    # sha256:<64 hex>, the digest of the snapshot's manifest.
    field :snapshot_id, :string, required: true
    # The input's repositories, ordered by path.
    field :repositories, {:list, :snapshot_repository}, required: true
  end

  ## Capabilities

  defcapability :resolve_reference,
    input: :resolve_reference_input,
    outcomes: [
      resolved: :resolved_reference,
      invalid_request: :problem,
      forbidden: :problem,
      unknown_reference: :problem,
      provider_unavailable: :problem
    ],
    right: :snapshot

  defcapability :create_snapshot,
    input: :create_snapshot_input,
    outcomes: [
      created: :snapshot,
      invalid_request: :problem,
      forbidden: :problem,
      unknown_revision: :problem,
      repository_mismatch: :problem,
      not_found: :problem,
      unsupported_content: :problem,
      provider_unavailable: :problem
    ],
    right: :snapshot
end
