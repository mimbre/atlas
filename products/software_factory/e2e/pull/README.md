# pull-e2e: the go-live gate's end-to-end test

The real Runtime puller, started without Mix (`atlas-runtime service start`), against Flow's
real work source with real Facts and Code test instances and a stub agent, all on one machine
over loopback. Plan: `delivery-evidence/pull-e2e-plan.md` rev 2, with re-review C1/C4 and the
S4 note, and Main's rulings (the 5 100 s / 5 400 s bound is an upper bound only).

**How a run goes:** `pull/run.sh` first compiles everything once into a warm cache
(`mix atlas.pull_e2e --prepare`: the stub, the Runtime CLI, the core and clients, and the
Runtime service's build, into `e2e/_build/pull-e2e/`), then starts the timed run. Each
Runtime home starts from a copy of the service build, so its own build is a no-op. Durations
print split into compile and test. Scenario order: S1, S2, S2b, S4, S6, S3, S5. S3 restarts
the core into the short `lease_ttl` (15 s) that S5 runs on.

**It never runs in CI.** No `ci.yml` job names it, and no `mix test` starts it: it is the Mix
task `mix atlas.pull_e2e`, run by the orchestrator through `atlas-heavy`:

```bash
cd <clean develop checkout>/atlas
atlas-heavy timeout --kill-after=60 5400 bin/atlas-dev pull-e2e        # every scenario
atlas-heavy timeout --kill-after=60 5400 bin/atlas-dev pull-e2e s5     # one
echo "exit $?"   # 0 passed · 1 failed · 3 watchdog · 4 environment_too_slow · 5 reap proof failed · 6 incomplete (needs D2)
ps -A -o pid=,command= | grep '/tmp/pe\.' | grep -v grep               # expect no lines
```

## Topology

```
 test BEAM (mix atlas.pull_e2e, MIX_ENV=dev, TMPDIR=<run>/tmp)
 ├─ Hub            every observation, stamped (seq, monotonic ms); events/*.jsonl
 ├─ Edge           TLS 1.3 on 127.0.0.1:<edge> ──plain──► Flow's listener 127.0.0.1:<ws>; the tap; faults
 ├─ Reader :stub   the agents' FIFO <run>/stub/events.fifo
 ├─ Reader :rt     atlas-runtime events --follow
 └─ Console        tmux control mode (navigation only)
 OS processes, each through `pull-stub session --` (a session and pgid of its own), in <run>/pids.jsonl:
 ├─ rela (start-bg.sh) + core (atlas-ops restart --env test, ATLAS_ENV_FILE=<run>/inst/test.json)
 ├─ Runtime CLI → build → Runtime BEAM (the CLI's own Setsid) → host helper → stub `codex`
 └─ tmux server (-S <run>/tmp/pe-tui.tmux)
```

## Files

| File | What |
|---|---|
| `pull/run.sh` | the wrapper: `--prepare`, then makes `<run>`, runs the BEAM, traps signals (TERM the BEAM first, then a KILL-only reap); a leak exits 5 on every path |
| `lib/atlas_e2e/pull/prepare.ex` | the warm cache: everything compiled once, before the timed run |
| `lib/mix/tasks/atlas.pull_e2e.ex` | `--run <run> [s1 …]`, `--reap <run> [--fast]`, exit codes |
| `lib/atlas_e2e/pull/run.ex` | setup, scenarios, durations, teardown, verdict |
| `lib/atlas_e2e/pull/bench.ex` | registry, step budgets, sessions, watchdog, reaper + proof, own-pgid guard, artifacts |
| `lib/atlas_e2e/pull/hub.ex`, `await.ex` | the event stream and the waits (`AtlasTestAwait`, events only) |
| `lib/atlas_e2e/pull/edge.ex` | the TLS edge, its tap and faults, the chunked reader |
| `lib/atlas_e2e/pull/core.ex`, `seed.ex` | the instance's settings (D6 timing, #342 Code), credentials, rela + seed, core restart/stop |
| `lib/atlas_e2e/pull/runtime.ex` | Runtime homes by name, policy/token/CA (D5), PATH check, start/stop/crash, events |
| `lib/atlas_e2e/pull/stub.ex`, `reader.ex` | the stub's build, wrappers, FIFO reader and gate |
| `lib/atlas_e2e/pull/console.ex` | the TUI as melle: Pick up, Hand over… |
| `lib/atlas_e2e/pull/facts.ex` | reads: rela's stored facts, Flow's result store |
| `lib/atlas_e2e/pull/fixture.ex` | xorshift blobs, the edge's test CA, the fixture remote |
| `lib/atlas_e2e/pull/needs.ex` | the F2/F3 seam (needs) and tree requirements (D2) |
| `lib/atlas_e2e/pull/scenario.ex`, `steps.ex` | the scenario DSL and shared steps |
| `pull/stub/main.go` | the stub: `agent` (codex stand-in, gate, events), `session --` and `tether --` (its child ends with the BEAM), `gate` (never blocks), `hold`, `ids` |
| `pull/scenarios/0*.exs` | S1 (01), S2 (02), S2b (02b), S4 (03), S6 (04), S3 (05), S5 (06) |
| `test/pull/*_test.exs` | the harness's guards (focused; `mix test test/pull`) |

## How it waits

Only on events: edge records, stub FIFO events, `events --follow` lines, tmux `%output`.
Facts are read after an event (`Await.facts`), negatives count answered polls begun after a
mark plus `resync_ms`, never elapsed time. Each wait's cap is what is left of its step's
budget (plan §10); the cap reports a hang, it decides nothing. The only real timers are the
product's (lease_ttl 180 s, grace 120 s, the Runtime's 5 s check, the sweep) and the bench's
own bound (the watchdog at 5 100 s).

## Extending it (F2/F3)

A scenario names `needs: [:github, :review_profiles]`; each is `AtlasE2E.Pull.Needs.<Name>`
(`lib/atlas_e2e/pull/needs/`) with any of `settings/1`, `policy/2`, `path/1`, `code/1`,
`start/1`, `stop/1`. New scenarios go in `pull/scenarios/20-*.exs`. A second Runtime is
`Runtime.prepare(run, :other, …)` + `Runtime.start/2` (homes and registry rows are keyed by
name) and needs D7 (`runtime_id` in `policy.json`) first.
