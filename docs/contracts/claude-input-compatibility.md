# Claude input compatibility (IS-Atlas-107)

**Result: unsupported for Atlas queued guidance.** Literal framing and UUID
correlation have pinned source evidence; native durable admission/query, restart
deduplication and recoverable consumed evidence remain unproved. This is a bounded
compatibility finding, not a claim that Claude can never support the contract.

No live input callback is added. The current Claude adapter still closes stdin,
uses --no-session-persistence, and defaults unsupported through Agent's optional
interface. Start/stop, broker, sandbox, actor/environment, tool allowlist and
budget/model settings are unchanged. No OMP adoption, SDK dependency, model call,
session resurrection or Runtime receipt integration is introduced. IS108 owns
admission and Facts receipt writes.

## Pinned evidence

Candidate local packages identify Claude Code **2.1.280**, darwin-arm64. The native
entry is 217254576 bytes, SHA-256
`387a5c5dcdbb815085edf0baf79591f9d8894efe922bceaf3d75b1b08055229d`.
Only metadata and bytes were read; the native executable was not launched, including
help/version. This identifies a candidate artifact, not a tested native runtime.

Protocol evidence is first-party **@anthropic-ai/claude-agent-sdk 0.3.280**, matched
to its [release commit 58d2e4b](https://github.com/anthropics/claude-agent-sdk-typescript/blob/58d2e4b81bdca2c6ce10e6e5db22ad7acdc1d58c/CHANGELOG.md).
The public npm tarball was inspected without installation or execution; SHA-512
integrity matched registry metadata. The checked-in [profile](../../beam/apps/atlas_runtime/test/fixtures/claude_2_1_280/profile.json)
records that integrity and SDK type/bundle SHA-256 hashes. CI uses synthetic fixtures,
with no network or native Claude dependency. The SDK is not vendored or imported.

The pinned SDKUserMessage shape includes type=user, typed text content, a UUID and
optional session ID. Its client_composed field and verbatimPrompts serialization
preserve supplied text without slash dispatch or @path expansion on the documented
CLI versions. That mode also suppresses the turn-start attachment pass; future live
adoption must assess that context effect rather than substituting it for current
authority controls. These are source claims plus an offline byte-preservation test,
not observations from an executed native session. [Published 0.3.280 package](https://www.npmjs.com/package/@anthropic-ai/claude-agent-sdk/v/0.3.280)

SDKUserMessageReplay identifies user echoes with isReplay. Assistant/result types
carry user_message_uuid and a bounded user_message_uuids list that can correlate
batched or folded inputs. The probe recognizes those separately from echoes; it
does not discard this evidence or incorrectly assert that correlation is absent.
The same pinned types are the source of these fixture fields. Current CLI docs
describe replay-user-messages as acknowledgment, not a restart-safe receipt.
[CLI reference](https://code.claude.com/docs/en/cli-reference)

## Compatibility result

| Requirement | Evidence and result |
|---|---|
| Literal JSON transport | Source-derived client_composed=true frame; newline, slash, Unicode, quotes and shell-looking body round-trip byte-for-byte through a private fake |
| Exact correlation | UUID/session candidates and scalar/batch result correlation recognized in synthetic event projections; no native execution verified |
| Durable acceptance/query | No established local-stdin authoritative inbox lookup for the exact Atlas identity after response loss |
| Restart deduplication | A client UUID/transcript is not itself a proved native same-ID immutable-body dedup contract across process loss |
| Consumed-at-safe-boundary proof | Source correlation is promising, but restart-recoverable native evidence/query for this Atlas attempt is not established |
| Authority | Existing adapter and broker remain unchanged; the probe never sends tool approvals, control commands, model changes or interrupts |

The SDK's getSessionMessages reads transcript history and documents empty results
when a session is missing. That is not definitive non-admission; current Atlas also
disables native session persistence. Interrupt queue snapshots would interrupt work
and are not a passive admission query. Hosted bridge delivery APIs require a separate
server/auth/lifecycle boundary; they are not adopted as a local stdin guarantee.

A private wrapper inbox can durably enqueue once, as IS106 proves. It cannot decide
whether to reinject after “pipe write may have happened, native reply was lost”
without an authoritative native dedup/query guarantee. Neither echo, generic output,
model text, EOF nor a session ID resolves that window. Capability version 1 requires
the complete evidence set, so Claude guidance stays unsupported. Concrete gaps for
coordinator: native durable admission lookup, restart-safe same-ID deduplication,
and durable consumed-evidence lookup tied to the original Atlas turn/attempt.

## Offline proof and limits

The test-only probe holds one immutable pending request. It encodes only the pinned
user fields; Atlas environment/worker/turn/attempt stay in its local fixture mapping,
not invented native metadata. After a send, an exact retry remains uncertain without
a second frame; changed payload/target conflicts. Recovery is explicitly unsupported.
This is conservative probe behavior, not a production durable dedup implementation.

The fixed Python fixture accepts no executable selection and never starts Claude.
It records one input and emits synthetic projections of the pinned echo/result/control
fields. Projections omit unused SDK fields and are neither captured native transcripts
nor full-schema validation. Correlation becomes a bounded observation only; every
verdict still says durable admission and consumption are unproved.

Tests cover duplicate echoes, scalar/batch correlation, subagent isolation, wrong
UUID/session, malformed/unsolicited frames, permission requests, EOF after input,
truncated response, split UTF-8/coalesced lines and overflow. Request budget stays
24 KiB; encoded input line 32 KiB; pending input/response buffer 64 KiB; verdict 8 KiB.
No unbounded transcript is accumulated. Parsing errors latch and cannot produce a
receipt. Existing Claude/broker authority regressions remain required.

No acceptance or live activation follows from this result. A real supported profile
needs native evidence for the identified gaps; IS108 must preserve uncertainty and
refuse retargeting while those gaps remain.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
