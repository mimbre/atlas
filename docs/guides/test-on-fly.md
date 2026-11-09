# Atlas test on Fly

Test's core (Bus, State, Flow, Control) and its rela run on Fly, in organisation eyra, on test's own private network; nothing of it has a public address. Runtime and the agents stay on the MacBook. Why two apps and how they connect: `docs/adr/0003-test-on-fly.md` (IS-Atlas-26).

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas-test` | shared-cpu-1x, 256 MB, ams | volume `core_data` at `/data` (State's own: `/data/beam`) |
| rela | `eyra-atlas-test-rela` | shared-cpu-1x, 256 MB, ams | volume `rela_data` at `/data` (`/data/rela`) |

## Use it

```sh
atlas tui --env test        # opens the tunnel to test's Control on Fly, then the TUI
atlas list scene --env test # the agents' commands too; each opens the tunnel when it is closed
atlas-ops status --env test        # the tunnel, and both apps' machines, checks and deployed build
atlas-ops logs --env test          # the core's log on Fly (rela's: fly logs -a eyra-atlas-test-rela)
atlas-ops tunnel close --env test  # closes this Mac's tunnel; test keeps running on Fly
```

The tunnel is `fly proxy 7693:7691 -a eyra-atlas-test`, flyctl's WireGuard into test's network, running in the background like the core used to. It needs flyctl logged in to organisation eyra (`fly auth whoami`); nothing else on the Mac (no VPN, no root). Its files are in `~/.local/share/atlas/test-on-fly/`.

Before passing the tunnel to a client, the launcher checks a read-only Control
handshake, not only the local port. It reopens an unresponsive existing proxy and
waits up to a minute for a new proxy to reach Control. `status` reports a broken
upstream as unavailable even if flyctl still listens locally. This restarts no Fly
machine and replays no client writes. A hello refusal is left to the client to
report; a handshake alone does not prove State/rela health.

`atlas-ops up`, `stop` and `restart` refuse for test: a merge to develop deploys test (CI job `deploy-test`, which runs `fly/deploy.sh test`):

Test deployment waits for the focused generator, contract, core, TUI and agent jobs,
not the full native end-to-end suite. End-to-end checks still run independently;
production deployment continues to require them. Data compatibility checks, paired
deployment serialization and the deployed read-only smoke remain mandatory.

1. On rela's machine, on a copy of its data: does this build's description describe all of it? When it does not, nothing is deployed and test keeps its build; that data needs a migration first (below).
2. rela, then the core.
3. A smoke check that reads only (`fly/smoke.sh test`).

The test deployment job serializes the entire rela/core pair without cancelling
an in-flight update. Pending jobs queue instead of replacing one another. After
acquiring its slot, `fly/deploy-test-current.sh` compares the checkout/build label
with the current authenticated `origin/develop` head. A stale job exits successfully
without any Fly operations; unresolved or inconsistent identities fail closed.
If develop advances after admission, the admitted pair finishes normally, and a
later eligible job deploys the newer head. CI readiness order alone never determines
which source revision may deploy. Production delivery is unchanged.

A successful stale skip is not delivery evidence: confirm the intended paired
image labels, manifest checks and positive smoke result in the deployment log.

The deployment verifies the packaged description manifest on both apps before smoke.
Smoke checks the image label and reads Control's advertised kinds. Ordinary kinds
must return successful lists. Kinds mapped by the packaged description's guidance
roles must instead return CLI exit 2 with the exact typed State code
`exact_identity_required`. A timeout, missing code, malformed JSON, unavailable
backend, unknown kind, or unexpected list success fails smoke with the kind and cause.
It never infers a code from the human error text or skips a kind without probing it.

This verifies the deployed scoped-read guard and the Control/CLI path, without
enumerating restricted collections or creating live guidance facts. It does not prove
positive scoped reads of stored guidance on the deployed environment. Actual State
tests use private synthetic execution, interaction and receipt records to prove valid
exact/execution/parent scopes, invalid scopes and writer authority separately. Private
composition tests run smoke's client against the real CLI, Control, State and rela.

State failure codes pass through the existing failure confirm's optional `code` field
and CLI JSON errors. Human text and exit statuses stay the same. Clients that ignore
the optional field keep working; smoke fails closed if an older server drops the code.

`atlas-ops status --env test` shows the build as the image label `develop-<commit>`. Prod is deployed the same way from master: `docs/guides/prod.md`.

## Test-only worker access

The image derives `rela/atlas-test.json` from the canonical description and
`fly/test/worker-access.json`. Only test's core selects it; production still selects
`rela/atlas.json`, with no worker grants added. Test also exposes the generic Workers
tab. Named actors `melle` and `releasewriter` may read and submit; `releaseviewer`
may only read. All other actors remain denied. A listed actor must still exist in
State; the grant does not create a person or authenticate a new identity.

Test enables release RPC only on loopback (`atlas@localhost`, loopback EPMD and
distribution sockets), reachable administratively through Fly SSH. This permits
synthetic execution fixtures to use the real Bus/State admission path without
exposing a remote Runtime writer endpoint or changing production distribution.
Fixture scripts must first require `AtlasBus.environment() == "test"`, use distinct
fixture keys and stop/end only their own synthetic turns. Immutable guidance and
receipt evidence remains retained; no raw deletion bypass is used for cleanup.

## The secrets CI needs

Two repository secrets, one deploy token per app (each can manage only its own app):

```sh
fly tokens create deploy -a eyra-atlas-test -n "eyra/atlas CI"        # secret FLY_API_TOKEN_TEST
fly tokens create deploy -a eyra-atlas-test-rela -n "eyra/atlas CI"   # secret FLY_API_TOKEN_TEST_RELA
```

Until both are there, the deploy job fails on its first step and names the missing one.

## Move data from the MacBook

Test's data moved on 3 Nov 2026 (from `~/.local/share/atlas/test-backup-20261103T204658Z-before-fly`). A move works the same any time, from a folder with `rela/` and `beam/`:

```sh
atlas-ops move-to-fly --env test --from <folder> --dry-run                   # checks and counts; sends nothing
atlas-ops move-to-fly --env test --from <folder> --replace-live              # the move
```

1. The dry run checks that this build's description describes all of that data, and counts the items per kind and the links per relation. It also shows what Fly holds now.
2. The move sends both folders and restarts rela, then the core. The copy is put in place at boot, before anything serves it.
3. It compares the result item by item. Every file must arrive as sent (SHA-256 of each, both apps), and the counts on Fly must be the ones sent.
4. What Fly held before stays there, in `/data/before-move/` on both apps.

`--replace-live` is needed because test's clients use Fly: the data there is the live one. A move refuses while a rela on this Mac still serves the folder.

## Back up the data on Fly

```sh
atlas-ops fetch-from-fly --env test --to ~/.local/share/atlas/test-backup-$(date -u +%Y%m%dT%H%M%SZ)
```

It holds both apps for about a minute: the machines stay up but serve nothing, so the copy is whole. It then copies `/data/rela` and `/data/beam` into `<folder>/rela` and `<folder>/beam`, the layout `move-to-fly` takes back. Last, it releases both apps.

## A migration

A migration command (today `atlas migrate-done-owner`) reads rela on the Mac, so `atlas` refuses it for an environment on Fly. A migration runs on a copy, on the Mac, as it always has, and the migrated copy goes back:

1. **Hold and copy.** `atlas-ops fetch-from-fly --env test --to <folder> --hold`. Test on Fly now serves nothing, so nothing writes to it during the migration. The TUI says Control does not answer.
2. **Migrate the copy on a private instance.**
   - Write a settings file like `env/test.json` without `"fly"`, with `rela.data`, `rela.bin` and `state.data` pointing into `<folder>`, and with free ports.
   - Run the migration with `ATLAS_ENV_FILE=<that file>`, exactly as its guide says, for example `atlas migrate-done-owner --env test --dry-run`, then the real run.
   - It runs on the build the migration expects; a private instance never meets the Mac's or Fly's.
   - Start that instance first with `atlas-ops restart --env test`, and stop it after with `atlas-ops stop --rela --env test`, with the same `ATLAS_ENV_FILE`.
3. **Deploy the build the migrated data needs.** Merge its pull request (or re-run `deploy-test`). A held environment is deployed without health checks or smoke check, and serves nothing yet.
4. **Bring it back.** `atlas-ops move-to-fly --env test --from <folder> --replace-live`. That checks every file and count, and ends the hold: test serves the migrated data on the new build.

If the deploy in step 3 comes first while test is not held, `fly/deploy.sh` refuses it: it names the data the new description does not describe, and test keeps its build. Then start at step 1.

A hold ends without a move with `fly ssh console -a <app> -C "rm /data/hold"` on both apps, then `fly machine restart` (rela first).

## When something is wrong

- `atlas-ops status --env test`: a machine not `started`, or a check not passing.
- `atlas-ops logs --env test`, `fly logs -a eyra-atlas-test-rela`.
- A deploy refused before it starts: this build's description does not describe data rela holds on Fly. The job names it; test keeps its build. Migrate it (above).
- Held: the machines log `held: /data/hold is there`. A `fetch-from-fly --hold` is waiting for its `move-to-fly`.
- `fly ssh console -a eyra-atlas-test-rela` opens a shell on rela's machine; its data is in `/data/rela`.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
