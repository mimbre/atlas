# Atlas prod

Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

Prod runs on Fly (IS-Atlas-79, below), like test since IS-Atlas-26 (`docs/guides/test-on-fly.md`). This Mac runs only its clients: the TUI, the agents' command line and the agent behind `:`.

## Optional Control TLS ingress (not activated)

The default remains the shared Fly tunnel described below. A client can explicitly
select `ATLAS_CONTROL_ENDPOINT=tls://<full-node-name>.tail8263c4.ts.net:<port>`.
The CLI, TUI, its `steer` child, discovery and worker-output connections inherit this
selection. They verify the system-trusted certificate chain and the full hostname/SNI
before sending any Control hello, token or request. An empty or invalid selection,
untrusted certificate, wrong hostname, plaintext peer or failed TLS handshake fails
closed: no tunnel or plaintext fallback. Unset the variable to restore ordinary settings;
setting it to an empty string does not disable selection. `atlas-ops` is unchanged.

Server support is independently opt-in: `ATLAS_CONTROL_TAILSCALE=1` in the core image
startup enables Control-only ingress; absent or `0` preserves normal startup. Any other
value fails. The image contains checksum-pinned Tailscale 1.104.7 static binaries.
Startup still applies a move first, honors `/data/hold`, and verifies Rela before
starting the sidecar. A held machine never starts or enrolls the sidecar.

The owned daemon uses userspace networking, a dedicated persisted node directory
`/data/control-tailscale` (mode 700), and socket directory
`/var/run/atlas-control-tailscale`. Do not share this state with another service.
`ATLAS_CONTROL_TS_STATE_DIR` and `ATLAS_CONTROL_TS_SOCKET_DIR` override these paths.
`ATLAS_CONTROL_TLS_PORT` defaults to 443. Startup reads the same `ATLAS_ENV_FILE`
(or `$ATLAS_ROOT/products/software_factory/environments/$ATLAS_ENV.json`) as the core and forwards only its configured
Control port, after checking that localhost can reach it. The existing Fly Control
listener/private path stays intact; Bus and Runtime are unchanged.

The supervised foreground command is
`tailscale serve --tls-terminated-tcp=<port> tcp://localhost:<control-port>`
([official Serve reference](https://tailscale.com/docs/reference/tailscale-cli/serve)).
Serve manages TLS termination; Atlas provisions no application certificate/key or
renewal subsystem. There is no Funnel, kernel routing, advertised tag/subnet route or
Tailscale SSH setup. Losing Serve, tailscaled or the core stops the owned processes
and fails startup; shutdown closes ingress and the core together.

Activation requires a separate operator permission/exposure review, an authorized
persisted node, tailnet HTTPS/certificate and MagicDNS prerequisites, and permission
for the intended Control port. The observed eyra.co tailnet uses
`tail8263c4.ts.net`, with an active broad `src=[*], dst=[*], ip=[*]` grant and no active
tagOwners: current policy does not confine Control access to one operator. A
self-device SSH check or member Funnel eligibility does not prove ingress exposure.
Do not activate based on those observations. No ACL, key, enrollment, access or live
Fly change is authorized by this implementation.

An already-authorized node requires no new key; a Stopped node resumes using its
persisted login. Only if an operator later
explicitly authorizes first login may they supply `TS_AUTHKEY`. Startup removes it
from the environment before every child (including apply-move and held startup),
uses a private temporary file only for necessary login, and removes that file. It
never places the key value in argv or logs, and never logs the node out on stop.
Removed/unauthorized nodes without such authorization must remain disabled.

Rollback: unset `ATLAS_CONTROL_ENDPOINT` in clients; disable
`ATLAS_CONTROL_TAILSCALE` and restart the core through the approved operational flow.
Preserve persisted state and existing Fly settings/tunnels. The local fixtures cover
TLS and lifecycle behavior only. The image build, real Fly certificate issuance,
enrollment, policy reachability and Serve route have **not** been exercised; this
section does not claim deployed or working tailnet ingress.

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
while its WireGuard tunnel or private DNS is unavailable. An existing tunnel is shared
by every client on this Mac (the TUI, `atlas` commands, agents), so it gets three hellos
of up to 10 s each, and is reopened only if they all fail and its `fly proxy` has died or
its port no longer accepts. If the port accepts but Control does not answer, `atlas`
prints `Control is slow or not answering through the tunnel: …` and leaves the tunnel
alone. A new proxy must reach Control within a minute before a client starts. This
changes only the local proxy, never the Fly machines or stored data, and never retries
a client's write. `atlas-ops status` reports an unavailable upstream
separately from a closed tunnel.

The probe proves transport, not Facts/rela health. An explicit hello refusal (for
example an outdated client) also proves transport works; the client reports that
refusal without a pointless proxy restart. Use `platform/ops/smoke.sh prod` for read-only
application checks. Persistent private-DNS or WireGuard failures still require
Fly connectivity to recover; no public address is needed.

**Prod runs master's build.** A merge to master deploys it (d-0014). A merge to develop changes this Mac's clients (the main clone follows develop) but not prod's core, so a new feature reaches prod only with the next merge to master. Control lets a client newer than itself in, and sends an older one away.

A deploy first checks that the build's description describes all of prod's data on Fly, as `atlas-ops restart` does for a core on this Mac (IS-Atlas-73). When it does not, nothing is deployed, prod keeps its build, and the job names the data: migrate it first (`docs/guides/test-on-fly.md`, "A migration").

## CI tests a tree once

One change reaches prod through four CI runs on the same git tree: its pull request (on GitHub's merge of it into develop), develop after the integration merge, the release pull request develop → master, and master. The tests (every job of `.github/workflows/ci.yml` except the deploys and the base job) run on the first, and on the others only when the tree is new.

- **The records.** When every test job of a run passed, job `record-tested-tree` uploads the artifact `tested-tree-<tree>` (`git rev-parse HEAD^{tree}`). The base job `model-base` (`mix model.gen --check --base`) is recorded on its own, as `tested-base-<tree>-<base key>` (job `record-tested-base`), because its result also depends on the base: the base key is the blob of `products/software_factory/model/targets/proof/digests.json` at the base commit, or `none` when the base has none. The files inside name the run, commit and ref. Artifacts, not caches: caches are scoped to a branch, but the repository's artifact list (`GET /repos/{owner}/{repo}/actions/artifacts?name=…`) shows a pull request's artifact to a later run on develop or master. They live as long as the repository's artifact retention.
- **The base.** A pull request's base is its base branch; a push's is its branch as it was before the push (`github.event.before`). So the pull request into develop and the push to develop that integrates it check against the same develop, and the release pull request and the push to master against the same master. A base that is no commit of the repository (a force push) fails `model-base`.
- **The lookup.** On a push to develop or master, and on a pull request into master, job `tested-tree` looks both up (`platform/ops/ci/tested-tree.mjs find`). It trusts a record only when it is not expired and its run is a completed, successful run of this same workflow file in this repository, not from a fork, and not this run. With the tree's record the test jobs report *skipped*; with the base record as well, `model-base` too. The base job is skipped only together with the tests, so every skipped job of a run is explained by the tree's record. The deploys run as before, with their description check and smoke check: test on develop, prod on master. A pull request into develop never looks up: it always runs, and records, everything.
- **Otherwise everything runs.** No record (develop moved before the integration, so the merge is another tree; a change pushed directly; an expired record), an untrusted one, or a failed lookup: everything runs as before. The lookup never fails a run. The run summary has one line for the tests and one for the base job, for example `tests skipped: tree <hash> passed in run <id>` or `full suite: no record for tree <hash>` with the reason.

In practice, on the release pull request the tests are skipped but `model-base` runs against master's `digests.json` (prod's history), unless master's file is the same blob as develop's; the push to master then finds that record and skips it.

Why it is safe: the test jobs read only the checked-out tree, so the same tree gives the same result, and a different tree, however small the difference, has another hash and runs everything. The one check that reads more, the run identities against the base's `digests.json` (`git show <base>:…`, nothing else from the base), is keyed on that file's content as well, so it is skipped only when the same tree passed against the same file. A record is written only after its jobs passed, and it is trusted only when that whole run succeeded, so a run that failed later, was cancelled or is still running counts for nothing. A fork's run can upload artifacts and run its own edited workflow, so its records are refused by the run's head repository. What stays trusted is a pull request from this repository: someone with write access could edit the workflow in their own branch to record a tree untested, as they could already push untested work; the review of workflow changes covers that.

The required checks stay satisfied: GitHub counts a skipped job as passed, and a run whose test jobs were skipped concludes `success`. The integrate gate's `ci_conclusion` is taken on pull requests into develop, which always run everything; on a release pull request read the run's conclusion or the required checks, not each job's own conclusion, which is `skipped`.

A new test job joins with `needs: tested-tree` and `if: ${{ !cancelled() && needs.tested-tree.outputs.tested != 'true' }}`, and its id in `record-tested-tree`'s needs; a job whose result depends on the base as well skips on `base_tested` instead, and goes into `record-tested-base`'s needs (the comment at the top of the workflow). `tested-tree` checks the workflow on every run and fails CI while a job is outside the scheme, a `deploy-*` job's `if` lost one of its clauses (no failure, no cancel, skipped only when tested), or a record job lost its success condition.

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | `eyra-atlas-test-rela` on Fly, private network only | `eyra-atlas-rela` on Fly, private network only |
| Control | `eyra-atlas-test` on Fly; this Mac's tunnel end 127.0.0.1:7693 | `eyra-atlas` on Fly; this Mac's tunnel end 127.0.0.1:7593 |
| Data | the apps' volumes on Fly | the apps' volumes on Fly (the Mac's copy from before the move: `~/.local/share/atlas/prod/`) |

Both run the same pinned rela (26.11.3); test runs develop's newest build, prod master's. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.

## Prod on Fly (IS-Atlas-79)

Prod gets the same two apps as test, on a private network of its own (`eyra-atlas-prod`), which test's apps and the rest of organisation eyra cannot reach. No public address.

| | App | Machine | Data |
|---|---|---|---|
| Core | `eyra-atlas` | shared-cpu-1x, 512 MB, ams (`products/software_factory/environments/prod/core.toml`) | volume `core_data` at `/data` (Facts' own: `/data/beam`) |
| rela | `eyra-atlas-rela` | performance-1x, 2048 MB, ams (`products/software_factory/environments/prod/rela.toml`) | volume `rela_data` at `/data` (`/data/rela`) |

A merge to master deploys prod (CI job `deploy-prod`, `platform/ops/deploy.sh prod`). It works as test's:
1. The description check on rela's machine; nothing is deployed when the data does not fit.
2. rela, then the core.
3. The smoke check, which reads only.

`products/software_factory/environments/prod.json` names the apps in its `"fly"` section. Until the switch below it said `"in_use": false`: `atlas` kept using this Mac's prod core and rela, and only `move-to-fly` and `fetch-from-fly` (today `atlas-ops move-to-fly --env prod` and `atlas-ops fetch-from-fly --env prod`) went to Fly.

### Secrets

| Where | Secret | What | Before the client switch |
|---|---|---|---|
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD` | `fly tokens create deploy -a eyra-atlas` | CI's per-app deploy token |
| eyra/atlas, repository secret | `FLY_API_TOKEN_PROD_RELA` | `fly tokens create deploy -a eyra-atlas-rela` | CI's per-app deploy token |
| Fly app `eyra-atlas`, `fly secrets set -a eyra-atlas GITHUB_TOKEN=…` | `GITHUB_TOKEN` | shared by the GitHub connector and Code's integrate receiver on eyra/atlas (private) | `gh auth token`: `connectors.github.token_command` in `products/software_factory/environments/prod.json`, the local gh keyring |

On Fly the connector and Code's integrate receiver read the same secret
(`connectors.github.token_env` in `products/software_factory/environments/prod/core.json`). Restrict the fine-grained token
to eyra/atlas. Integration needs **Pull requests: read and write**, **Contents: read and
write**, **Checks: read**, **Commit statuses: read**, and **Metadata: read**. Also grant
**Workflows: write** if an update from the base can bring in `.github/workflows` changes.
The connector still only reads, but sharing this token gives its process write authority
too. A read-only token is sufficient for polling, not for integration.

Deploy the code and migration with the existing read-only token first; migrated
`integrating` runs wait in `blocked`, so deployment alone does not request their merge.
Verify that migration before rotating the secret to the permissions above, then explicitly
retry only runs whose revision has approving review and test links. Rotation does not
retry a durable refusal. For a request with an uncertain remote outcome, restore access
and let its existing id be looked up; never clear its journal or create a fresh request
to recover it. Verify the installed token through a private PR refresh and a controlled
integration; presence or activation metadata alone does not prove the permissions. If a
token is missing, each connector round logs `no token: GITHUB_TOKEN is not set` and keeps
the stored values.

Fly test keeps the integrate receiver selected so the shared subflow can run, but
`products/software_factory/environments/test/core.json` allows no repositories (`code.repositories: []`). Requests are
refused locally as `repository_not_allowed` and the run reaches `blocked` without any
GitHub read, credential lookup or write. Private e2e instances use their local GitHub
stand-in instead. An unfinished request already in the journal is paused as `working`
while its repository is disabled, with no GitHub call and no invented refusal; reconcile
its existing id once access is intentionally restored.

#### Before changing `code.repositories`

A repository that leaves prod's allow-list pauses its unfinished integrate requests as
`working`, with no GitHub call, until it is allowed again. Before deploying such a change
(for example eyra/atlas → mimbre/atlas), list them from this Mac. The script reads the
journal over `fly ssh console` and changes nothing:

```sh
platform/ops/pending-integrations.sh --repository eyra/atlas
```

It reads the core app from `environments/prod.json` (`--app` to override) and
`/data/code/effects` (`--data` for another `code.data`). It prints one line per request
(`id`, `phase`, `merge_attempted`, `run`, `subject`, `target`, `head`) and exits 0 when
there are none, 1 when it listed some and 2 when it could not read the journal whole.
Settle each listed run first, or keep the repository in the list until they are settled.
`--journal <folder>` reads a local copy instead, for a dry run.

There is no Flux connector yet: `flux_id` and `flux_ref` are described as set by a connector, but no code reads Flux, so nothing needs a Flux secret. When one is built, its secret goes on `eyra-atlas` the same way.

### Back up prod's data

`atlas-ops fetch-from-fly` is prod's backup route. It reads the app names from
`products/software_factory/environments/prod.json`, so it follows every release; it needs flyctl, logged in (`fly auth login`)
with access to both prod apps.

```sh
atlas-ops fetch-from-fly --env prod --to ~/.local/share/atlas/prod-backup-$(date -u +%Y%m%dT%H%M%SZ)
```

1. First it asks both apps whether they already have a hold (`/data/hold`) or a pending
   move (`/data/incoming/<name>.tar.gz`, left by an unfinished `move-to-fly`). If either one
   does, or an app does not answer, it refuses and changes nothing. A restart would end that
   hold, putting prod back in service in the middle of a migration. It would also apply that
   move at boot, before the hold check, replacing prod's data. Find out whose hold or move
   it is and finish that first; never remove it just to make a backup.
2. Then it holds both apps, the core first, then rela (`/data/hold`, then a restart), so
   nothing writes while it copies. For about a minute prod serves nothing: Control does not
   answer, and a linked Runtime loses its Bus link and links again after the release. What
   the Runtime sends in that minute is not answered; it asks again a few times and then
   gives up, so start the backup when no turn is running.
3. It copies `/data/rela` (rela's data) and `/data/beam` (Facts' own) into `<folder>/rela`
   and `<folder>/beam`, the layout `move-to-fly --from` takes back, and counts the items per
   kind on a separate private extraction. The returned raw backup is never opened by
   the counter: even read-only SQLite access can reconstruct its SHM sidecar.
4. It releases rela, then the core, and waits until both pass their health checks.

The folder must be new or empty. A failure can leave prod held: see "Held" in
`docs/guides/test-on-fly.md` before anything else. With `--hold` both apps stay held after
the copy, for a migration (below). The copy carries no checksums. To check it, run
`atlas-ops move-to-fly --env prod --from <folder> --dry-run`, which checks the description
fits it and counts it without changing Fly, or restore it to a private instance
(`ATLAS_ENV_FILE`).

**Code's journal stays with the core volume.** `/data/code/effects` holds the request
ids, update ancestry and durable outcomes. `fetch-from-fly` and `move-to-fly` currently
copy only `rela` and `beam`; their folder is not a complete integration backup. The hold
does stop Code's writes too, but it does not copy its journal. Preserve `/data/code`
alongside the matching stopped `beam` and `rela` data when backing up or transferring
an environment with integration requests. Keep the destination's stopped journal too;
do not combine a different environment's journal with moved runs or release the core
until the matching data has been restored.

**Code's service home is on the core volume too.** With `code.home` (prod:
`/data/code-home`) the core runs a registered Code service (`AtlasCode.Core`) that reads
base repositories from `code.sources`, anonymously for an entry with
`"credentials": "none"` (no gh in the image). Its bare clones can be fetched again, but its
revision handles (`revisions/`) and snapshot manifests (`snapshots/`) exist only there:
without them, the handles and snapshot IDs Flow already holds are unknown to Code. The
move scripts do not copy it either; preserve it with `/data/code`. A home whose owner
crashed is recovered at the next boot through its OS lock (`service.lock`), without `ps`.
Remove `code.home` to run the core without it.

GitHub can supply the current pull state after a move, but cannot rebuild the original
request ids and update ancestry. With a lost journal, `merged_elsewhere` can mean Code
merged at an update head that is no longer in the rebuilt ancestry; `stale_revision`
can mean an earlier branch update landed. An id collision gives `conflict`. These need
operator reconciliation against the preserved records and GitHub state, not a blind
`integration: retry`. Restore the matching journal and look up the existing request
where possible. Never discard or resubmit an ambiguous effect to reconstruct it.

For a stopped source, move-to-fly stages the original archives and their every-file
SHA-256 manifests before fits/counts open a disposable extraction. It sends those
original archives unchanged and compares the boot-time arrival receipts, including
SQLite DB, WAL and SHM files. Validation leaves the source backup byte-identical.
The extraction used for validation may acquire a reconstructed SHM; that extraction
is never repacked as the transfer artifact.

A live local source is supported only by `--dry-run`: checks use coherent SQLite
online backups rather than copying active DB/WAL/SHM files. Logical read-only access
can reconstruct the live SHM sidecar; live checks do not promise byte immutability.
A real move still refuses a served source and requires it to be stopped or a backup.

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
   checkout, inspect `products/software_factory/model/targets/rela/` changes and follow backup-before-pull: stop the old rela,
   copy the complete environment to a new timestamped backup, then restart the old
   build. Never start new-schema rela over data that still needs a migration.
1. **Freeze every source writer using the OLD client settings.** Keep the operational
   checkout on `fly.in_use=false` through verification. Stop the Runtime service on
   every agent machine that links to the core (`atlas-runtime service stop`),
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
6. **Verify through Control on Fly:** `platform/ops/smoke.sh prod` lists kinds and counts;
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

Runtime is the standalone service (`platform/atlas_runtime/host/README.md`), started
explicitly with `atlas-runtime service start`. It is an independent process: it never
starts Atlas core services, and stopping or restarting the core does not stop it.

Its only link to the core is the optional `server.json` in its Runtime home, read once when
the service starts (`AtlasRuntime.Integrations.AtlasServer.Lifecycle`). Without that file
nothing connects and the service runs purely locally. With it, the file must contain exactly
these keys, or the service refuses to start:

| Key | Meaning |
| --- | --- |
| `environment` | `test` or `prod` |
| `host`, `port` | The core's Bus listener this service connects to. It never retargets on its own, for example from the Mac to Fly |
| `machine` | This service's own dedicated machine name, never one another Bus client uses |
| `token_file` | A regular file inside the Runtime home, owned by the home's owner, mode `0600` or stricter, no symbolic link, at most 4 KiB, holding this machine's Bus token |
| `workers` | Nonempty list of distinct local worker IDs whose turns are reported. Each must be a Server agent. Other workers run without any Facts write |

The token is read only from `token_file` and passed only to the Bus link. It never reaches
native agents, status, history or log messages, and the repository never stores it. Keep
test and prod homes, settings and tokens separate.

Activated on 2026-11-13 (IS-91 approval). `products/software_factory/environments/prod/core.json` enables the private Bus
listener (`bus_link`) on `::`, port `7594`. `products/software_factory/environments/prod/core.toml` declares no public service for it.
The core secret `ATLAS_BUS_LINK_TOKEN` (a JSON object mapping each machine name to its own
random token) must be set on `eyra-atlas` before this configuration deploys: the core
refuses to boot when it is missing or malformed. A machine's `token_file` holds that
machine's entry. Agents' CLI calls use the ordinary client environment file, so they go
through Fly Control.

Prod's settings also add the Workers tab and its grants (`control.tabs`,
`control.workers`): `melle` may read and submit.

What the link does: for each turn of a listed worker, the service creates the Server turn
`TU-<machine>-<local turn ID>`, registers that attempt's execution, renews its activity and
lease while it runs, and ends it as `finished`, `failed: …` or `stopped`. It sets no item
and no Flow outcome, and it gives Server no start, stop or guidance over the native agent.

This is a best-effort mirror. Each write is one bounded exchange, and the native turn never
waits for it. The outcome of each write, confirmed or the last failure, is kept on the turn
as `server.report`. A dropped Bus connection is retried, but there is no retry queue,
replay, crash reconciliation, cross-machine failover or durable outbox. An unconfirmed
write stays unconfirmed, and a turn left running by a service that died keeps a lease
until it runs out. A Runtime PID alone does not prove a connected Bus: before real agent
work, check that a listed worker's turn shows up on the Server and that its
`server.report` is confirmed.

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
python3 platform/ops/rehearse-transfer.py --output <new-private-folder> --rela-bin <pinned-rela-bin-folder>
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
