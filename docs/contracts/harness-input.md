# Harness input contract (IS-Atlas-106)

`AtlasRuntime.Agent` keeps start/stop and adds optional capabilities/accept/query
callbacks, accessed through the corresponding Agent wrappers. Missing, partial or
unknown-version capabilities mean unsupported. Stub and Claude are unchanged and
remain unsupported for guidance. The private fake is absent from the configured
port catalogue. This contract adds no Bus listener, Facts receipt writer, model call,
Runtime reconciliation or Control/TUI input path. IS108 owns those admission checks.

Capabilities version `1` requires queued_input, durable_accept_query,
consumption_evidence and literal_text, all true, plus both input callbacks. Harness
and version labels are bounded; configured and reported model remain distinct and
unknown is nil. Only declared public descriptor fields leave the wrapper. Normalized
activity has a version, status/output/tool kind and UTF-8 summary of at most 1 KiB;
it never counts as input evidence. Publishers must choose safe summaries.

Input is a string-keyed map: environment, worker, turn, attempt, interaction, body,
mode. Every identity field is nonempty UTF-8, at most 256 bytes. Mode is
queued_guidance. Body is nonempty literal UTF-8, including slash-prefixed lines,
quotes and shell-looking text. Nothing interprets it as commands or interrupts;
stop remains a separate operation. Encoded input is at most 24 KiB. Unknown fields
and malformed identities refuse before adapter invocation.

Query supplies only the five identity fields. Admission/query returns one of:

- `{:ok, evidence}`: exact identity, admitted/consumed stage and stable admission ID;
  consumed additionally requires its stable consumption ID.
- `{:not_admitted, exact_identity}`: query-only definitive absence from an intact
  authoritative inbox. It is never inferred from timeout, missing storage or error.
- `{:error, reason}`: unsupported, conflict, stale, invalid input/identity,
  wrong environment, record too large, unavailable or uncertain. Unknown errors,
  malformed/mismatched/oversized replies and callback exits become uncertain.

Descriptor and evidence responses are capped at 8 KiB encoded JSON, matching IS105
execution/receipt limits. Errors are bounded atoms. An uncertain accept may have
committed: retain the exact request and query its original identity, never silently
retarget or invent a fresh interaction. These are adapter proofs, not Facts receipts
or proof that a model understood, obeyed or completed anything.

## Private fake inbox

`Agent.FakeInbox.start/2` accepts an exact synthetic turn/attempt/environment/machine
and a private inbox directory. First creation requires initialize: true on an empty
directory; reopening requires both the immutable identity marker and intact DETS
history. Missing/corrupt history refuses uncertain, including when initialize is
mistakenly repeated. Store repair is disabled. Environment and machine are pinned
in the marker and metadata; another scope cannot reuse the inbox.

A physical-directory identity lock prevents duplicate owners, including symlink
aliases, on one BEAM node. This is a private process protocol, not an inter-host
or independent-VM lock. One owner serializes immutable claims by interaction ID
across every retained attempt. Same full request returns original evidence; changed
body/mode/target conflicts or refuses without another admission. Different IDs may
intentionally contain the same body.

Admission is synced before its response. consume/2 is an explicit synthetic safe
boundary: it syncs a consumption proof before notifying the owner via
`{:agent, pid, {:guidance, evidence}}`. Query recovers lost responses/notifications.
Repeated consume returns the same proof without another notification. context_input/2
inspects one consumed literal text (at most the admitted input bound), not an
unbounded context/history response. The fake transition has no model/external side
effect; it does not establish exactly-once model execution.

close_attempt/1 durably closes admission/consumption and retains a tombstone. A
successor may use the same inbox only after closure, retaining all old immutable
records. A closed attempt cannot be resurrected. Old evidence stays queryable and
exact retries recover their original proof without new injection. No pruning.

Each retained request/evidence record is capped at 32 KiB encoded JSON, reserving
consumption-proof space at initial admission. All records are checked when reopened;
collection scanning is internal, with no unbounded public history response. Storage
failure latches uncertainty until restart; it never becomes authoritative absence.

The live owner pins the physical directory and named regular history/marker files
by device/inode, plus the marker's identity bytes. It validates that binding before
and after calls, and around admission/consumption barriers before writing or emitting
success. Moving or replacing either named file, or changing marker identity, latches
uncertainty even when DETS still serves its old open handle. Restoring the original
binding does not clear the latch; restart must validate the retained history again.
No archive is deleted, repaired, relabelled or implicitly initialized. A transition
already synced before binding loss can be recovered after restoration/restart, but
cannot emit a successful reply or consumption notification once loss is detected.
These checks cover partial named-history loss; they are not an external-writer lock
or a guarantee against arbitrary deletion after the final check/response.

Deterministic private barriers exist before/after admission and consumption to test
process-crash windows. Synced DETS plus an identity marker proves these process/reply
boundaries, not arbitrary power loss, rollback/deletion of all storage, distributed
allocation or external-harness deduplication. Real harness compatibility is IS107;
durable Runtime execution registration, fences, authority and Facts receipts are
IS108. No live adapter is enabled by this issue.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
