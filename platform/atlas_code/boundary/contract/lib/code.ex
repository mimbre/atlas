defmodule AtlasCodeBoundary.Code do
  @moduledoc """
  Code's boundary contract (Flow Engine plan §5, C1.0): what a caller next to Code may ask
  of it, in Code's own words: resolving a reference, creating a snapshot (C1.0) and reading
  one, its manifest and its blobs (C1a); changes and reviews join it later.

  A caller sees repository names, reference names, `sha256:` snapshot IDs and opaque
  `rev_<64 hex>` revision handles; commits, remotes and Git output stay inside Code. A
  refusal is an outcome of its own, named after its reason, with a message and the values
  it concerns. A blob's bytes come as a stream of chunks, read only as the caller reads
  them, so no file is held whole. Declarations only: the generator (`AtlasCodeBoundary.Generator.Schema`)
  turns them into `__schema__/0`.
  """
  use AtlasCodeBoundary.Generator.Schema

  version "0.2.0"

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
    field :snapshot_id, :string
    field :sha256, :string
    # A superseded snapshot's successor, when Code knows it.
    field :successor, :string
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

  defmodel :get_manifest_input do
    field :snapshot_id, :string, required: true
  end

  defmodel :get_blob_input do
    field :snapshot_id, :string, required: true
    # 64 lowercase hex characters: the sha256 of an entry of the snapshot's manifest.
    field :sha256, :string, required: true
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

  # One file or symlink of a snapshot, at its path in the snapshot's tree.
  defmodel :manifest_entry do
    field :repository, :string, required: true
    # The repository's snapshot path, then the entry's path inside the repository.
    field :path, :string, required: true
    field :kind, {:enum, [:file, :symlink]}, required: true
    # "100644" or "100755" for a file, "120000" for a symlink.
    field :mode, :string, required: true
    # Of the blob: a file's bytes as stored, or a symlink's target.
    field :size, :integer, required: true
    field :sha256, :string, required: true
    # A symlink's target (relative, inside its repository).
    field :target, :string
  end

  # What a snapshot holds. Without `snapshot_id`, its canonical JSON (keys sorted) is the
  # document the snapshot ID is the digest of.
  defmodel :manifest do
    field :snapshot_id, :string, required: true
    field :version, :integer, required: true
    field :repositories, {:list, :snapshot_repository}, required: true
    # Ordered by path.
    field :entries, {:list, :manifest_entry}, required: true
  end

  # One blob of a snapshot: its bytes as a stream of binary chunks (at most 64 KiB each),
  # read from Code only as the receiver enumerates it, and again on each enumeration.
  defmodel :blob do
    field :sha256, :string, required: true
    field :size, :integer, required: true
    field :content, :stream, required: true
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

  defcapability :get_manifest,
    input: :get_manifest_input,
    outcomes: [
      manifest: :manifest,
      invalid_request: :problem,
      not_found: :problem,
      snapshot_superseded: :problem
    ],
    right: :snapshot

  # The repository's revision is fetched into Code's cache when it is not there, so the
  # refusals of reaching it apply too.
  defcapability :get_blob,
    input: :get_blob_input,
    outcomes: [
      blob: :blob,
      invalid_request: :problem,
      not_found: :problem,
      snapshot_superseded: :problem,
      forbidden: :problem,
      unknown_revision: :problem,
      repository_mismatch: :problem,
      provider_unavailable: :problem
    ],
    right: :snapshot
end
