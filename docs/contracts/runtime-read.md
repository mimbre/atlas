# Runtime read API (`runtime.read/1`)

A read-only, UI-independent view of a standalone Runtime: worker overview, exact turn
identity, status and activity, execution events, retained public output and terminal
results. It needs neither Atlas Server nor a Runtime client library; viewers such as the
local Prism viewer (`clients/viewer`) and independent macOS clients consume the same contract.

## Transport

- `<runtime home>/read.sock`, a Unix socket with mode `0600`, beside `runtime.sock`.
- One JSON object per line, one request per connection; the reply is one JSON line, except
  for `follow`, whose reply is a stream of lines on the same connection (see "Follow").
- Clients poll with cursors, or `follow` execution events, and reconnect at will.
- The socket exists while the service runs. Its file mode limits it to the Runtime's user;
  it is not an authentication or authorization layer.

`read.sock` cannot change anything: it admits only the operations below, and the service
answers them from its state without dispatching a command. `runtime.sock`, the CLI and
Atlas Server reporting are unchanged.

## Requests and replies

Request: `{"api": "runtime.read/1", "op": OP, ...fields}`. Reply: `{"api", "op", ...result}`,
or `{"api", "error": {"code", "message"}}`.

| `op` | Fields | Result |
|---|---|---|
| `workers` | none | `service` (`running`/`stopping`), `workers`, `events_cursor` |
| `turns` | none | `turns`: turn summaries, newest first |
| `turn` | `turn_id` | `turn`: summary plus `answer`, `answer_truncated` |
| `events` | `cursor?`, `limit?` (1..100, default 50) | `events`, `cursor`, `more`, `recording_started_at`, `reset?` |
| `follow` | `cursor?` | a stream of frames, below |
| `output` | `turn_id`, `cursor?` | `stream`, `events`, `cursor`, `more`, `reset?` |

Error codes:

| Code | Meaning |
|---|---|
| `not_a_read` | No `op`, or an `op` that is not a read, including every `runtime.sock` command |
| `unsupported_api` | A read `op` without `api: "runtime.read/1"` |
| `invalid_request` | Not a JSON object, unknown or missing fields, or invalid values |
| `unknown_turn` | No turn with this ID |
| `invalid_cursor` | A malformed cursor, or one past the stream's end |
| `output_unavailable` | No output is retained for this turn |
| `too_many_followers` | 32 `follow` connections are already open |
| `read_failed` | Runtime could not read its own records |

## Projections

A **worker** is `{worker_id, state, turn}` for each worker registered since the service
started. A restarted service starts with none, and earlier turns remain in `turns`.
`events_cursor` is the events position as of the overview, for reading what follows it.

A **turn summary** has only these fields; absent values are `null` or omitted:

- `turn_id`, `worker_id`, `source_turn_id` (the turn it continued), and `attempt`: the
  Server attempt of a Server-reported turn, otherwise `null`.
- `state`: `running`, `stopping`, `killing`, `finished`, `failed`, `stopped`, `killed` or
  `unknown`. A turn saved as running, stopping or killing by a service that is gone is
  `unknown` with that `recorded_state`. At start, a service ends such a turn whose process is
  provably gone (its recorded PID runs no process and leads no process group, or now belongs
  to a process started at another time): `failed`, an `error` beginning `interrupted:`, that
  `recorded_state`, and one `execution_failed` event with `interruption: "service_restart"`.
  A turn whose process may still run stays.
- `backend`, `requested_model`, `model` (as confirmed), `questions_enabled`.
- `pending_question`: `{question_id, revision}` or `null`; question text is not returned.
- `started_at`, `ended_at`, `activity` (the latest generic activity summary while live,
  or the last checkpointed summary after restart), `result`, `error`. Historical
  activity is not evidence that the worker is still running; use `state`.

These fields are not returned: the assignment, working directory, permissions or sandbox,
repository, native session ID, artifact paths, backend selection and quota, request IDs and
Server configuration. Native records (`stream.jsonl`) are never returned.

`turn` adds `answer`, the turn's `answer.txt` (or `null`), up to 1 MiB on a UTF-8 boundary,
with `answer_truncated` when it was longer.

**Payloads.** `answer`, `result`, `error` and output event text are what the worker or
provider produced. They are returned as is and may contain paths or other user content.

An **execution event** has `sequence`, `kind`, `turn_id`, `worker_id` and `timestamp`, plus,
where the event has them, `backend`, `model`, `operation`, `question_id`, `revision`,
`peer_worker_id`, `peer_source_turn_id`, `response_turn_id` and `interruption`. Session IDs
and record references are omitted. `interruption` is `"service_restart"` only on the
`execution_failed` of a turn a starting service ended because the service that ran it was
gone and so was its process; an ordinary failure has no `interruption`. `execution_finished` is not task verification.

## Cursors, reconnect and gaps

Cursors are opaque. Keep the last one received and send it on the next read, on any
connection. A read returns only what follows the cursor; `more` means another page is ready.

Both streams report loss the same way, as a `reset` before the earliest retained events:

- `{"reason": "retention_gap", "from_sequence", "to_sequence"}`: these inclusive sequences
  were dropped before this reader saw them. A first read without a cursor reports one when
  earlier events were already dropped.
- `{"reason": "epoch_changed"}`: the cursor belongs to a replaced stream; what was lost is
  unknown.

**Events** are the durable journal (`execution-events.json`, the newest 256 events). Its
cursor survives service restarts. Restart recovery adds `question_invalidated` events for
turns whose service ended.

**Output** is the bounded, ephemeral public projection (`text`/`activity` with `text`, or
`tool` with `tool_name` and `status`), with the limits and `stream` fields of
`AtlasRuntime.Output`. Here, `stream` is `{turn_id, worker_id, epoch, first_sequence,
watermark, ended}`. `ended` means the producer closed the stream, not that the turn
completed; read `turn` for that. Output is lost when the service process exits, and expires
15 minutes after a turn ends; reads then return `output_unavailable`. Durable terminal
results stay available through `turn`.

A turn reported to Atlas Server keeps its output under its exact Server identity, which the
Bus output endpoint also serves. Any other turn's output is kept under a local identity in
a separate buffer that only `read.sock` reads. It is never reported or served over Bus.

## Follow

`{"api": "runtime.read/1", "op": "follow", "cursor"?: C}` keeps the connection open and
pushes execution events as the service records them. There is no `limit`; pages hold up
to 100 events. Admission is as for the other operations; an error (`invalid_request`,
`invalid_cursor`, `too_many_followers`) is one error line, then the connection closes.

Each frame is one line with `"api": "runtime.read/1", "op": "follow"` and a `type`:

| `type` | Fields | When |
|---|---|---|
| `page` | the `events` result: `events`, `cursor`, `more`, `recording_started_at`, `reset?` | first, then whenever events were recorded |
| `heartbeat` | `cursor` | 15 s without a page, once the service answered a read |
| `end` | `reason`: `service_stopping`, `service_unresponsive` or `too_slow` | before the Runtime closes the stream, best effort |

- **At least once, in order.** Every event after the cursor arrives at least once, in
  strictly increasing `sequence` within one epoch, unless retention dropped it, which a
  `reset` reports exactly as for `events`. Keep the last `cursor` after handling a page and
  reconnect with it; duplicates occur only after a reconnect. There is no order across
  epochs: after `epoch_changed`, reconcile from `turns` and `workers`.
- **Liveness.** Each heartbeat is preceded by a page read the service must answer within
  5 s; otherwise the stream ends with `service_unresponsive`. A heartbeat therefore means
  the service answered within the last 20 s.
- **Slow readers.** A reader that does not take a line within 5 s is closed (`too_slow`,
  best effort); the service itself never waits for a follower.
- **Closing.** Any input after the request closes the connection. A service stop ends the
  stream with `service_stopping`. From then until the Runtime exits, a new `follow` gets
  only that `end` line, never a page, so a reconnect does not find a stopping Runtime
  reachable. EOF without `end` means the Runtime is gone or unreachable.

Frames are transport, not journal events, and are never persisted. `follow` is read-only
like every operation here: it starts, stops, answers, acknowledges and restarts nothing.

## Not part of this contract

Starting, stopping, continuing or assigning work, answering questions, handoffs,
preferences, publishing and orchestration; progress percentages; remote access or hosting;
HTTP; authentication; and any viewer UI.
