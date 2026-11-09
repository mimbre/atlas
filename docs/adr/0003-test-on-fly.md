# 0003: Test on Fly: two apps on test's own private network

Status: accepted, 2026-11-03 (decision: "i think we just need to create a new fly eyra-atlas-test", "and eyra-atlas (the prod)"; d-0005, d-0014). IS-Atlas-26; prod follows the same way in IS-Atlas-79.

## Context

Test ran on the MacBook: rela on 7690 and the core (Bus, State, Flow, Control) on 7691, started by `atlas up --env test`. d-0005 puts rela on Fly, reachable only over a private network; d-0014 deploys test on every merge to develop. Runtime and the agents stay on the MacBook (d-0006), and they and the TUI are clients of Control.

## Decision

1. **Two apps: `eyra-atlas-test` (the core) and `eyra-atlas-test-rela` (rela)**, each one machine (shared-cpu-1x, 512 MB for the core, 256 MB for rela, region ams) with its own 1 GB volume at `/data`.
   - rela is an outside system to State, the same pinned binary as on a Mac (`rela/scripts/start-test.sh`). As its own app it keeps its own lifecycle: a core deploy restarts the core only, while rela keeps serving.
   - A crash of one does not take the other down, and its logs, checks and status are its own (`fly status -a …`).
   - Each has its own deploy token, so CI's core token cannot touch rela's data except through Control.
   - Cost: one more machine and volume of the smallest size, and a deploy of two apps in order (rela, then the core).
2. **Test's own private network.** Both apps were created with `--network eyra-atlas-test`, a Fly network of their own: the other apps of organisation eyra (eyra-flux*, eyra-next*, nova-mica*) cannot reach them, and prod gets its own network (d-0003: test and prod never connect). No app has a public address or a `[[services]]` section; `eyra-atlas-test.fly.dev` resolves to nothing.
3. **The MacBook reaches Control over WireGuard with `fly proxy`.** `bin/atlas` opens `fly proxy 7693:7691 -a eyra-atlas-test` in the background when a command needs Control, like it starts the core on a Mac. flyctl's own WireGuard tunnel joins test's network without root, a system VPN or `.internal` DNS on the Mac. The TUI and the agents' command line keep talking to `127.0.0.1`; they do not know test moved.
4. **CI deploys on a merge to develop** (`.github/workflows/ci.yml`, job `deploy-test`), after every other job passed: rela, then the core, each image labelled `develop-<commit>`, then `fly/smoke.sh test`, which reads only.
5. **Data moves with `atlas move-to-fly --env test`**: the Mac's rela and State folders, as archives, applied at boot by `fly/apply-move.sh` while nothing serves them; what was on Fly is kept in `/data/before-move/`.

## Consequences

- `atlas up/stop/restart --env test` no longer run a core on the Mac; `atlas status --env test` shows Fly's machines, `atlas logs --env test` Fly's logs. A private instance (`ATLAS_ENV_FILE` without a `fly` section, as the end-to-end test makes) still runs on the Mac.
- *Amended 2026-11-10 (design-cli-structure-1, S3):* the operating commands named in this record (`up`, `stop`, `restart`, `status`, `logs`, `move-to-fly`, `fetch-from-fly`, and `rela-stop`, now `stop --rela`) moved from `atlas` to `atlas-ops`. On Fly, `atlas-ops stop` and `restart` refuse; `atlas-ops tunnel close` closes the tunnel, and `atlas` still opens it when a command needs Control.
- The migrations (`atlas migrate-*`) read rela on the Mac and are refused for an environment on Fly. A migration runs on a copy on the Mac (IS-Atlas-79, below).
- Every client on a machine needs flyctl logged in to organisation eyra (the Mac mini too, when it runs test's agents).

## Prod, and what came with it (IS-Atlas-79)

- **Prod, the same way.** Prod gets the same two apps, `eyra-atlas` and `eyra-atlas-rela`, on their own network `eyra-atlas-prod`. A merge to master deploys them (CI job `deploy-prod`). `env/prod.json` names them with `"in_use": false`: prod's clients keep using the Mac's core until its data has moved and been checked, and one edit switches them.
- **A deploy checks the description first** (`fly/deploy.sh`). On rela's machine, on a copy of its data, it checks that the new description describes all of it, as `atlas restart` does on a Mac. When it does not, nothing is deployed and the environment keeps its build.
- **A move is checked item by item.** `fly/apply-move.sh` writes a manifest (the SHA-256 of every file) of what arrived. `move-to-fly` compares it with the manifest of what it sent, for rela's data and State's, then compares the counts per kind and per relation.
- **Hold.** `atlas fetch-from-fly --hold` keeps both machines up while serving nothing (`/data/hold`), for a whole copy: a backup, or a migration on the Mac. A move ends it. A held environment deploys without health checks and without a smoke check.
- **Connectors read their secrets from the environment on Fly.** GitHub's token is the app's secret `GITHUB_TOKEN` (`token_env`); on a Mac it stays `gh auth token`.
