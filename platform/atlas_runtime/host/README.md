# Runtime service and CLI

One Go command-line client and a separate Elixir Runtime daemon that runs native agents (the official Codex and Claude CLIs) in slots. Clients submit **work**; the Runtime queues it, picks a slot and a harness under its human-owned [model policy](#model-policy), and runs one attempt at a time. No Atlas server connection, unless explicitly opted into [lifecycle reporting](#optional-atlas-server-lifecycle-reporting), and no orchestration. Runtime and Bus are the only Atlas applications started; Facts, Flow, Control and Rela are not started.

```sh
atlas-runtime service start
atlas-runtime start --profile deep_coding --cost-class standard --cwd /path/to/project --key task-1 "Read the project and explain its entry points"
atlas-runtime status --key task-1
atlas-runtime output --turn "$TURN_ID"
atlas-runtime stop --work "$WORK_ID"
atlas-runtime service stop
```

The service listens on two owner-only Unix sockets in its home:

| Socket | Serves | Until |
|---|---|---|
| `backend.sock` | The work contract over HTTP/1.1 (design "Runtime boundary contracts and Runtime backend", 2026-11-16, §8; `platform/atlas_runtime/backend/contract/lib/work_api.ex`): `start`, `continue`, `status`, `capacity`, `retry`, `stop`, `kill`, `output`. The operations contract (§13 S2; `backend/contract/lib/operations_api.ex`): `service status`, `service stop`, `service pause`/`resume`/`drain`, `preferences`, `release`. The history contract (`history_api.ex`): `turns`; also Learn and the viewer | — |
| `runtime.sock` | Guidance (`question`, `answer`, handoffs, peer correlation) and the journal: `events` and `events --follow`, as the `runtime.read/1` operations `events` and `follow`. It refuses the work commands, the operations (`service-status`, `service-stop`, `preferences`, `release`) and every other `runtime.read/1` operation (`not_journal`), and names where each went. | — |

Commands print one JSON response, except `events --follow`, which streams JSON lines. Command failures exit nonzero; a refusal of the work or operations contract prints its problem. `service status` prints the runtime info (see [Operations commands](#operations-commands-backendsock)); `service stop` returns once `backend.sock` is gone. No automatic daemon startup and no stdin session.

## Work commands (backend.sock)

| Command | Request | Answer |
|---|---|---|
| `start` | `POST /v1/work` | 201 the work (`accepted`), or 200 the same work for a repeated `--key` (`existing`) |
| `continue --resume-from TURN_ID` | `POST /v1/work` with `resume_from` | as `start` |
| `status` | `GET /v1/work` (`--state`, `--changed-since`), `GET /v1/work?key=` (`--key`) or `GET /v1/work/WORK_ID` (`--work`) | the list with its change `sequence`, or one work |
| `capacity` | `GET /v1/capacity` | slots, buffer, per-profile availability, `accepting`, `policy_version`, `incarnation` |
| `retry --work WORK_ID [--resume]` | `POST /v1/work/WORK_ID/attempts` | 201 the work with its next attempt |
| `stop --work WORK_ID` / `kill --work WORK_ID` | `POST /v1/work/WORK_ID/cancel`, `mode` `graceful` / `force` | 202 the work (`cancelling`, the attempt's `cancel_stage`), or 200 when it had already ended |
| `output --turn TURN_ID [--cursor C] [--follow]` | `GET /v1/turns/TURN_ID/output` | one page: `events` (`text` or `activity`), `cursor`, `more`, `ended`; with `--follow` every page from the cursor on, one JSON line each, until a page says `ended` (work contract 0.2.0; a Runtime whose pages lack `ended` is refused) |
| `turns` | `GET /v1/turns?limit=100`, then `&cursor=` until a page's `more` is false | `{"turns": [...]}`, every page in order; each turn `turn_id`, `slot`, `state`, `native_outcome`, `started_at`, `ended_at`, `harness`, `configured_model`, `reported_model`, `conversation_id` |
| `events [--cursor C] [--limit N] [--follow]` | `runtime.sock` `runtime.read/1` `events` / `follow` | see [Durable execution discovery](#durable-execution-discovery) |

```sh
atlas-runtime start --profile deep_coding --cost-class standard --cwd /abs/folder [--permissions read-only|workspace-write|materialized-folder] [--title TITLE] [--key KEY] [--slot SLOT] "assignment"
atlas-runtime start --profile deep_coding --cost-class standard --repo https://github.com/OWNER/REPO.git --branch NEW_BRANCH [--base develop] [--key KEY] "assignment"
atlas-runtime continue --resume-from TURN_ID --profile deep_coding --cost-class standard --cwd /abs/folder "next assignment"
atlas-runtime status [--work WORK_ID | --key KEY | --state running --changed-since 41]
atlas-runtime capacity
atlas-runtime retry --work WORK_ID [--resume]
atlas-runtime stop|kill --work WORK_ID [--reason TEXT]
atlas-runtime output --turn TURN_ID [--cursor CURSOR] [--follow]
```

- **The Runtime validates.** The CLI maps its flags onto one request as given and checks only what it needs to build it: one assignment, after the flags (`--` before one starting with a dash); a folder (`--cwd`, `--permissions`) or a repository (`--repo`, `--branch`, `--base`), not both; the work or turn a path names. A relative `--cwd` is made absolute. `--title` defaults to the assignment's first line, `--permissions` to `read-only`, `--base` to `develop` (the only base accepted). Everything else, including a missing profile or workspace and an unknown field, is the Runtime's answer.
- **A work states its needs, never a model.** `--profile` (for example `deep_coding`, `light_work`, `independent_review`) and `--cost-class` (`low`, `standard`, `high`) resolve through `policy.json`; there is no `--backend`, `--model` or `--sandbox`. The attempt's `provenance` records the harness, the configured and reported model and the `selection`.
- **Queued, not run.** `start` answers once the work is recorded, before its turn starts or ends: the work is added to the Runtime's built-in local work source, which hands it to the executor as any work source does (M2), under the same `work_id`. Follow it with `status`, `output --follow` and `events --follow`. While every slot is busy or its profile is out of quota, the work waits there, `buffered`. There is no other way in: while the Runtime takes no new work (paused, draining or stopping, or its policy's `sources` name no `local`), `start` answers `at-capacity` (HTTP 503) with reason `not_accepting`, `retry_after` and `capacity`; submit again after `retry_after`.
- **Client key.** `--key` is sent as `Idempotency-Key`. The same key with the same request returns the same work (200); with another request it is refused as `idempotency-conflict` (409). A lost reply is therefore safe to repeat. Without `--key` every `start` is a new work.
- **Slots.** The slots are `policy.json`'s `slots` (default `["default"]`); the Runtime picks a free one. `--slot` pins it and is available only to the socket's owner, a human at this machine. A continuation and a resumed retry run on their source turn's slot.
- **Continue and retry.** `continue --resume-from TURN_ID` is a new work that continues that turn's native conversation and workspace; it needs the same profile, cost class and workspace flags as `start`. `retry --work` queues the next attempt of an ended work at the local work source, under the same `work_id`; it waits for a slot like a new work. A work whose attempt has not ended is refused (`conflict`): stop it first. `--resume` continues an `interrupted` attempt's conversation, and a `resume-unavailable` refusal means: retry without it.
- **Cancel.** `stop` cancels gracefully: the turn's process group gets one SIGINT and is killed after the grace period (30 s); `kill` forces at once. A buffered work never starts. Both answer with the work; its current attempt shows `cancel_stage` (`requested`, `signalled`, `forced`) and ends `cancelled`.
- **Refusals** print the problem+json body plus `error`, and exit 1: `type` (`invalid`, `not-permitted`, `idempotency-conflict`, `policy-forbids`, `no-permitted-option`, `resume-unavailable`, `unsupported-workspace`, `at-capacity`, `not-found`, `pruned`), `status`, `reason` and `detail`. `not-found` means never seen; `pruned` means it existed, ended with `kind` and was pruned.
- **Plain HTTP** works the same: `curl --unix-socket "$ATLAS_RUNTIME_HOME/backend.sock" http://localhost/v1/capacity`. Every client of the socket is its owner, `local:<user>`, with every work right.
- **History.** `turns` is the history contract's `list_turns` (`GET /v1/turns`, also `GET /v1/turns/TURN_ID` for one turn). A turn's `slot` is the worker name `question`, `handoff` and the peer commands take as `--worker`. A turn holds metadata only: no assignment, result, answer, continued turn or pending question; read those with `output`, `handoff` and `question`. A turn from before work moved to `backend.sock` has no work record and is listed only to a client that may read all history, as the socket's owner may.

## Operations commands (backend.sock)

The operations contract (`platform/atlas_runtime/boundary/contract/lib/operations.ex`; design §13 S2, §13.1 Q4–Q9) inspects and operates the Runtime itself. The socket's owner holds both its rights, `inspect` and `operate`. `runtime.sock` refuses these commands and names the request below.

| Command | Request | Answer |
|---|---|---|
| `service status` | `GET /v1/runtime` | the runtime info: `mode` (`open`, `paused`, `draining`, `stopping`), `incarnation` (new on every boot), `runtime_build`, `policy_version`, `slots` (`name`, `busy`); `{"service":"stopped"}` when nothing answers on `backend.sock` |
| `service pause` / `resume` / `drain` | `POST /v1/control/pause` / `resume` / `drain` | 200 the runtime info, also when already in that mode |
| `service stop [--force]` | `POST /v1/control/stop`, body `{"force": false}` (`true` with `--force`) | 202 the runtime info (`mode: stopping`), also on a repeat; the CLI then waits until `backend.sock` is gone and adds `"service": "stopped"` |
| `service start` | — | starts the Runtime unless `backend.sock` answers; waits until `GET /v1/runtime` does |
| `preferences` | `GET /v1/policy` | the policy view: `version`, `changed_by`, `changed_at`, `buffer_size`, `independence`, and per profile its `permissions`, `cost_classes`, `limits` and `options` (`provider`, `harness`, `model`, `availability`) |
| `preferences --reenable HARNESS` | `POST /v1/harnesses/HARNESS/clear-quota-mark` | 200 `cleared` (also for a harness without a mark); 404 for an unknown harness |
| `service update --build BUILD` | `GET /v1/runtime`, `POST /v1/control/pause`/`resume`/`stop`, then the release | installs the released build BUILD and restarts the Runtime on it; refuses while a slot is busy or another update holds the lock (see [Upgrading through Atlas](#upgrading-through-atlas)) |
| `release --slot SLOT` | `POST /v1/slots/SLOT/release` | 200 `released` (also with nothing to release); 404 for a slot not in `policy.json`; 409 `slot-busy` while the slot's process is alive, printed as `slot busy: …` |

```sh
atlas-runtime service status
atlas-runtime service pause      # no new work and no new starts; running turns continue
atlas-runtime service drain      # also returns the accepted, unstarted work; stays draining until resume
atlas-runtime service resume
atlas-runtime service stop [--force]
atlas-runtime service update --build BUILD   # install a released build and restart on it
atlas-runtime preferences [--reenable HARNESS]
atlas-runtime release --slot SLOT
```

- **Modes.** `pause` takes no new work (`at-capacity`, `not_accepting`) and starts no buffered work, while `starting` and `running` turns continue. `drain` also takes no new work, returns every work the executor accepted from a work source and has not started (`returned`, `never_started`, retryable) and lets running turns finish; work still queued at the local source stays queued, and is handed over after `resume`. The Runtime stays `draining` until `resume`, also with an empty buffer. `drain` while paused returns the buffer; `pause` while draining gives `paused`. `resume` opens the Runtime again. The mode is kept in `mode.json` and outlasts a restart; `service stop` does not change it.
- **Stop.** The Runtime takes no new work and keeps the buffer. Without `--force` it cancels running turns through the cancel stages (SIGINT, then the kill after the grace period, 30 s); with `--force` it kills them at once. Their attempts end `interrupted`, reason `runtime_stop`, retryable, and the process exits. `service stop` returns 0 only once `backend.sock` is gone, and exits nonzero if it is still there after 60 s; run it again, with `--force` to kill the turns. It holds `service.lock`, as `service start` does. With nothing on `backend.sock` it prints `{"service":"stopped"}`.
- **Policy.** `preferences` only shows the policy; its `version` is the one in force. To change it, set the machinery's `configuration` through Control (see [Where the configuration is set: Control](#where-the-configuration-is-set-control)); without Control, edit `policy.json` locally and raise its `version`. `--preferred`, `--fallback` and their model flags are removed and exit nonzero naming `policy.json`. `--reenable HARNESS` clears a quota mark: an operational act, not a policy change.
- **Release** clears the slot's admission latch. If the slot's turn is `unknown` (a previous service left it without proof that it ended), it also marks the turn gone and its attempt quiescent, so the next buffered work can start there. It refuses with `slot busy` while the slot's process is alive, and starts nothing itself. `--worker` is removed from `release` and exits nonzero naming `--slot`; the guidance commands keep `--worker`.
- **Refusals** print the problem plus `error` and exit 1, as for the work commands: also `not-permitted` (403) for a missing right and `invalid` (400) for a bad input.
- **Plain HTTP:** `curl --unix-socket "$ATLAS_RUNTIME_HOME/backend.sock" http://localhost/v1/runtime`.

History readers on `backend.sock`: this CLI's `turns`, Learn (`platform/atlas_learn/lib/atlas_learn/observations/worker_passes.ex`, through OTP `:httpc`) and the viewer (`platform/atlas_runtime/viewer/lib/atlas_viewer/read_client.ex`, which also reads `GET /v1/runtime` and turn output). This CLI's `events [--follow]` reads the journal on `runtime.sock`. The coordinator watcher (`platform/ops/orchestrator/atlas-watch.mjs`) follows `events --follow` and reads `turns` and `events` pages, taking each turn's `slot` as its worker; its `service status` probe is on `backend.sock`.

The sections below describe how the Service runs turns. The work core drives them through the Service's own start, continue, stop and kill, with the slot as the worker and a request ID derived from the work and attempt. Their proof records, and some examples marked as such, come from before the cutover, when the CLI sent those commands on `runtime.sock` with `--worker`, `--backend`, `--sandbox`, `--request-id`, `--questions` and `output --follow`. `runtime.sock` now refuses them.

## No network listener

The service serves its backend on `backend.sock` only. The S3 loopback TCP listener, its `clients.json` and the mini runbook were removed before they were ever activated (work acquisition decision 2026-11-17, M0): a Runtime will get remote work only by pulling it from the work sources it is configured with, so no agent machine has a network listener.

This is enforced at start: the service runs without Mix (`elixir -pz/-pa … -r host/boot.exs host/service.exs`, because `mix run` opens Mix's PubSub loopback listener), and `service.exs` fails its start, before `backend.sock` serves and again before `Runtime ready`, when the VM owns any IP listen socket: inet ports of `gen_tcp`/`gen_sctp`, and `:socket` sockets of domain `inet`/`inet6` of any protocol (`AtlasRuntime.ListenerCheck`). A `:socket` the socket registry does not hold cannot be inspected, so it fails the start too. The log line holds only the reason and the ports: `Runtime not ready: {"ports":[…],"reason":"ip_listener"}` (or `{"reason":"unregistered_socket","sockets":N}`).

## Concurrent slots

```sh
atlas-runtime start --profile deep_coding --cost-class standard --slot server --repo https://github.com/eyra/atlas.git --branch work/server-task "Server assignment"
atlas-runtime start --profile deep_coding --cost-class standard --slot console --repo https://github.com/eyra/atlas.git --branch work/console-task "Console assignment"
atlas-runtime status --state running
```

Each slot is a Service worker with at most one active execution; slot names match `[a-z][a-z0-9_-]{0,63}` and come from `policy.json`. The work core starts a turn on a slot only once the slot's previous attempt is terminal and quiescent. `release --slot SLOT` (on `backend.sock`) names a slot. `turns` lists all slots' history; `events` remains one global ordered stream, with `worker_id` (the slot) on every new event. Older journal entries remain unchanged and unattributed.

The proofs below ran before the cutover, with `start --worker NAME`.

Real isolated public-CLI proof on 2026-11-07: Server `turn-849a0f44f47663c9`, Console `turn-711cf725b155be0f` and Runtime `turn-a7e5136ac3891023` each provisioned a separate clone/branch from base `568217bf7986b3f266be4df27fc121cb13200fb9`. All three real `claude-opus-5-5` sessions overlapped inside bounded Bash calls. Stopping Runtime removed its process group/private temp while Server and Console remained running, then independently finished with exact worker-specific file contents and answers. Events attributed accepted/finished/stopped transitions to the correct workers/turns. Ambiguous control, duplicate worker, workspace collision and mismatched saved ownership refused; repeated stop added no event.

After daemon restart, explicit Server continuation `turn-6f4aa53f92af74df` retained session `b400b621-68e0-488e-8d16-c95fec47e819`, model, cwd, repository and permissions, recalling the previous answer without tools. Targeted follow pinned worker/turn; replay from the prior global cursor returned only the continuation pair. The 39 focused ExUnit tests, 27 Python runner tests and Go CLI suite passed. All owned proof daemons/process groups/private temp directories were absent afterward; disposable binaries/builds were removed. That concurrent-worker proof did not exercise question/reply. Peer chat, scheduling, automatic recovery and Server/Console integration remain outside this capability.

## Stop, kill and release

```sh
atlas-runtime stop --work "$WORK_ID"
atlas-runtime kill --work "$WORK_ID"
atlas-runtime release --slot SLOT
atlas-runtime continue --resume-from "$TURN_ID" --profile deep_coding --cost-class standard --cwd /abs/folder "Continue from the current files"
```

A cancel of a running work reaches its turn as the Service's stop or kill below. `stop --work` sends the stop and, if the turn is still there after the grace period (30 s), the kill; `kill --work` sends the kill at once. The work core lifts the admission latch its own stops leave, once the attempt is settled and nothing else holds the slot; a latch from a model change or a service stop stays until `release`.

At the Service, a stop asks the turn's native process group to end: the host sends one SIGINT and never escalates. The turn is `stopping` until the leader is reaped and no live member remains in its process group; a native CLI or descendant that ignores SIGINT keeps it `stopping`, with the workspace lock held, indefinitely. `kill` sends SIGKILL to the group immediately; the turn is `killing` until the same confirmation. Kill wins: it is accepted while stopping, and a later stop neither downgrades it nor sends anything. The terminal states are `stopped` and `killed`, with `execution_stopped` and `execution_killed` events; `stopping` and `killing` are persisted in `turn.json` and status only, with no events. After accepting a stop or kill the host no longer decodes provider output: the bytes stay raw in `stream.jsonl`, so partial or invalid JSON written while ending cannot fail the turn. The host releases the directory lock, and removes its private temp or scratch, only after that confirmation. The worker folder, baseline, output and diagnostics are kept.

Both commands need the exact current turn of the named worker. A turn that already ended `stopped` or `killed` repeats idempotently; a finished, failed, replaced, unknown or foreign turn refuses without signalling. Repeated requests keep their first request time. The host signals once per control; a repeat re-attempts only a signal that was refused. The turn's `termination` record holds `mode`, `stop_requested_at`/`kill_requested_at`, `stop_signalled_at`/`kill_signalled_at`, `confirmed_at`, the leader's `exit_code`, `native_result` and the last signalling or termination `error`. A refused signal leaves the execution owned and running. If the host fails while stopping, the turn is `failed` with that error. If the execution ended before the host applied the control, it keeps its natural outcome (`finished` with its result, or `failed`) and the request stays recorded.

Before signalling, Runtime writes the worker's admission latch, `workers/<worker>/admission-latch.json`. While it exists, every new `start` and `continue` for that worker refuses, including after daemon restart. Only `release --slot SLOT` removes it. Release refuses (`slot busy`) while the slot's process is alive, is idempotent, and starts, resumes or reschedules nothing. A corrupt latch fails closed. `service status` shows whether each slot is busy.

`continue` accepts a `finished`, `stopped` or `killed` source turn that has a confirmed native session (and confirmed model and saved context, for Claude). It creates a new turn from the saved provider conversation and the files as they are now, including human edits made before the explicit continuation. It is not a frozen-process restore: the stopped native process is gone, and work that was in flight inside it is lost. After a daemon restart a turn left `stopping` or `killing` shows `state: "unknown"` with its `recorded_state`; nothing is owned or signalled, and the latch remains.

`service stop` cancels every running turn (see [Operations commands](#operations-commands-backendsock)); their attempts end `interrupted` with reason `runtime_stop`, and a later `retry --resume` continues them. Until the process exits, new work is answered `at-capacity` with reason `not_accepting`, and buffered work stays buffered.

Limits:

- The confirmation covers the owned process group. A descendant that leaves the group with `setsid`/`setpgid` (detached into its own session) is outside the group, outside Runtime's reach and is not confirmed gone. A focused host test shows such a descendant surviving `kill`.
- Parent loss (the daemon or Native process disappears and closes the host's control input) keeps the host's bounded cleanup: one SIGINT, then SIGKILL after 3 s, because nothing can follow or kill the execution afterwards. Natural completion also keeps its existing 3 s exit window, after which leftover group members are killed, unless a stop or kill was requested.
- Group liveness is probed with `kill(-pgid, 0)` after the leader is reaped, every 20 ms. As before, the group ID could in principle be reused once the group is empty.
- Server lifecycle reporting passes `why: "killed"` through as text. How Atlas Server and its consumers treat that value has not been verified.

## Lost-response-safe start and continuation

```sh
atlas-runtime start --key task-42 --profile deep_coding --cost-class standard --cwd /path/to/project "Explain the entry points"
atlas-runtime start --key task-42 --profile deep_coding --cost-class standard --cwd /path/to/project "Explain the entry points"   # same work
```

For a client, `--key` is the lost-response protection: see [Work commands](#work-commands-backendsock). Below it, the work core gives every attempt's Service start a request ID, `w` plus the first 63 hex digits of the SHA-256 of `WORK_ID:ATTEMPT`, so a core that crashes between asking and recording never starts a turn twice. The rest of this section describes those Service admissions; the examples of the time used a caller-supplied `--request-id`, which the CLI no longer has.

At the Service, a request ID is optional; Runtime never retries a command automatically. IDs match `[A-Za-z0-9][A-Za-z0-9_-]{0,63}` and share one namespace across start/continue in the selected Runtime home. Existing commands without an ID retain their response and execution behavior.

If the response is lost, repeat the same command with the same ID. Its recorded admission returns without launching or resuming again, including while running, after completion, and after daemon restart. Assignment bytes remain exact; cwd aliases resolve canonically; omitted read-only sandbox and disabled-question defaults normalize. Explicit versus omitted worker, source turn and backend selectors remain distinct. The first admission pins the resolved worker/source turn, cwd, scope, repository and provider/model/session settings. Later worker registrations, saved-turn changes, policy and quota changes do not redirect a repeated command. Different valid caller intent under the same ID conflicts; malformed requests refuse. A new ID represents a separate explicit assignment, not recovery of a lost reply.

ID-bearing responses contain `request_id`, `admission`, `worker_id`, `turn_id`, `source_turn_id`, `recorded_result` and `requires_reconciliation`. `accepted` means native startup returned and Runtime persisted the turn/lifecycle admission before acknowledging. `recorded_result` is the immutable original admission snapshot, **not current status or verified task success**. Use targeted `status`, `output --turn`, `turns` and events for later evidence. New turn metadata also retains `request_id`.

Runtime reserves an `indeterminate` record before native startup. A launch failure or crash before acceptance can leave that state even if native execution happened. Its result remains null and `requires_reconciliation` remains true; identical retries return the uncertainty and never launch again. Inspect the recorded turn/artifacts and reconcile native ownership/effects before deciding on another assignment. Do not delete the admission to force a retry. Restart restores no worker or native process and never promotes an uncertain reservation by guessing from other files.

Records use bounded atomic JSON replacement at `admissions/<request-id>.json`: canonical requests are limited to 128 KiB, records to 1 MiB, with the planned result checked before launch. Corrupt records and unresolved temporary-only records fail closed. This relies on one daemon owning its state directory and retained admission files; it is not a distributed lock, fsync/power-loss guarantee or exactly-once provider-execution claim.

Real isolated public-CLI proof on 2026-11-07: request `Start_e0c8f2df4a4eea72` admitted only `turn-6d7fa4cdd96b84f7`. Explicit continuation `Continue_591e244adc78e4af` admitted only `turn-cf73e2ca48188090`, retained session `269badfc-2733-4ca8-9d44-3ada8691f7c9` and recalled the conversation-only marker `ADMISSION_239ddf30c505`. Both ran with native `claude-opus-5-5[1m]`, without a model preference override. Identical repeats while running, after completion and across restart returned the original snapshots. Changed assignment/source IDs conflicted. Both admissions remained queryable after deleting the disposable cwd, while a new ID refused that missing cwd. History held exactly two turns, one session and four unchanged lifecycle events; restart replay left workers empty. Both native groups and all three owned daemons were absent afterward; disposable client/build/workspace were removed and evidence retained.

Focused verification passed: 103 ExUnit tests, 47 Python runner tests and the Go CLI suite. Deterministic native fixtures count actual launches/resumes across concurrent retries, conflicts, changed context, lost callers, startup failure, post-launch journal/acceptance-write failure and restart uncertainty. Managed saved-continuation metadata retains its base revision. This slice does not add automated reconciliation, cross-daemon coordination, provider fallback retries or Atlas integration.

## Explicit completion and PR handoff

```sh
atlas-runtime output --turn "$TURN_ID"
atlas-runtime submit-handoff --worker runtime --turn "$TURN_ID" --handoff "$HANDOFF_JSON"
atlas-runtime handoff --worker runtime --turn "$TURN_ID"
```

Do not build `HANDOFF_JSON` from `status`: its `result` is a summary cut to 2,000 characters, so a longer declaration may be truncated there. Take the full native final answer from the `answer` field of `output --turn`, then parse and validate the actual declaration before submitting it. `output` only reads the answer; it never creates a handoff.

The supported route is an **external coordinator submitting worker declarations** through the existing owner-only CLI/socket. Runtime does not expose that socket to native workers or expand their sandbox. A first submission requires an existing saved turn with matching worker attribution; both selectors are mandatory. There is one immutable record per turn. Identical submission repeats return the original record without another event; any changed declaration conflicts. Choose completion versus PR before submission: a completion record cannot later be upgraded in place.

`HANDOFF_JSON` has exactly these required fields:

- `kind`: `completion` or `pull_request`.
- `repository_url`: GitHub HTTPS repository URL, optionally ending in `.git`, without credentials, query or fragment.
- `branch`: nonblank text, at most 255 UTF-8 bytes.
- `base_sha`, `head_sha`: 40 or 64 lowercase hexadecimal characters.
- `result`: nonblank text, at most 4096 UTF-8 bytes.
- `verification`, `limits`, `remaining_processes`: arrays of 0–16 nonblank strings, at most 1024 UTF-8 bytes per string. Empty arrays are explicit declarations, not evidence that Runtime independently checked anything.

`pull_request` additionally requires `pr_url` shaped as `https://github.com/OWNER/REPO/pull/NUMBER`, matching the declared repository. `completion` forbids `pr_url`. No GitHub request verifies existence, authorship or state. Unknown fields, malformed types and client JSON with duplicate keys refuse. Declaration JSON is bounded to 32 KiB; the stored record is bounded to 64 KiB.

For managed executions, submission compares repository URL, branch and base revision against each field already present in saved execution metadata. Repository identity comparison ignores owner/name case and the clone URL's `.git` suffix. Missing metadata remains declared, not inferred or independently verified. Head revision, verification evidence, limits and remaining processes remain caller declarations. Submission does not require or change terminal execution state, stop a worker, accept work, merge a PR or assign the next task.

The public record contains `worker_id`, `turn_id`, `record_ref`, `submitted_at`, fixed `provenance: "coordinator_submitted_declaration"`, and `handoff`. Provenance describes the supported submission route, not authenticated native authorship or a verified-success flag. Runtime never converts result prose or `execution_finished` into a handoff.

Storage uses `turns/<turn>/handoff.json` and the existing atomic-replacement/event-checkpoint conventions. One `handoff_submitted` event references the record with worker/turn attribution, timestamp and sequence; it carries no copied declaration payload. Records, references and cursor replay survive clean restart. Publication recovery precedes unrelated restart events; checkpointed records are not republished after journal pruning. Existing retention gaps still apply, while targeted inspection remains available. Corrupt authoritative storage fails closed. This is not an fsync/power-loss or distributed ownership guarantee.

Real isolated public-CLI proof on 2026-11-07: native Claude turn `turn-b549ec16fbba4cdd`, session `d6641e60-129d-4519-b50e-15c562cf1008`, produced a completion declaration after creating and committing only `runtime-handoff-proof.txt`. Native tool results showed the exact 25-byte marker line, clean status, base `d10afefe469e829d2b310b64ab49c80db86c2216` and local head `02227a3c1c633e0a147f7cf80f9575b649a1c8ba`. No handoff existed automatically at execution finish. Explicit submission refused a mismatched branch, then stored the actual declaration with coordinator provenance. Inspect/repeat matched exactly; changed head and wrong worker refused. After daemon restart, inspection and repeated submission preserved one record, one handoff event, three total lifecycle/handoff events and one turn, with no restored worker. No smoke PR or fabricated PR URL was used.

Focused verification passed: 106 ExUnit tests across handoff storage/service, execution events, service, question records and command/native admission; Go CLI checks passed. Owned native group/private temp and both proof daemons were absent afterward; disposable client/build/clone were removed and compact native evidence retained. No product test suite, default installation, default-daemon restart or deployment was performed.

## Explicit coordinator-routed peer correlation

```sh
atlas-runtime route-peer-question --worker sender --turn "$SENDER_TURN" --question "$QUESTION_ID" --peer-worker peer --peer-turn "$PEER_SOURCE"
atlas-runtime peer-question --worker sender --turn "$SENDER_TURN" --question "$QUESTION_ID"
# Dispatch is a separate, explicit coordinator decision:
atlas-runtime continue --resume-from "$PEER_SOURCE" --profile deep_coding --cost-class standard --cwd "$PEER_FOLDER" "$QUESTION_ASSIGNMENT"
atlas-runtime bind-peer-reply --worker sender --turn "$SENDER_TURN" --question "$QUESTION_ID" --response-turn "$FINISHED_RESPONSE"
# Delivery is also separate; use the actual peer response:
atlas-runtime answer --worker sender --turn "$SENDER_TURN" --question "$QUESTION_ID" --answers "$ANSWERS_JSON"
```

Routing pins one existing sender question to a distinct peer worker and its successfully finished, attributed source turn. First routing and first reply binding require the exact current running sender attempt, an active pending durable question, and matching native-derived pending evidence. Answered, stopped, replaced or restarted senders cannot acquire a new transition. This check is a current-state admission check, not a lease guaranteeing that a native process cannot exit immediately afterward.

Binding accepts only a successfully finished continuation of that exact peer source, with matching worker, backend, native session, model, cwd, sandbox, permissions and repository metadata. New continuations persist `source_turn_id`; older responses without it are refused rather than inferred from a shared session. The response must differ from both sender and source turns. The peer may already be busy on other work: these record commands never start, continue, stop, interrupt, answer or authorize an execution.

Each bounded 16 KiB record at `turns/<sender-turn>/peer-questions/<question-id>.json` stores sender worker/turn/question, `question_ref`, peer worker/source turn, nullable `response_turn_id`, `record_ref`, `created_at`, nullable `bound_at`, revision and fixed `provenance: "coordinator_routed_declaration"`. It references existing question and response evidence, without a second payload store. This provenance is not authenticated native peer delivery or proof that the answer is correct; authenticated/scoped routing remains a separate gate.

Routing creates revision 1; binding makes the sole transition to revision 2. Identical routing repeats return original revision-1 evidence even after binding. Identical binding repeats return the original bound evidence; inspection returns current evidence. Historical repeats survive sender completion, replacement and restart without retargeting or revalidation against later mutable turn state. Changed peer targets or responses conflict.

`peer_question_routed` and `peer_reply_bound` events contain sender/peer identities, response turn when bound, record reference, revision, timestamp and sequence, not copied payloads. They have separate deduplication from native question events. Existing atomic replacement, outbox checkpoint recovery, 256-event retention and explicit cursor gaps apply. Peer publication recovery precedes restart question invalidation. Corrupt authoritative records fail closed; this is not an fsync/power-loss guarantee.

Public-CLI verification on 2026-11-07 used two separately labelled proofs. A synthetic native executable proved unchanged launch/input/answer counts and pending question evidence across routing/binding, conflicting-target refusal, and exact record/event replay after restart: three explicit turns, one explicit answer and twelve events. It does not establish provider acceptance.

The independent real-provider documentation exchange used default-model Claude (`claude-opus-5-5[1m]`) without model or safety changes. Peer source `turn-331188a7413e35e7` read the handoff README section. Sender `turn-f6d114e6a89ff5be` emitted native question `question-be3e022e4784482fbc0f070de647728b`; explicit continuation `turn-a554012197811559` returned `atlas-runtime handoff --worker NAME --turn TURN_ID`. Routing and binding left the pending question and turn set unchanged. A separate explicit answer delivered the actual reply; native processing was observed and the sender returned that exact command. This fresh documentation task did not retry the earlier provider-blocked constant task; its failure evidence and native identity guard remain unchanged.

Focused checks cover stale attempts, wrong ownership/source/session/scope, missing legacy source metadata, concurrent duplicates/conflicts, backward clock movement, event recovery and namespace isolation. All six owned native groups and three isolated daemons were absent afterward; disposable binaries, fixture executable and builds were removed. Compact evidence remains at `~/.ac-pc-xwkhvk4s/public-peer-proof-evidence.json`. No default installation, default-daemon restart, deployment or authenticated peer-delivery claim.

## Durable execution discovery

```sh
atlas-runtime events --limit 50
atlas-runtime events --cursor "$NEXT_CURSOR" --limit 50
atlas-runtime events --follow --cursor "$CURSOR"
atlas-runtime output --turn turn-0123456789abcdef
```

`events` and `events --follow` read the journal on `runtime.sock` with the `runtime.read/1` operations `events` and `follow`: the request lines, the `epoch:sequence` cursor, the reply lines and the printed lines are unchanged since S1. Any other `runtime.read/1` operation on `runtime.sock` is refused with `not_journal`; history is not read there.

`events --follow [--cursor C]` streams the same execution events from `runtime.sock` until SIGINT or SIGTERM, which exit with status 0. It prints one JSON line per event as it arrives, `{"reset":{...}}` before the events when the Runtime reports a retention gap or epoch change, and `{"cursor":C}` after each page whose cursor changed. It is the `epoch:sequence` cursor of `events`; save it only after handling the lines before it. It reconnects on its own from the last printed cursor: at once after a connection closes without an `end` frame (or ends `too_slow`), otherwise with back-off from 1 s to 15 s. It prints its own `{"reachable":false,"reason":R}` once when the Runtime is lost (`R` is `connect_failed`, `connection_closed`, `silence` for 45 s without a page or heartbeat, the `end` reason such as `service_stopping`, or a retryable read error code), and `{"reachable":true}` with the next page. Delivery is at least once; duplicates can follow a reconnect. `invalid_cursor` and other refusals exit nonzero, as does a Runtime that answers the journal request with a command error (one from before the journal moved to `runtime.sock`); `--limit` is refused with `--follow`. It never starts the service or any worker.

`events` is a finite query, not a watcher. It returns immutable ordered execution, question-evidence, peer-correlation and handoff-reference snapshots with stable turn IDs, worker attribution for new events, native identity when known, and references usable by `output --turn`, `question`, `peer-question` or `handoff` for inspection. `execution_accepted` means Runtime accepted a start or continuation; `execution_finished` means the native turn ended normally, **not that its assigned task was verified successful**. Failure, confirmed stop and confirmed kill use `execution_failed`, `execution_stopped` and `execution_killed`; a turn a starting service ended because its service and process were gone is an `execution_failed` with `interruption: "service_restart"`, a field no ordinary failure has; requesting a stop or kill appends no event. Assignments, questions, answers, handoff declarations and full logs are not copied into the event stream.

The response includes `events`, `cursor`, `more`, `recording_started_at` and, after a retention gap or a replaced journal, `reset` (`reason` `retention_gap` with `from_sequence`/`to_sequence`, or `epoch_changed`). Save `cursor` only after processing the returned page; read on while `more`. It advances only through returned events; an empty page preserves the supplied cursor. The initial empty query still returns a usable cursor. Replaying a retained cursor returns the same ordered prefix; newly appended events may extend a previously short page.

Default page size is 50, maximum 100. The bounded journal retains the latest 256 events with bounded identity fields. Omitted cursor starts at the oldest retained event and reports a `retention_gap` reset if earlier events were removed. A stale cursor gives the same reset and the oldest retained events; a cursor of another journal gives an `epoch_changed` reset; malformed and future cursors are refused with `invalid_cursor`. Cursor identity and events survive clean daemon restart. Replacing/removing the journal starts a different stream, never silently reuses old cursors.

The journal begins when this capability is first started; `recording_started_at` marks coverage. Existing mutable turn files are not backfilled into invented historical acceptance/terminal events. Corrupt journals fail visibly rather than reset. This is not abrupt-crash recovery, automatic re-execution or verified-task reporting; existing output/history remain the detailed evidence.

Verification on 2026-11-07: eight focused journal tests and the Go CLI suite passed, including retention gaps, malformed/foreign/future/stale cursors, corrupt storage and a worst-case escaped 100-event response below the 1 MiB socket cap. Real isolated Claude turns `turn-c5719def1b653ee6` and `turn-75138de581f8e32f` produced accepted/finished sequences 1–4 with native session `da1e4115-ee6b-415b-8a47-a3f4fd5a40fe` and model `claude-opus-5-5`. One-event pagination, repeated-cursor replay, daemon restart from the prior cursor, empty checkpoint stability and historical output lookup passed. A separately labelled synthetic native executable exercised actual daemon failure/stop transitions, repeated-stop deduplication and post-restart stop replay; these are lifecycle checks, not provider-failure evidence. All owned proof daemons/process groups were stopped and build/fixture scaffolding removed.

## Continuing a conversation

After a work's attempt `completed`, continue that turn's conversation in a new work:

```sh
atlas-runtime continue --resume-from turn-0123456789abcdef --profile deep_coding --cost-class standard --cwd /path/to/project "Now explain the tradeoff in more detail"
```

The work core continues the turn through the Service's continuation, on the turn's slot, using its previous explicit native `session_id`, working directory and permissions. The source turn must be `finished`, `stopped`, `killed` or `failed`, with a confirmed native session ID; otherwise the answer is `resume-unavailable`. `start` always creates a fresh conversation. Native session confirmation is required; there is no `--last` selection or fallback to another session. Both native CLIs retain conversation history in their normal local storage; Runtime artifacts remain separate. Restart never restores a conversation automatically.

Saved conversations resume the same way after a daemon restart. The saved turn must be `finished`, `stopped`, `killed` or `failed`, with a confirmed native session ID and valid saved cwd/sandbox; its working directory must still exist. A failed turn without a session ID is refused with `The selected turn has no confirmed native session`. Running, stopping, killing, unknown and incomplete records are refused, and so is a worker whose stop latch has not been released. An active agent for that worker blocks continuation; other workers may continue independently unless their workspaces overlap. A new Runtime turn/artifact folder is created; the selected record is unchanged. Selecting an older turn resumes that conversation's current native history, not a rollback or fork at the selected turn. If the selected native backend cannot resume the exact session, the new turn fails without fallback.

A folder defaults to **read-only**. Codex uses the official CLI and the user's existing ChatGPT login (`codex login`). Explicitly opt into Codex's workspace-write sandbox for an editing assignment, with a profile whose policy permits it:

```sh
atlas-runtime start --profile deep_coding --cost-class standard --cwd /path/to/project --permissions workspace-write "Make the requested file change"
```

Codex web search is explicitly disabled for `read-only`, `workspace-write` and `materialized-folder` workers, whose profiles block external network access. The network-enabled `dedicated-repository` profile enables live web search. Command networking keeps each profile's existing restrictions.

**Runtime home deny (every profile).** Every worker profile denies the Runtime home (its sockets `runtime.sock` and `backend.sock`, each also denied by path, turn records, `code.json`) and the Code token file and directory named by `code.json`: no read, no write, no Unix-socket connect. Service passes its home to the native host as `ATLAS_RUNTIME_HOME`; the host removes the variable before the native CLI starts and, when it is absent (direct adapter use), denies the default `~/.local/state/atlas-runtime`. Codex `read-only` and `workspace-write` run as the explicit permission profiles `atlas_read_only` and `atlas_workspace_write`: the built-in `:read-only` and `:workspace` plus these denies, without network. A workspace below the Runtime home (or the token directory) keeps the mode's access to it as the more specific path; one that is the home or the token directory is refused. Claude read-only then omits the rule for the containing directory, and `--restricted` keeps its file tools in the workspace. `dedicated-repository` adds the denies to `atlas_repository` (see below); `materialized-folder` already had them. Claude read-only adds `Read(//…)` deny rules for its file tools.

Folder permissions are `read-only`, `workspace-write` (Codex only) and `materialized-folder`; the turn records the selected mode. A read-only denial never automatically escalates permissions. Both standalone backends reuse `AtlasRuntime.Agent.Native` and its owned process-group runner; no credentials are copied, no global native settings change, and no API fallback. Guidance, queues, multi-agent scheduling and Atlas hookup remain outside this step.

The installed official Claude CLI, with its existing authentication, runs when the profile's policy option is Claude (for example the S1 mini's `deep_coding`):

```sh
atlas-runtime start --profile deep_coding --cost-class standard --cwd /path/to/project "Read the project and explain its entry points"
```

Claude defaults to fresh read-only file-tool assignments. Native restricted/safe modes expose only `Read`, `Glob` and `Grep`, confine those file tools to the working directory, disable user/project customizations and MCP servers, and deny permission prompts. This default is native tool-level restriction, not a claim of OS-wide sandbox confinement. No Bash, write, browser or network tool is enabled in read-only mode; normal provider communication and existing native authentication remain available. API-key/token environment overrides are not forwarded.

Claude generic workspace-write is explicitly refused before execution. Unknown backends are refused. Started turns never switch vendors or retry automatically. Saved legacy turns without a backend remain Codex turns; new turns persist `backend`, native `session_id` and native-confirmed `model` when available. Claude local errors with a synthetic assistant model do not replace the native initialization model. A pre-request failure can therefore identify the configured native model without claiming that model completed an inference. Codex model identity comes from this invocation's native session `turn_context`, matched by session ID, working directory and timestamp; unavailable evidence remains `null`, never copied from the requested model.

Claude requires native initialization identity, a successful result and clean process exit before Runtime reports completion. Native JSONL and final/error text remain inspectable through the same artifacts and output commands. Native Claude persistence is enabled for new turns. The Atlas-connected Claude adapter and broker are unchanged.

### Explicit Claude continuation

`continue --turn ID` resumes a successful Claude turn with official `--resume UUID`, the confirmed original model, cwd and permission scope. Native initialization must confirm the exact session and model; a different model in subsequent assistant output also fails. Missing model, session, saved execution context or native history fails visibly, without a new session or provider fallback. Earlier Claude turns created with persistence disabled cannot be recovered through this feature.

Each Claude execution records `claude-context.json` with canonical cwd, permission scope and Git root/branch/origin identity. Continuation revalidates that context before native execution; unreadable Git identity fails closed. Branch/origin drift refuses rather than switching/resetting. Detached HEAD identity is pinned to its revision and cannot continue after that revision changes. Managed continuation retains the existing origin/branch/ownership checks and preserves unfinished work without fetching or reprovisioning. Every write-scoped attempt receives a new owned private temp subtree with the existing byte limit and cleanup rules. Preference/model changes do not migrate saved conversations.

Real isolated restart proof on 2026-11-07: turns `turn-58f8fe115a937a1e` and `turn-1fe661d1abf893e3` retained native session `0e7c47b3-e8ec-40df-9abe-2ab169eadb1a` and actual model `claude-opus-5-5`. First turn remembered a unique conversation-only marker and made an uncommitted edit. After daemon restart and changing the preferred model to `claude-sonnet-4-6`, explicit saved continuation recalled that marker without repeating it in the assignment or reading files/logs, made a second edit and preserved the managed branch/base/scope. Each turn made one successful Bash call. Exact file bytes, missing-session/model/scope-drift admission refusals, private-temp removal and native process cleanup were checked. No automatic recovery, failed-turn retry, live input or worker push/PR was added.

## Opt-in Claude questions

The work contract does not offer the questions opt-in in S1: work submitted on `backend.sock` runs without it. `question` and `answer` keep serving turns that recorded the capability. The example is from before the cutover.

```sh
# before the cutover:
atlas-runtime start --worker research --backend claude --questions --cwd /path/to/project "Ask which module to explain, then explain it"
atlas-runtime status --worker research
# still served on runtime.sock:
atlas-runtime question --worker research --turn "$TURN_ID" --question "$QUESTION_ID"
atlas-runtime answer --worker research --turn "$TURN_ID" --question "$QUESTION_ID" --answers '{"Which module?":"runtime"}'
```

Copy the exact question text and opaque question ID from `pending_question` in `status` or `output`. Every first answer requires the current worker, Runtime turn and question ID; omitted selectors, wrong targets, unadmitted late answers, extra fields and permission updates refuse. An identical repeat of an admitted answer returns recorded evidence without resending; a conflicting answer refuses, including after completion or restart. Answers must cover the exact question-text key set with nonempty string values, including custom text. At most four questions, two to four options each, 4 KiB per question text/answer value, 32 KiB native question input and 16 KiB answer JSON are supported. Unsupported native question shapes fail closed rather than being silently changed.

Only explicit `start --questions` enables this path. `questions_enabled` is saved with the turn; continuation retains it and accepts no override. Legacy turns remain disabled. A selected Codex backend refuses the capability rather than changing provider. Default Claude execution remains `dontAsk`/`none`, with no live input.

The opt-in uses native stream input and `manual`/`host` permissions with the stdio permission host. It adds `AskUserQuestion` to available tools, not the automatic allowlist. The host approves only the exact pending question, bound to the owned process, native session/model, tool-use ID, process-local request ID and original input. Non-question permission requests are denied; mode/scope changes are refused. Existing read-only tool restrictions and repository Bash/private-temp sandbox settings remain. This shifts the question permission decision into Runtime; it is not a blanket equivalence claim between native permission modes.

`answer` persists `admission: "accepted"` before its only native send. `status: "delivered"` / `transport: "delivered"` requires a completed native input write; `processing: "processed"` requires the matching non-error native tool result. Accepted but unconfirmed platform/clients/transport/processing remains `unknown`, not a command retry instruction. These fields never prove the model used the answer correctly or completed the assigned task. One bounded pending/in-flight answer remains; there is no automatic resend, native recovery or exactly-once guarantee. Stop, completion and transport loss invalidate pending control and clean up the owned process group without discarding recorded evidence.

Real isolated public-CLI proof on 2026-11-07 with Claude 2.1.280 / `claude-opus-5-5`: read-only turn `turn-04a7f0a8940de9dd` asked, accepted a newly generated custom answer and returned `657050 + 37 = 657087` in the same execution. Write-scoped turn `turn-d4d47e2afce4f490` asked before any edit, then used one successful Bash call to write exactly `native-answer-d7a74a7277c4\n`; sibling and `.git/config` writes received `PermissionError` and preserved original bytes. Wrong worker/turn/question and mismatched answer keys refused.

After daemon restart, continuation `turn-9dc6eb32607cfb71` retained the original session/model and opt-in, asked a fresh question, then stopped while pending; a late answer refused. All three native process groups, the write-scoped private temp and both isolated daemons were absent afterward. Focused checks passed: 49 ExUnit tests, 45 Python runner tests and the Go CLI suite. The question transport has since moved to the Go native host; its behavior tests run with `go -C platform/atlas_runtime/host test ./...`. No default installation, Atlas integration or comprehensive native-version/network certification was performed.

Claude's documented [`[1m]` context-window option](https://code.claude.com/docs/en/model-config.md) can remain in native initialization (`claude-opus-5-5[1m]`) while assistant records name its base model (`claude-opus-5-5`). Question-host and continuation checks accept only that exact base-model representation difference, not arbitrary aliases, other modifiers or different models. Initialization/session and resumed configuration checks remain exact. Runtime retains the initialized `[1m]` value for status and saved continuation rather than silently replacing its context option with the assistant's base ID. Native artifacts preserve both original representations.

Default-selection regression proof on 2026-11-07: retained failed turn `turn-70c8440cf908d6d6` and daemon diagnostics established the assistant identity comparison as the cause. Fixed isolated public turn `turn-2cc4a66a4f6196c3` used the same cwd and command semantics, no model preference or `--model` override, and exposed a pending question held for two seconds. Fresh answer `768259` produced correlated processing and result `768276` (+17). After daemon restart, continuation `turn-e61d8bbff3826258` retained session `c48f2e47-c72c-4daa-9adf-c657724c5c82` and configured model `claude-opus-5-5[1m]`, returning `768278` (+19) from prior conversation context. Both streams retained init `[1m]` and assistant base IDs. Focused verification passed: 41 ExUnit and 46 Python tests, including the failing-before question regression and strict mismatch cases. Owned native groups/daemons were absent afterward; disposable client/build removed. Default installation and daemon were untouched.

### Durable question/answer records

`question --worker NAME --turn TURN_ID --question QUESTION_ID` returns one bounded persisted record, including historical records after restart. It exposes original input, exact native session/model/tool-use/request/PID correlation, admitted answer, separate admission/transport/processing/outcome fields, revision and record reference. It does not require private-file inspection. `active` tracks unresolved native ownership; it does not authorize another answer once admission is accepted. Reconnecting to a running daemon exposes the same pending question; restarting never restores native controls or processes.

New durable event kinds are `question_available`, `answer_accepted`, `answer_delivered`, `answer_processed` and `question_invalidated`. Events carry worker/turn/question identity, revision and record reference, not duplicated payloads. Existing cursor semantics, 256-event retention and explicit retention gaps remain. Save question IDs when consuming events if later inspection is needed beyond journal retention.

Records use existing per-turn atomic JSON storage, bounded to 128 KiB each. A bounded transition outbox checkpoints journal publication; restart flushes uncheckpointed transitions without duplicating retained revisions or replaying already checkpointed/pruned history. Pending requests become inactive/invalidated when their execution ends. Accepted answers with uncertain transport or processing retain `unknown` and are never resent automatically. Confirmed delivery/processing evidence remains intact. Corrupt storage fails closed rather than forgetting admission. Durability covers process restart under existing atomic-rename conventions, not an fsync/power-loss guarantee. Earlier turns without these records report unavailable history; no admission is reconstructed from old logs.

Real public-CLI record proof on 2026-11-07: turn `turn-1d1549169e830b87` exposed the same pending record across separate client queries, consumed fresh answer `203483` and returned `203483 + 59 = 203542`. Identical repeats returned recorded admission, conflicting answers refused, and the completed record plus exact event-cursor replay survived daemon restart without starting a worker. Continued turn `turn-cfd044123d1a9d7f` stopped while pending; its invalidation record and event replay survived another restart, with late admission refused. Native correlations matched actual emitted requests and process IDs. Both native groups and all three isolated daemons were absent afterward; disposable client/build removed.

Focused verification passed: 64 ExUnit tests, 46 Python runner tests and the Go CLI suite. Deterministic checks cover lost-response send counts, pre-transport admission, ambiguous crash state, outbox crash windows, pruning, corruption and finalized stop evidence. This proof did not repeat repository-write containment or certify power-loss recovery, provider parity or Atlas integration.

Integrated default-model proof on 2026-11-07, after the coordinator cleared the installed model blocker: fresh base `dd3495f849d29afd8828a62d3aec224117d4a7c6` plus the preserved records changes passed 65 focused ExUnit tests, 47 Python runner tests and the Go CLI suite. No functionality was added; the integration retained both model/configuration and record correlation behavior. Public turn `turn-4ac10c564e7d5364`, session `26d24086-d103-49e6-9be3-fb4272395f90`, used `requested_model: null` with no native `--model` override. Native init/record correlation retained `claude-opus-5-5[1m]`, while assistant output named `claude-opus-5-5`. Fresh answer `815903` produced processed evidence and result `815926` (+23). Identical repeats returned admission, conflicts refused, and the full record plus exact six-event cursor replay survived restart. A repeated answer after restart returned processed evidence with an empty worker registry and no new events. Native group and both isolated daemons were absent afterward; disposable client/build removed. Default installation remained untouched; broad write containment was not repeated.

## Materialized-folder workers (Codex and Claude)

```sh
atlas-runtime snapshot materialize --snapshot sha256:HEX --dest /abs/assignment   # outside the Runtime home
atlas-runtime start --profile deep_coding --cost-class standard --slot NAME --cwd /abs/assignment --permissions materialized-folder "Assignment"
atlas-runtime continue --resume-from TURN_ID --profile deep_coding --cost-class standard --cwd /abs/assignment --permissions materialized-folder "Next step"
```

The worker can read, edit and test the assigned folder and inspect it with `"$ATLAS_RUNTIME_EXECUTABLE" snapshot status|diff --dest .`. `ATLAS_RUNTIME_EXECUTABLE` is the exact CLI that launched the worker; a bare `atlas-runtime` may resolve to another installation in a login shell. The folder must be materialized outside the Runtime home; overlapping folders are refused before launch. The worker cannot read the user's home directory outside the home read allow-list below, Git metadata, the Runtime home (beyond this snapshot's record and baseline, and the launching executable if it lives there), Code tokens or the listed credential locations (including `~/.erlang.cookie`). It has local loopback networking only, always on: external connections are blocked. Local binding is on by design for both backends (Claude `allowLocalBinding: true` at `host/claude.go:518-519`, mirror `lib/atlas_runtime/sandbox/spec.ex:817-822`; Codex `allow_local_binding=true` at `host/codex.go:485-492`, mirror `spec.ex:966-971`), because Elixir 1.18 `mix compile`/`mix test` always start Mix PubSub, which listens on 127.0.0.1 and raises without it (Elixir 1.18.4 `mix/tasks/deps.loadpaths.ex:46`, `mix/sync/pubsub.ex:208-209`). Accepted limit: a worker can connect to every host loopback TCP listener, IPv4 and IPv6, including other workers' servers, and can bind and listen on 127.0.0.1, `::1` and `0.0.0.0` (probe from a real Claude materialized-folder worker on macOS, 2026-11-17, assignment `sandbox-loopback-check-20261117`; Codex loopback: `host/folder_test.go:751-753`). Unauthenticated local services (Postgres trust auth, the DevTools endpoint of a running automation browser) are reachable; while such a browser runs, the external-network block is not a guarantee. What protects each loopback service: Code checks a bearer token on every request (`platform/atlas_code/lib/atlas_code.ex:7-8`) and the sandbox denies reading the token file and its directory (`host/claude.go:413-421`, `host/codex.go:452`); its 0600 mode alone would not stop a same-uid worker. The Runtime sockets are protected by the path deny for Unix sockets below. The Mix PubSub listener in every build VM (the mini Runtime's and other workers' `mix` VMs included) has no authentication and is an accepted upstream risk. The rela (Facts) test and live servers on a Mac (127.0.0.1, test port 7690, live 7612; `platform/atlas_facts/rela/scripts/start-test.sh`) have no access control (`products/software_factory/model/targets/rela/acl.yaml:5-7`), so a worker can read and write the store over HTTP while one runs (same probe). `ps` and `pgrep` are blocked in the Claude worker sandbox (`operation not permitted: ps`, `Cannot get process list`; same probe), so a Claude worker cannot read `-setcookie` or `RELEASE_COOKIE` from other processes' arguments through them; other ways of reading process arguments, and `ps` under Codex, were not probed. `lsof` still works and lists every process with its listeners and working directory, which reveals other workers' folders and the Runtime home path. Codex sets `HTTP(S)_PROXY`/`ALL_PROXY` and a `NO_PROXY` covering localhost and private ranges under its proxy. Loopback listen and connect are verified for Codex and Claude on macOS; no behaviour is claimed for Linux. Unix-domain sockets bind and connect only inside the worker's own scratch folder (which contains its `TMPDIR`); all other socket paths, including the live `runtime.sock`, get `EPERM` (same probe; Runtime home and socket denies at `host/claude.go:375-384`, `host/codex.go:425-429`). Claude scopes them on macOS only, so on Linux Claude workers still get `EPERM` for every Unix socket. macOS caps socket paths at 104 bytes; scratch paths fit with a short Runtime home. The planned real fix is a separate macOS worker user plus a firewall (`pf`) rule for that user on loopback; the separate user alone does not close loopback TCP, which is not scoped by user (same probe). Provider authentication still works because the trusted native host runs outside the sandbox. Runtime setup and continuation run no Git and make no Code request; Code may be stopped while the worker runs. Claude or Codex follows the profile's policy option. See the architecture document for both exact profiles and their deny-list limits.

**Home read allow-list (both backends).** The worker sandbox denies reading `HOME` (Codex: `HOME` = `none`; Claude: `HOME` first in `sandbox.filesystem.denyRead`) and re-allows read-only only these paths, each resolved through symlinks (`homeReadable` in `host/codex.go`, shared by `host/claude.go`):

| Path | Why |
|---|---|
| every absolute `PATH` directory that lies under `HOME` (for example `~/.asdf/shims`, `~/.local/bin`, `~/go/bin`) | the worker must find and run its toolchain commands |
| `~/.asdf` | asdf installs: the targets of the shims (Erlang, Elixir, Go, Node, Python) |
| `~/.tool-versions` | asdf falls back to it when the folder names no version |
| `~/.hex`, `~/.mix` | Hex package cache and Mix archives for `mix test` |
| `~/go/pkg/mod` | Go module cache; `GOMODCACHE` is not redirected, so `go test` needs the cached modules |
| `~/.cache/atlas` | the tools folder: the pinned tools a repository's checks need (for Atlas the rela that `bin/generate model` and `bin/check` use), installed once per machine outside the sandbox, read-only inside it |
| *not re-allowed:* `HOME` and the other directories above `DEST` (Codex cannot grant stat-only access) | `snapshot status`/`diff`/`submit` resolve `DEST` without statting them: on macOS they open `DEST` itself (`O_DIRECTORY|O_NOFOLLOW`) and take its canonical path from the kernel (`F_GETPATH`), so ancestor symlinks still resolve and a symlink at `DEST` is still refused. Linux keeps resolving the parent through symlinks |

Everything the worker already needed stays as before: `DEST` and its scratch/private temp are writable (Claude also lists both in `allowRead`), and this snapshot's record, baseline and, when present, rebind done marker or preparation result stay read-only. Claude keeps `~/.claude/shell-snapshots` and `~/.claude/session-env` readable for its Bash. An executable inspector inside the denied home is readable as that one file. Left out on purpose: `HOME` itself, `PATH` entries outside `HOME` (readable anyway), relative `PATH` entries, and any entry inside a denied path (Runtime home, Code token directory, `.git`, a credential path) or inside `DEST`/scratch. The credential deny-list stays on top: those paths are listed after the re-allows and, as the more specific rule, stay denied even inside a re-allowed path (for example `~/.config/gh` when `~/.config` is on `PATH`). Under Claude the home is denied to Bash only; it is not added to `denyWrite` or to `Read(//…)` permission rules, because those would also deny `DEST` below it. The file tools are confined to `DEST` by `--restricted`. `process.json` records the exact profile.

Consequences to expect: `cat ~/.npmrc`, `ls ~/Documents` and `ls ~` fail with `Operation not permitted`. Under Codex, `HOME` and every directory above `DEST` cannot even be stat'ed, so a worker tool that stats them, for example Go's `filepath.EvalSymlinks`, Node's `fs.realpath` or a shell's logical `cd`/`pwd` path walk (use `cd -P`), fails with `EPERM`; the scratch folder under the Runtime home already had this. Claude's sandbox still allows stat (not listing) of every directory, so Claude workers are not affected. Shell startup files (`~/.zshenv`, `~/.zprofile`, `~/.zshrc`) are unreadable too, so a login shell may print errors and does not apply them; the worker inherits Runtime's `PATH` instead. Global npm packages are not re-allowed: `~/.npm-global/bin` is on `PATH`, but its links point into `~/.npm-global/lib`, which stays denied. A tool that needs another home path fails with a normal `EPERM` tool error; add that path to `homeReadNames` with evidence. There is no fallback to the old profile.

**Pseudo-terminals (Claude only).** A Claude `materialized-folder` worker's settings carry `sandbox.allowPty: true` (Claude Code 2.1.x, macOS only), so its Bash can open `/dev/ptmx`. tmux panes, and with them `bin/atlas-dev e2e` and the e2e tests that open a tmux pane, run in the worker. `dedicated-repository` workers get no `allowPty`. Codex workers are unchanged. Not verified in a real worker yet: the installed Runtime has to be rebuilt first. `allowGitConfig` is left out on purpose. Runtime denies writes and reads to the folder's `.git` (`denyWrite`/`denyRead`). A repository's own `.git` is writable with the folder, so the agent can stage and commit in a job's checkout (IS-Atlas-14), but its `config` and `hooks` are in `denyWrite`, as they are read-only in the Codex profile (`repositoryGitEntries`). Claude's deny wins over its allow, so `allowGitConfig` could not open them. Git tests keep their repositories under the system temp folder anyway.

**Read-only folder (a job's review, IS-Atlas-20).** A read-only work whose folder is a Git checkout (its lease asks for `checkout` without a `result_ref`, work source contract 0.6.0) runs as a `materialized-folder` turn whose scope carries `read_only: true`. The work core starts it with `"permissions": "materialized-folder", "read_only": true`, and the policy is asked for `read-only` workspaces, as the work is. The worker has Bash, so it reads the change with Git and runs `bin/check`. The folder is frozen. Codex runs `atlas_read_only_folder`, which is `atlas_folder` with the folder `read` instead of `write`, so only the turn's scratch is written. Claude's sandbox writes only the private temp, with the folder in `denyWrite` and `Edit`/`Write` deny rules on it. Its build goes to the scratch: `MIX_BUILD_ROOT=<scratch>/_build` and `REBAR_BASE_DIR=<scratch>/_build/rebar3`, the state rebar3 otherwise keeps in a dependency's own `_build`. Every write in the checkout, including a Git commit, is refused by the sandbox (spec rows `codex.folder-read-only` and `claude.folder-read-only`, `SP4c` in `test/sandbox/spec_security_test.exs`, and `TestReadOnlyFolderIsEnforcedByInstalledCodexSandbox`, which runs only outside an agent sandbox). The folder is not sealed on disk: the Runtime writes it as it checks it out. Nothing is pushed: no `refs/atlas/results/<review task>` is made, and its result is its answer.

Inspector contract verified on 2026-11-08 in an isolated daemon whose `atlas-runtime` lives inside its own private Runtime home, as in the dedicated deployment. Code was stopped before the workers started, and the login-shell `atlas-runtime` outside the sandbox is the older shared `~/.local/bin/atlas-runtime`, whose help lacks this profile.

- A folder materialized inside the Runtime home was refused at start with the overlap message, and no turn was created.
- Codex (`gpt-6.1-sol`, session `01a1bc39-0740-7b60-b3c4-1f0970402b9d`) and Claude (`claude-opus-5-5[1m]`, session `f5ccfd17-198e-4f46-ade4-1747a0a5fe5b`) each worked on their own folder outside the home:
  - `ATLAS_RUNTIME_EXECUTABLE` named the home-resident binary;
  - they edited `calc.go`, `go test` passed, and `"$ATLAS_RUNTIME_EXECUTABLE" snapshot status` listed the change;
  - `cat $ATLAS_RUNTIME_HOME/code.json` and `ls $ATLAS_RUNTIME_HOME` both exited 1;
  - continuations ran `snapshot diff` with the exact hunk.
- With the older CLI explicitly first on `PATH`, a bare `atlas-runtime` resolved to `~/.local/bin/atlas-runtime` and failed (Codex: `mkdir …: file exists`; Claude: `chmod …: operation not permitted`). The explicit `"$ATLAS_RUNTIME_EXECUTABLE"` in the same command succeeded.
- Runtime ran no Git. The only Git calls came from native Claude's own launch probes.

Evidence: `~/.ac-ic-m7lo4zo9/folder-inspector-evidence.json`.

Verified on 2026-11-08 in an isolated daemon (Codex 0.166.0, `gpt-6.1-sol`). Snapshot `sha256:cdf993d12d454292b0499266d03df591cc45629dd8559d3b94b8c0ab92f72c9a` (repositories `app`, `docs`) was materialized; the worker is `fw`, session `01a1bc16-3d75-7821-a326-04a23f27043e`.

- Turn `turn-6c4944b06b69a732` added `Sub` and `TestSub`, ran `go test` (ok) and reported its two changes with `snapshot status`.
- Continuation `turn-9d16b1d43c53fc32` reported the unified diff with `snapshot diff`.
- Code was then stopped. Continuation `turn-66d6cafa4e4353de` reran `go test` (ok) with the same session, model and scope.
- A logging `git` shim on the daemon `PATH` recorded zero Git invocations for service start, start and continuations.
- The model declined to run the credential sentinels itself. So the turn's recorded profile arguments were run through the installed `codex sandbox` with the same script:

  | Probe | Sandboxed | Unsandboxed |
  |---|---|---|
  | `~/.codex/auth.json`, `~/.config/gh/hosts.yml`, `~/.ssh`, the Runtime `code.json`, the Code token | 1 (all) | 0 (all) |
  | Code `/v1/health` over curl | 7 (blocked) | 0 |
  | Keychain lookup for `gh:github.com` | 44 | 0 |
  | `mkdir app/.git` / `mkdir .git` | 1 / 1 | 0 / 0 |

  Exit codes only; no contents were printed.
- Claude with `--permissions materialized-folder` was refused at the time; Claude support followed in the next slice (below).
- A stopped long turn (`turn-a97676d65224d5dd`) released the lock and removed its scratch folder.
- The baseline and record were unchanged.

Evidence: `~/.ac-nf-p6hmdtmf/codex-folder-profile-evidence.json`. No installation, default-daemon restart or deployment.

Claude verified on 2026-11-08 in an isolated daemon (Claude Code 2.1.280, `claude-opus-5-5[1m]`). Snapshot `sha256:cb304b7a4aca253fdb8c005f6b5df71c74aef519624ba56c9b2a64d71e46e485` (`app`, `docs`), session `07267e9f-3820-4d16-bcd3-0fca908c0fe6`, with `--questions`.

- **Turn `turn-e630649b1f59c41a`:**
  - The model ran the exit-code-only self-test in its own Bash sandbox. Every probe was denied:
    - harmless sentinels planted in `~/.codex`, `~/.config/gh`, `~/.ssh`, `~/.claude`, the Runtime home and the Code home: 1;
    - `~/.codex/auth.json`, `~/.config/gh/hosts.yml`, `~/.ssh`, `code.json` and the Code token: 1;
    - Code `/v1/health`: curl 7;
    - keychain: 44;
    - baseline write: "Operation not permitted";
    - `mkdir app/.git` and `.git`: 1.
  - Unsandboxed controls: 0 for all except the read-only baseline file.
  - The native Read tool was denied for all 6 sentinel and `code.json` paths ("denied by your permission settings"), and Glob over the Runtime home was denied.
  - The worker then edited `calc.go` and its test, `go test` passed, and `snapshot status` reported the 2 changes.
  - Its AskUserQuestion was answered and processed, and the answer was applied.
- **Code stopped:** continuation `turn-52f4946b4d992283` (same session, model, scope and saved context) ran `go test` (ok) and `snapshot diff`.
- **Git:** the Runtime host ran none. The Git shim saw only the native Claude CLI's own `remote`/`ls-files` probes in the non-repository folder.
- **Stop with a pending question:** stopping `turn-0ff852f0dded00b9` reaped the group, released the lock and removed the private temp. A late answer was refused.
- Sentinels were removed afterwards.

Evidence: `~/.ac-cf-taaclyk6/claude-folder-profile-evidence.json`. No installation, default-daemon restart or deployment.

## Explicit folder preparation (npm ci)

```sh
atlas-runtime snapshot materialize --snapshot sha256:HEX --dest /abs/assignment
atlas-runtime snapshot prepare --dest /abs/assignment --npm-ci atlas/platform/atlas_runtime/viewer/assets
atlas-runtime start --profile deep_coding --cost-class standard --cwd /abs/assignment --permissions materialized-folder "Assignment"
```

The orchestrator authorizes setup by running `prepare` before the worker starts; Runtime never detects or runs setup by itself, and a folder that is never prepared works exactly as before. There are two forms, in this order: install the tracked lockfile of one package folder, then at most one declared, network-off script of that package ([below](#network-off-generation-npm-run)).

- **What runs:** exactly `npm ci --ignore-scripts --no-audit --no-fund` in `REPO_PATH[/SUBDIR]`. No lifecycle script of the package or its dependencies runs, so no repository or package code runs while the registry is reachable. The command runs in the CLI process: no daemon, Code request, Git or model call.
- **Refused before anything runs or is recorded:**
  - a folder changed since materialization: preparation installs exactly the snapshot's lockfile, so the folder must be fresh. Nothing is discarded; a changed `package-lock.json` must first become part of a snapshot;
  - an untracked `package.json` or `package-lock.json`;
  - a `.npmrc` in the package folder or any folder above it in the destination;
  - a lockfile entry that is not an `https://registry.npmjs.org/` tarball with a sha512 integrity, including other hosts, credentials in the URL, Git or local sources, links, workspaces and bundled packages;
  - tracked files under `node_modules`;
  - a package folder reached through a symlink;
  - a folder already prepared, or one held by a worker, a submission or another preparation.
- **Boundary:** `codex sandbox` with profile `atlas_setup`.
  - Writes only `SUBDIR/node_modules` and an owned scratch under the Runtime home; the rest of the folder is read-only.
  - Network only to `registry.npmjs.org` through Codex's network proxy.
  - Denied: the Runtime home (records and diagnostics included), Git metadata, the Code token, the worker credential paths and `~/.npmrc`. The `~/.npmrc` deny applies to the preparation only; worker profiles are unchanged.
- **Environment:** only `HOME`, `USER`, `LOGNAME`, `PATH`, `LANG`, `LC_ALL`, `LC_CTYPE` and `CODEX_HOME` are inherited. Tokens, API keys, `NODE_OPTIONS` and `npm_config_*` are not. npm's user and global configuration are empty files, and its cache and temp are in the scratch. Clearing the environment does not hide files: anything outside the deny-list stays readable under the `:read-only` base.
- **Lifecycle:** the existing folder lock is held throughout, so workers, submissions and other preparations refuse while it runs. npm runs in an owned process group, killed and reaped on exit, after a fixed 10-minute timeout, or on Ctrl-C/SIGTERM. Each of stdout and stderr keeps its first 1 MiB; the rest is counted. Nothing is retried.
- **Records** under `<runtime home>/preparations/<sha256(dest)>/`:
  - `result.json` is the minimal result workers may read (destination, snapshot, package path, outputs, state, exit code, times). It is created with one exclusive rename before npm starts, as `running`, and replaced by the outcome.
  - `private/` holds `request.json` (command and environment), `process.json`, `stdout.log`, `stderr.log` and `outcome.json`. No worker profile grants it.
- **Result:** `{destination, snapshot_id, kind, path, outputs, state, ready, reason, exit_code, started_at, ended_at, diagnostics}`. A result that is not ready exits nonzero and adds `error`. A repeat returns the recorded result without running again.
- **Readiness:** `succeeded` is ready. `failed` (`exit`, `timeout`, `interrupted`, `changed` when files outside the output changed, `start`, `cleanup`) and a leftover `running` are not ready. Workers refuse such a folder at start, continuation and launch. Recovery is a fresh materialization; the folder, its edits and diagnostics are kept for inspection, and status, diff and submit still work in it.
- **Exclusion:** status, diff and submit skip the output only while it is a real directory, in any state, and only because the result names it and the snapshot tracks nothing under it. Nothing is followed: a symlink in its place is reported as an added link, and submit refuses one leaving the repository. Files a worker puts in `node_modules` are not published.
- **Workers:** the folder scope is unchanged, so Elixir admission and saved turns are unaffected. Codex and Claude worker profiles additionally read only `result.json`.

Verified on 2026-11-09 (step 11a): Go tests using stand-in Codex and npm commands cover the scrubbed environment, disabled lifecycle scripts, 1 MiB log cap, result records, status/diff/submit agreement, failures, interruption, timeout, tracked-file protection, refusals and shared lock. The coordinator also passed `TestSetupProfileIsEnforcedByInstalledCodexSandbox` outside the worker sandbox, including its direct network positive control and denied network/write probes. A real registry install through Codex's proxy installed 74 packages; offline use succeeded and all 550 tracked files remained unchanged. These checks do not establish which macOS trust services are necessary.

### Network-off generation (npm run)

```sh
atlas-runtime snapshot prepare --dest /abs/assignment --npm-ci atlas/platform/atlas_runtime/viewer/assets
atlas-runtime snapshot prepare --dest /abs/assignment --npm-run atlas/platform/atlas_runtime/viewer/assets --script build \
  --output atlas/platform/atlas_runtime/viewer/priv/static/app.css --output atlas/platform/atlas_runtime/viewer/priv/static/prism --output atlas/platform/atlas_runtime/viewer/assets/.build
```

A strict, reproducible preparation, not a rebuild after edits: it regenerates exactly the snapshot's files with the installed dependencies, so a worker starts in a folder whose generated files were proven to come from its sources.

- **What runs:** exactly `npm run --ignore-scripts --offline NAME` in the package folder, for a `NAME` in the tracked `package.json` `scripts`; npm runs none of its pre- or post-scripts. Once per folder, only after a succeeded `--npm-ci` of the same package.
- **Outputs:** every path the script writes is declared with `--output`, repeated. Each is a path in the package's repository, not nested in another, outside `node_modules` and the package's `package.json`/`package-lock.json`, and does not contain the package folder. An existing output and every folder above it is a real directory, or, for the output itself, a regular tracked or new file; nothing is a symlink. The script may write, overwrite and clear inside a declared output, but cannot remove the output path itself, so a build empties a declared directory in place rather than deleting and recreating it.
- **Refused before anything runs or is recorded:** no succeeded npm-ci of the package, an untracked script, an invalid output, a project `.npmrc`, a folder changed since materialization (outside `node_modules`), a folder already holding an npm-run, or one held by a worker, a submission or another preparation. `node` must be on PATH outside the folder.
- **Boundary:** the same `atlas_setup` profile and deny-list as npm-ci, with `network={enabled=false}` and no network proxy. It writes only the declared outputs and the owned scratch; `node_modules` and the rest of the folder are read-only. Same scrubbed environment and empty npm configuration, plus `npm_config_offline=true`.
- **Strict outcome:** afterwards every tracked file, the regenerated ones included, must be byte- and mode-identical to the snapshot, and nothing may be added outside the excluded outputs; otherwise the run fails with reason `changed`, and the outcome names the changes.
- **Exclusion:** status, diff and submit additionally skip only the declared outputs that hold no tracked path (for the viewer, `assets/.build`), while each is a real directory. A declared output that holds tracked paths (`app.css`, `prism`) is never excluded: its files stay ordinary tracked changes.
- **Records and lifecycle:** the same lock, timeout, log cap, readiness and recovery as npm-ci. `result.json` becomes version 2 (`kind` `npm-run`, `script`, sorted `outputs`, and the npm-ci as `previous`), written as `running` before npm starts. The run's private request, process, logs and outcome are in `private/npm-run/`, created exclusively. Version 1 results stay valid.
- **Repeat:** the same run, with its outputs in any order, reports its recorded result without running again; repeating the npm-ci reports the npm-ci's. Any other npm-ci or run is refused.

Tests (step 11b, 2026-11-09): Go tests with stand-in Codex, npm and node cover the exact arguments and offline environment, regeneration with a clean status, diff and submit, exclusion of only untracked outputs, failures for a changed, re-moded or removed tracked output, a file outside the outputs and a failing script, every refusal, repeats, the shared lock, an interrupted claim, and version 1 and 2 record validation. `TestRunProfileIsEnforcedByInstalledCodexSandbox` probes the network-off profile under the installed Codex sandbox; it, the host-level tests and a real viewer build need a run outside the worker sandbox, where its Codex home check and loopback listening are denied; only the snapshot-level tests ran inside it.

## Review packets (snapshot freeze)

```sh
atlas-runtime snapshot freeze --dest /abs/assignment --turn TURN_ID --packet /abs/packet --packet-id UUID [--previous PACKET_ID] [--revision REVISION]
```

Freezes a materialized folder after its author turn, so a review has a stable subject while the author keeps working. Offline: no Code, Runtime service or Git.

- **Refused first, nothing made:** an active owner of the folder (the lock workers and submissions take), a turn that did not run in the folder or is not finished, stopped or killed, a packet path that exists, overlaps the folder or the Runtime home, or lies in a Git work tree, a `--previous` that is not a recorded packet or is this packet, a `--revision` that is not 1 to 255 visible ASCII characters, and anything submit refuses (FIFOs, sockets and devices anywhere; in a repository also escaping symlinks, `.git` paths, files over 64 MiB and a request over 1 MiB).
- **Packet:** `/abs/packet/tree` is a copy of the folder, each file an APFS clone (copy-on-write, so only metadata is written) or, where the filesystem cannot clone, a streamed copy. Directories are 0555 and files lose their write bits. The tree is recorded as a materialization of the same snapshot with `packet_id`, and a preparation result is copied with it, so `snapshot status|diff|submit --dest /abs/packet/tree` work and report what the folder reported. Next to it: `packet.json`, `diff.json` (exactly `snapshot diff --dest /abs/packet/tree`) and an empty, writable `findings/`. The Runtime home keeps the authoritative `packet.json` and `diff.json` in `packets/PACKET_ID/`.
- **Revision:** `--revision` names the revision of the reviewed change the packet is for (the commit a review is of). It is recorded in `packet.json` as `revision`, exactly as given and never interpreted, and only when given; it is in no fingerprint. A review pass on the packet refuses it unless it is the revision the review names.
- **Fingerprints:** every repository in `packet.json` has the fingerprint and entries `snapshot submit` reports and sends for the same content; a clean repository has `entries: []`. The packet fingerprint is `fpr_` + SHA-256 of `{"repositories":[{"fingerprint","path","repository"}…],"snapshot_id","version":1}`, sorted by path. Paths outside every repository are listed in `outside` and are in no fingerprint.
- **Consistency:** the tree is scanned again after the copy; content that differs from the folder's scan refuses with `folder … changed during freeze; nothing was frozen` and removes the packet folder and its records.
- **Result:** `packet.json` plus `state: "frozen"`, `packet` and `cost`: `elapsed_ms`, `files`, `bytes`, `cloned_files`, `copied_files`, `copied_bytes`, `free_bytes_before`, `free_bytes_after` and `disk_used_bytes` (the drop in free space; noisy on a busy volume). A repeat with the same packet ID and arguments returns the recorded packet with `state: "existing"` and no cost; other arguments under a used ID are a conflict.
- **Limits:** read-only modes do not stop a process of the same user. No worker profile runs in a packet tree: a materialized-folder scope of it is refused (`Materialized folder … is the tree of frozen packet …; it cannot be a worker folder`), and the `review-packet` profile was removed (S5b). Clones keep extended attributes and ACLs. Runtime removes no packet by itself; `snapshot discard` below removes one on request.

## Review findings and the packet chain (snapshot findings, snapshot packets)

```sh
atlas-runtime snapshot findings --packet /abs/packet --turn REVIEW_TURN_ID
atlas-runtime snapshot packets --dest /abs/assignment
```

`snapshot findings` records what a review pass wrote to `/abs/packet/findings/findings.json`. Fixed rules only: Runtime never writes a verdict, and a refusal is never a pass. Offline: no Code, Runtime service or Git.

- **The file:** at most 65536 bytes (64 KiB) of UTF-8 JSON, one object without repeated keys and with exactly these fields:

  ```json
  {"version": 1, "packet_id": "<this packet>", "fingerprint": "<this packet's fpr_>",
   "verdict": "pass | changes_required | uncertain", "summary": "…",
   "findings": [{"id": "F1", "severity": "blocking | should-fix | note", "repository": "github.com/o/r", "path": "atlas/x.go",
                 "lines": {"side": "new | old", "start": 10, "end": 14}, "problem": "…", "evidence": "…", "direction": "…"}],
   "checked": ["…"], "not_checked": ["…"]}
  ```

  `repository`, `path` and `lines` may be `null` but must be present. `repository` and `path` are as `diff.json` names them: the repository name, and the path relative to the tree. The path must be in the tree or its baseline (a deleted file), reached through real directories only, and in the named repository. `lines` must lie within the tree's file (`new`) or the baseline's file (`old`). `id`, `summary` and `problem` are nonempty, and IDs are unique. A `blocking` finding with verdict `pass` is invalid.
- **Refused, with nothing recorded:**
  - the turn did not run in `/abs/packet/tree`, is not a `review-packet` pass of this packet and fingerprint, or is not finished, stopped or killed;
  - an owner holds the tree's lock;
  - code `packet_modified`: the tree, `packet.json` or `diff.json` changed after the freeze;
  - code `packet_discarded`: the packet was discarded (`snapshot discard`), checked under the tree's lock;
  - code `findings_missing`: no file;
  - code `findings_invalid`: anything else above, including a file over 64 KiB or a symlink.

  The CLI prints `{"error": …, "code": …}` for the coded refusals and exits 1.
- **Record:** `<home>/packets/PACKET_ID/findings/REVIEW_TURN_ID.json` (0444, never replaced) and the result are `{version: 1, packet_id, fingerprint, review_turn, reviewer: {worker_id, backend, model, selection}, author: {turn_id, worker_id, backend, model, selection}, recorded_at, sha256, findings}`. `findings` is the file, compacted. `sha256` is the hash of its original bytes. The reviewer comes from the review turn's record. The author comes from `packet.json`, with the selection from the author turn's record (`null` if that record is gone). The result adds `state: "recorded"` and `record`.
- **Repeat:** the same turn with an unchanged file returns the record with `state: "existing"`. A changed or removed file is a conflict. Each review turn is recorded once, and a packet can have several.

`snapshot packets` lists every packet frozen from the folder, oldest first along the `previous` links (then by `created_at` and ID). Each entry has `packet_id`, `fingerprint`, `previous`, `snapshot_id`, `created_at`, `author`, `packet` (the packet folder), `discarded_at` (`null` until `snapshot discard`) and `findings` (every findings record, oldest first). It only reads, and the folder need not exist any more.

Tests (review step 5, 2026-11-11): Go tests in `snapshot/findings_test.go` cover:
- a recorded file with both selections, a repeat, a conflict after a change, and the exact 64 KiB boundary;
- every refusal above, including one byte past 64 KiB;
- a three-packet chain whose IDs sort opposite to the chain, listed in chain order with its findings.

Historic: until S5b, a review pass that Flow sent (the BEAM pass receiver, `review-packet` permissions on `P/tree`; both removed in S5b) was taken only for the packet it named: its `packet_id`, `fingerprint` and `revision` had to be the packet's, the revision as `snapshot freeze --revision` recorded it, so a packet frozen without one, or for another revision, was refused for reconciliation and never reviewed. It ended once its turn was finished, stopped or killed: Runtime recorded its findings as above and returned the record as the pass's evidence, with the findings' `verdict` as its outcome. `findings_missing` and `findings_invalid` ended it as `failed`; any other refusal, or a record of another packet or turn, was left for reconciliation and was never an outcome. `snapshot findings` still records findings of such saved turns.

Limits:
- Findings move through the Runtime record only. Delivering them as Issue channel messages is UC-Chan-04 (channels S9).
- Line bounds are checked against the whole file, not the diff hunks.
- The list includes full records, so its size grows with the chain.

## Review packet discard (snapshot discard)

```sh
atlas-runtime snapshot discard --packet /abs/packet | --packet-id UUID
```

Removes a packet folder once its review is over. Offline: no Code, Runtime service or Git.

- **Refused, nothing removed:** both or neither of `--packet` and `--packet-id`, a packet ID or path with no record under `packets/`, a lock on `/abs/packet/tree` (a review pass, `snapshot findings` or a submission from the tree: `folder … has an active Runtime owner; nothing was discarded`), and a folder at the recorded path whose `tree` is not a directory or is not recorded as this packet.
- **Removed:** `/abs/packet` (the read-only tree, `packet.json`, `diff.json` and `findings/`), the tree's materialization record and its copied preparation result. Read-only directories and files are made writable first; symbolic links are never followed, and every change stays inside the folder, as the host's scratch cleanup does.
- **Kept:** `packets/PACKET_ID/` with `packet.json`, `diff.json` and the findings records, plus a new `discarded.json` `{packet_id, packet, tree, fingerprint, discarded_at}`. Retention of these records is the planned cleanup step.
- **With findings:** discard and `snapshot findings` take the same tree lock, so each refuses while the other runs. A stamped packet takes no more findings (code `packet_discarded`), and `snapshot packets` still lists it, with its findings and `discarded_at`.
- **Result and repeats:** `{state: "discarded", packet_id, packet, tree, fingerprint, discarded_at, record}`. A repeat by path or ID returns the same result; an interrupted discard (folder gone, record left) completes on a repeat. By path, after a later freeze reused the path, the packet not yet discarded is chosen; with all discarded, the latest discard is reported.
- **Limits:** a folder left by a freeze killed before its commit point has no record under `packets/` and is not removed by discard; remove it by hand.

## Change sets and composed folders (snapshot changes, snapshot compose, materialize --read-only)

```sh
atlas-runtime snapshot changes --dest PATH --blobs DIR
atlas-runtime snapshot compose --base-id sha256:HEX --change-set FILE --blobs DIR --dest NEW_PATH [--read-only]
atlas-runtime snapshot materialize --snapshot sha256:HEX --dest NEW_PATH --read-only
```

These are the helper steps behind a work's frozen result and its `from_work` and `base` folders (S5a). The Runtime core runs them; they are ordinary CLI commands too. `changes` and `compose` need neither Code nor the Runtime service, run no Git and never read `code.json`.

- **`changes`** reports a materialized or composed folder as a change set against its recorded baseline: `{"snapshot_id", "roots": [{"root", "entries"}], "outside": [...]}`.
  - Every repository path of the baseline is a root, in manifest order. An unchanged root has `"entries": []`.
  - Entries are what `submit` would send, with paths relative to the root. A write is `{path, op: "write", kind: "file"|"symlink", mode: "100644"|"100755"|"120000", size, sha256}`, plus `target` for a symlink. A delete is `{path, op: "delete"}`.
  - `outside` lists the paths outside every repository. A change set cannot hold them; the core fails closed on them.
  - Every written file's content is kept as `DIR/<sha256>`: read-only, published by an exclusive rename, and an existing blob is kept.
  - It takes the folder lock that workers, preparations and submissions take, and scans twice, like `submit`. Only when both scans agree are the blobs published and the result printed.
  - It works on a read-only folder and writes to neither the folder nor its baseline.
  - On failure it exits nonzero and writes `{"code", "error"}` to **stderr**. The codes: `not_materialized` (no record for PATH), `busy` (an owner holds the lock), `changed_during_scan` (also for a file that vanished between the walk and its capture), `unsupported_entry` (what `submit` refuses: a FIFO, socket, device, `.git` path, symlink leaving its repository or a file over 64 MiB) and `io`.
- **`compose`** builds `NEW_PATH` from `<runtime home>/snapshots/HEX/tree` plus exactly the change set in `FILE` (`{"base", "roots"}` as `changes` prints them; `base` must be `--base-id`).
  - A delete must name a baseline file or symlink. Every write is a valid entry, nothing lies inside a file or symlink, and every symlink resolves inside its repository. Otherwise the code is `invalid_change_set`.
  - A written file's content comes from `DIR/<sha256>`, as an APFS clone where the filesystem allows it. The size and sha256 are checked on the copy itself (`blob_mismatch` for a wrong, missing or non-regular blob). Kept baseline files are cloned too.
  - With `--read-only`, files lose their write bits and directories are 0555.
  - `NEW_PATH` must not exist (`destination_exists`), and its parent must exist. Inside the Runtime home only `<runtime home>/workers/work-NAME` is accepted, where NAME is a lowercase letter, then lowercase letters, digits, `_` or `-`, up to 64 characters. Every other path that is or lies inside the home is refused (`destination_not_allowed`), including when it is reached through a symlink or spelled in another case.
  - It publishes by an exclusive rename and records `NEW_PATH` as a materialization of HEX. So `status`, `diff`, `submit` and `changes` of the new folder are relative to the same baseline, and a chain of composed folders keeps one base.
  - The result is `{"snapshot_id", "destination", "read_only"}`. On failure it exits nonzero, leaves no `NEW_PATH`, record or staging, and writes `{"code", "error"}` to stderr. The other codes are `baseline_missing` and `io`.
- **`materialize --read-only`** is today's `materialize`, with the folder sealed as `compose --read-only` seals it.
  - The baseline and the record are the same as without the flag.
  - Every result now carries `"read_only": true|false`.
  - The folder's own root is sealed right after the publishing rename and everything below it before, because macOS 15 refuses to move a directory without write permission to another parent.
  - It remains the only one of the three that contacts Code.

## After-check (host check)

```sh
atlas-runtime host check --cwd DIR (--scope JSON | --sandbox read-only) --scratch RUNTIME_HOME/scratch/NAME \
  --timeout SEC --grace SEC --tail BYTES -- ARGV...
```

This is the helper step behind a work's `after_check` (design §3.10, S5a). The Runtime core starts it as a port after the attempt's result and frozen result are persisted, and reads its events. It needs `ATLAS_RUNTIME_HOME`, and neither Code, the Runtime service nor Git.

- **Sandbox:** it always runs `<codex> sandbox -P <profile> -C DIR <profile arguments> -- ARGV`, the way preparation runs npm. `<codex>` is `codex` found on `PATH`, and it must be an absolute path. The profile is the turn's own, rendered by the same code the turn uses:
  - `--scope JSON` is the turn's materialized-folder scope, which gives `atlas_folder`: the folder and the scratch are writable, the Runtime home (sibling workers, frozen store and sockets included), the Code token and the user's credentials are denied, network is loopback only, and Unix sockets work only inside the scratch. The scope must be exactly the folder's recorded scope (its verified record and baseline, plus `profile`, `version` and `home`), and the folder must be ready and not a packet tree. A folder below the home, such as `RUNTIME_HOME/workers/work-NAME`, is accepted.
  - `--sandbox read-only` gives `atlas_read_only`: everything is read-only, there is no network, and the scratch is not writable either.
- **Command:** ARGV runs without a shell, in DIR, as the leader of its own process group, with stdout and stderr merged. `ARGV[0]` is either a relative path that stays inside DIR after every symlink, or a bare name found on `PATH`. The environment is preparation's: `HOME USER LOGNAME PATH LANG LC_ALL LC_CTYPE CODEX_HOME` as inherited, `TMPDIR`, `XDG_CACHE_HOME` and the npm cache and empty npm configuration inside the scratch. `codex sandbox` adds its network-proxy variables to it under the folder profile, and only `CODEX_SANDBOX_NETWORK_DISABLED=1` under the read-only profile. `ATLAS_RUNTIME_HOME` and tokens are never passed on.
- **Refusals:** without an absolute `codex`, or when `ARGV[0]` is absolute, contains `..`, or resolves outside DIR (also through a symlink), or is not found, nothing runs. The only line is `{"event":"refused","why":"sandbox_unavailable"|"leaves_folder"|"not_found"}`, and the exit status is 0.
- **Events (stdout, one JSON object per line):** `{"event":"started","pgid":N}`, then exactly one `{"event":"ended","exit_status","signal","timed_out","stopped","duration_ms","output":{"tail","complete"},"group_gone","scratch_removed"}`.
  - `signal` is `"SIGINT"` or `"SIGKILL"` only for a stop the helper sent itself (timeout, `stop`, or a lost parent). Then `exit_status` is null.
  - Otherwise `exit_status` is the status `codex sandbox` passed on. A command that dies of its own signal gets 128 plus the signal number (143 for SIGTERM), and `signal` is null.
  - `tail` is at most `--tail` bytes of the merged output, cut on a UTF-8 boundary, with invalid bytes dropped. `complete` means the whole output fit.
  - `group_gone` is false only if the group could not be emptied within 10 seconds. The scratch is then kept, for the core to remove once the group is gone.
- **Stopping (stdin, one JSON object per line):** `{"stop":"signal"}` sends SIGINT to the whole group, and SIGKILL follows after `--grace`. `{"stop":"kill"}` sends SIGKILL at once. EOF on stdin, or SIGINT or SIGTERM to the helper, means the parent is lost: SIGINT, SIGKILL after `--grace`, then the end. A timeout uses the same stages. The command gets the default SIGINT disposition even when the helper was started with SIGINT ignored.
- **Scratch:** `--scratch` must be `RUNTIME_HOME/scratch/NAME`. A scratch left by an earlier helper is removed first. The scratch is created 0700, and removed after the group is gone on every end, with `scratch_removed` reporting it.
- **Ownership:** the check holds the folder lock that workers, preparations and submissions take. A held lock, a usage error or a changed scope prints `{"error"}` on stderr and no event, and exits 1.
- **Gate:** the unit tests run the helper against a passthrough stand-in for `codex sandbox`. `TestCheckSandboxDeniesRuntimeSockets` runs it under the installed `codex sandbox` (`ATLAS_RUNTIME_NATIVE_SANDBOX=1 go test -count=1 -v -run 'TestCheckSandbox' ./host/`, macOS, outside any agent sandbox). It covers a folder at `RUNTIME_HOME/workers/work-x`, a sibling worker, the frozen store and the three Runtime sockets, under both profiles.

## Claude scoped repository writes

The work contract does not offer `dedicated-repository` on a folder in S1; its repository workspace (`--repo`, `--branch`) is the managed form below. Before the cutover, Claude repository writes were selected with `atlas-runtime start --backend claude --cwd /canonical/independent/repository --permissions dedicated-repository "Edit the assigned file and create a local commit"`, or use managed `--repo` provisioning below. This reuses independent-root validation and owned directory locking. It enables Bash alongside read-only Read/Glob/Grep, never Edit/Write. Native settings require sandbox availability, disable unsandboxed escape and excluded commands, retain the existing GitHub domain list, and deny writes to `.agents`, `.codex`, `.aws`, `.claude`, `.git/config` and `.git/hooks`. The Runtime home and the Code token with its directory are in `denyRead`, `denyWrite` and `Read(//…)` deny rules. Claude's denies win over its allows, so when the home contains the repository (managed `--repo` provisioning puts it under `workers/`), the home is in `denyRead` only with the repository in `allowRead`: Bash writes stay limited to the repository and private temp, and `--restricted` confines the file tools to the repository. A repository that is the Runtime home or the Code token directory is refused; one inside the token directory is handled like one inside the home, and the token file itself stays denied. Generic workspace-write remains refused.

On macOS, dedicated-repository settings explicitly allow Mach lookup of `com.apple.trustd.agent` so native `gh` can validate TLS certificates. TLS verification stays enabled; all other sandbox settings stay unchanged. This service access applies to **every sandboxed command**, not just `gh`. Service-mediated networking makes effective isolation weaker than a strict GitHub-only network boundary. Other platforms receive no Mach lookup allowance.

The write scope is the assigned repository **plus one exact private native temporary subtree**, not repository-only and not identical to Codex confinement. Runtime securely creates an unpredictable `0700` `.ac-*` directory beneath the canonical user home for each execution. `process.json` records `native_temporary` and the exact native settings. Runtime removes only that owned directory after terminating the native process group, including failure/cancellation paths. System temporary roots remain write-denied; repositories inside those roots are unsupported. No shared `/tmp/claude-<uid>`, whole-home allowance or nested Codex wrapper is used.

Installed Claude Code 2.1.280 selects shared `/tmp/claude-<uid>` when the UTF-8 byte length of `<CLAUDE_CODE_TMPDIR>/claude-<uid>` exceeds 44. Its shell wrapper uses that selection for cwd bookkeeping and shell temporary files; setting launch `TMPDIR` cannot override it. Runtime validates this limit before spawning and fails explicitly on homes too long to fit. Earlier repository-local-temp attempts failed first on heredoc creation, then on wrapper cwd bookkeeping after a successful edit/commit. The short private directory fixes both in the bounded native proof below; arbitrary shell compatibility is not claimed. The [native sandbox documentation](https://code.claude.com/docs/en/sandboxing) describes shell-only isolation; built-in Edit/Write tools run outside it and remain disabled here.

Focused checks passed: 24 Python runner tests, including exact temp scope, the 44-byte boundary, long-home refusal, and cleanup on completion, native failure and stop. Earlier candidate verification also passed 26 Elixir policy/adapter tests and the Go CLI suite. Synthetic lifecycle checks do not substitute for native containment evidence.

Real public-CLI proof on 2026-11-07: turn `turn-b894577aa26ff18b`, native Claude `claude-opus-5-5`, session `5cb705a0-b34e-4eca-84fd-d7e881696841`. Exactly one Bash call ran ordinary shell output and a Python heredoc, edited `proof.txt`, and created local commit `160c948d5d973e89ca2bae17ffb01001a8f1d844` containing only that file with bytes `after-native-claude\n`. Bash succeeded without a tool error; native execution completed cleanly. Actual writes to an outside sibling, `.agents/protected.txt`, `.git/config`, and a separate owned sentinel outside the temp subtree were refused with original bytes preserved. Independent inspection confirmed the exact commit, scope, absent native process group and removed owned temp.

The proof used isolated Runtime state, after the trusted weekly reset; no default install, daemon restart, merge or deployment occurred. Push/PR operations from Claude, provisioning, continuation, comprehensive network isolation and arbitrary shell commands were not verified by this proof. Native source/version changes can alter temp routing and require new verification.

## Model policy

Two files in the Runtime home replace `backends.json` (design `2026-11-16-runtime-backend.md` §6, §7):

- **`policy.json`** is set through Control (IS-Atlas-27, below): its supervisor sets it on the Runtime's machinery fact, and the Runtime fetches it over its work source link and writes the file itself. Without Control (no remote source), a human edits it locally and raises `version` on every change. It is read again for every start, so a change applies to every turn not yet started. A missing or invalid file permits no profile start (`policy_forbids`).
- **`availability.json`** holds quota evidence per harness. Runtime records exact native weekly-quota evidence there; a human may mark a harness out, or re-enable one, by editing it locally while no start is pending.

`atlas-runtime preferences` only reads: it prints the policy view (`GET /v1/policy` on `backend.sock`), with each option's availability, and its `version` is the one in force, Control's once applied. It never writes `policy.json`; `--preferred` and `--fallback` are removed and exit nonzero naming the file. `preferences --reenable HARNESS` clears that harness's quota mark in `availability.json` (`POST /v1/harnesses/HARNESS/clear-quota-mark`).

### Where the configuration is set: Control

A Runtime's configuration (sources with `url` and `git_url`, profiles with permissions, cost classes and options, slots, `version`) is set through Control, not on the machine and with no restart:

1. **Its supervisor sets it** in the `configuration` field of the Runtime's machinery fact: the one whose key is the Runtime's id in its work source credential (for example `mac-mini`). The field holds the whole `policy.json` as JSON. Raise its `version` on every change. From the CLI: `atlas get mac-mini` shows it with `applied_version`, `refused_version` and `refused_reason`, and `atlas set mac-mini configuration=@policy.json` sets it from a file (add `--env test` for test). In the Console, it is the machinery's page and its change form.
2. **The Runtime fetches it** over the work source link it already polls on: Flow's work source answers a poll with `configuration` while the Runtime's `policy_version` is another one (`work_source` 0.4.0). That source's puller checks it (`AtlasRuntime.Configuration`), writes `policy.json` itself (through `policy.json.tmp`, then a rename) and applies it to every attempt not yet started. An attempt already started keeps its selection. The next poll, and `atlas-runtime preferences` and `service status`, show the new version, within one poll (at most `poll_max`, 25 s).
3. **Control shows what the Runtime did**: `applied_version` is the version the Runtime runs under, from its last poll. A configuration it refuses leaves the old `policy.json` in force, and the refusal is reported with every later poll until another version applies: `refused_version` and `refused_reason` show it. A refused version is not served again, so fix the document and raise its `version`.

The Runtime refuses a configuration that is not a valid `policy.json` (the rules below, reason `invalid: …`), whose `version` is not above the one in force, or that changes the source it came over (its `name`, `kind`, `url`, `credential_file`, `ca_file`). It also refuses one that adds, removes or moves another source: each puller opens its link once, at boot, so that still needs a restart. A source's `priority`, `max_slots`, `max_store_bytes` and `git_url`, the profiles and their options, the slots and the buffer apply live. A document without a positive integer `version` is not served; Flow records it refused with `refused_version` 0.

Credentials (`sources/<name>/token`, a `ca_file`) stay on the machine and never cross Control. A local edit of `policy.json` still works, and Control's next version replaces it.

### `policy.json`

```json
{
  "version": 1, "changed_by": "operator", "changed_at": "2026-11-16T09:00:00Z",
  "slots": ["dev1", "dev2", "dev3", "dev4", "dev5", "dev6"],
  "buffer_size": 6,
  "profiles": {
    "deep_coding": {
      "permissions": ["dedicated-repository", "materialized-folder", "workspace-write"],
      "cost_classes": ["standard", "high"],
      "options": [
        {"provider": "anthropic", "harness": "claude", "model": "claude-opus-5-5"},
        {"provider": "openai", "harness": "codex", "model": "gpt-6.1-sol"}
      ],
      "limits": {"max_duration": 14400}
    }
  }
}
```

| Field | Rule |
|---|---|
| `version` | required positive integer; recorded as `policy_version` |
| `changed_by`, `changed_at` | optional strings |
| `slots` | optional non-empty list of distinct worker names; default `["default"]` |
| `buffer_size` | optional non-negative integer; default one per slot |
| `independence` | optional `{"different_from": "conversation"\|"model"\|"provider"}`; not applied before S4 |
| `profiles.<name>.permissions` | non-empty subset of `dedicated-repository`, `materialized-folder`, `workspace-write`, `read-only` |
| `profiles.<name>.cost_classes` | non-empty subset of `low`, `standard`, `high` |
| `profiles.<name>.options` | ordered, non-empty list of distinct `{provider, harness, model}`; `harness` is `claude` or `codex` |
| `profiles.<name>.limits` | optional `{"max_duration": seconds}`; otherwise `deep_coding` 4 h, `independent_review` 1 h, `light_work` 30 min, any other 4 h |

Unknown fields make the file invalid.

**Resolution.** A start that names `profile` and `cost_class` resolves mechanically:

1. The profile must exist, and must list the workspace permission and the cost class. Otherwise: `policy_forbids`.
2. A resume selects the source turn's option with reason `continuation` if the profile still lists it. Otherwise: `resume_unavailable`.
3. Options are walked in order. An option is skipped when its harness cannot serve the permission (`unsupported_permission`: Claude has no `workspace-write`), when it is not installed (`not_installed`), or when `availability.json` marks it out (`quota`).
4. The first option left wins: reason `preferred` if it is the first option, otherwise `fallback`, with the skipped options and why.
5. If nothing is left and an option was skipped for quota, the result is `profile_unavailable` with the earliest known return time. Otherwise it is `no_permitted_option`. Runtime never improvises.

The turn's `selection` records `profile`, `policy_version`, `option`, `reason` and `skipped`, plus `requested`/`selected` `{backend, model}`. A start that names a backend instead (only in-BEAM callers of the Service: since D3 the CLI starts work on `backend.sock`, and `runtime.sock` serves no start) gets exactly that backend, never a fallback, with the policy's model for that harness when all its options agree, otherwise the native default (reason `explicit`). Without either, the former preference pair (imported from `backends.json`, see below) applies: its preferred Claude target (reason `preferred`), or its Codex fallback while Claude's weekly quota is out (reason `confirmed_weekly_quota`, with the quota entry); without a pair, Codex runs (reason `default`). A backend that cannot serve the requested permission is refused before execution.

### `availability.json`

```json
{
  "format_version": 1,
  "quota": {
    "claude": {"evidence": {"status": "rejected", "rateLimitType": "seven_day", "resetsAt": 1794052800, "...": "..."},
               "turn_id": "turn-0123456789abcdef", "observed_at": 1794050000, "reenabled_at": null},
    "codex": {"evidence": {"source": "operator", "note": "no credits", "resetsAt": null},
              "turn_id": null, "observed_at": 1794050000, "reenabled_at": null}
  }
}
```

Each entry keeps the former `claude_quota` shape. Native evidence (Claude only) is a structured `rate_limit_event` with rejected `seven_day`, no active overage and no allowed overage. Generic authentication, network or provider errors, text that mentions limits, and other quota windows are never quota. Operator evidence is `{"source": "operator", "note", "resetsAt"}` with a `null` `turn_id`.

A harness is out until its positive numeric `resetsAt` (Unix seconds) has passed, or until `reenabled_at` is set. A missing or unparseable reset stays `null` and requires a re-enable; localized text such as "1pm" is never parsed. Re-enabling keeps the evidence, and a later confirmed rejection disables the harness again. Invalid evidence fails the start visibly instead of selecting another option.

At service start, the `claude_quota` of an existing `backends.json` is imported once into a new `availability.json`, together with its `preferred`/`fallback` pair as `"preferences": {"preferred": {"backend": "claude", "model"}, "fallback": {"backend": "codex", "model"}}`. `backends.json` is not read again. The pair serves only starts that name neither a profile nor a backend.

### S1 mini policy

On the Mac mini, `deep_coding` lists `claude-opus-5-5` first and Codex second. While Codex has no credits, it is marked out in `availability.json` with the operator entry above. `deep_coding` therefore resolves to Claude (`preferred`), and to `profile_unavailable` while Claude's weekly quota is also out. Remove the Codex entry, or set its `reenabled_at`, once credits return.

Turn metadata separates `requested_model` from native-confirmed `model`. The first normalized model a top-level native record reports is the turn's `model`; subagent records (`parent_tool_use_id`) never count. A later top-level record with a different model records `model_changed` (`first`, `reported`, `at`) and stops the turn the way `stop` does, so the slot stays latched until `release`. Continuation keeps its saved provider and model whatever the policy or quota now says; Claude requires a confirmed model rather than falling back to a requested alias.

## Codex dedicated repository permissions

For an explicitly authorized Git/PR assignment in an **independent clone**, a separate, fixed permission profile applies. Work reaches it through the repository workspace ([Managed repository provisioning](#managed-repository-provisioning)); a folder with `dedicated-repository`, as below, was a pre-cutover form the work contract does not offer in S1:

```sh
atlas-runtime start --cwd /canonical/path/to/independent-clone --permissions dedicated-repository "Complete the assigned change and create its PR"   # before the cutover
```

It could not be combined with `--sandbox`. It permits writes only beneath the canonical repository root, including its own `.git`, while retaining read-only `.agents`, `.codex` and `.aws` paths. Outside writes, including system temporary directories and home caches, remain denied; tools needing writable caches must use repository-local paths. Existing read access is unchanged, except that the Runtime home and the Code token with its directory are denied (`none`); a managed repository below the home stays writable as the more specific path. Because Codex cannot even `lstat` below a `none` path and Git `lstat`s every ancestor of its worktree, a home (or token directory) containing the repository is not denied whole: every entry existing at launch in it and in each directory down to the repository is denied unless it lies on that ancestor chain, and `runtime.sock`, `backend.sock`, `turns`, `code.json`, `server.json`, `backends.json`, `policy.json`, `availability.json`, `service.log`, `service.lock`, `passes`, `snapshots`, `materializations`, `scratch` and the Code token are denied by path even when absent at launch. A repository inside one of those named entries is refused. Every other `workers/<id>` directory, including one created after launch, is also denied by Codex deny-read glob entries, which Codex checks at access time; a Runtime home path containing `\` is refused. Known limits: other entries created after launch directly in the home or inside the worker's own `workers/<id>` are not covered, and the ancestor directories' names, including the worker names in `workers`, stay listable. The globs rely on Codex glob deny-read support, verified with Codex 0.167.1; no minimum Codex version is enforced. Command networking uses Codex's enforced proxy and allows only `github.com` and `api.github.com`; no unrestricted network fallback is provided.

Validation refuses linked worktrees, non-root/aliased paths, external/shared Git metadata, object alternates, metadata symlinks and shared hardlinks. Project/ancestor and system Codex configuration files are refused because legacy sandbox settings can override a native profile; the ignored user config is exempt. Use an independent remote clone, not a local clone with shared objects. Validation runs before launch and again before native execution.

The status/history `permissions` object records profile name/version, canonical root, Git directory and exact allowed network hosts; `sandbox` is `null` for this opt-in. Both ordinary and saved-turn continuation retain and revalidate that scope. There is no permission override on continuation and no fallback to a legacy mode. Native execution retains ignored user config/execpolicy rules, disabled hooks, no approvals, exact session confirmation and owned-process cleanup. The native profile path does not pass the conflicting `--sandbox` flag.

Use HTTPS Git transport with the existing GitHub CLI authentication when the stored origin uses SSH. For example, `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' -c remote.origin.url=https://github.com/eyra/atlas.git fetch origin develop`. Apply the same per-command URL/helper settings to push; do not change global Git configuration or copy credentials. `gh pr create --repo eyra/atlas ...` uses the same allowed GitHub API host. Domain approval does not restrict access to one GitHub repository: the authenticated account's GitHub rights still apply.

Verified on macOS with Codex 0.166.0. Other platforms/versions are not certified. Native network denial can terminate the entire shell command; it is not necessarily a catchable HTTP error inside a script.

## Managed repository provisioning

Both a Claude and a Codex option of the profile support this existing provisioning path. Git preparation still uses the installed Codex sandbox and its fixed repository profile, without making a Codex model request. Missing Codex fails explicitly rather than running unsandboxed Git. Once preparation and scope validation succeed, Claude executes in its own native repository-plus-private-temp scope; there is no nested Codex wrapper around Claude. Existing clone identity, clean-worktree, branch-existence and ownership checks apply unchanged. Explicit successful-session continuation preserves unfinished work.

Workspace validation, exclusive ownership and Git preparation live in `platform/atlas_runtime/host/workspace/workspace.go`. Elixir admission calls the CLI's internal `workspace` command for path, scope and repository-request checks; `native-host` uses the same package in process and holds the directory lock until native process-group cleanup finishes. The launching CLI supplies its own executable path to the daemon through `ATLAS_RUNTIME_EXECUTABLE`; no alternate installed binary or runtime Go compilation is used. Go owns Git arguments and clone/fetch/branch/continuation checks. Elixir keeps admission and lifecycle ownership. See the [Runtime architecture](../../../docs/runtime-architecture.md) for the implemented boundary and the proposed Code service contract.

Verified through an isolated public CLI on 2026-11-07: eligible preferred Claude provisioned `https://github.com/eyra/atlas.git` on `work/runtime-claude-managed-proof` at freshly fetched base `c59b1971b323f1242fb372a1a4ebe926f7db4167`. Turn `turn-2a5912b14bd3f675`, native `claude-opus-5-5`, session `e29bd430-e7e0-4ac2-b79b-613fe864b517`, made one successful Bash call and local commit `5501bcf876a65e4a3c5b79ddd049c468754d8bc1`. Its parent matched recorded base and `origin/develop`; its only changed file contained `native Claude managed provisioning proof\n`. Repository remained clean, private temp and native process group were absent afterward, and the isolated service was stopped. No worker push/PR, live Atlas call or default-instance change occurred. Focused verification passed 25 Python runner/provisioning tests and 26 Elixir policy/native-adapter tests.

To have Runtime provision the clone and task branch, supply an explicit GitHub HTTPS URL and a new branch instead of `--cwd`:

```sh
atlas-runtime start --profile deep_coding --cost-class standard --repo https://github.com/eyra/atlas.git --branch work/server-task "Complete the assigned change"
```

The daemon manages one independent clone per worker and normalized owner/repository beneath its selected state directory: `workers/<worker>/repositories/<owner>/<repository>`. Each caller supplies its own task branch. Older managed paths remain available to their saved continuations; new starts use worker-specific paths without moving existing work. The URL must name `https://github.com/OWNER/REPO[.git]`, without embedded credentials, query strings or fragments. `--repo` and `--branch` form the repository workspace (dedicated-repository permissions), with `--base` `develop` (the only base accepted; anything else is `unsupported-workspace`), and cannot be combined with `--cwd` or `--permissions`. Repository choice, branch name and assignment remain external decisions.

Runtime clones an absent path, or reuses only a Runtime-marked independent clone with a matching origin and clean tracked/untracked state. It freshly fetches remote heads and creates the requested new branch at exactly the fetched `origin/develop`, recorded as `base_sha`. Existing local or remote task branches are refused, including `develop`. Dirty, unmanaged, mismatched or actively owned paths are refused without reset, stash, deletion or branch overwrite; ignored-file collisions also prevent checkout. Previous task branches/commits stay intact. Stale remote-tracking branches are not automatically pruned.

Managed starts do not use Code: this older Git-native profile resolves `develop` itself, in the worker's sandboxed clone. Admissions recorded while Code resolved the base keep their `resolved_commit` as recorded. Code serves materialized folders (snapshots, changes, reviews and integrations), which use only its opaque revision handles.

Git preparation runs under the same native repository/network profile, using the existing GitHub credential helper without copying credentials or changing global Git config. The existing runner holds an advisory directory lock through preparation, native execution and process-group cleanup. Dedicated-repository starts, and legacy `--cwd` starts on a marked managed clone, honor that lock. The daemon also refuses canonical identical, nested or parent workspace overlap with any active worker, including symlink aliases and unscoped sandbox modes. Directory locks coordinate Runtime owners; they are not locks against humans or other tools that ignore them.

`start` still returns before completion: a running turn is not proof that preparation or native execution succeeded. On preparation success, the stream includes `runtime.repository_prepared`, and status/history persist `repository: {url, branch, base_sha}` before the worker starts. Preparation refusals leave a failed turn with diagnostics in its `stderr.log`; partially prepared paths are preserved for explicit inspection, never automatically deleted or retried.

Saved/ordinary continuation reuses the exact session and scope without fetching, recreating a branch or discarding unfinished work. Managed continuation additionally requires the saved origin and branch to still match. If another task reused the clone and switched its branch, continuation refuses rather than switching it back. No automatic scheduling, recovery, installation, merging or deployment is introduced.

The client talks to owner-only Unix sockets under `~/.local/state/atlas-runtime/`. `service.log` contains daemon diagnostics. Per-turn artifacts retain full native JSONL, stderr, final answer and process details. `output --turn ID` returns one page of the turn's public output (`events` of kind `text` or `activity`, `cursor`, `more`); pass `--cursor` for the next page. The output buffer is in memory: a turn from before the last restart answers an empty page, while its artifacts stay on disk. A work's final answer (at most 8 KB) is in its attempt's `result.answer`. Restart resets the in-memory worker registry; retained artifacts do not trigger restoration or re-execution.

`output --follow` is gone with the cutover: follow progress with `events --follow` and `status`, and read output pages with `output --turn`.

Inspect local turn history through the running daemon (the history contract on `backend.sock`):

```sh
atlas-runtime turns
atlas-runtime output --turn turn-0123456789abcdef
```

`turns` returns a `turns` array, every page in order, in the history contract's shape: `turn_id`, `slot`, `state`, `native_outcome`, `started_at`, `ended_at`, `harness`, `configured_model`, `reported_model` and `conversation_id`; no assignment, folder, settings or native session. It lists turns from before the cutover too, to the socket's owner. Each new turn saves `turn.json` atomically beside its existing artifacts at start, native session confirmation, and terminal transition. Unknown/malformed turn IDs fail.

Work and its attempts survive daemon restart (`work/` in the home): a turn that was running becomes `interrupted`, and `retry --resume` continues it. `continue --resume-from ID` selects a saved conversation; failed turns are eligible when their native session ID is confirmed. Older artifact folders without metadata remain readable with state `unknown`; missing assignment/timestamp/session fields are not guessed. A saved `running` turn no longer owned by this daemon is shown as `unknown` with `recorded_state: running`, not claimed to be active or successful. No automatic restart, crash recovery, retention/deletion policy or server connection is introduced.

Requires the normal Elixir/OTP/Mix toolchain and the selected official CLI (`codex` or `claude`) on PATH. First service start compiles the `beam` umbrella (Runtime, Bus and the model that `server.json` wires) into its own build directory; it starts only Runtime and Bus. `ATLAS_RUNTIME_HOME=/absolute/path` selects an isolated instance; use it consistently across commands. Directory aliases are resolved before building, including macOS `/tmp` → `/private/tmp`, so Mix's relative `priv` links resolve correctly.

## Optional Atlas Server lifecycle reporting

Opt-in: lifecycle, and live public output for Console. Write `server.json` in the Runtime home before `service start`:

```json
{"environment": "test", "machine": "laptop-runtime", "host": "127.0.0.1", "port": 4100,
 "token_file": "server.token", "workers": ["runner"]}
```

Without `server.json`, nothing changes: no Bus link, no reporter, no extra `turn.json` fields. If it is present but invalid, the service refuses to start. `machine` must be a valid, explicit name dedicated to this service; never use a machine another Bus client already uses. The Bus link token is bound to that machine. A local check cannot prove that no other node uses the name: an actual link or attach conflict shows up as an unconfirmed report. `token_file` must be a regular file inside the Runtime home, with no symbolic link on its path, owned by the home's owner and readable by nobody else (`chmod 600`). Invalid files are refused, never repaired. The token goes only to the Bus link. It is never put in the environment, native input, status, history or artifacts. The Bus link client keeps it out of its supervisor child spec and start arguments, and holds it only in an opaque closure. Printed diagnostics (default and SASL crash reports, failure arguments, a caller's exit) therefore show `#Function<…>` instead. This protects printed output only: code in the same VM can still read the token, for example from the application env or the process state.

`workers` controls reporting only. For each turn of a listed worker (each must be an existing Server agent), the service saves a `server` record in `turn.json` before any remote write: `environment`, `machine`, `worker`, the Server turn `TU-<machine>-<local turn ID>` and a fresh `attempt`. Local turn IDs never change. A background reporter then, as `runtime@<machine>`:

1. creates that turn `running` on this machine, by its worker, without an item, with its `title` (the assignment's first heading and line, at most 120 characters) and the requested `model`, when there is one;
2. registers that exact attempt's `worker_execution`, with harness `codex`/`claude`, harness version `unknown`, the requested model or `unknown`, and `queued_input`, `durable_accept_query` and `consumption_evidence` all `false`;
3. renews `activity` and `lease_until` at most once per lease interval, as connected turns do;
   and writes the turn's `model` once the harness reports it (the execution record is immutable and written before that, so it keeps the requested model or `unknown`);
4. ends it `ended` with an empty lease, `ended_at`, and `why` `finished`, `failed: <error>`, `stopped` or `killed` (not verified against Server consumers).

It never sets a Flow outcome or item ownership, and Server gets no start, stop or guidance control over the native agent. Unlisted workers run as before, with no Facts writes.

`status`, `turns` and `turn.json` show what Server confirmed, in `server.report`: `turn` (`unconfirmed`, `running`, `ended`), `execution` (`unconfirmed`, `registered`) and the last failure in `error` (for example `turn not created: Facts did not answer`). Each write is one bounded exchange, so a missing or refusing Server never delays or changes `start`, `output`, `stop` or the local terminal state. `service stop` cancels the running turns and returns once `backend.sock` is gone. The daemon waits up to 5 s for pending reports before it exits, and the command returns once it has. With Server unreachable, a measured `service stop` took about 6 s in total.

This is a best-effort mirror. There is no retry queue, replay, crash reconciliation or automatic recovery. A failed write stays failed. If the turn was never created, nothing more is written for it. A turn left `running` by a daemon that died keeps a lease that simply runs out.

### Live output

A reported turn's public output is also kept, in memory, in the existing Runtime output ring under its exact Server identity: `environment`, `machine` and `worker`, the Server turn and its `attempt`, as saved in `turn.json`. The service opens the ring before it handles any of the agent's events and closes it when the turn finishes, fails (including a crashed agent) or is stopped. Only the provider's public projection goes in, the same one connected turns use: completed assistant text, and tool name with `started`/`completed`/`failed` (or a short activity line). Native records, reasoning, tool input and results, session details and the token never do. Text is split into bounded events, and retention, expiry and gap `reset` behavior are the ring's own (at most 1000 events, 1 MiB and 15 minutes per turn). Nothing new is persisted: `output` and the artifacts are unchanged, and output from before a daemon restart is gone.

With `server.json`, the service serves the existing read-only output endpoint as `runtime@<machine>/output`, for the configured `machine` only, over the same Bus link. Console reads it through Control's existing exact-attempt route. A request for any other machine, turn or attempt gets `output_unavailable` or `invalid_request`, never output. Without `server.json`, no link is made and no reported ring exists, so nothing is served off this machine. Output is recorded locally and never waits for Server. After a down link recovers, retained output is readable if Server registered the execution; a refused registration does not become readable merely because the link recovers. A lost ring does not fail the native turn, and its next public event reopens the ring in a new epoch. Local ring calls are synchronous and retain their normal timeout; this is not a zero-delay guarantee. Viewers can only read: there are no start, stop, guidance or other controls.

## Install

From the Atlas checkout, with Go installed:

```sh
go -C platform/atlas_runtime/host build -ldflags "-X main.repoRoot=$PWD" -o "$HOME/.local/bin/atlas-runtime" .
```

The binary points to this checkout for service startup; rebuild if the checkout moves. Restart an existing daemon after updating the service/adapter code so it loads the new version (stopping the service also stops any active agent). The service is not implemented in Go and does not live inside the client process. Existing Atlas-connected launcher tooling is left untouched.

Development checks use `go -C platform/atlas_runtime/host test ./...`. Runtime ExUnit tests build an isolated copy of the same command plus a small Go fake native CLI, so those test runs require Go; they do not reuse or replace the installed client. All native executions run through the CLI's internal `native-host` command; workspace behavior is implemented only in Go. Runtime build, execution and tests do not use Python. The local Go module has no external dependencies.

### Persistent instance

The machine has one Runtime installation: `$HOME/.local/bin/atlas-runtime`, built from the main clone as above. Its home is set once in the shell environment (for example in `~/.zshenv`):

```sh
export ATLAS_RUNTIME_HOME=/abs/runtime-home
```

Every `atlas-runtime` command then uses that binary and home. They belong together: a daemon launches workers through the binary that started it, so do not start this home's daemon from another binary.

```sh
#!/bin/sh
# atlas-dev-code: runs Code in the foreground until stopped
cd /abs/persistent-checkout/platform/atlas_code || exit 1
ATLAS_CODE_HOME="${ATLAS_CODE_HOME:-/abs/code-home}" exec mix atlas_code.server
```

```sh
atlas-dev-code               # own terminal; prints "Code ready on 127.0.0.1:PORT"
atlas-runtime service start
atlas-runtime service status # runtime info: mode, incarnation, slots with busy
atlas-runtime turns          # saved history across workers and restarts
atlas-runtime service stop
```

For a process supervisor (launchd), run Code as the `atlas_code` OTP release instead: it skips `mix`'s startup (compile check, deps), so a restart after a hard kill takes well under a second instead of ~14 s. It starts Code through the same path as `mix atlas_code.server` (`AtlasCode.Server.serve/1`): same `ATLAS_CODE_HOME`, owner, lock and recovery, and the same `Code ready on 127.0.0.1:PORT` line. On a Mac set up by `install.sh`, its launch agent runs the release that comes with the installed Runtime release ([Start at login](#start-at-login-macos)); nothing is built on the machine. The release carries no ERTS: it boots on the Erlang on `PATH`, which must be the one it was built with (the `.tool-versions` of the tree). To build it from a checkout instead:

```sh
cd /abs/persistent-checkout/products/software_factory
MIX_ENV=prod mix release atlas_code          # writes _build/prod/rel/atlas_code; --path DIR elsewhere
```

```sh
#!/bin/sh
# atlas-code: runs the Code release in the foreground until stopped
ATLAS_CODE_HOME="${ATLAS_CODE_HOME:-/abs/code-home}" \
  exec /abs/persistent-checkout/products/software_factory/_build/prod/rel/atlas_code/bin/atlas_code eval "AtlasCode.Server.run()"
```

Use `eval "AtlasCode.Server.run()"`, not `bin/atlas_code start`: Code's application starts only the core's effect receiver, which this release never configures, so `start` would boot an idle VM. The release reads no `config/runtime.exs` (no `ATLAS_ENV` needed), as with the mix task. It exits nonzero without `ATLAS_CODE_HOME` or when start is refused; SIGTERM stops it as below. `mix atlas_code.server` remains the way to run Code during development; `mix atlas_code.unlock` and `mix atlas_code.migrate` stay mix tasks.

Run one Code process per Code home; a second start, or `mix atlas_code.migrate`, is refused while `service.owner/` names a live owner. Stop Code with SIGTERM (`kill PID`): it stops serving, then releases the home. Ctrl-C, a crash, SIGKILL or power loss leaves `service.owner/` behind; the next start recovers it itself when `ps` shows the recorded PID gone, keeps the `service.owner.ended-OWNER` tombstone, logs the old owner ID and PID, and starts, so a process supervisor such as launchd can restart Code. While that PID is running (including a PID since reused by another process) or `ps` cannot tell, start is refused as before and prints the owner's ID; once you have checked that the owner has stopped, recover with `ATLAS_CODE_HOME=/abs/code-home mix atlas_code.unlock --owner OWNER` (same check), or, for a reused PID, rename `service.owner` to `service.owner.ended-OWNER` by hand. `mix atlas_code.migrate` never recovers automatically. Atlas itself does not restart Code. The Runtime home's `code.json` keeps pointing at that port and `runtime.token`. Existing homes, saved turns and the daemon are reused unchanged; the wrapper moves or overwrites nothing. Rebuild the binary only after its daemon is stopped.

### Start at login (macOS)

On a dedicated Mac, launchd starts the Runtime with its Bus link and its Code service at login. The files are in [`macos/`](macos): `start.sh` (fetches the Bus token, writes `server.token` and `server.json`, waits for the Bus port, runs `atlas-runtime service start`), `secret.sh` (one secret from Infisical, with credentials from the login keychain), `fly-proxy.sh` (the private Bus tunnel to a Fly app) and `code.sh` (the Code service: the `atlas_code` release of the installed Runtime release, the one `atlas-runtime version` names as `root`). `install.sh` copies them to `~/.config/atlas-runtime/` and writes their launch agents: `com.mimbre.atlas-runtime` (runs `start.sh` once at login) and, when configured, `com.mimbre.atlas-fly-proxy` (keeps `fly-proxy.sh` running) and `com.mimbre.atlas-code` (keeps `code.sh` running). With `code` it also writes the Code home's `config.json`, its `runtime.token` once (never replaced), and the Runtime home's `code.json` naming both. Logs: `~/Library/Logs/atlas-runtime-start.log`, `~/Library/Logs/atlas-fly-proxy.log` and `~/Library/Logs/atlas-code.log`.

No secret is ever a process argument (`ps` shows none): `secret.sh` gives `infisical login` the client ID and secret in its environment (`INFISICAL_UNIVERSAL_AUTH_CLIENT_ID`, `INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET`) and `infisical secrets get` its token as `INFISICAL_TOKEN`; `fly proxy` gets `FLY_API_TOKEN` in its environment, and the Runtime its Bus token in `server.token`.

Everything machine-specific is in `~/.config/atlas-runtime/machine.json`, outside the repository; the scripts read it each time they run. See [`macos/machine.example.json`](macos/machine.example.json):

| Key | Meaning |
| --- | --- |
| `machine`, `environment`, `workers` | written into `server.json` (see [Optional Atlas Server lifecycle reporting](#optional-atlas-server-lifecycle-reporting)) |
| `runtime_home` | the Runtime home (`ATLAS_RUNTIME_HOME`); set the same value in `~/.zshenv` |
| `path` | `PATH` for the service and its workers: `atlas-runtime`, the asdf shims (Elixir), `codex`/`claude` |
| `bus.host`, `bus.port` | the Bus listener in `server.json`; `start.sh` waits up to 60 s for it |
| `fly_proxy.app`, `fly_proxy.remote_port` | optional: tunnel `127.0.0.1:bus.port` to that port of that Fly app; leave out when the Bus is reachable directly |
| `code.home`, `code.config` | optional: the Code service. `code.home` is its home (`ATLAS_CODE_HOME`, not the Runtime home); `code.config` is the home's whole `config.json` (`port`, fixed, which `code.json` names; `repositories`). Needs a released build installed |
| `infisical.domain`, `.project_id`, `.env`, `.path` | where this machine's secrets are: `ATLAS_BUS_LINK_TOKEN` (this machine's token) and, with `fly_proxy`, `FLY_API_TOKEN` |

**Install on a new Mac.** Log in as the user that runs the Runtime, install the asdf Erlang/Elixir of `.tool-versions`, `codex`/`claude`, the Infisical CLI and, for the tunnel, flyctl, and give the machine its own Infisical universal-auth identity that can read only its folder (`infisical.path`), with its secrets there. Then run the install command of a released build, `install-macos.sh` next to its archive (`macos/bootstrap.sh`, published by [`release.sh`](release.sh)). Its secrets come only from the environment, never from an argument:

```sh
curl -fsSLO https://github.com/mimbre/atlas/releases/download/atlas-runtime-BUILD/install-macos.sh
INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=… INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=… ATLAS_WORK_SOURCE_TOKEN=… \
  zsh install-macos.sh --build BUILD --environment prod --machine mac-mini --workers dev1,dev2 \
    --source-url https://… --git-url https://… --fly-app APP --fly-remote-port 7594 \
    --infisical-project-id ID [--dry-run]
```

It stores the Infisical identity in the login keychain (through `security -i` on its stdin, so not as an argument) and the work source credential as `sources/flow/token` in the Runtime home; writes a first `policy.json` when there is none (version 1: the source and the slots, no profile, so the Runtime takes no work until Control's configuration, version 2 or above, replaces it on its first poll; the source itself cannot change later); installs the build with its own `atlas-runtime service update --build BUILD --restart none` (the SHA-256 checked, as for an upgrade); writes `machine.json` from its arguments and `ATLAS_RUNTIME_HOME` in `~/.zshenv` when that names none; and runs the release's `install.sh`, which loads the Runtime, Fly proxy and Code agents. Each step is skipped when it is done already, so running the command again changes nothing. On a Mac that runs another build it stops: upgrade that one through Control. The head of `bootstrap.sh` lists every option.

**By hand**, the same from a checkout: put the identity's credentials in the login keychain under the machine name (`security add-generic-password -a MACHINE -s atlas-infisical-client-id -w`, and `-s atlas-infisical-client-secret`; each prompts for the value), write `~/.config/atlas-runtime/machine.json` (mode 600) from the example, then `platform/atlas_runtime/host/macos/install.sh --dry-run` (checks machine.json, tools and keychain items; shows what would change) and `install.sh`.

`install.sh` is idempotent: identical files are left alone, and an agent is (re)loaded only when its plist changed or it is not loaded (the Code agent also when its `code.sh` or `config.json` changed). A hand-made `com.mimbre.atlas-code` is replaced once `machine.json` has `code`, and left alone without it. Loading the Runtime agent runs `start.sh`, which starts the service, or does nothing when it is already running; it never stops a running Runtime. Reloading the tunnel agent drops the Bus link for a moment; the Runtime links again by itself. A changed `start.sh` takes effect at its next run.

**Update.** Upgrade the Runtime through Atlas ([Upgrading through Atlas](#upgrading-through-atlas)): nothing is typed on the machine. The update restarts the Code agent too, so Code runs the new release's `atlas_code`. A changed `start.sh` or launch agent still needs `install.sh` again (the new release's, under `~/.local/share/atlas-runtime/releases/BUILD/platform/atlas_runtime/host/macos/`).

**What survives a reboot.** Launch agents run only in a logged-in session, and `secret.sh` can read the keychain only there. So the Mac must log in by itself: System Settings → Users & Groups → *Automatically log in as* this user (not available with FileVault on), with the login keychain's password equal to the login password, so that the login unlocks it. Then, after a reboot: the tunnel agent starts and is restarted every 10 s until it holds; `start.sh` retries the token for 5 minutes (the network or keychain may not be ready yet), writes `server.json`, waits for the Bus port and starts the service; `server.token` is deleted again once the service has read it. Turns running at the moment of the reboot do not continue, and their Server turns keep their lease until it runs out. The Code agent starts at login too and is restarted every 10 s until it holds. Not managed here: sleep and power settings (for a server, `sudo pmset -a sleep 0` and `sudo pmset -a autorestart 1`).

**Rehearse a reboot.** Only when no slot is busy:

```sh
atlas-runtime service status           # every slot "busy": false
atlas-runtime service stop
sudo shutdown -r now
# after the Mac is back, without logging in by hand:
tail ~/Library/Logs/atlas-fly-proxy.log ~/Library/Logs/atlas-runtime-start.log ~/Library/Logs/atlas-code.log
launchctl print gui/$UID/com.mimbre.atlas-runtime | grep 'last exit code'   # 0
launchctl print gui/$UID/com.mimbre.atlas-code | grep 'state'               # running
atlas-runtime service status           # new incarnation, slots idle
ps -axww -o command | grep -E 'infisical|fly proxy|atlas'   # no secret in any argument
```

Then start one turn of a listed worker and check that it shows up on the Server with a confirmed `server.report`. To exercise only `start.sh` without rebooting (not the auto-login and keychain), stop the service and run `launchctl kickstart gui/$UID/com.mimbre.atlas-runtime`.

### Upgrading through Atlas

A Runtime is upgraded to a build Atlas released, never to a checkout on the machine (IS-Atlas-26, UC-Atlas-50).

**The release.** Each push to develop (test) and master (prod) publishes the Runtime at its revision as the GitHub release `atlas-runtime-<branch>-<commit12>` (CI job `deploy-runtime-release`, [`release.sh`](release.sh)): one `atlas-runtime-BUILD-darwin-arm64.tar.gz` with its `.sha256`. It holds the Atlas tree at that revision with its generated targets and the umbrella's Hex dependencies, `BUILD` (the build's name) and `bin/atlas-runtime`, this CLI built without a checkout location: it runs the Runtime from the release it is in and gives it `ATLAS_RUNTIME_BUILD`, so `service status` shows the build as `runtime_build` (a checkout build shows the application's version). `atlas-runtime version` prints the build and the tree.

**The supervisor starts it from Control.** On the Runtime's machinery page in the Console, or from the CLI:

```sh
atlas put runtime_upgrade --in mac-mini --build develop-0123456789ab --env test
atlas get RU-01 --env test      # step, busy, from_build, incarnation, failed_step, reason
```

Then, one poll of the Runtime at a time (`AtlasFlow.WorkSource.Upgrade`, `AtlasRuntime.Upgrade`, `work_source` 0.5.0), the upgrade's `step` and its flow (`runtime_upgrade`) move on:

1. `draining`: Flow orders the Runtime to drain (`service drain`): no new work, the unstarted work returned, running turns finish.
2. `waiting`: while a slot runs a turn; `busy` names the slots.
3. `updating`: once no slot is busy, the Runtime runs its update command in the background (below), once per upgrade.
4. `verifying`: the Runtime polls again from a new incarnation on the build; Flow orders it to resume.
5. `done` once it is open and offers its slots, so it accepts work again; or `failed`, with `failed_step` (`start`, `update` or `restart`) and `reason`. An upgrade that does not move on for a while shows `Stalled`, and goes on by itself when the Runtime reports again.

One upgrade at a time per Runtime: a second one under the same machinery is refused when it is made, while one has not ended (and Flow ends any that got through `failed` at `start`).

**The update command.** `atlas-runtime service update --build BUILD` is the one command that installs a release, run by the Runtime for an upgrade and by hand as well:

- it takes `update.lock` in the Runtime home, and refuses while another update holds it, naming it (`another update holds the lock: upgrade RU-01 to build … (pid …)`);
- it refuses while a slot is busy, naming the slots (`slot busy: dev1; …`), exit 1 with `{"update": "refused", "step": "update", "error": …}`. A Runtime that is open is paused first, so nothing starts between the check and the stop, and opened again after;
- it downloads the release from `https://github.com/mimbre/atlas/releases/download/atlas-runtime-BUILD/` (`--releases URL|DIR`, or `ATLAS_RUNTIME_RELEASES`), checks its SHA-256 and that its CLI says it is BUILD, unpacks it into `~/.local/share/atlas-runtime/releases/BUILD`, and points `~/.local/bin/atlas-runtime` (`--install PATH`) at its CLI, a symbolic link swapped in one rename;
- it stops the Runtime and starts it again through its launch agent (`launchctl kickstart gui/$UID/com.mimbre.atlas-runtime`, as at login, after `kickstart -k` of the Code agent `com.mimbre.atlas-code` when there is one) or, without one, with the new CLI's `service start` (`--restart auto|launchd|direct|none`); a stopped Runtime is only installed;
- it waits (up to 20 minutes: the first start on a release compiles it) until `service status` shows BUILD in a new incarnation. A Runtime that was draining stays draining: the upgrade resumes it.

What it did is in `update.json` in the Runtime home (`upgrade`, `build`, `state`: `running`, `refused`, `failed` or `installed`, `step`, `reason`, `previous`: the CLI the install pointed at before); a detached run logs to `update.log`. All three are denied to the Runtime's agents, as the rest of the home is. To go back by hand, update to the earlier build again.

**Once, by hand.** A Runtime from before this release runs a CLI without `service update` and ignores an upgrade. Bring it to a release once: build this revision's CLI, then `atlas-runtime service update --build BUILD`. From then on its upgrades go through Atlas.

## Model-free native sandbox verification

On macOS with Seatbelt and the official Codex CLI installed, run from `platform/atlas_runtime` with `ATLAS_RUNTIME_EXECUTABLE` pointing at a built `atlas-runtime`:

```sh
MIX_ENV=test mix run --no-start host/verify_sandbox.exs
```

This opt-in check requires no login or model call and starts no Runtime daemon or Atlas core applications. It uses isolated workspaces and empty Codex homes, then removes its own temporary files. The Runtime adapter and native host launch a small shell bridge that reads the actual forwarded permission profile (`default_permissions` and its `permissions` table) and `--cd` arguments. The host forwards each mode as an explicit profile, `atlas_read_only` or `atlas_workspace_write`, extending Codex's documented [built-in permission profiles](https://developers.openai.com/codex/permissions) `:read-only` and `:workspace` with the Runtime home deny; the bridge invokes the official `codex sandbox` command with exactly that profile to execute the same bounded shell write. The bridge records the native exit status and stderr; it does not simulate denial or perform the write itself.

Assertions require read-only to produce an actual `Operation not permitted` shell error, exit 1 and unchanged `before\n` bytes; workspace-write must exit 0 and produce exact `after\n` bytes. A wrong forwarded mode changes the native outcome and fails the check. CLI configuration/usage errors cannot pass as a read-only denial. Codex 0.166.0 was exercised; older CLIs lacking these built-in profiles will fail this explicit check rather than silently skip it.

Boundary: this proves native sandbox enforcement and adapter-to-native mode selection through the bridge, not model-driven `codex exec` scheduling or its internal legacy-flag-to-profile conversion. It does not test broader filesystem/network confinement or other platforms. No production policy or adapter implementation is changed.

## Verified

Explicit Claude selection was exercised through an isolated public Runtime CLI with Claude Code 2.1.280. Native initialization confirmed only `Glob`, `Grep`, `Read`, no MCP servers, `dontAsk`, and model `claude-opus-5-5[1m]`. The single attempt was rejected by the existing weekly limit: `rateLimitType: seven_day`, `overageDisabledReason: out_of_credits`, zero input/output tokens. Runtime retained the model/session and exact error answer, marked the turn failed, refused continuation, and cleaned the native process group. No retry or fallback was attempted. A successful real Claude read remains unverified because of this quota limit; deterministic native-stream regressions cover successful completion, identity requirements, error precedence and private-content filtering.

Preference/fallback verification used clearly labelled synthetic replay of that exact previously observed weekly-quota event, not another Claude provider call. After an isolated daemon restart, a new public CLI assignment selected real Codex `gpt-6.1-sol`, returned `FALLBACK_OK`, and recorded native-confirmed model identity plus the quota selection reason. After explicit Claude re-enablement, Codex continuation kept the same session/model and returned `CONTINUATION_OK`. Public CLI/daemon checks also proved re-enablement persistence, generic-error non-poisoning, explicit backend override and incapable-backend refusal. Successful real Claude completion remains unverified; no additional Claude quota was consumed.


Installed CLI exercised against a separate real daemon: idempotent service start, real Codex completion reading a disposable file, concurrent-start refusal, output retrieval, explicit real Codex stop with native-process cleanup, daemon survival after agent stop, service stop/restart, and refusal without implicit startup when the service is stopped. A synthetic hanging executable also proved daemon shutdown cleans its active agent process group. All smoke daemons were stopped.

2026-11-06: added the standalone Runtime service and Go client; kept Atlas orchestration out of this first interaction.

2026-11-06: fixed aliased build directories and separated command-error replies from failed-turn data. Reverified the reported `/tmp` instance with a real Codex assignment, then proved synthetic failure inspection exits zero while a refused command still exits nonzero. Response regression: `go test platform/atlas_runtime/host/main.go platform/atlas_runtime/host/main_test.go`.

2026-11-06: added explicit `--sandbox workspace-write`, retaining read-only defaults. Real Codex proof: default mode denied a write and left the file unchanged; opted-in mode changed exactly the requested file bytes; cancellation in write mode removed the recorded native, helper and sleep processes while leaving the daemon running. Unsupported sandbox admission and existing lifecycle regressions pass.

2026-11-06 release review: normal completion now terminates remaining descendants in the owned process group, including children that redirected their output. A synthetic regression reproduced the leak before the fix and passed afterward; no model invocation was needed.

2026-11-06: added explicit post-success `continue` with fixed cwd/sandbox. Installed CLI retained a marker across two real turns with the same native session ID and distinct Runtime IDs. Go response tests and all nine Codex adapter tests passed, including rejection of missing/mismatched resume confirmation.

Independent installed-CLI continuation verification passed: retained context, explicit-session resume, fixed cwd/sandbox, exact workspace-write bytes, CLI/socket override rejection, refusal while idle/running/stopped/failed, fresh-session starts, restart-to-idle, and cancellation of the recorded helper/native/descendant processes while the daemon survived. Both isolated daemons were stopped. The tester's separate read-only denial probe had only agent-prose evidence, not a captured command denial; no stronger confinement claim is made.

2026-11-06: added client-only `output --follow`. Real Codex smoke observed events while running and exactly matched all seven saved native events, ending with the expected final answer; idle returned immediately. Go regressions cover split UTF-8 records across EOF, a final record without newline, no duplicate emission, and truncated final JSON rejection.

Independent follow verification passed against the installed client and real daemon with deterministic native fixtures: live/replayed event equality, a 70,088-byte record, split UTF-8 across file growth, failed/stopped result inspection, viewer-only SIGINT, explicit agent stop, turn-replacement refusal, and visible service-loss errors. All owned followers and daemon processes were stopped. These fixture checks complement the real Codex smoke; they do not claim token-level streaming or abrupt-crash recovery.

2026-11-06: added persisted local turn history and explicit historical output. Installed real-Codex smoke ran an initial turn and continuation, inspected the first without replacing the second, restarted the isolated daemon, and recovered both finished turns in newest-first order with their shared native session, separate timestamps and correct answers. Current status remained idle; malformed turn ID was refused. Existing Go client regressions passed.

Independent installed-client/real-daemon history checks passed with deterministic native fixtures: finished/failed/stopped persistence, active-turn read isolation, graceful shutdown persistence, restart-to-idle, malformed/traversal ID rejection, legacy/stale-running unknown states, and a complete 1,207,791-byte history response. Ordinary individual output retains its pre-existing 1 MiB response cap. All owned test processes were stopped; abrupt-crash recovery was not claimed.

2026-11-06: added explicit saved-turn continuation. Real Codex smoke selected an older successful conversation after a newer unrelated session and daemon restart; the new turn retained the older marker, native session, cwd and sandbox. Plain continuation from idle still refused; selected history remained unchanged. Go client regressions passed; all owned smoke processes stopped.

Independent saved-resume verification passed: real Codex workspace-write after restart from a different client cwd, unchanged selected metadata, subsequent ordinary continuation, and 25 admission refusals without launching/replacing a turn. Deterministic native fixtures proved unavailable/mismatched session attempts fail without alternate-session launch, plus active-turn rejection and cancellation cleanup. Both isolated daemons were stopped; provider-side session deletion and abrupt-crash recovery were not tested.

2026-11-06: closed the native write-denial evidence gap with the model-free verification above: 2 checks passed against official Codex 0.166.0, with real shell stderr/exit and exact on-disk bytes for both modes. The existing Codex adapter suite also passed all 9 tests.

2026-11-06: fixed a macOS cleanup exit race. Signalling an owned group whose last member is exiting/unreaped can return EPERM before a nonblocking poll can reap the leader. The runner now waits up to its existing three-second cleanup bound for that owned leader and retries the same group signal once, preserving descendant cleanup. A live leader beyond the bound or a second permission denial still fails; permission errors are not ignored. This preserves the original protocol/session failure rather than replacing it with cleanup EPERM. Focused checks from `platform/atlas_runtime`: `python3 -B test/codex_runner_test.py -v` (3 real-process regressions) and `mix test test/codex_test.exs` (9 adapter tests), all passed. Direct runner smoke confirmed clean normal completion and explicit cancellation, with recorded native/sleep PIDs absent and empty helper stderr.

2026-11-06: added two cleanup safety-boundary checks without changing production code. With owned real processes and explicitly injected `killpg` permission failures, a live leader produces a bounded visible failure rather than hanging, and persistent denial still propagates after the exited leader is reaped. Existing exited-leader/live-descendant and original-session-error coverage is reused, not duplicated. `python3 -B test/codex_runner_test.py -v` now passes all 5 checks. These injected-denial results establish error propagation, not native foreign-user permission behavior or cross-platform proof.

2026-11-07: added explicit persisted dedicated-repository permissions. Disposable native Runtime proof created a branch/commit, denied outside/protected writes, fetched authenticated GitHub develop, accessed the repository API, and denied a nonapproved domain. Saved-turn continuation after daemon restart retained the same native session and exact scope; altered saved scope and worktree admission were refused. Eight Python regressions, ten Codex adapter tests, Go client tests and both model-free legacy sandbox checks passed. Default installed daemon and binary were not changed.

2026-11-07: added explicit managed repository provisioning through `start --repo ... --branch ... --permissions dedicated-repository`. An isolated Runtime cloned Atlas, fetched fresh develop, recorded its exact base, and ran a real native worker that created and committed one proof file. CLI checks preserved work while refusing existing branches, dirty state, mismatched origin and active ownership; clean reuse preserved the previous task commit. Saved continuation after restart retained native session/repository context and unfinished work, while older branch context was refused. Cancellation reaped the owned group and released repository ownership. Fourteen Python regressions, ten adapter tests, Go client checks and both native legacy-mode checks passed. Default installed Runtime was not changed.

2026-11-08: integrated the exact macOS Claude trust-service allowance and extracted shared workspace preparation without changing its validation or Git semantics. Focused verification passed 48 Python runner tests, 55 ExUnit native/admission/service tests and the Go CLI suite. Through the modified isolated Runtime, Claude turn `turn-ebf7aec4681a0c54` ran one ordinary `gh api --method GET repos/eyra/atlas` command with the requested JSON projection; its native tool result returned the repository identity with `is_error: false`. Codex turn `turn-97deccfa901a74dc` confirmed its managed branch and base through successful native Git commands. Both fresh branches used fetched base `a79aa2663cb5626a59a79fc805d3d749673670bc`. Continuations `turn-5ccbe100bfb5a177` (Claude) and `turn-7c617d8e73a00a32` (Codex) retained exact session/model/scope/repository and read preserved unfinished files. Actual Claude settings differed from the original policy only by the authorized trust-service allowance. All owned native groups, private temporary directories and the isolated daemon were absent afterward; disposable clones, binary and build were removed. No default installation change, push/PR workflow proof, broad confinement revalidation or full end-to-end suite was performed.

2026-11-08: migrated the workspace responsibility to the existing Go CLI and removed its Python implementation. Go CLI/workspace tests, 48 Python integration tests and 55 focused ExUnit tests passed. Real managed starts `turn-8612a8a43fa0c8b8` (Claude) and `turn-b299a0c4b2942a64` (Codex) confirmed fresh branches at `170b1f28eacb8ec875388ba2d6edc935c6ea284c`. Successful continuations `turn-3978e1b75e7b0783` and `turn-ae4aa87751116799` retained exact session/model/workspace/scope/repository and read preserved unfinished files. Ordinary-read cancellation turns `turn-0fd11a325dc3054d` and `turn-81339f04379aa5e7` held their directory locks during native execution, then released ownership only after stop reaped their groups. Stopping Claude left Codex active with its own lock. A prior Claude standalone-sleep probe was refused by its native tool; no bypass was attempted. All eight smoke native groups, private temps and the isolated daemon were absent afterward; disposable clones/build/binary were removed. No default restart, installation, merge, deployment, centralized GitHub implementation or broad confinement claim.

2026-11-08: split the standalone implementation into execution, interaction, handoff, persistence, workspace, host and provider responsibilities, and grouped the existing connected path separately. No further language migration or external dependency was added. Final verification passed both Go package suites and all 48 Python cases. Runtime ExUnit verification reported 276 tests, zero failures and one platform-specific exclusion.

Real isolated proof used freshly fetched base `0b9c492d481f2fd6198df6f7c243c0b852e0d689`. Claude `turn-e7f83eac1eaccdd5` asked a native question; Codex `turn-a00c9cb607e3feb1` continued as `turn-f00ad6754b6e15e8` to supply a documentation-based peer answer. Explicit routing/binding preserved the pending question, and separate answer delivery produced native processed evidence. Claude's actual completion declaration was explicitly submitted and inspected. Claude continuation `turn-900eea337f76d574` and the Codex continuation preserved session/model/workspace/scope/repository and exact unfinished-file bytes. Stopping Claude `turn-331594171c0cc555` invalidated its unanswered question and refused late delivery while Codex independently finished normally. A separate Codex continuation, `turn-010aa44e45b211cd`, was stopped after native thread confirmation and lock acquisition. Both locks were released after cleanup. All seven native groups, private temporary directories and both isolated daemons were absent afterward. Handoff, peer/question records, event replay and idempotent admissions survived restart without starting workers. Disposable binaries, builds and clones were removed. No default installation, deployment, permission expansion or authenticated peer-delivery claim.

2026-11-08: moved canonical cwd/Git identity discovery from the Claude Python adapter into the existing Go `workspace context PATH` operation. Saved-context comparison, permission scope and persistence remain in Python. Both Go package suites, 49 Python runner tests and 47 focused native/admission/service ExUnit tests passed. Real isolated Claude start `turn-c35dd82999da1ae7` and continuation `turn-01c23d7b55f842e9` preserved session/model/cwd/scope/repository and unfinished bytes; the continued native question received a delivered and processed answer. Controller-side branch drift refused before native initialization (`turn-07454797a4b4b31a`). A separate valid continuation was cancelled with directory-lock release and complete group/private-temp cleanup. Codex start `turn-3fa7496b01246499` and continuation `turn-98777c404546f2f8` preserved identity and recalled the file marker. All six owned groups and the isolated daemon exited; disposable binaries/builds/workspaces were removed. Origin and scope drift were covered by Python integration tests, not additional live-native attempts. No installation, default-daemon restart or deployment occurred.

2026-11-08: moved Codex model-evidence discovery from the Python provider into `AtlasRuntime.Providers.Codex`. The Python host now reports the exact launch time, workspace and effective Codex home in `runtime.process_started`; Elixir reads the rollout on a non-stopped process end, before terminal completion. 282 Runtime ExUnit tests passed (one platform exclusion), plus 45 Python runner tests and both Go packages. In an isolated daemon, real Codex `turn-dfb9047bfa338584` recorded `gpt-6.1-sol` with no requested model. Its continuation `turn-3a0c888bb83e49bc` kept session, model and workspace. The running child's environment had `HOME` and no `CODEX_HOME`, matching the `~/.codex` rollout whose turn-context cwd equalled the launch workspace. Cancelled Codex continuation `turn-72d496d3e722c98a` stayed without identity and its group exited. Claude start `turn-846e7b93d3776759` and continuation `turn-262aab2552ae1aa6` kept session/model/repository context; the continued question was delivered and processed. All owned groups and the daemon exited; disposable binary/build/workspaces were removed. No installation, default-daemon restart or deployment.

2026-11-08: added the separate local `atlas_code` service (`GET /v1/health`, `POST /v1/revisions/resolve`). Managed starts now take their base commit from it. Focused checks: Go packages, `atlas_code` tests (6) and 85 focused Runtime ExUnit tests passed. Isolated two-process proof, with Code and Runtime each in their own process and no Atlas Server:

- A local fixture repository's `develop` resolved to its exact `git rev-parse` commit.
- Wrong token, missing token, invalid ref, unknown ref and a disallowed repository returned 401/401/400/404/403 without echoing the token.
- `github.com/eyra/atlas` resolved to `88150b631427a34d52cd6a5f367ee1a47144e557`, equal to `git ls-remote`. Managed Codex start `turn-fbc65b544ee91192` recorded that `base_sha` and its branch HEAD.
- With Code stopped, two managed starts (one with `--request-id`) failed with `Code service unavailable: … econnrefused`, leaving no worker directory, turn or admission file.
- Continuation `turn-4898c2b74150ca31` and a `--cwd` run still worked without Code.

No installation, default-daemon restart or deployment.

2026-11-08: added Code snapshot creation, manifest and archive endpoints (`POST /v1/snapshots`, `GET /v1/snapshots/{id}/manifest`, `GET /v1/snapshots/{id}/archive?path=`); Runtime does not use them yet. `atlas_code` tests (8) passed. Separate Code process proof with local fixture repositories:

- Repositories `app` at `edd24028318f6e47683a20b1eb36333f29bdcc06` and `docs` at `11b3c08253b271fe595101cc584c7dbea2b3bced` (mounted at `vendor/docs`) gave snapshot `sha256:122107cc10ce4e9f93d0f6f6674b2bbb911b3c34abb27801340fb7af70344e6d`.
- The same ID came back for the reversed request, and it equals the sha256 of the canonical manifest.
- Both archives matched every manifest entry: bytes and size, the executable bit on `bin/run.sh`, binary NUL content and the symlink target. They contained no `.git`, and `$Format:%H$` stayed unexpanded.
- Refusals:
  - wrong or missing token: 401;
  - unknown commit: 404;
  - `../x`, `/abs`, duplicate and nested paths: 400;
  - repository not allowed: 403;
  - escaping symlink: 422 `unsupported_content`;
  - unknown snapshot: 404.
- The token never appeared in responses or the log.

Evidence: `~/.ac-sn-r3489bll/code-snapshots-evidence.json`. No installation, default-daemon restart or deployment.

2026-11-08: added `atlas-runtime snapshot materialize --snapshot sha256:<hex> --dest NEW_PATH`. It downloads a Code snapshot's manifest and archives, verifies every entry, publishes the destination atomically, and keeps an immutable baseline under `<runtime home>/snapshots/`. Managed starts do not use it yet. Go packages passed, including deterministic tests for unsafe manifests, corrupt archives, partial downloads, existing destinations and Code errors. Real CLI proof against a separate Code process:

- Repositories `app` at `a99b27677b14f2496ada190b7e5bce67bd694c2e` and `docs` at `4da3e291e2b70f05422dd4a043838a57242253e6` (mounted at `vendor/docs`) gave snapshot `sha256:d817209fcf045f8de66dce16a13a55b7a5d45ff24678df6bd90317d481e90dff`.
- That snapshot materialized into `work/w1` with exact bytes, a 0755 script, a 0644 binary file, a symlink and a long-named file. There was no `.git` and no token.
- The read-only baseline is outside the destination, and its `manifest.json` hashes to the snapshot ID. The materialization record names the destination and the ID.
- Materializing into `w1` again, after worker edits, was refused with the edits byte-identical.
- A second destination reused the same baseline.
- An unknown snapshot returned `Code refused snapshot …: 404 not_found`, and a stopped Code returned `Code service unavailable: … connection refused`. Neither left a partial destination or staging folder.

Evidence: `~/.ac-mt-uz2po9t1/materialization-evidence.json`. No installation, default-daemon restart or deployment.

2026-11-08: added offline `atlas-runtime snapshot status --dest PATH [--path REPO_PATH]...` and `atlas-runtime snapshot diff …`. They compare a materialized folder with its Runtime-owned baseline without the daemon, Code, network or Git. Go packages passed, with deterministic tests for every change kind, symlinks not followed, `--path` filtering, record/baseline/manifest refusals and read-only behaviour. Real CLI proof:

- Repositories `app` and `docs` were materialized from a separate Code process as snapshot `sha256:f8cacb27b2e6c0960e5bd78bb355a113f174387a7b06ada84af2ae783f7a241c`, and Code was then stopped.
- An untouched materialization reported `clean: true`.
- Edits in a second materialization were reported exactly:
  - a text change, with a unified hunk;
  - a binary change;
  - an added file and a deleted file, each with a diff;
  - an executable bit removed (`mode`);
  - a symlink retargeted;
  - an added symlink to a folder outside, reported as a link and not followed.
- `--path docs` limited the output to that repository.
- A missing record failed with `no materialization record for …`.
- Destination and baseline modes, mtimes, bytes and links were unchanged by inspection.

Evidence: `~/.ac-od-l2jz2wti/offline-status-diff-evidence.json`. No installation, daemon restart or deployment.

2026-11-08: added Code change submission (`POST /v1/changes`, `PUT /v1/changes/{id}/blobs/{sha256}`, `POST /v1/changes/{id}/seal`). Runtime does not upload yet. `atlas_code` tests (10) passed. Isolated HTTP proof against a separate Code process:

- Fixture `app` was snapshotted at `5571cb34743e1fe55e539d17083cd5bb584f086b`; its source `develop` then advanced to `efdef920d16100017897d094b31af0aaef3b70a6`.
- The change combined a text edit, a binary edit, a delete, `tool.sh` becoming 100755, a symlink retarget, a new symlink, and `dir/` replaced by a file with explicit deletes.
- Request checks:
  - a reordered repeat returned the same state;
  - a different body got 409 `conflict`, and the advanced base got 409 `base_mismatch`;
  - replacing `dir` without deleting its files got 400;
  - a wrong token got 401;
  - an early seal got 422 `incomplete_upload`.
- Upload checks: wrong size 400, wrong digest at the same size 400, unreferenced digest 404, repeat 200.
- Seal produced `32c8d528028fe1e4845f879255948b47126d9f94`. Its only parent is the snapshot base, its tree matches the intended bytes, modes and symlink targets exactly, and `refs/atlas/changes/<id>` points at it.
- A repeated seal and a repeated POST returned the same commit.
- The cache `refs/heads/develop` and all fixture-remote refs were unchanged, and the commit is absent from the remote.

Evidence: `~/.ac-cs-tzajs3ev/change-submission-evidence.json`. No installation, daemon restart or deployment.

2026-11-08: added `atlas-runtime snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID`. It submits one materialized repository's offline changes to Code and returns the sealed private commit; nothing is pushed or published. Go packages passed, with tests for mixed conversion, clean results, partial-upload resume, repeat, conflict, unavailable Code, and the local refusals listed in the architecture document. Real CLI proof against a separate Code process:

- Two repositories materialized as `sha256:11d74dc9313ce4b527c01cb5ccdb7840c46573d33b9cb09a09bf4e9151c7cc61`.
- `app` (base `29b78cedced4755a194b73b388da30a43cdabc12`) was edited: text, binary, an added file, a delete, a mode change, a symlink retarget, a new symlink, a directory replaced by a file, and a file replaced by a directory.
- Its submit sealed `7907eb92e526967d22dbc841093548f519946b86`. The only parent is the base, and the private tree equals the intended bytes, modes and targets. A repeat returned the same commit.
- `docs` reported `state: "clean"` while untouched. After its own edit it submitted independently as `7b65dbf3fac93afb858c85d16feaf01082a462af`.
- Omitting `--path` with two repositories was refused, and changed content under the same ID got `409 conflict`.
- A proxy dropped the second blob upload: the submit failed with the resume hint. Repeating the command uploaded the two remaining blobs and sealed `0e3359495ca00c4660e09ec81f27e33daaed256d`.
- With Code stopped, submit failed as unavailable.
- Destination and baseline modes, mtimes, bytes and links were unchanged, and no temporary copies remained. Neither commit exists in the fixture remotes.

Evidence: `~/.ac-fs-avnie5kj/folder-submit-evidence.json`. No installation, daemon restart or deployment.

2026-11-08: added Code publication (`POST /v1/publications`, orchestrator token only); see the architecture document for configuration, authorization and retry phases. `atlas_code` tests (19) passed. They cover role refusal, validation, open and unknown changes, exact create-only pushes, existing branches at another commit, at the same commit and at an ancestor, a pre-receive race, same-ID replay and conflict, and PR create/adopt/partial-failure reconciliation through a fixture `gh`. Separate Code process proof against a local fixture remote:

- Runtime token: `403` "Publication requires the orchestrator token".
- Open change: `409 change_not_sealed`.
- A PR on the `file`-path remote: `422 unsupported_provider`, refused before any push.
- The orchestrator published branch `work/publication-proof` at exactly the sealed commit `7a45c6962042271fafce06ae50a0c3c451d68ff8`, whose only parent is base `19f95300387066c8e335fceeedf85fdc56a2e526`. Remote `develop` stayed at the base.
- Repeats:
  - an identical repeat returned the identical result;
  - a changed body under the same ID gave `409 conflict`;
  - a second ID for the same branch gave `409 branch_exists`.
- Pre-existing remote branches at the base (fast-forward possible) and at the sealed commit itself both gave `409 branch_exists` and stayed unchanged.
- The cache `refs/heads` stayed at `develop`.

This is fixture evidence only; real GitHub PR creation was not exercised. Evidence: `~/.ac-pb-10wtc6jv/code-publication-evidence.json`. No installation, daemon restart or deployment.

2026-11-08: moved Claude `answer.txt` persistence from the Python provider into `AtlasRuntime.Agent.Native`. Session/model confirmation stays in Python, before records are forwarded. Each forwarded string result, error results included, overwrites the artifact before terminal notification; a failed write fails the turn. Focused native, admission, service, question, Codex and protocol ExUnit tests (84) and both Python runner modules (20 and 25) passed. In an isolated daemon, real Claude start `turn-3db17cd9af722dda` and saved continuation `turn-c8b6c3fe665d9d34` (same session/model/repository) had their saved answers returned by `output --turn`, including the question-dependent `ANSWER_BETA`; that answer was delivered and processed. Cancelled continuation `turn-3b52fce43ea74d83` wrote no answer, released its lock and removed its group/private temp. The daemon stopped; disposable binary/build/clone were removed. No installation, default-daemon restart or deployment.

2026-11-08: moved Codex native hosting from the Python runner to the Go `atlas-runtime native-host` command. It keeps the same arguments, stdout records, stop control, diagnostics and artifacts; Claude stays on Python. Go packages (including race-checked host tests), both Python runner modules (25 and 20 tests) and 73 focused ExUnit tests passed. Isolated public-CLI proof ran two concurrent workers: read-only Codex `turn-1bbf325ed9afb4fb` and workspace-write `turn-3d84605e2fdd9249`, which created the requested file. Read-only continuation `turn-6b86db84a3a3f16a` kept session and model `gpt-6.1-sol` from rollout evidence. Managed repository start `turn-9c691e7ce2885bf2` provisioned a fresh branch at the fetched base, and continuation `turn-a8edc3e54d5fc863` read preserved unfinished bytes. During cancelled managed continuation `turn-c4c332cb95dfda73`, `ps` showed `atlas-runtime native-host` as the parent of the Codex group leader; stopping it released the directory lock and removed the group. After restart, saved-turn continuation `turn-4b4bfccadc4c3f53`, with a replaced session ID, failed as `{:codex_failed, 1, nil}` with `Native runner: Codex resume ended without confirming its session`. `service stop` during active managed turn `turn-09242c1c516e2cc5` reaped its group and released the lock. Claude start `turn-09052cd5ed27150b` with a delivered and processed question still ran on Python. Disposable binary, build and workspaces were removed. No installation, default-daemon restart or deployment.

2026-11-08: moved question-disabled Claude hosting to the Go `native-host`: validation, argv, synchronous session/model confirmation, private temp with the 44-byte and system-temp-root checks, repository sandbox settings, managed preparation and saved-context check. Claude with `--questions` stays on Python. Go packages (new Claude tests cover the exact 44/45-byte boundary, temp-root refusal, temp-directory candidate selection, cleanup and context drift), both Python runner modules (25 and 20 tests) and 84 focused ExUnit tests passed. Isolated public-CLI proof ran three concurrent workers:

- Claude read-only `turn-8d42c30efa7d4869` and continuation `turn-046d2fbba42604c5` kept the same session and model.
- Managed dedicated-repository Claude `turn-bfc8d13f9341557d` wrote `claude-go-proof.txt` with Bash. Continuation `turn-e7642906d8f03fc6` read the 15 preserved unfinished bytes with an identical saved context.
- Codex `turn-dbe63f923073830a` and continuation `turn-501f3128322dc893` ran as a regression check.
- Generic Claude workspace-write was still refused.
- After restart, continuation `turn-112d8f2dfc6aa35a`, with a replaced saved session, failed as `{:claude_failed, 1, nil}` with `Native runner: Claude resume ended without confirming its session`. A mismatched init session or model is proven by Go tests only.
- `ps` showed `atlas-runtime native-host` as the Claude group leader's parent. Cancelling `turn-0d6bfa87c7669a0e` and running `service stop` during `turn-2b8b5437285b68cc` each removed the group and private temp and released the lock.
- Python question regression `turn-a9fa7bcfe5593b52` delivered and processed its answer. An earlier attempt, `turn-c63fd0f0a5ffe383`, was correctly refused when the provider's safety classifier switched the assistant model.

Disposable binary, build and workspaces were removed. No installation, default-daemon restart or deployment.

2026-11-08: moved the Claude question transport to the Go `native-host`. Every Claude and Codex execution now runs there, and the `priv/runtime` Python runner was deleted. The interaction contract is unchanged: bounded `stop`/answer control, question identity and validation, delivered/rejected/processed records and their order, strict session/model identity checks before forwarding, a 1 MiB bound and 3 s stall deadline on native stdin, and stop/EOF handling. Go packages (ported question host and process cases, plus write-stall cleanup with and without a dedicated scope), the remaining Python runner module (14 tests) and 109 focused ExUnit tests passed. Isolated public-CLI proof:

- Concurrent question workers: read-only `turn-aae7b1b309a4d87d` and managed dedicated-repository `turn-bd8cd39891bb046c`, both hosted by `atlas-runtime native-host`. An answer to one worker's question submitted through the other was refused.
- Both answers were delivered and processed, with correct final answers.
- Continuation `turn-80800e1ad1137565` asked and answered a second question with the same session and model.
- Non-question Claude `turn-4075635c914a84d9`/`turn-e23bf9ee06750462` and Codex `turn-923e9ab0a3b3aff4`/`turn-07160b0e981fda8b` start/continuation passed as regression checks.
- Cancelling `turn-b26b0a837a2da7fd` while its question was pending invalidated the question and refused a late answer. `service stop` during pending `turn-871fb4d74def2aaa` reaped the group. In both cases the private temp was removed and the lock released.

Disposable binary, build and workspaces were removed. No installation, default-daemon restart or deployment.

2026-11-08: finished removing Python from Runtime.

- Deleted the last Python test modules (`codex_runner_test.py`, `workspace_test_support.py`) and the Python fake native CLIs. Their behaviour now lives in Go workspace/host tests and a Go fake native CLI built by `test_helper.exs`.
- Removed the internal `workspace lock`/`context`/`dedicated-scope`/`prepare` CLI operations, which had no remaining callers. `native-host` uses those functions in process.
- Converted the `verify_sandbox.exs` and `worker_control.exs` fixtures to shell.

Checks: Go packages, 284 Runtime ExUnit tests (one platform exclusion), and the model-free sandbox check (2 tests).

Isolated public-CLI proof:

- Codex `turn-d0314bde131ef690`/`turn-643171efa46e5413` and Claude `turn-70ca20929657c458`/`turn-2dbcdb694b1573d6` start/continuation kept session and model.
- Claude question turns `turn-cfc136e0d3aad0b5` and `turn-e4ba55e19866352a` (continuation) processed answers `BETA_CQ_9855C012` and `ALPHA_CQ_9855C012`.
- Dedicated-repository Claude `turn-14badf03c32966e0` wrote exactly `NOPY_9855C012\n`.
- Cancelling `turn-d067a286ce8d4428`, and `service stop` during `turn-73683e65dd14866c`, removed the group and private temp and released the lock.
- Process trees below the daemon contained only `erl_child_setup`, `atlas-runtime native-host`, `codex`, `claude`, `zsh` and `sleep`, with no Python executable.

Disposable binary, build and workspaces were removed. No installation, default-daemon restart or deployment.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
