# Atlas prod


Remote transport now requires verified full hostnames and TLS certificates; the live configuration is not supplied and cutover is blocked. See [private transport](private-transport.md). Short node names below identify apps, not authenticated connection destinations.
Prod holds the plan: real scenes, use cases and issues. Its data is real from the first write: never wipe it, and never run the end-to-end test or an experiment against it. Try things in test (`atlas tui --env test`) or on a private instance (`ATLAS_ENV_FILE`).

Prod runs on Fly (IS-Atlas-79, below), like test since IS-Atlas-26 (`docs/guides/test-on-fly.md`). This Mac runs only its clients: the TUI, the agents' command line and the agent behind `:`.

## Start

```sh
atlas
```

The same as `atlas tui --env prod`. Prod's core is on the tailnet (D-0089): its machine joins it as `eyra-atlas`, and Console connects straight to Control at `eyra-atlas:7591` (`control.host` and `control.port` of `env/prod.json`). This Mac must be on the tailnet, and the tailnet's ACL must let it reach that port; nothing is opened or started here. The header identifies the environment: `Atlas Console · prod` or `Atlas Console · test`.

When Control does not answer there, `atlas` says so and stops: `not on the tailnet: tailscale status`. A name resolving or a TCP port answering proves no identity; the client must authenticate TLS for the configured full hostname. On it, check that the core runs (`atlas-ops status`): the core's node stays on the tailnet while its machine is stopped, but shows as offline (`tailscale status`), and nothing answers there.

More:
- `atlas-ops status`: whether Control answers over the tailnet, and both apps' machines, checks and deployed build (the image label `master-<commit>`).
- `atlas-ops logs`: the core's log on Fly; rela's is `fly logs -a eyra-atlas-rela`. Prod keeps running on Fly: `atlas-ops stop` and `atlas-ops restart` refuse there.
- `atlas-ops env`: which environment a command works on.
- `atlas-ops install`: link `atlas` and `atlas-ops` into `~/.local/bin`, from the main clone.

`atlas-ops status` and `atlas` check that Control's port accepts a connection, nothing more; the client then authenticates TLS before its protocol hello. Use `fly/smoke.sh prod` (from a machine on the tailnet) for read-only application checks. flyctl is still needed for `status`, `logs`, the data moves and backups, not for reaching Control.

**Prod runs master's build.** A merge to master deploys it (d-0014). A merge to develop changes this Mac's clients (the main clone follows develop) but not prod's core, so a new feature reaches prod only with the next merge to master. Control lets a client newer than itself in, and sends an older one away. A change that the old core cannot serve at all, like the move to the tailnet, needs an order: "Cutover to the tailnet" below.

A deploy first checks that the build's description describes all of prod's data on Fly, as `atlas-ops restart` does for a core on this Mac (IS-Atlas-73). When it does not, nothing is deployed, prod keeps its build, and the job names the data: migrate it first (`docs/guides/test-on-fly.md`, "A migration").

## CI tests a tree once

One change reaches prod through four CI runs on the same git tree: its pull request (on GitHub's merge of it into develop), develop after the integration merge, the release pull request develop → master, and master. The tests (every job of `.github/workflows/ci.yml` except the deploys and the base job) run on the first, and on the others only when the tree is new.

- **The records.** When every test job of a run passed, job `record-tested-tree` uploads the artifact `tested-tree-<tree>` (`git rev-parse HEAD^{tree}`). The base job `model-base` (`mix model.gen --check --base`) is recorded on its own, as `tested-base-<tree>-<base key>` (job `record-tested-base`), because its result also depends on the base: the base key is the blob of `model/targets/proof/digests.json` at the base commit, or `none` when the base has none. The files inside name the run, commit and ref. Artifacts, not caches: caches are scoped to a branch, but the repository's artifact list (`GET /repos/{owner}/{repo}/actions/artifacts?name=…`) shows a pull request's artifact to a later run on develop or master. They live as long as the repository's artifact retention.
- **The base.** A pull request's base is its base branch; a push's is its branch as it was before the push (`github.event.before`). So the pull request into develop and the push to develop that integrates it check against the same develop, and the release pull request and the push to master against the same master. A base that is no commit of the repository (a force push) fails `model-base`.
- **The lookup.** On a push to develop or master, and on a pull request into master, job `tested-tree` looks both up (`tools/ci/tested-tree.mjs find`). It trusts a record only when it is not expired and its run is a completed, successful run of this same workflow file in this repository, not from a fork, and not this run. With the tree's record the test jobs report *skipped*; with the base record as well, `model-base` too. The base job is skipped only together with the tests, so every skipped job of a run is explained by the tree's record. The deploys run as before, with their description check and smoke check: test on develop, prod on master. A pull request into develop never looks up: it always runs, and records, everything.
- **Otherwise everything runs.** No record (develop moved before the integration, so the merge is another tree; a change pushed directly; an expired record), an untrusted one, or a failed lookup: everything runs as before. The lookup never fails a run. The run summary has one line for the tests and one for the base job, for example `tests skipped: tree <hash> passed in run <id>` or `full suite: no record for tree <hash>` with the reason.

In practice, on the release pull request the tests are skipped but `model-base` runs against master's `digests.json` (prod's history), unless master's file is the same blob as develop's; the push to master then finds that record and skips it.

Why it is safe: the test jobs read only the checked-out tree, so the same tree gives the same result, and a different tree, however small the difference, has another hash and runs everything. The one check that reads more, the run identities against the base's `digests.json` (`git show <base>:…`, nothing else from the base), is keyed on that file's content as well, so it is skipped only when the same tree passed against the same file. A record is written only after its jobs passed, and it is trusted only when that whole run succeeded, so a run that failed later, was cancelled or is still running counts for nothing. A fork's run can upload artifacts and run its own edited workflow, so its records are refused by the run's head repository. What stays trusted is a pull request from this repository: someone with write access could edit the workflow in their own branch to record a tree untested, as they could already push untested work; the review of workflow changes covers that.

The required checks stay satisfied: GitHub counts a skipped job as passed, and a run whose test jobs were skipped concludes `success`. The integrate gate's `ci_conclusion` is taken on pull requests into develop, which always run everything; on a release pull request read the run's conclusion or the required checks, not each job's own conclusion, which is `skipped`.

A new test job joins with `needs: tested-tree` and `if: ${{ !cancelled() && needs.tested-tree.outputs.tested != 'true' }}`, and its id in `record-tested-tree`'s needs; a job whose result depends on the base as well skips on `base_tested` instead, and goes into `record-tested-base`'s needs (the comment at the top of the workflow). `tested-tree` checks the workflow on every run and fails CI while a job is outside the scheme, a `deploy-*` job's `if` lost one of its clauses (no failure, no cancel, skipped only when tested), or a record job lost its success condition.

## Where it runs

| | Test | Prod |
|---|---|---|
| rela | `eyra-atlas-test-rela` on Fly, private network only | `eyra-atlas-rela` on Fly, private network only |
| Control | `eyra-atlas-test` on Fly; `eyra-atlas-test:7691` on the tailnet | `eyra-atlas` on Fly; `eyra-atlas:7591` on the tailnet |
| Bus link | `eyra-atlas-test.<tailnet>.ts.net:7694` on the tailnet | `eyra-atlas.<tailnet>.ts.net:7594` on the tailnet |
| Data | the apps' volumes on Fly | the apps' volumes on Fly (the Mac's copy from before the move: `~/.local/share/atlas/prod/`) |

Both run the same pinned rela (26.11.2); test runs develop's newest build, prod master's. Test and prod never connect: each has its own Bus, and a prod Bus or Control refuses a test message or client (and the other way round). Facts never move from test to prod.

## Prod on Fly (IS-Atlas-79)

Prod gets the same two apps as test, on a private network of its own (`eyra-atlas-prod`), which test's apps and the rest of organisation eyra cannot reach. No public address. The core alone also joins the tailnet (D-0089), which is how clients reach it; rela stays on the private network only.

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
| Fly app `eyra-atlas`, from Infisical `prod:/tailscale` (below) | `TS_AUTHKEY` | the tailnet key the core logs in with on its first boot (`fly/core-run.sh`): reusable, pre-approved, tagged `tag:atlas-prod`, not ephemeral | none: before D-0089 clients used `fly proxy` |
| eyra/atlas, repository secret | `TS_AUTHKEY_CI` | the tailnet key CI's deploy jobs join with for the smoke check: reusable, ephemeral, pre-approved, tagged `tag:atlas-ci`; shared by test's and prod's jobs | none |

**The tailnet key.** The core does not start without `TS_AUTHKEY`: it stops with `core-run: TS_AUTHKEY is not set`, and `fly/deploy.sh` refuses to deploy (nothing changes) while the core app has no such secret. It comes from Infisical, like the Runtime's credentials, and goes onto the app as every other core secret does, with `fly secrets`; through stdin, so the key is in no command line or shell history:

```sh
printf 'TS_AUTHKEY=%s\n' "$(infisical secrets get TS_AUTHKEY --plain --env prod --path /tailscale)" \
  | fly secrets import -a eyra-atlas
```

`fly secrets import` restarts the machine with the key. Test's is the same from `test:/tailscale` onto `eyra-atlas-test`.

**One node per app, kept on the volume.** The machine joins as `<the Fly app's name>`, tagged `tag:atlas-<env>`, and is a persistent node: tailscaled keeps its state, the node's key among it, in `/data/tailscale` on the app's volume (`core_data`, at `/data`). The key logs in only a node without a login: the first boot, a new or wiped volume, or a node removed from the tailnet (its state is still on the volume, so it comes up as logged in, the tailnet refuses it, and it logs in again with the key, once per boot). `tailscale up` reads the key from a file only root can read, removed right after; it is on no command line and in no process's environment. Every other boot, a restart, a deploy or a crash, comes back as the same node with the same name, and the key is not used; a stop does not log out. Stopped, the node stays in the tailnet as offline. `fetch-from-fly` and `move-to-fly` copy only `/data/beam` and `/data/rela`, so the node's state never leaves its volume. Two things would make a second node: a new volume while the old node still exists, which then joins as `eyra-atlas-1` (remove the old node in the admin console first, and the new one gets the name), and a copy of the volume (`fly volumes fork`) started as a second machine, which would share the node; keep one core machine.

Tailscale's auth keys expire (90 days at most); a persistent node does not, since tagged nodes have key expiry off. An expired `TS_AUTHKEY` therefore matters only on the next login: a boot that needs one stops with `not on the tailnet after 60 s (state NeedsLogin, …)`. Replace the key in Infisical and on the app, as above, before a volume is replaced.

**The owner's steps, once per tailnet** (in the Tailscale admin console):

1. Tags `tag:atlas-prod`, `tag:atlas-test` and `tag:atlas-ci`, each owned (`tagOwners`) by whoever creates the keys.
2. The cores' keys: one per environment, **reusable and pre-approved, not ephemeral**, tagged `tag:atlas-prod` (into Infisical `prod:/tailscale` as `TS_AUTHKEY`) and `tag:atlas-test` (into `test:/tailscale`); then onto each core app with `fly secrets import`, as above.
3. CI's key: **ephemeral, reusable, pre-approved**, tagged `tag:atlas-ci`, as the repository secret `TS_AUTHKEY_CI` of eyra/atlas (Settings, Secrets and variables, Actions), shared by `deploy-test` and `deploy-prod`. Ephemeral, so each job's node is removed when the job ends; without the secret both deploy jobs fail before deploying anything.
4. An ACL that lets the owner's devices reach `tag:atlas-prod:7591,7594` and `tag:atlas-test:7691,7694`, lets `tag:atlas-ci` reach `tag:atlas-test:7691` and `tag:atlas-prod:7591` only (Control, for the smoke check), and allows nothing else.
5. MagicDNS on, so `eyra-atlas` and `eyra-atlas-test` resolve on every device that may reach them.
6. A core that ran as an ephemeral node before this change: after its first boot with the state on the volume, remove any leftover offline `eyra-atlas` or `eyra-atlas-test` node and check the running one has the plain name (`tailscale status`).

On Fly the connector reads its token from that secret (`connectors.github.token_env` in `fly/prod/core.json`). A token that can only read pull requests of eyra/atlas is enough, for example a fine-grained token with "Pull requests: read" on that one repository. The installed token is verified through an actual private PR refresh; presence or activation metadata alone does not prove authentication. If a token is missing, each round logs `no token: GITHUB_TOKEN is not set` and keeps the stored values.

There is no Flux connector yet: `flux_id` and `flux_ref` are described as set by a connector, but no code reads Flux, so nothing needs a Flux secret. When one is built, its secret goes on `eyra-atlas` the same way.

### Cutover to the tailnet (once, D-0089)

This change moves prod's clients and prod's core to the tailnet together, but they arrive by different routes: the clients with develop (this Mac's main clone follows develop, and `atlas tui` pulls it), the core with master. Develop's clients have no `fly proxy` tunnel any more and reach prod only at `eyra-atlas:7591`, which exists only once master's deploy has put prod's core on the tailnet. So this Mac's prod clients take develop's change only after that deploy, in this order:

The branch is **not ready for live cutover**. Full names, issued certificates,
protected certificate/key paths and renewal ownership have not been supplied or
verified. See [private transport](private-transport.md). A `.ts.net` suffix, an open
port or a protocol welcome proves no destination identity.

1. **Before any merge or deployment:** verify those TLS prerequisites, environment
   separation, exact Tailscale CLI support, staged secrets and existing ACLs. This
   guide grants no permission to change them. Set the environment-specific
   `ATLAS_CONTROL_TEST_HOST` / `ATLAS_CONTROL_PROD_HOST` to the confirmed certificate
   names; CI reads the corresponding repository variables. Never guess the suffix.
2. **Hold compatible clients and proxies.** Preserve the exact previous client
   checkout and configuration on every machine, including the Runtime node, and
   its working Control/Bus proxy configuration. Do not update checkouts, remove
   LaunchAgents/proxies, or release holds until application checks pass. Record a
   held-client/proxy read-only smoke command usable during recovery.
3. **Capture before replacing either app.** `deploy.sh` requires
   `ATLAS_DEPLOY_RECOVERY` naming a new protected directory on durable storage.
   `image-pair.sh capture` saves each actual running immutable image digest,
   machine ID and machine configuration, refusing missing/multiple machines or
   mutable-only image records. CI retains the protected recovery record as an
   access-controlled repository artifact for seven days; copy it to approved
   durable operations storage before that expires. It is operational configuration,
   not public evidence. Capture is complete before preflight uploads or deployment.
4. **Deploy test, verify, then separately authorize prod.** Each pair replaces rela
   first, then core; post-deploy validation and smoke happen **after** replacement.
   A failed command can therefore leave either or both candidate images active.
   `phase` records the last attempted boundary, not a claim of remote success.
5. **Recover according to the boundary.** A pre-deploy refusal leaves the old pair
   untouched. After any attempted deployment, inspect the actual pair and retain
   holds; never assume failure kept the old server. Review the saved images and
   configuration for compatibility with the **current authoritative data**, client
   protocol, credentials and proxy. If incompatible, keep holds and fix forward.
   If compatible, explicitly run:

   ```sh
   ATLAS_RECOVERY_COMPATIBLE=1 ATLAS_RECOVERY_SMOKE=/protected/held-client-check \
     fly/image-pair.sh recover /protected/captured-pair
   ```

   Recovery refuses changed machine ownership, stops the candidate core to quiesce
   writes, restores rela then core using the saved immutable images and machine
   configurations, verifies their running digests, and runs the supplied held-client
   reachability check. A failure at any recovery step keeps client/proxy holds and
   requires diagnosis or rerunning the same reviewed recovery. It never restores
   datasets, volumes, backups, or tailnet node state. Secret versions are not captured
   by the machine configuration: review compatibility without reverting live secrets.
   Changed volume bindings are refused before recovery; reattaching an older volume
   would risk reverting data authority. Retain both registry image digests for the
   entire recovery window; capture alone does not guarantee registry availability.
6. **Release holds only after authenticated application checks** from the intended
   ordinary CLI, discovery, TUI/output and Runtime Bus clients. A TCP `nc` probe is
   insufficient. Remove obsolete proxies only after separate authorization.

Rehearse pre-deploy refusal, failure during each pair replacement, post-deploy
validation/smoke failure, failed recovery and successful held-client recovery using
private fake Fly transport and synthetic immutable images before live approval.

### Back up prod's data

`atlas-ops fetch-from-fly` is prod's backup route. It reads the app names from
`env/prod.json`, so it follows every release; it needs flyctl, logged in (`fly auth login`)
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
   kind.
4. It releases rela, then the core, and waits until both pass their health checks.

The folder must be new or empty. A failure can leave prod held: see "Held" in
`docs/guides/test-on-fly.md` before anything else. With `--hold` both apps stay held after
the copy, for a migration (below). The copy carries no checksums. To check it, run
`atlas-ops move-to-fly --env prod --from <folder> --dry-run`, which checks the description
fits it and counts it without changing Fly, or restore it to a private instance
(`ATLAS_ENV_FILE`).

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
   the agreed policy, #61 set `fly.in_use=true` and removed the local core settings
   (then with a `fly proxy` port; since D-0089 `control.host` is `eyra-atlas` and
   `control.port` 7591, on the tailnet). Validate the prod TUI and CLI against Fly Control. Keep all
   backups and the source dataset. Changing client settings starts no Runtime.

### Runtime after the client switch (IS-Atlas-91)

Coordinate with #78 and `docs/guides/runtime-node.md` when available. Runtime is an
independent process with its own PID and log. Core stop/restart
does not stop it. A disconnected node retries its configured endpoint; it does not
retarget automatically from the Mac to Fly. Settings are read when the node starts.

Activated on 2026-11-13 (IS-91 approval). `fly/prod/core.json` enables the private Bus
listener on `::`, port `7594`; `fly/prod/core.toml` declares no public service for it.
The core secret `ATLAS_BUS_LINK_TOKEN` (a JSON object from machine name to a distinct
random token) must be set on `eyra-atlas` before this configuration deploys: the core
refuses to boot when it is missing or malformed. The first node is the Mac mini's machine
(the name `ATLAS_BUS_LINK_TOKEN` holds for it). Since D-0089 it reaches the listener
directly over the tailnet, at `eyra-atlas.<tailnet>.ts.net:7594`; before, it went through a `fly proxy`
LaunchAgent on `127.0.0.1:7595`, which is removed once (`tools/runtime/README.md`). That
machine's Bus token comes from Infisical (project Atlas, environment `prod`, path
`/runtimes/<machine>`), read at Runtime start through the machine's identity and passed
to the node as an environment variable; it is not stored in the repository, and the
node needs no Fly token any more. Each machine's local `runtime.json` names its machine
and the Bus link's host and port; Runtime is then started explicitly. Agents' CLI calls
use the ordinary client environment file and therefore Fly Control. Keep test/prod
settings and credentials separate.

Prod's settings also add the Workers tab and its grants (`control.tabs`,
`control.workers`): `melle` may read and submit.

Verify Bus registration and stub-turn leases/logs before real agent work. A Runtime
PID alone does not prove a connected Bus. IS-91 retries dropped Bus connections (also
while the Mac mini or the core is off the tailnet); it does not promise cross-machine
failover or a durable outbox.

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
