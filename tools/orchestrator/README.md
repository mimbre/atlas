# Coordinator watcher

`atlas-watch.mjs` is the coordinator's Runtime and inbox watcher, loaded by the operator's inbox
extension (`atlas-inbox.mjs`, kept outside the repository). Plain Node 18+, no dependencies.

```sh
node --test tools/orchestrator/atlas-watch.test.mjs
```

## Behavior

- One long-running child follows `atlas-runtime events --follow [--cursor C]`
  ([Runtime README](../runtime/README.md)). Lines are handled as they arrive:
  - an event: `question_available` and `handoff_submitted` queue a `question`/`handoff`
    inspection; `execution_finished|failed|stopped|killed` record a terminal turn item;
  - `{"reset":R}` records one `gap` item and queues `service status` and `turns`;
  - `{"cursor":C}` becomes the saved cursor, persisted with the items before it;
  - `{"reachable":false,"reason":R}` raises the `unavailable` item; `{"reachable":true}` clears
    the state (the item stays until acknowledged) and lifts the query back-off.
  - Anything else records a `stream` item with the offending line.
- If the child exits, that is recorded as `unavailable` (or, for `invalid_cursor`, as a `gap`
  with the cursor dropped), and the next `check()` starts a new follower from the saved cursor.
  The watcher never starts the Runtime service or any worker; `close()` ends the follower.
- `check()` keeps the rest unchanged: inbox scan, up to eight bounded inspection queries per
  call, nudges every 120 s while items are pending. Only `ack()` clears an item.

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
   `import { createWatch } from '<atlas checkout>/tools/orchestrator/atlas-watch.mjs';`
   (or symlink the file next to the inbox).
2. Recommended: in `reset()` (session shutdown and role change), call `watch.close()` so the
   follower ends with the session. Otherwise it ends when the host process exits.

Discovery is pushed, but items still reach the coordinator on the inbox's 15 s `check()` tick,
which also runs the inspection queries.
