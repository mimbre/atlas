defmodule AtlasCodeBoundary.Code do
  @moduledoc """
  Code's boundary contract (Flow Engine plan §5, C1.0): what a caller next to Code may ask
  of it, in Code's own words: resolving a reference, creating a snapshot (C1.0), reading
  one, its manifest and its blobs (C1a), and changing a snapshot's repository and putting
  that change up for review (C1b): a change is created, its blobs put and then sealed into
  a revision; a review of a sealed change opens it on the repository's provider (GitHub) and an
  update moves an open review to another sealed change. A review may open as a draft (Flow's
  publications, F3), which is marked ready once it is approved and green; its status reports
  the provider's approvals, requested changes and CI on the review's head (K2).

  A draft review is Flow's: Code opens it at a location of its own (`work/flow-review-<id>`, not
  the `work/review-<id>` of other reviews), so nothing but Flow, through Code's `integrate`
  effect, merges it, also after it is marked ready.

  A caller sees repository names, reference names, `sha256:` snapshot IDs and opaque
  `rev_<64 hex>` revision handles; commits, remotes and Git output stay inside Code. A
  refusal is an outcome of its own, named after its reason, with a message and the values
  it concerns. A blob's bytes come as a stream of chunks, read only as the caller reads
  them, so no file is held whole. Declarations only: the generator (`AtlasCodeBoundary.Generator.Schema`)
  turns them into `__schema__/0`.
  """
  use AtlasCodeBoundary.Generator.Schema

  version "0.4.0"

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

  # One entry of a change: a path of the repository, deleted, or written as a file
  # (`mode` "100644" or "100755", with the size and sha256 of its bytes) or as a symlink
  # (`mode` "120000", with its `target` and that target's size and sha256).
  defmodel :change_entry do
    # Relative to the repository's root.
    field :path, :string, required: true
    field :op, {:enum, [:write, :delete]}, required: true
    field :kind, {:enum, [:file, :symlink]}
    field :mode, :string
    field :size, :integer
    field :sha256, :string
    field :target, :string
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
    field :change_id, :string
    field :base_revision, :string
    # An entry of the input that Code refuses.
    field :entry, :change_entry
    # The sha256 of each blob a change still waits for.
    field :missing, {:list, :string}
    field :review_id, :string
    field :update_id, :string
    # The fingerprint of the change's content.
    field :fingerprint, :string
    # How far a review got: "pushed" when it is visible but not yet opened.
    field :phase, :string
    # The revision a moved review location is at now, when it still exists.
    field :current, :string
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

  defmodel :create_change_input do
    # A lowercase UUID the caller chooses; repeating the same input is the same change.
    field :change_id, :string, required: true
    field :snapshot_id, :string, required: true
    # A repository of the snapshot, and its revision there.
    field :repository, :string, required: true
    field :base_revision, :string, required: true
    # At least one; paths unique.
    field :entries, {:list, :change_entry}, required: true
  end

  defmodel :put_change_blob_input do
    field :change_id, :string, required: true
    field :sha256, :string, required: true
    # The blob's bytes, whole: any binary, not only text.
    field :content, :string, required: true
  end

  defmodel :seal_change_input do
    field :change_id, :string, required: true
  end

  defmodel :create_review_input do
    # A lowercase UUID the caller chooses; repeating the same input resumes the same review.
    field :review_id, :string, required: true
    # A sealed change.
    field :change_id, :string, required: true
    # The branch name the review asks to land on.
    field :target, :string, required: true
    # One line of at most 256 characters.
    field :title, :string, required: true
    # Carries the attribution "Written by an AI agent".
    field :body, :string, required: true
    # When given, the change's content must have this fingerprint.
    # Without it, Code does not check the content; Flow (F3) always passes the fingerprint it decided on.
    field :fingerprint, :string
    # true: the review opens as a draft, at Flow's own location (see the moduledoc). Left out
    # or false: a review ready at once, as before. Part of the request a repeat must match.
    field :draft, :boolean
  end

  defmodel :update_review_input do
    # A lowercase UUID the caller chooses; repeating the same input resumes the same update.
    field :update_id, :string, required: true
    # An open review.
    field :review_id, :string, required: true
    # A sealed change of the review's repository.
    field :change_id, :string, required: true
    # The review's current revision.
    field :revision, :string, required: true
    # The fingerprint of the change's content, decided on.
    field :fingerprint, :string, required: true
  end

  defmodel :mark_ready_input do
    # An open review.
    field :review_id, :string, required: true
  end

  defmodel :review_report_input do
    # An open review.
    field :review_id, :string, required: true
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

  # A change: open while it waits for blobs (`missing`), sealed once it is a revision.
  defmodel :change do
    field :change_id, :string, required: true
    field :state, {:enum, [:open, :sealed]}, required: true
    # Ordered; empty once every blob is there.
    field :missing, {:list, :string}, required: true
    # The handle of the sealed change; only when sealed.
    field :revision, :string
  end

  # An open review of a sealed change, at its current revision.
  defmodel :review do
    field :review_id, :string, required: true
    field :change_id, :string, required: true
    field :repository, :string, required: true
    field :target, :string, required: true
    field :revision, :string, required: true
    field :state, {:enum, [:open]}, required: true
    # The review's URL on the repository's provider, when the provider has one.
    field :link, :string
  end

  # A review moved to another sealed change: the review's revision before and after.
  defmodel :review_update do
    field :update_id, :string, required: true
    field :review_id, :string, required: true
    field :change_id, :string, required: true
    field :repository, :string, required: true
    field :previous_revision, :string, required: true
    field :revision, :string, required: true
    field :state, {:enum, [:open]}, required: true
    field :link, :string
  end

  # A review that is no longer a draft (or never was one).
  defmodel :review_ready do
    field :review_id, :string, required: true
    # The review's current revision.
    field :revision, :string, required: true
    field :link, :string
  end

  # What the review's provider holds of it now. Approvals, requested changes and CI are those
  # of the provider's head of the review, which `at_revision` says is the review's revision;
  # a review without a provider is open, without approvals and with CI `none`.
  defmodel :review_report do
    field :review_id, :string, required: true
    # The review's current revision, as Code moved it.
    field :revision, :string, required: true
    field :state, {:enum, [:open, :merged, :closed]}, required: true
    field :draft, :boolean, required: true
    # false when someone else moved the review's head: what follows is not about `revision`.
    field :at_revision, :boolean, required: true
    # As Code's integrate reads CI: success only when every check and status passed; none
    # when the review has no provider.
    field :ci, {:enum, [:success, :failure, :pending, :none]}, required: true
    # The names of the failed checks and statuses, sorted; only when `ci` is failure.
    field :failing, {:list, :string}
    # The reviewers whose latest review approves the head, sorted.
    field :approvals, {:list, :string}, required: true
    # The reviewers whose latest review asks for changes, sorted.
    field :changes_requested, {:list, :string}, required: true
    # Left out while the provider has not worked it out, and without a provider.
    field :mergeable, :boolean
    # Whether the target has moved on since the head; left out unless open on a provider.
    field :behind_base, :boolean
    field :link, :string
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

  # The change is checked against its base in the snapshot before it is recorded.
  defcapability :create_change,
    input: :create_change_input,
    outcomes: [
      change: :change,
      invalid_request: :problem,
      forbidden: :problem,
      not_found: :problem,
      snapshot_superseded: :problem,
      base_mismatch: :problem,
      conflict: :problem,
      unsupported_content: :problem
    ],
    right: :change

  defcapability :put_change_blob,
    input: :put_change_blob_input,
    outcomes: [
      change: :change,
      invalid_request: :problem,
      not_found: :problem
    ],
    right: :change

  # Sealing reaches the base revision (fetched into Code's cache when it is not there), so
  # the refusals of reaching it apply too. A sealed change seals again as itself.
  defcapability :seal_change,
    input: :seal_change_input,
    outcomes: [
      change: :change,
      invalid_request: :problem,
      not_found: :problem,
      incomplete_upload: :problem,
      forbidden: :problem,
      unknown_revision: :problem,
      repository_mismatch: :problem,
      provider_unavailable: :problem,
      conflict: :problem
    ],
    right: :change

  # Opens a review at a location only Code names, once: a repeat answers the open review
  # or resumes where the last attempt stopped (`review_incomplete`).
  defcapability :create_review,
    input: :create_review_input,
    outcomes: [
      review: :review,
      invalid_request: :problem,
      not_found: :problem,
      change_not_sealed: :problem,
      fingerprint_mismatch: :problem,
      forbidden: :problem,
      unknown_revision: :problem,
      repository_mismatch: :problem,
      conflict: :problem,
      location_taken: :problem,
      provider_unavailable: :problem,
      review_incomplete: :problem
    ],
    right: :review

  # Moves an open review to a sealed change; never overwrites a location someone else moved.
  defcapability :update_review,
    input: :update_review_input,
    outcomes: [
      updated: :review_update,
      invalid_request: :problem,
      not_found: :problem,
      review_not_open: :problem,
      change_not_sealed: :problem,
      repository_mismatch: :problem,
      revision_mismatch: :problem,
      fingerprint_mismatch: :problem,
      forbidden: :problem,
      unknown_revision: :problem,
      conflict: :problem,
      provider_unavailable: :problem,
      location_moved: :problem,
      update_refused: :problem
    ],
    right: :review

  # A draft review becomes ready for review, once: a repeat, or a review that never was a
  # draft, answers ready without changing it again.
  defcapability :mark_ready,
    input: :mark_ready_input,
    outcomes: [
      ready: :review_ready,
      invalid_request: :problem,
      not_found: :problem,
      review_not_open: :problem,
      forbidden: :problem,
      provider_unavailable: :problem
    ],
    right: :review

  # Reads only; changes nothing.
  defcapability :review_status,
    input: :review_report_input,
    outcomes: [
      report: :review_report,
      invalid_request: :problem,
      not_found: :problem,
      review_not_open: :problem,
      forbidden: :problem,
      provider_unavailable: :problem
    ],
    right: :review
end
