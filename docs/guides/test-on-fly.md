# Atlas test on Fly


Remote transport now requires verified full hostnames and TLS certificates; the live configuration is not supplied and cutover is blocked. See [private transport](private-transport.md). Short node names below identify apps, not authenticated connection destinations.
Test's core (Bus, Facts, Flow, Control) and its rela run on Fly, in organisation eyra, on test's own private network; nothing of it has a public address. The core also joins the tailnet as `eyra-atlas-test` (D-0089), and that is where every client reaches it. Runtime and the agents stay on the MacBook. Why two apps and how they connect: `docs/adr/0003-test-on-fly.md` (IS-Atlas-26).

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas-test` | shared-cpu-1x, 512 MB, ams | volume `core_data` at `/data` (Facts' own: `/data/beam`) |
| rela | `eyra-atlas-test-rela` | shared-cpu-1x, 256 MB, ams | volume `rela_data` at `/data` (`/data/rela`) |

## Use it

```sh
atlas tui --env test        # the TUI, on test's Control over the tailnet
atlas list scene --env test # the agents' commands too
atlas-ops status --env test # whether Control answers over the tailnet, and both apps' machines, checks and deployed build
atlas-ops logs --env test   # the core's log on Fly (rela's: fly logs -a eyra-atlas-test-rela)
```

Control is at `eyra-atlas-test:7691` on the tailnet (`control.host` and `control.port` of `env/test.json`), the Bus link at `eyra-atlas-test:7694`. The Mac must be on the tailnet (the Tailscale app on, MagicDNS on), and the tailnet's ACL must let it reach those ports; nothing is opened or started for it. When Control does not answer, a command says `not on the tailnet: tailscale status` and stops. flyctl, logged in (`fly auth whoami`), is still needed for `status`, `logs` and the data moves below. The TUI's agent log is in `~/.local/share/atlas/test-on-fly/`.

The check before a command is only whether Control's port accepts a connection; the client then authenticates TLS before its protocol hello, and a refusal is the client's to report. It does not prove Facts/rela health: that is the smoke check's.

`atlas-ops up`, `stop` and `restart` refuse for test: a merge to develop deploys test (CI job `deploy-test`, which runs `fly/deploy.sh test`):

Test deployment waits for the focused generator, contract, core, TUI and agent jobs,
not the full native end-to-end suite. End-to-end checks still run independently;
production deployment continues to require them. Data compatibility checks, paired
deployment serialization and the deployed read-only smoke remain mandatory.
When the merged tree already passed every test job (on its pull request), those jobs are
skipped and test deploys right away; see `docs/guides/prod.md`, "CI tests a tree once".

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
roles must instead return CLI exit 2 with the exact typed Facts code
`exact_identity_required`. A timeout, missing code, malformed JSON, unavailable
backend, unknown kind, or unexpected list success fails smoke with the kind and cause.
It never infers a code from the human error text or skips a kind without probing it.

This verifies the deployed scoped-read guard and the Control/CLI path, without
enumerating restricted collections or creating live guidance facts. It does not prove
positive scoped reads of stored guidance on the deployed environment. Actual Facts
tests use private synthetic execution, interaction and receipt records to prove valid
exact/execution/parent scopes, invalid scopes and writer authority separately. Private
composition tests run smoke's client against the real CLI, Control, Facts and rela.

Facts failure codes pass through the existing failure confirm's optional `code` field
and CLI JSON errors. Human text and exit statuses stay the same. Clients that ignore
the optional field keep working; smoke fails closed if an older server drops the code.

`atlas-ops status --env test` shows the build as the image label `develop-<commit>`. Prod is deployed the same way from master: `docs/guides/prod.md`.

## Test-only worker access

Test's settings add them, not the model: `control.tabs` (the generic Workers tab,
after the model's tabs) and `control.workers` (the grants) in `fly/test/core.json`,
which test's core runs on, and in `env/test.json` for a local test instance;
`config/runtime.exs` hands both to Control. Production's settings add the same tab
with only `melle` as reader and submitter (`docs/guides/prod.md`). In test, named actors `melle` and `releasewriter` may read and
submit; `releaseviewer` may only read. All other actors remain denied. A listed actor must still exist in
Facts; the grant does not create a person or authenticate a new identity.

Test enables release RPC only on loopback (`atlas@localhost`, loopback EPMD and
distribution sockets), reachable administratively through Fly SSH. This permits
synthetic execution fixtures to use the real Bus/Facts admission path without
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

The deploy job also joins the tailnet for the smoke check, with the repository secret `TS_AUTHKEY_CI` (an ephemeral, reusable, pre-approved key tagged `tag:atlas-ci`, shared with prod's job; the ACL lets it reach `eyra-atlas-test:7691` only); without it the job fails before deploying anything.

## The tailnet key

The core joins the tailnet before it starts (`fly/core-run.sh`). Its node is persistent, with its state on the volume (`/data/tailscale`): the app's secret `TS_AUTHKEY` (a reusable, pre-approved key tagged `tag:atlas-test`, not ephemeral), from Infisical `test:/tailscale`, logs it in on the first boot or after the volume was wiped, and a restart is the same node, `eyra-atlas-test`, without the key:

```sh
printf 'TS_AUTHKEY=%s\n' "$(infisical secrets get TS_AUTHKEY --plain --env test --path /tailscale)" \
  | fly secrets import -a eyra-atlas-test
```

Without it the core does not start (`core-run: TS_AUTHKEY is not set`), and `fly/deploy.sh` refuses to deploy. What the tailnet needs (tags, keys, ACL, CI's key) and when the key is used: the owner's steps in `docs/guides/prod.md`, "Secrets".

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

It first refuses, changing nothing, when either app already has a hold or a pending move (`/data/incoming/<name>.tar.gz`): a restart would end that hold or apply that move. It holds both apps for about a minute: the machines stay up but serve nothing, so the copy is whole. It then copies `/data/rela` and `/data/beam` into `<folder>/rela` and `<folder>/beam`, the layout `move-to-fly` takes back. Last, it releases both apps.

## A migration

A migration command (today `atlas migrate-done-owner`) reads rela on the Mac, so `atlas` refuses it for an environment on Fly. A migration runs on a copy, on the Mac, as it always has, and the migrated copy goes back:

1. **Hold and copy.** `atlas-ops fetch-from-fly --env test --to <folder> --hold`. Test on Fly now serves nothing, so nothing writes to it during the migration. The TUI says Control does not answer.
2. **Migrate the copy on a private instance.**
   - Write a settings file like `env/test.json` without `"fly"`, with `rela.data`, `rela.bin` and `facts.data` pointing into `<folder>`, and with free ports.
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
