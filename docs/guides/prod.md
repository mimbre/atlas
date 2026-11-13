# Atlas prod

Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

Prod runs on Fly (IS-Atlas-79, below), like test since IS-Atlas-26 (`docs/guides/test-on-fly.md`). This Mac runs only its clients: the TUI, the agents' command line and the agent behind `:`.

## Start

```sh
atlas
```

The same as `atlas tui --env prod`. It opens the tunnel to prod's Control on Fly in the background (`fly proxy 7593:7591 -a eyra-atlas`, flyctl's WireGuard; flyctl must be logged in to organisation eyra), then Console. The header identifies the environment: `Atlas Console · prod` or `Atlas Console · test`.

More:
- `atlas-ops status`: the tunnel, and both apps' machines, checks and deployed build (the image label `master-<commit>`).
- `atlas-ops logs`: the core's log on Fly; rela's is `fly logs -a eyra-atlas-rela`.
- `atlas-ops tunnel status`, `atlas-ops tunnel close`: show or close this Mac's tunnel; the next `atlas` command opens it again. Prod keeps running on Fly: `atlas-ops stop` and `atlas-ops restart` refuse there.
- `atlas-ops env`: which environment a command works on.
- `atlas-ops install`: link `atlas` and `atlas-ops` into `~/.local/bin`, from the main clone.

Before reusing or opening a tunnel, `atlas` sends a read-only Control hello through
it. A local listening port alone is not enough: flyctl can keep that port open
while its WireGuard tunnel or private DNS is unavailable. An unresponsive existing
proxy is reopened; a new proxy must reach Control within a minute before a client
starts. This changes only the local proxy, never the Fly machines or stored data,
and never retries a client's write. `atlas-ops status` reports an unavailable upstream
separately from a closed tunnel.

The probe proves transport, not Facts/rela health. An explicit hello refusal (for
example an outdated client) also proves transport works; the client reports that
refusal without a pointless proxy restart. Use `fly/smoke.sh prod` for read-only
application checks. Persistent private-DNS or WireGuard failures still require
Fly connectivity to recover; no public address is needed.

**Prod runs master's build.** A merge to master deploys it (d-0014). A merge to develop changes this Mac's clients (the main clone follows develop) but not prod's core, so a new feature reaches prod only with the next merge to master. Control lets a client newer than itself in, and sends an older one away.

A deploy first checks that the build's description describes all of prod's data on Fly, as `atlas-ops restart` does for a core on this Mac (IS-Atlas-73). When it does not, nothing is deployed, prod keeps its build, and the job names the data: migrate it first (`docs/guides/test-on-fly.md`, "A migration").

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | `eyra-atlas-test-rela` on Fly, private network only | `eyra-atlas-rela` on Fly, private network only |
| Control | `eyra-atlas-test` on Fly; this Mac's tunnel end 127.0.0.1:7693 | `eyra-atlas` on Fly; this Mac's tunnel end 127.0.0.1:7593 |
| Data | the apps' volumes on Fly | the apps' volumes on Fly (the Mac's copy from before the move: `~/.local/share/atlas/prod/`) |

Both run the same pinned rela (26.11.2); test runs develop's newest build, prod master's. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.

## Prod on Fly (IS-Atlas-79)

Prod gets the same two apps as test, on a private network of its own (`eyra-atlas-prod`), which test's apps and the rest of organisation eyra cannot reach. No public address.

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas` | shared-cpu-1x, 512 MB, ams (`fly/prod/core.toml`) | volume `core_data` at `/data` (Facts' own: `/data/beam`) |
| rela | `eyra-atlas-rela` | performance-1x, 2048 MB, ams (`fly/prod/rela.toml`) | volume `rela_data` at `/data` (`/data/rela`) |

A merge to master deploys prod (CI job `deploy-prod`, `fly/deploy.sh prod`). It works as test's:
1. The description check on rela's machine; nothing is deployed when the data does not fit.
2. rela, then the core.
3. The smoke check, which reads only.

`env/prod.json` names the apps in its `"fly"` section. Until the switch below it said `"in_use": false`: `atlas` kept using this Mac's prod core and rela, and only `move-to-fly` and `fetch-from-fly` (today `atlas-ops move-to-fly --env prod` and `atlas-ops fetch-from-fly --env prod`) went to Fly.

### Secrets

| Where | Secret | What | Before the client switch |
|---|---|---|---|
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD` | `fly tokens create deploy -a eyra-atlas` | CI's per-app deploy token |
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD_RELA` | `fly tokens create deploy -a eyra-atlas-rela` | CI's per-app deploy token |
| Fly app `eyra-atlas`, `fly secrets set -a eyra-atlas GITHUB_TOKEN=…` | `GITHUB_TOKEN` | the GitHub connector's token: reads the pull requests of eyra/atlas (private), GET only | `gh auth token`: `connectors.github.token_command` in `env/prod.json`, the local gh keyring |

On Fly the connector reads its token from that secret (`connectors.github.token_env` in `fly/prod/core.json`). A token that can only read pull requests of eyra/atlas is enough, for example a fine-grained token with "Pull requests: read" on that one repository. The installed token is verified through an actual private PR refresh; presence or activation metadata alone does not prove authentication. If a token is missing, each round logs `no token: GITHUB_TOKEN is not set` and keeps the stored values.

There is no Flux connector yet: `flux_id` and `flux_ref` are described as set by a connector, but no code reads Flux, so nothing needs a Flux secret. When one is built, its secret goes on `eyra-atlas` the same way.

### Move prod's data, and switch (IS-Atlas-90)

**The coordinator authorizes the maintenance window; keep #61 draft until data checks pass.**
The earlier a-0003 and d-0023 gates are complete. The restricted GitHub token is
deployed and authenticated against a private PR. Under d-0023, the coordinator may
release the exact tested develop build after successful Fly test deployment/smoke.
First release #85 is master 92fbc2692cf5591d6ce315c78d804de59d36e45d, with the same
tree as tested source 46dea5f0092726eb063e477a37d2ba81053f695c. Its actual prod pair,
closure, health and Control were verified. The IS-90 source-transfer window is
separately authorized; the ordinary client switch still requires coordinator review
after the data checks. This guide grants no Runtime/listener/model activation.
Preserve both `rela/` and `beam/`, including Facts' provenance and answered-fact records.

0. **Choose and verify the build.** Use the approved release policy (d-0023), confirm
   private GitHub authentication (a-0003), record the source/master commits and
   successful deploy, and verify BOTH
   apps' image labels (`fly status -a eyra-atlas` and `fly status -a eyra-atlas-rela`).
   Compare the code/configuration trees: source and master can have different commit
   IDs because the release preserves merge history. Check source data with that
   build's description. Before pulling an operational Mac
   checkout, inspect `rela/` changes and follow backup-before-pull: stop the old rela,
   copy the complete environment to a new timestamped backup, then restart the old
   build. Never start new-schema rela over data that still needs a migration.
1. **Freeze every source writer using the OLD client settings.** Keep the operational
   checkout on `fly.in_use=false` through verification. Stop independent Runtime nodes
   on every agent machine (`atlas-runtime node stop --env prod`, when IS-91 is installed),
   close ordinary clients and stop other automated writers. Core stop alone does not
   stop Runtime. Run `atlas-ops stop --rela --env prod` (the core, then rela) on the
   source. Prevent clients, supervisors and unattended deploys from restarting either
   authority during the maintenance window. After #61, `atlas-ops stop` refuses for an
   environment on Fly; use the old settings here.
2. **Preserve the stopped source and destination.** Copy the complete stopped Mac
   environment to a new timestamped folder; keep it immutable:
   ```sh
   cp -Rp ~/.local/share/atlas/prod ~/.local/share/atlas/prod-backup-<UTC-time>
   ```
   Quiesce destination core writers BEFORE replacing destination rela. With old
   settings still in use, hold both destination services and preserve their data:
   ```sh
   atlas-ops fetch-from-fly --env prod --to <new-destination-backup> --hold
   ```
   This holds/restarts the destination core first, then rela. Verify both holds and
   successful backup output before continuing. A failure can leave services held;
   do not reopen either authority until its data and hold state are understood.
   Keep Runtime stopped. During the move rela starts first while the core stays held
   until its own `beam/` archive is applied. Applying an archive removes that app's
   hold. `/data/before-move/` is additional preservation, not a substitute for this
   backup and writer exclusion.
3. **Dry run against the exact stopped source backup:**
   ```sh
   atlas-ops move-to-fly --env prod --from <source-backup> --dry-run
   ```
   Save the schema-fit result and counts per kind and relation, including Assignment,
   `assignment`, `accepted_by` and ownership links. Held destination files remain
   readable over SSH; services need not accept writes for this check.
4. **Transfer that same backup**, using the same command without `--dry-run`, only
   under live-move authorization. Save the output. A partial failure may leave incoming
   archives or one replaced store; inspect both apps and preserve their data before
   restarting or retrying. Do not simply restart both sides.
5. **Separate arrival integrity from reconciliation.** SHA-256 manifests compare
   the sent archives with the manifests recorded by `apply-move.sh` BEFORE service
   boot. This proves byte-for-byte arrival of `rela/` and `beam/`, not that the stores
   remain unchanged after startup. The subsequent counts are read after boot, when
   Flow and connectors may already have reconciled. Investigate mismatches against
   arrival evidence and later facts; save a fresh consistent snapshot if needed.
   Do not start Runtime during these checks.
6. **Verify through Control on Fly:** `fly/smoke.sh prod` lists kinds and counts;
   it is not a semantic comparison of every item. Also compare known scene/use-case/
   issue/PR records, Assignment/ownership and acceptance links, including provenance.
   Account for expected Flow and GitHub changes from the baseline. Confirm the build,
   token-backed GitHub refresh and environment separation. Clients use Control;
   layers use Bus.
7. **Switch ordinary clients only after data checks and delivery approval.** Under
   the agreed policy, #61 sets `fly.in_use=true` and `control.port=7593`, removing
   local core settings. Validate the prod TUI and CLI against Fly Control. Keep all
   backups and the source dataset. Changing client settings starts no Runtime.

### Runtime after the client switch (IS-Atlas-91)

Coordinate with #78 and `docs/guides/runtime-node.md` when available. Runtime is an
independent process with its own PID, log and optional Bus proxy. Core stop/restart
does not stop it. A disconnected node retries its configured endpoint; it does not
retarget automatically from the Mac to Fly. Settings are read when the node starts.

Activated on 2026-11-13 (IS-91 approval). `fly/prod/core.json` enables the private Bus
listener on `::`, port `7594`; `fly/prod/core.toml` declares no public service for it.
The core secret `ATLAS_BUS_LINK_TOKEN` (a JSON object from machine name to a distinct
random token) must be set on `eyra-atlas` before this configuration deploys: the core
refuses to boot when it is missing or malformed. The first node is machine
`melle-mac-mini` on the Mac mini; it reaches the listener through prod's Bus tunnel
`7595:7594`, independent of Control's `7593:7591`. That machine's Bus token and Fly
WireGuard token come from Infisical (project Atlas, environment `prod`, path
`/runtimes/melle-mac-mini`), read at Runtime start through the machine identity
`melle-mac-mini` and passed to the node as environment variables; neither is stored in
the repository. Each machine's local `runtime.json`
names its machine and the tunnel; Runtime is then started explicitly. Agents' CLI calls
use the ordinary client environment file and therefore Fly Control. Keep test/prod
settings and credentials separate.

Prod's settings also add the Workers tab and its grants (`control.tabs`,
`control.workers`): `melle` may read and submit.

Verify Bus registration and stub-turn leases/logs before real agent work. A Runtime
PID alone does not prove a connected Bus. IS-91 retries dropped Bus connections; it
does not promise indefinite recovery of a dead flyctl proxy, cross-machine failover or
a durable outbox.

### Rollback preserves the latest authority

Before the switch, restarting the Mac on its stopped source dataset is safe ONLY
when destination writers are stopped and no destination changes need keeping. Fly's
Flow and connectors may write even before clients switch. Establish which dataset
is authoritative from the facts, not the client settings.

After Fly accepts changes, reverting #61 and restarting the pre-move Mac dataset
can discard them. First stop Runtime and every other writer, hold Fly and preserve a
current consistent copy of BOTH `rela/` and `beam/` in a NEW folder:
`atlas-ops fetch-from-fly --env prod --to <new-latest-backup> --hold`. Check compatibility
with the intended rollback build, restore that latest copy to a separate local
instance and verify through its Control, including ownership, acceptance and
provenance. Only then, under rollback authorization, switch clients to that validated
dataset. Keep Fly held until a single writable authority is established. Preserve
pre-move backups; reverting settings reverses neither data nor external actions.

`atlas-ops fetch-from-fly --env prod --to <new-folder>` makes a consistent backup with a
brief hold; `--hold` keeps both services held. A migration follows
`docs/guides/test-on-fly.md`, "A migration", with its own authorization. Preserve
previous worktrees, branches and backups; cleanup needs separate authorization.

### Private transfer rehearsal

Run from this worktree, with a NEW output folder and the pinned rela executables:

```sh
python3 fly/rehearse-transfer.py --output <new-private-folder> --rela-bin <pinned-rela-bin-folder>
```

The harness copies only the executables, starts real Atlas/rela instances on free
loopback ports with synthetic data, no external connectors and no Runtime agents,
and substitutes a local transport accepting only `rehearsal-core` and
`rehearsal-rela`. It never invokes flyctl. It runs the actual fetch/move/count/
manifest helpers; the boot-time apply helper runs with private mount paths.

Checks cover live-replacement refusal before transport, dry-run without upload or
restart, core-first destination holds, rela-first application, arrival manifests,
linked records through Control, and preservation of a later write when restoring
the latest snapshot to a third private instance. It stops only its own services
and keeps synthetic stores, logs and transport calls in the output folder.

This is a local process/transfer rehearsal, not validation of Fly networking,
VM boot, deployed health checks, GitHub credentials or real model work. Those live
checks belong to the authorized live release/move window. Completed token/release
policy gates do not authorize independent Runtime or real model activation.

### Storage backend and future backups

This transfer copies the current rela file backend, including any attachments and
selected configuration closure, plus separate durable BEAM Facts data. File manifests
are not a general database backup contract. Managed PostgreSQL is the intended later
destination; conversion and routine backup infrastructure remain planned under
SC-Atlas-09 / UC-Atlas-40 / IS-Atlas-115, outside the current release/transfer path.
A PostgreSQL deployment still needs filesystem configuration closure and its own
supported database backup/export, restore/import and isolated restore verification.
