# Runtime guidance boundary (IS-Atlas-108)

Runtime stores a fresh turn attempt and an immutable execution through Facts/Bus before
calling an adapter's `start`. A missing/unknown execution acknowledgement is recovered
only by exact environment + turn + attempt lookup and complete metadata comparison.
Unconfirmed registration does not start an adapter. Legacy descriptions with no guidance
section retain ordinary turn behavior; partial guidance mappings fail closed.

The supplied configuration selects execution/interaction/receipt kinds and fields. Runtime
uses the existing Flow description's ownership, open-state and handover fields; it does
not call Flow internals or choose an owner. No new conversation store is introduced.

## Typed adapter boundary

The IS106 capability/accept/query interface remains available. Runtime additionally needs:

| Call | Meaning |
| --- | --- |
| `describe(context, opts)` | Side-effect-free metadata before any adapter/model start |
| `accept(pid, immutable_request, deadline_ms)` | Exact-target literal admission with a typed deadline |
| `close_input(pid)` | Serialize closure against new admission; historical proof remains queryable |
| `recover_input(context, opts)` | Open existing evidence without starting a model, creating history or activating an attempt |

Context binds environment, machine, worker (`agent`), turn (`key`) and attempt. Admission
requests retain IS106's immutable environment/worker/turn/attempt/interaction/body/mode
shape and bounds. Deadline is separate machine control, not part of the user's body or
immutable submission identity. Control calls, task text, and correlated outbound evidence
are distinct typed channels even if a later JSON transport multiplexes them. Runtime does
not parse chat or activity for control authority. These calls are a small adapter boundary,
not a second communication framework; IS126 can supply shared DSL definitions later.

Missing callbacks default to unsupported. Configured Stub and Claude still do not expose
native guidance admission. The durable private fake is available only through explicit
test dependency injection, never through the installed port catalogue. Claude's IS107
native durable admission/query/consumption gaps remain unresolved; **real Claude Send is
unsupported**. There is no model launch in these tests, no OMP adoption or live activation.

## Reconciliation and bounds

A Turn reconciles one Facts interaction per round, periodically and on hints. Cursor wrap
revisits pending inputs; losing it is safe. Interaction pages are exact-execution scoped,
count/byte bounded by Facts. Nested receipts are a fixed-size projection; immutable full
receipt history retains its existing bounded pagination. Runtime stores no separate body
or receipt history.

Before new admission Runtime queries the original native identity. Only explicit
`not_admitted` permits dispatch after fresh eligibility reads. Unknown/unavailable history
is uncertainty, never absence. Evidence must match the full identity and live capability
metadata; an event is just a wakeup to query, even if its payload looks like a receipt.

Fresh eligibility requires the original running machine/attempt/worker/item, no outcome,
one authoritative owner, an open item, no handover barrier, an unexpired persisted lease
and remaining local silence/max budget. A held handover pauses admission. Confirmed
absence, closure, replacement, ownership loss or expiration closes the original target;
read failure does not. Existing terminal closures prohibit later admission even if an
owner is restored. No input is resolved onto a successor turn.

Stable evidence IDs make replay of a receipt idempotent after a lost Facts reply. Native
admission produces delivered; correlated durable consumption produces acknowledged.
Uncertainty and closure remain alongside the last proven stage. Guidance and receipts
never update activity, leases, assignment, expected work or turn budget.

## Exact linearization limits

There is **no atomic Facts-to-harness transaction** in this slice. The order is:

1. Turn reads Facts eligibility and computes the minimum lease/silence/max deadline.
2. Turn invokes the typed native admission call, serialized with its other local work.
3. The private fake's GenServer checks active/open exact identity, named-history binding
   and deadline immediately before inserting/syncing its immutable admission record.
4. Runtime records historical proof through Bus and rechecks eligibility. If that recheck
   is closed, paused or unavailable, it also records uncertainty.

The fake's admission gate check is its linearization boundary. Deadline is checked before
the durable write, not a promise about wall-clock time when a delayed disk sync finishes.
An accept already running finishes before a queued close call; a completed close prohibits
subsequent new admission. Turn messages and fake inbox calls are individually serialized.
They do not serialize an independently committed Facts outcome/ownership change with the
native write. The deterministic concurrent-closure test deliberately commits an outcome
between dispatch and the native gate: historical admission is retained as delivered plus
uncertainty. It does **not** assert that the closure prevented that admission.

These are private protocol proofs, not a claim that any real harness supplies the same
guarantees. A stronger native/Facts admission fence, if required for future enabled input,
needs its own contract against Flow/outcome changes. Coordinator/t0029 received this
boundary; native Rela channels/hooks alone cannot substitute for admission or receipt
proof. No native cutover or Flow ownership offload is implemented here.

## Closure and restart

Local finish closes native input before stop/end, then reconciles at most one page. It
never drains a queue to keep a worker alive. Remaining history is reconciled by Engine,
one ended turn/page per round. Orphan turns are ended first; historical recovery is a
separate explicitly model-free call, never fallback `start`. It cannot resurrect an old
attempt. Startup and historical recovery use the same complete adapter option builder
(agent configuration, paths, environment/client options and explicit private adapter
options). Recovery receives the immutable execution descriptor and first checks its
original exact identity/model/capabilities against the current binding. Changed model or
descriptor provenance fails closed before opening native history; `unknown` is not a
wildcard. Restoring a matching binding can recover retained proof without rewriting the
execution or clearing earlier uncertainty. The fake monitors its owner, retains closed tombstones and named-file guards,
and opens recovery with admission/consumption disabled. Opening an old attempt's history
cannot close or activate a different current attempt.

Missing/replaced named history produces uncertainty while preserving archived evidence.
This provides no distributed ownership or broad power-loss guarantee. Historical native
proof remains attributed to its original execution; absent old input becomes stale and
never migrates. Existing immutable facts and artifacts are retained.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
