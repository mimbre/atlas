defmodule AtlasRuntimeBoundary.WorkSource do
  @moduledoc """
  The Runtime's work source contract (decision 2026-11-17-work-acquisition §5, migration
  step M1): how a Runtime gets its work, in the Runtime's own words. The Runtime calls;
  the source answers. A source is the built-in local one (in the Runtime's BEAM) or a
  remote one the Runtime dials out to; Flow is one, and translates its tasks into work on
  its own side. The contract knows nothing of Flow.

  Vocabulary (§5.1): a source offers **work** under its own stable `work_key`; a **lease**
  is the right of one Runtime to run one attempt of one work until `expires_at`; a
  **report** is a state change of a lease (`accepted`, `refused`, `started`, `ended`);
  the **holdings** are the leases a Runtime holds, from its persisted state.

  Capabilities (§5.2): `poll` (a long-poll, at most `poll_max` seconds; the heartbeat and
  the cancel channel at once), `report`, `get_blob` and `put_blob`. The caller is the
  Runtime, received as an opaque `client` holding the right `lease`.

  Fencing (§5.3): every write is conditional on the lease being the work's current,
  unexpired one. A stale lease's `report` or `put_blob` answers `lease_lost`, and so does
  an `accepted` that arrives after the source's accept deadline (30 s). `poll` renews
  only the current, unexpired leases among the holdings and answers every other one in
  `lease_lost`.

  Blobs (§3 F6, §5.2, §6.2): `get_blob` serves only blobs the current lease's input names
  (its manifests and the blobs their write entries name); `put_blob` takes only blobs the
  lease's recorded `ended` manifest references (`not_referenced` otherwise) and answers
  `too_large` past the source's caps, counted while the bytes stream in. Visibility is per
  source: a Runtime downloads every input blob from the source that names it, and never
  reuses one another source supplied.

  The request offered has no `slot`, `folder`, `resume_from` or `repository`: those are
  for the local source only, which adds them through the Runtime CLI, not through this
  contract. No path on the Runtime's machine crosses it.

  Declarations only: the generator (`AtlasRuntimeBoundary.Generator.Schema`) turns them
  into `__schema__/0`. `put_blob` takes its bytes as a `:stream` input field (an upload).
  """
  use AtlasRuntimeBoundary.Generator.Schema

  # 0.2.0: change_set declares its base (required), which the Runtime always sent and
  # needs back on import. 0.3.0: a work's input may name a result_ref (the result over Git).
  version("0.3.0")

  # The Runtime's own enumerations (as in the work contract, which this one does not name).
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
  @permissions [:"read-only", :"workspace-write"]

  ## Client

  # The calling Runtime: opaque. A remote source knows it by its per-Runtime credential.
  defmodel :client do
    field(:id, :string, required: true)
    field(:rights, {:list, {:enum, [:lease]}}, required: true)
  end

  ## poll (§5.2)

  defmodel :poll_input do
    field(:runtime_id, :string, required: true)
    # New on every boot of the Runtime (§5.3 item 5).
    field(:incarnation, :string, required: true)
    field(:build, :string, required: true)
    field(:policy_version, :integer, required: true)
    # The Runtime's free slots and the execution profiles it can serve now (Main's O1): each
    # available profile names the same total, which is what the source may lease in all, not
    # per profile. Empty when full. The Runtime keeps one poll open, even when full.
    field(:offer, {:map, :integer}, required: true)
    field(:holdings, {:list, :holding}, required: true)
  end

  # A lease the Runtime holds, as its persisted state has it.
  defmodel :holding do
    field(:lease_id, :string, required: true)
    field(:state, {:enum, @attempt_states}, required: true)
    # The last harness event or output byte.
    field(:last_progress_at, :datetime)
  end

  # The answer comes early when there is a lease or a cancel, else at poll_max.
  defmodel :polled do
    # New leases, each within the offer.
    field(:leases, {:list, :lease}, required: true)
    # Held leases to cancel (§3.7 cancel stages); still current until the work ends.
    field(:cancel, {:list, :string}, required: true)
    # Holdings that are not, or no longer, current: the Runtime cancels their attempts.
    field(:lease_lost, {:list, :string}, required: true)
    field(:timing, :timing, required: true)
  end

  # Seconds. A lease not renewed for lease_ttl is self-fenced by the Runtime (§5.3 item 2).
  defmodel :timing do
    field(:lease_ttl, :integer, required: true, range: 1..86_400)
    field(:poll_max, :integer, required: true, range: 1..25)
  end

  defmodel :lease do
    # Made by the source; opaque. The Runtime's client key for the work (I3).
    field(:lease_id, :string, required: true)
    field(:expires_at, :datetime, required: true)
    field(:work, :offered_work, required: true)
  end

  ## Work as offered (§5.1): the work request without slot, folder, resume_from or
  ## repository.

  defmodel :offered_work do
    # The source's stable key for the work; the turn's idempotency key for outside effects.
    field(:work_key, :string, required: true)
    field(:title, :string, required: true)
    # The text the agent receives.
    field(:instructions, :string, required: true)
    # An execution profile of the Runtime's policy.
    field(:profile, :string, required: true)
    field(:cost_class, {:enum, [:low, :standard, :high]}, required: true)
    field(:input, :work_input, required: true)
    field(:after_check, :after_check)
  end

  # A base, optionally with a frozen change set on top (from_work across machines). Its
  # blobs come from the same source (F6). result_ref: when given, the result goes back over
  # Git, not as a change set: the Runtime commits its folder on the base's commit and pushes
  # it to the source's Code under this ref, and its ended report carries no change set.
  defmodel :work_input do
    field(:base, :base_ref, required: true)
    field(:change_set, :change_set_ref)
    field(:permissions, {:enum, @permissions}, required: true)
    field(:result_ref, :string)
  end

  # manifest: the sha256 of the blob that holds the base's entries in the change-set
  # entry shape; get_blob serves it and every blob its write entries name.
  defmodel :base_ref do
    field(:base_id, :string, required: true)
    field(:manifest, :string, required: true)
  end

  # manifest: as for a base. fingerprints: each root's csf_ fingerprint, checked against
  # the change set when it is imported.
  defmodel :change_set_ref do
    field(:manifest, :string, required: true)
    field(:fingerprints, {:list, :root_fingerprint}, required: true)
  end

  defmodel :root_fingerprint do
    field(:root, :string, required: true)
    field(:fingerprint, :string, required: true)
  end

  # An argv list, never a shell line; timeout in seconds, within the Runtime's cap.
  defmodel :after_check do
    field(:command, {:list, :string}, required: true)
    field(:timeout, :integer)
  end

  ## report (§5.2, §5.3)

  # revision: 1 for the first report of a lease, then +1 for each. A report sent again
  # with the same revision and content is recorded again (idempotent); any other revision
  # than the last recorded one or the next is rejected as a conflict.
  defmodel :report_input do
    field(:lease_id, :string, required: true)
    field(:revision, :integer, required: true, range: 1..2_147_483_647)

    field(:report, {:one_of, [:accepted, :refused, :started, :ended], tag: :state},
      required: true
    )
  end

  # The lease's work is persisted under it; the attempt starts only after recorded.
  defmodel :accepted do
  end

  # The Runtime's policy does not take the lease's work.
  defmodel :refused do
    field(
      :reason,
      {:enum,
       [
         :not_permitted,
         :invalid,
         :unsupported_workspace,
         :policy_forbids,
         :no_permitted_option,
         :too_large
       ]},
      required: true
    )

    # Never a path on the Runtime's machine.
    field(:detail, :string)
  end

  defmodel :started do
  end

  # change_set: the attempt's frozen result, when it produced one. Its write entries'
  # blobs are what put_blob may upload.
  defmodel :ended do
    field(:result, :result, required: true)
    # One record per turn.
    field(:provenance, {:list, :provenance}, required: true)
    field(:change_set, :change_set)
  end

  defmodel :result do
    field(:kind, {:enum, @result_kinds}, required: true)

    field(
      :reason,
      {:enum,
       [
         :time_limit,
         :quota,
         :launch,
         :workspace,
         :model_changed,
         :cancel,
         :superseded,
         :runtime_stop,
         :lease_lost
       ]}
    )

    # Advice; retries belong to the source (I4).
    field(:retryable, :boolean, required: true)
    field(:never_started, :boolean, required: true)
    # The final agent message, at most 8 KB.
    field(:answer, :string)
    field(:check, :check_result)
  end

  # The after-check's outcome (§3.10).
  defmodel :check_result do
    field(:command, {:list, :string}, required: true)
    field(:exit_status, :integer)
    field(:signal, :string)
    field(:error, {:enum, [:sandbox_unavailable, :leaves_folder, :not_found, :helper_failed]})
    field(:timed_out, :boolean, required: true)
    field(:duration_ms, :integer, required: true)
    field(:output_tail, :string, required: true)
  end

  defmodel :provenance do
    field(:provider, :string, required: true)
    field(:harness, :string, required: true)
    field(:harness_version, :string)
    field(:runtime_build, :string, required: true)
    field(:machine, :string, required: true)
    field(:slot, :string, required: true)
    field(:configured_model, :string, required: true)
    field(:reported_model, :string)
    field(:profile, :string, required: true)
    field(:policy_version, :integer, required: true)
    field(:turn_id, :string, required: true)
    field(:started_at, :datetime, required: true)
    field(:ended_at, :datetime)
  end

  # The frozen result: its change set per root, each with its csf_ fingerprint.
  #
  # base: the id (sha256:<hex>) of the baseline snapshot the Runtime imported from the
  # work's input base and froze on; part of every root's csf_. It is content-derived and
  # deterministic: the sha256 of the canonical manifest of the served base's entries (roots,
  # paths, kinds, modes, sizes, sha256s, symlink targets) and nothing else: no Runtime home,
  # time, user, entry order or salt. So every Runtime that imports the same served base
  # reports the same base. It is not the input's base_id (the source's own name for what it
  # serves); a source stores it as reported, and a change set given back as a later work's
  # input must sit on exactly the base that work's input imports to.
  defmodel :change_set do
    field(:base, :string, required: true)
    field(:roots, {:list, :change_root}, required: true)
  end

  defmodel :change_root do
    field(:root, :string, required: true)
    field(:fingerprint, :string, required: true)
    field(:entries, {:list, :change_entry}, required: true)
  end

  # A write carries kind, mode, size and sha256 (and target for a symlink); a delete only
  # its path. Paths are relative to their root.
  defmodel :change_entry do
    field(:path, :string, required: true)
    field(:op, {:enum, [:write, :delete]}, required: true)
    field(:kind, {:enum, [:file, :symlink]})
    field(:mode, {:enum, [:"100644", :"100755", :"120000"]})
    field(:size, :integer)
    field(:sha256, :string)
    field(:target, :string)
  end

  # missing: for ended, the referenced blobs the source does not hold yet, each to be
  # sent with put_blob; empty for every other report.
  defmodel :recorded do
    field(:missing, {:list, :string}, required: true)
  end

  ## Blobs (§5.2)

  defmodel :get_blob_input do
    field(:lease_id, :string, required: true)
    field(:sha256, :string, required: true)
  end

  # One blob, as a byte stream; the Runtime checks its sha256 and size as it reads.
  defmodel :blob do
    field(:sha256, :string, required: true)
    field(:size, :integer, required: true)
    field(:content, :stream, required: true)
  end

  # size: the bytes the stream will carry, so a source can refuse too_large before reading;
  # it still counts while reading.
  defmodel :put_blob_input do
    field(:lease_id, :string, required: true)
    field(:sha256, :string, required: true)
    field(:size, :integer, required: true, range: 0..9_007_199_254_740_991)
    field(:content, :stream, required: true)
  end

  ## Outcomes shared by several capabilities

  # invalid: the input does not fit the contract. conflict: a report revision that is
  # neither the last recorded nor the next, or the same revision with another report.
  # digest_mismatch: put_blob's bytes do not have the given sha256 or size.
  defmodel :rejected do
    field(:reason, {:enum, [:invalid, :conflict, :digest_mismatch]}, required: true)
    field(:detail, :string)
  end

  ## Capabilities (§5.2)

  invalid_input(:rejected, set: [reason: :invalid], detail: :detail)

  defcapability(:poll,
    input: :poll_input,
    outcomes: [polled: :polled, rejected: :rejected],
    right: :lease
  )

  # lease_lost: the lease is not the work's current, unexpired one, or an accepted came
  # after the accept deadline. Nothing of it is recorded.
  defcapability(:report,
    input: :report_input,
    outcomes: [recorded: :recorded, lease_lost: nil, rejected: :rejected],
    right: :lease
  )

  # not_found: the lease is not current, its input names no such blob, or the source has
  # none. A blob is never found through another lease or another source.
  defcapability(:get_blob,
    input: :get_blob_input,
    outcomes: [blob: :blob, not_found: nil, rejected: :rejected],
    right: :lease
  )

  # Fenced first (lease_lost), then the reference (not_referenced: no recorded ended of
  # this lease references the blob), then the caps (too_large: past the per-result or the
  # store cap, also while the bytes stream in). Stored again is stored.
  defcapability(:put_blob,
    input: :put_blob_input,
    outcomes: [
      stored: nil,
      lease_lost: nil,
      too_large: nil,
      not_referenced: nil,
      rejected: :rejected
    ],
    right: :lease
  )
end
