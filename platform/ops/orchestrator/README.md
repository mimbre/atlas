# Coordinator watcher

`atlas-watch.mjs` is the coordinator's Runtime and inbox watcher, loaded by the operator's inbox
extension (`atlas-inbox.mjs`, kept outside the repository). Plain Node 18+, no dependencies.

```sh
node --test platform/ops/orchestrator/atlas-watch.test.mjs
```

## Behavior

- One long-running child follows `atlas-runtime events --follow [--cursor C]`
  ([Runtime README](../../atlas_runtime/host/README.md)). Lines are handled as they arrive:
  - an event: `question_available` and `handoff_submitted` queue a `question`/`handoff`
    inspection; `execution_finished|failed|stopped|killed` record a terminal turn item, whose
    selector is `output --turn ID`;
  - `{"reset":R}` records one `gap` item and queues the reconcile (below);
  - `{"cursor":C}` becomes the saved cursor, persisted with the items before it;
  - `{"reachable":false,"reason":R}` raises the `unavailable` item; `{"reachable":true}` clears
    the state (the item stays until acknowledged) and lifts the query back-off.
  - Anything else records a `stream` item with the offending line.
- If the child exits, that is recorded as `unavailable` (or, for `invalid_cursor`, as a `gap`
  with the cursor dropped), and the next `check()` starts a new follower from the saved cursor.
  The watcher never starts the Runtime service or any worker; `close()` ends the follower.
- `check()` keeps the rest unchanged: inbox scan, up to eight bounded inspection queries per
  call (the replay's pages among them), nudges every 120 s while items are pending. Only
  `ack()` clears an item.
- **Reconcile** (on a fresh start and after every gap), as queued inspection queries:
  - `service status`: the reachability probe only. Since the operations cutover it answers the
    runtime info (`runtime_build`, `incarnation`, `mode`, `policy_version`, `slots`) from
    `backend.sock`; only that shape counts as reachable. `{"service":"stopped"}` (exit 0) and
    any other answer record `unavailable` and back off for 60 s.
  - `turns`: the Runtime's history contract on `backend.sock`, each turn's `slot`, `turn_id`
    and `state`. A turn whose state is one of the native outcomes (`finished`, `failed`,
    `stopped`, `killed`) records a terminal turn item; every turn queues a `handoff --worker
    <slot> --turn <turn_id>` inspection, the slot being the guidance worker name. A history
    turn carries no pending question, so `turns` queues no `question`. Turn identifiers that
    fail the pattern below record one `turns` item instead.
  - **the journal replay**: `events --limit 100`, which starts at the oldest retained entry, then
    `--cursor C` from each page while its `more` is true. It stops only on `more: false`, never
    on a short page. Each event goes through the same handling as a followed line, so pending
    questions (`question_available`), handoffs and terminal turns are found from the journal;
    `service status` no longer lists them. The replay's `reset` (the journal was pruned before
    its oldest entry) is expected and is not a gap.
  - A `question` inspection only records a question that is still `active` with admission
    `pending`, so replaying old questions records nothing. One the replay queued whose record
    is gone ("Question record unavailable") is recorded once as
    `missing_question:<turn>:<question>`, and does not start another replay. The same failure
    for a question from the live follow is a `gap`, as before, and so reconciles once.
  - Pending questions are found only from the journal: a question still pending after its
    `question_available` entry was pruned is not found (plan S2 RQ7, accepted).
- `events --follow` and the replay pages read the journal on `runtime.sock`; `turns` reads
  history on `backend.sock`. `question` and `handoff` stay on `runtime.sock`, `service status`
  is on `backend.sock`. The
  work commands (`start`, `status`, `output`, `stop`, …) are on `backend.sock` too; the watcher
  runs none of them, and an item's `output` selector is for the coordinator to run.

## Target

`agent-reports/atlas/inbox/.delivery/runtime-target.json` (re-read on every `check()`) selects
the Runtime. Without it: `atlas-runtime` from `PATH` and `ATLAS_RUNTIME_HOME` (default
`~/.local/state/atlas-runtime`).

```json
{"runtimeHome": "/Users/me/.local/state/atlas-runtime", "executable": "/usr/local/bin/atlas-runtime"}
{"runtimeHome": "/Users/me/.local/state/atlas-runtime", "command": ["/usr/bin/ssh", "mac-mini", "atlas-runtime"], "timeoutMs": 5000}
```

- `command` is the prefix for the follower and for every query (`[...command, "events",
  "--follow", ...]`); its first element must be absolute. It replaces `executable`.
- `runtimeHome` must be absolute. It keys the saved cursor and acknowledgement identities, and it
  is passed as `ATLAS_RUNTIME_HOME` to local children only; ssh does not forward it. For a
  non-default remote home, put it in the command: `["/usr/bin/ssh", "mac-mini", "env",
  "ATLAS_RUNTIME_HOME=/Users/me/rt", "atlas-runtime"]`.
- `timeoutMs` (100–30000, default 1500) bounds each inspection query, not the follower.
- Items from a `command` target carry that `command`, so the coordinator can run their selectors.
- Event identifiers and cursors must match `[A-Za-z0-9][A-Za-z0-9_.:-]*` because they pass
  through the remote shell; others are recorded as a `stream` item.

## Inbox compatibility

The interface `atlas-inbox.mjs` uses is unchanged: `createWatch(home)`, `check(ctx, pi, now?)`,
`ack(id, signature, resolution)`, and the saved state file. Two changes in the inbox:

1. Import from the repository:
   `import { createWatch } from '<atlas checkout>/platform/ops/orchestrator/atlas-watch.mjs';`
   (or symlink the file next to the inbox).
2. Recommended: in `reset()` (session shutdown and role change), call `watch.close()` so the
   follower ends with the session. Otherwise it ends when the host process exits.

Discovery is pushed, but items still reach the coordinator on the inbox's 15 s `check()` tick,
which also runs the inspection queries.
