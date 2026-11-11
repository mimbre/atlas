# One-off production recovery point · IS-Atlas-137

This focused route is separate from fixed-head release PR108 (formerly107).
No merge into ECC or live execution is part of preparation. Existing production
credentials stay in CI environment only; no credential/resource/model change.

## Review and execution

After independent review of this exact source, the coordinator may authorize an
operator to push atlas-prod-backup-<full reviewed SHA> pointing at that commit.
Do not create/move that tag during preparation. PR events run private tests only.
The production job admits only this repository/event/full-SHA tag, expected master
dcf7785 and fixed release/ecc28f3-20261106 at ECC. Develop can advance independently.
The tag asserts operator authorization; independent review evidence remains required.
No pre-release merge of this workflow is needed for a push-tag workflow execution.

It shares fly-deploy-prod concurrency with no in-flight cancellation. Preflight
requires the healthy recorded old pair, absent holds, matching packaged settings
and manifest/schema, no pending /data/incoming/{beam,rela}.tar.gz on either app,
dormant Runtime/model/listener configuration, and sufficient
existing disk capacity. It refuses rather than resizing or changing credentials.

## Coverage, consistency and confidentiality

The unchanged supported fetch-from-fly.sh holds/restarts core first, then rela,
copies complete /data/beam and /data/rela while both are held, and releases rela
then core with health checks. State/Bus persisted replies, positions and link
provenance live in the complete beam tree; no additional configured Bus disk store
exists. The rela tree covers facts/relations/attachments and schema/description closure.

The transport rechecks the entire recorded machine/image pair and both pending
inputs at every I/O barrier. SSH/SFTP explicitly target the recorded ID; restarts
must name that same ID. A private intent journal and remote operation marker bind
hold acquisition, copying, retention and normal/exceptional release. Hold contents
must match the operation; acquired holds must remain present and released holds
must stay absent. Pending archives are never removed or applied automatically.

The scoped Fly transport checks both holds at each transfer; remote file manifests
before/after must match. Compressed remote/local SHA256 and extracted per-file
manifests must match. Private State DETS files are opened read-only, repair:false,
and their bytes must stay identical. No Atlas application/model/restore service starts.

Verified archives, manifests and counts are retained under
/data/backups/pre-ecc-<UTC>-<review SHA prefix>/ on the existing per-app volumes.
Both archives are rehashed. Matching complete.json on BOTH sides identifies the
same pair/operation and component digests; one marker is not enough. Final proof
also requires unchanged healthy machine/images and no holds.

These are SAME-VOLUME release recovery copies, not independent disaster recovery
or scheduled IS115 backups. Full plaintext archives, config, per-file names,
counts and private diagnostics must never be public Actions artifacts.
Only bounded proof/failure JSON (aggregate totals, hashes, app/image identity,
operation status) is uploaded. CI plaintext staging is ephemeral; durable copies
remain on private Fly storage. Existing backups are preserved.

## Failure semantics

A pre-existing hold or pending archive is refused before any hold/restart. Pending
input discovered later stops mutations, including automatic release: restart would
apply it before the pinned launcher's hold check. Preserve it for separately
authorized inspection. Never restart merely to clear a pending move.

Failure reconciles journal ownership and only releases acquired sides, in the
existing rela-then-core order. Untouched sides are never restarted. Each barrier
checks both machine/image identities, both pending paths and remote owner/hold
content. Changed identity or foreign ownership stops cleanup without clearing an
unknown hold. Remote owner markers and failed journals remain for diagnosis.
SIGTERM uses the same guards; automatic in-flight cancellation is disabled.

These are check-before-mutation fences under the existing production serialization
slot, not an atomic transaction across SSH, Fly API and independent writers. All
deployment/move/backup writers must honor that slot. An out-of-band writer changing
inputs after a check is outside the protocol. Explicit machine selection prevents
dynamic selection of a replacement by the helper's transport.

Network loss, a hard kill or failed health recovery may still leave holds/partial
retention. A failed job proves neither release nor completeness. Inspect both
sides through authorized access; finish only the known operation's release.
Never clear an unknown hold, blindly retry backup/deploy or claim success from
one archive. Bounded failure metadata identifies the operation without raw output.
No rollback or live data replacement is automatic.

## Concrete recovery procedure — prepared, not executed

1. Stop release/replacement activity. Preserve a NEW latest coherent pair before
   any rollback with supported fetch-from-fly while held. This ECC-specific job
   refuses changed source/image bindings; review a new binding if CI is the only
   available access route. Old Mac data is not authoritative.
2. Read matching complete.json from both retained locations through authorized
   app-scoped SSH/SFTP. Retrieve each archive and files.sha256/counts.txt into a
   new private folder. Match compressed hashes before extraction; never publish
   those files as public artifacts.
3. Extract to recovery/rela and recovery/beam. Verify every file hash, counts,
   schema closure and read-only State DETS integrity. Backup execution checks
   extraction against held source manifests; repeat against retained bytes before
   actual restoration. Keep original archives immutable.
4. Prefer roll-forward with latest data. For a chosen paired restore, run the
   supported matching-source atlas-ops move-to-fly --env prod --from <recovery>
   --dry-run. Only after coordinator's explicit recovery decision use
   --replace-live. Route existing app credentials through the reviewed transport,
   with no token values in argv/logs. Existing apply-move preserves displaced
   data in /data/before-move and compares arrival file manifests/counts.
5. Old dcf7785 code may reject new guidance-kind facts. Never delete them or
   overwrite later writes with this older recovery point without preserving all
   latest history and making an explicit data/code recovery decision. Roll
   forward or review a migration instead. Record any intentional data-loss window.
6. Require both chosen image identities, schema/manifest, health, absent holds
   and positive scoped-read smoke before reopening use. Retain all before/after
   evidence. No live restore rehearsal or automatic rollback is included.

The local fallback is the human's existing interactive fly auth login, but no
human action is currently requested: prepare/review the existing CI credential
route first. If CI credentials fail preflight, report the exact app/operation
and smallest authorized access repair before attempting any hold.

## Private tests

ELIXIR_ERL_OPTIONS='+S 1:1' python3 -m unittest discover -s tools/prod-backup -v

Tests use the real existing fetch helper with a private file-backed fake Fly peer
and small real DETS files. No network/service/model starts. They prove trigger,
source/app/token/operation guards, coherent archive bytes, foreign holds,
corruption/retention failure, DETS readability and changed-machine refusal.
They do not prove current live access or a fresh production backup.



Production image digests are pinned from successful authenticated master CI41913896681/job126879062084, not guessed from labels. Live preflight must match those digests plus source configuration/manifest before any hold. A different pair requires a newly reviewed binding.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
