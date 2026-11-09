# Durable exact-turn guidance (IS-Atlas-105 / IS-Atlas-109)

**Interactions are channel messages.** Everything a person or agent says to another (guidance, questions and answers, questions between workers, handoffs, review findings, rework input, PR comments) is stored as a message in a Rela Channel on the work item it is about, never in a custom entity or record. Conversations run over the protocol: which execution and attempt may receive a message, fencing, and the receipts that prove arrival are Atlas protocol records, never channel messages. They carry the message's id and digest, do not hold its text, and never interpret it. Message text never decides anything: Flow and Runtime act only on typed operations.

This is the target rule, not today's behaviour. Today's guidance (the Rela `interaction` entity, with `worker_execution` and `interaction_receipt`) and Runtime's question, peer-question and handoff records predate it. They migrate as the channels migration design specifies; until then this contract describes the current store.

The selected description maps execution, interaction and receipt roles to kinds and
properties. Foundation supplies the three immutable entities. No organisation-specific work kinds
appear in the BEAM protocol; existing turn/Assignment links resolve the work item.

All writes travel over Bus to Facts, using an operation and semantic values.
Execution registration requires the durable running turn, worker, machine and
attempt. Only the owning Runtime machine or exact turn endpoint may register it
or publish receipts. The Bus link binds remote machine identity. Fenced turn
machine/attempt fields cannot be replaced through generic Facts writes. A failed
turn read refuses before ordinary storage. Only confirmed absence permits new turn
creation; successfully read unfenced turns retain compatibility. IS-108 introduces
their Runtime fences.

Confirmed absence alone does not authorize deleting a turn. Facts retains deletion
provenance in its private ledger: the full effective request (environment, Bus
sender, kind, payload) and the authorized machine/attempt/version. After ordinary
validation, this intent is synced immediately before the backend delete. Stored
acknowledgement and completion evidence are recorded together. Exact retries recover
the original acknowledgement/position after confirmed absence; a fresh envelope for
the same proven request can acknowledge absence without another backend mutation.
A crash after backend commit but before acknowledgement is recovered from the
synced intent. Unavailable/failed reads still refuse before any cached answer.
Changed sender/target/payload cannot borrow an old request id or deletion proof;
a reappearing target or replacement attempt cannot receive an old deletion. Old
unbound ledger entries are not guessed into authority. An already answered but
unbound id conflicts before either a present-target cache lookup or an absent-target
proof can bind it, including ordinary acknowledgements created by Facts as it is now.
The original answer stays unchanged and no deletion binding is added. Only an unused
id or an exact bound deletion request can enter those recovery paths.
This adds private ledger
keys, not schema entities or a data conversion.

Interaction submission also carries by, asserted by an admitted Control session.
Facts refuses injected actor/environment/timestamp/position values. This retains
the existing admitted-client identity model. Local BEAM applications are trusted.
Control derives the client actor and checks current eligibility as described below.

Facts refuses ordinary CRUD on these roles. Identity scopes are:
- execution: environment, turn, attempt;
- interaction: environment, actor, client key;
- receipt: environment, interaction, evidence ID.

Atomic backend create claims the identity. On an existing key Facts compares the
complete immutable payload, including body bytes, target, mode and cause. Identical
replay returns the original record and current receipts; changed payload conflicts.
A new client key deliberately makes another interaction. No expiry or purge exists.

Facts reserves durable ordering before storage and persists the position with each
record. Gaps are allowed. A lost storage response cannot change its creation position.
Writer and payload checks precede every reply, bypassing the envelope answer cache.

Queued requires the stored interaction and a capable execution descriptor. Delivered
requires an admission ID; acknowledged requires admission and consumption IDs. Other
receipt stages require reasons. Runtime obtains these proofs from the adapter in
IS-108; output and socket writes prove neither. Canonical receipt writer is the
owning Runtime machine, allowing recovery from its exact turn or reconciler endpoint.

Projection preserves proven queued/delivered/acknowledged stage, independent
uncertainty and stale/unsupported/rejected closures. Late evidence never regresses
proof. Contradictory admission identities flag uncertainty. Uncertainty is conservative
and remains in history after proof improves. Historical evidence stays on its
original attempt; receipts change no ownership, leases, outcomes or acceptance.
Control checks live eligibility; harness admission and reconciliation require Runtime's lifecycle.

Interaction create/replay/exact reads return immutable identity, a bounded projection
and receipt_count, never an embedded evidence history. Read the receipt role with
interaction=<key> and optional after_position/limit to traverse retained evidence.
Interaction pages select execution=<key>. Both collections are ordered by durable
Facts position, at most 100 records and 64 KiB of encoded JSON payload per page;
after_position/more continue after the last included record. Byte limits can make a
page shorter than its requested record count. The whole retained history stays
immutable; no evidence is purged or truncated to satisfy response limits.

Stored execution/receipt records are limited to 8 KiB each; interaction records to
32 KiB, measured as encoded JSON including server metadata and identity (both
semantic and mapped forms). Oversized writes refuse with record_too_large before
backend creation. Identical retries retain the original metadata: growth in the
newly reserved position cannot invalidate an already admitted boundary record.
Exact record reads enforce those bounds too. An out-of-contract
oversized retained record fails visibly rather than returning a non-advancing empty
page or silently discarding its contents. Summary projections retain only bounded
proof/uncertainty/closure state, regardless of evidence count. Control wraps Facts
positions in execution- and viewer-scoped opaque cursors.

The current backend still scans collections internally; indexed storage can replace
that through Facts/Rela. Response bounds are not an indexed-query guarantee. All
receipts remain durable history, separate from future bounded token output.

The schema adds three kinds and optional turn attempt. Tests preserve every previous
definition and field order. No migration is required; closure/provenance packaging
includes the additions. Tests use private synthetic disk stores and pinned HTTP rela,
concurrent barriers and a deterministic loss after storage/before response. No models
or production data participate. Real harness delivery still requires a Runtime
that registers attempts and reconciles interactions and receipts.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>

## Control worker access and guidance

`AtlasBFFContract.Wire.Control.Workers` owns these six durable Control operations:
`worker_overview`, `worker_inspect`, `worker_submit`, `worker_query`,
`worker_history` and `worker_receipts`. Each request carries `channel: "control"`,
`version: "0.1.0"` and a correlation `id`; results and errors retain that id.
The exact target is the shared nested `runtime_execution`: worker
`{environment, machine, worker}`, plus `turn` and `attempt`. Missing fences,
unknown fields and unsupported versions refuse; Control never invents an attempt
or redirects guidance to a replacement.

Access is an environment setting and defaults to denied. Configure separate named
admitted actor keys, not actor kinds, under `control.workers` in the environment's
settings (`env/<env>.json`, or the settings file an instance runs on, such as
`fly/test/core.json`); `config/runtime.exs` hands them to Control:

```json
{
  "control": {
    "workers": {
      "read": {"actors": ["H-1", "H-2"]},
      "submit": {"actors": ["H-1"]}
    }
  }
}
```

The execution/interaction/receipt mappings stay the model's (`guidance`); the
grants are not part of it. Read permits worker inspection and retained history.
Submit is independent. Missing, malformed or unlisted grants deny; Control also
confirms the admitted actor still exists in Facts. Request payloads cannot choose
the actor. This retains the admitted-Control-session trust model, not a new
authentication mechanism. No production grants are enabled by this change.

A new submission requires the exact registered descriptor and current turn:
same machine, worker and attempt, running, no outcome, unexpired lease, exactly
one running turn for that worker, and current item ownership without pending
handover. The descriptor must report version-1 queued-input, durable accept-query
and consumption-evidence support. Unsupported capability remains visible but cannot
send. Missing/unfenced running executions fail visibly rather than appearing ready.

Authorized exact-target views expose the stored turn reason as optional
`worker_view.reason`, read through the model's turn mapping (`runtime turn: why:`).
Worker details and unavailable-guidance pages display it as **State reason** beside
the exact state. This is distinct from `guidance.reason`, which still explains send
eligibility (for example `stale_execution`); it never grants guidance capability.
Forbidden or mismatched targets do not disclose the state or its reason.

Guidance contains only `client_key`, literal `body` and `cause`. Slash-prefixed
text is not a Runtime command. A stored Facts interaction means queued, never
delivered. Exact same-key retries return the original immutable interaction even
after the turn closes; different body, cause or target conflicts. Control never
automatically resends a guidance write. An acknowledgement timeout reports
`outcome_unknown`; `worker_query` with the original actor/client key and target
recovers the durable outcome without replay.

History and receipt responses request at most 50 Facts records and retain Facts'
64-KiB page bounds. Cursors bind environment, viewer, execution and, for receipts,
interaction. They are pagination state, not authorization credentials. Queries
never turn another actor's submission into the caller's. Historical evidence
remains readable after closure, independently of current send eligibility.

Existing generic list/item/form blocks expose `/workers`,
`/workers/:machine/:worker/:turn/:attempt` and the corresponding `/guidance` form.
The detail includes item title/link, harness/version, separately configured and
reported model, activity, lease and confirmation time. Unknown reported model or
activity timestamp stays unknown; confirmation time is not an activity heartbeat.
The generic detail shows the first bounded history page and explicitly indicates
more; typed history/receipt operations traverse all retained evidence. Full
conversation rendering and live token output are separate client work.
Shell configuration may include a `/workers` tab without introducing a new block.

`beam/integration/worker_control.exs` exercises actual TCP Control sessions,
Bus and Facts with a private durable synthetic backend. Its e2e entry point is
`e2e/test/worker_control_test.exs`. It proves named grants, exact fencing, literal
form submission, two-client history, duplicate conflicts, scoped paging, reconnect,
unsupported adapters and recovery after a real post-commit lost acknowledgement.
This is an automated test fixture, not a required local Runtime installation.
Runtime output production is separate from durable guidance acceptance. A readable
output ring does not establish queued-input support or prove guidance consumption.

## Bounded worker output and conversation actions (IS-Atlas-110 / IS-Atlas-111)

`worker_output_subscribe`, `worker_output_next` and `worker_output_unsubscribe`
use a separate admitted Control connection with the same typed request correlation.
The first valid output operation reserves that connection for output; ordinary
commands and guidance stay on the main connection. Each subscribe and next request
reauthorizes the exact execution through Facts before reading Runtime. Missing
permission never returns a worker view.

Control addresses `request` envelopes of kind `runtime.output` to
`runtime@<machine>/output`. The authenticated Bus link permits only the designated
machine endpoint and `control/*` request senders; Runtime answers preserve the
request ID. Control checks sender, address, environment, ID and typed execution.
Output creates no Facts facts, positions or hints.

Each connection owns one active subscription. Aggregate admission is limited to
128 viewers; process death and unsubscribe release admission. Output connections
expire after 60 seconds without a valid output request. Runtime reads have a
2-second deadline and socket writes a 1-second deadline. Active-once socket reads
bound in-flight dispatch; slow viewers cannot queue output requests in another
viewer's session. Connection-local authenticated tokens let repeated unsubscribe
remain harmless even after a newer subscription replaces the old one, without
retaining an unbounded tombstone list. Reconnect uses a fresh connection/token
and the last accepted opaque output cursor.

Output cursors never substitute for durable-history cursors. Retention gaps,
epoch changes and missing rings remain explicit; reset-bearing replies include a
fresh independently confirmed worker view. Missing output is unavailable, not an
empty successful stream. `stream.ended` closes only the ephemeral producer, not the
authoritative worker lifecycle. Detach and reads neither stop workers nor renew
their leases. Detail-page output availability is probed only after authorization
against the exact existing ring; overview does not serially probe every Runtime.

Worker pages preserve `worker`, `guidance-history` and `worker-output` boundaries
with existing Worker/Conversation parts. Server-declared history, selected-history
receipt and capability-gated output actions remain the authority for operations,
targets and legends. Clients may advance only a successfully correlated history
cursor and bind receipts only to a selected record for that same execution; they
may narrow availability but never enable undeclared operations.

`guidance-history` is a native List of the first bounded history page. Each row's
id is the durable interaction key, its label is the literal body, and its
destination is the existing exact worker-detail route. A nonempty list enables
the ordinary declared row navigation; empty history enables neither row movement
nor receipt inspection. `guidance-details` retains literal bodies and recorded
identity/projection evidence as generic Item content, before the separate output
block. Console may extend the same list with successfully correlated later pages;
it must still bind receipts only to a selected loaded record for the exact execution.

Focused Control output tests cover ownership, revoked access, reset facts, missing
rings, invalid cursors, correlation and admission cleanup. The private
`beam/integration/worker_control.exs` path also exercises real TCP Control, Bus,
Facts and Runtime output store/endpoint delivery with two viewers, retention gaps,
forbidden-view suppression, invalid-cursor refusal, continued production after
unsubscribe, and explicit epoch reset after replacing only the private output
store/endpoint. This is not a claim that the full Console conversation acceptance
or deployed behavior has been verified.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
