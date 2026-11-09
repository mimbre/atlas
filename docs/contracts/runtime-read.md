# Runtime read API (`runtime.read/1`)

A read-only, UI-independent view of a standalone Runtime: worker overview, exact turn
identity, status and activity, execution events, retained public output and terminal
results. It needs neither Atlas Server nor a Runtime client library; viewers such as the
local Prism viewer (`clients/viewer`) and independent macOS clients consume the same contract.

## Transport

- `<runtime home>/read.sock`, a Unix socket with mode `0600`, beside `runtime.sock`.
- One JSON object per line, one request per connection; the reply is one JSON line.
- No subscription or push. Clients poll with cursors and reconnect at will.
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
| `read_failed` | Runtime could not read its own records |

## Projections

A **worker** is `{worker_id, state, turn}` for each worker registered since the service
started. A restarted service starts with none, and earlier turns remain in `turns`.
`events_cursor` is the events position as of the overview, for reading what follows it.

A **turn summary** has only these fields; absent values are `null` or omitted:

- `turn_id`, `worker_id`, `source_turn_id` (the turn it continued), and `attempt`: the
  Server attempt of a Server-reported turn, otherwise `null`.
- `state`: `running`, `finished`, `failed`, `stopped` or `unknown`. A turn saved as running
  by a service that is gone is `unknown` with `recorded_state: "running"`.
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
`peer_worker_id`, `peer_source_turn_id` and `response_turn_id`. Session IDs and record
references are omitted. `execution_finished` is not task verification.

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

## Not part of this contract

Starting, stopping, continuing or assigning work, answering questions, handoffs,
preferences, publishing and orchestration; progress percentages; remote access or hosting;
HTTP; authentication; and any viewer UI.
