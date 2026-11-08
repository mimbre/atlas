# Runtime architecture

Status: proposed target architecture, recorded from the architecture discussion with Melle. This document does not claim that the current implementation has these boundaries, nor authorize a refactor or permission changes.

## Purpose: make the architecture express the product

Runtime is a worker-execution system, not a collection of CLI wrappers. Its source structure should expose workers, assignments, executions, conversations, interactions, workspaces and handoffs. Provider names, transport protocols, process management and storage formats are implementation details below those concepts.

This is the intent of **screaming architecture**: opening the codebase should reveal what Runtime does, rather than which frameworks or external tools it uses.

Not every domain concept needs a separate layer, application, process or service. Concepts describe the business of Runtime; layers separate responsibilities and dependency direction. Prefer the smallest implementation that preserves those boundaries.

## Ownership boundary

**Runtime owns execution mechanics:** native sessions, execution identity and lifecycle, workspace preparation, permission enforcement, provider selection, local quota eligibility, interaction delivery evidence, durable records and execution events.

**Atlas Server owns orchestration:** work queues, dependencies, assignment selection, workflow gates, acceptance, merge/release policy and escalation rules. A locally installed orchestration server is Atlas Server, not a second workflow engine inside Runtime.

**Console and other clients present state and request permitted operations.** The temporary external coordinator uses the same Runtime interface that Atlas Server should consume. Neither Markdown instructions nor model output authorize workflow transitions.

## Planned local isolation and centralized GitHub access

Decision from Melle: GitHub access should be centralized, not independently available to every agent. This is a planned architecture direction, not an expansion of the current workspace-to-Go migration.

Runtime remains local-first, running native agent CLIs on macOS. Neither Linux nor a VM is required. The implementation stack is Elixir and Go; Python has been removed from Runtime, and no Rust is planned.

### Access boundaries

- Agents receive assigned repository workspaces and private temporary storage, not unrestricted access to the user's home directory, SSH keys or cloud credentials. Worktrees alone are not isolation boundaries.
- Agents may edit, test and perform permitted local Git operations. GitHub credentials and direct authenticated GitHub access belong to a trusted local component outside agent execution sandboxes.
- Centralize GitHub reads and writes required by the workflow, including repository acquisition/fetch, push and PR operations. Workspace preparation requests remote operations through that boundary rather than exposing credentials to agent processes.
- Expose specific operations with validated repository, branch and execution context, not arbitrary shell commands or a generic authenticated HTTP proxy. Apply repository/account restrictions and narrowly scoped credentials.
- Keep permission configuration and credential material outside agent-writable locations. Agents cannot expand their own permissions.
- Atlas Server or the external coordinator still owns workflow authorization, acceptance, merge and release decisions. The local component executes authorized GitHub operations; centralizing credentials does not transfer orchestration to Runtime.

### Code service: contract (implemented: endpoints 1–7; release proposed)

Status: endpoints 1–7 below (health, resolve, snapshot creation, manifest, archive, change submission, publication) are implemented in `beam/apps/atlas_code`. **Release remains a proposal.** Runtime can materialize a snapshot, inspect it offline and submit a repository's changes as a sealed Code-private commit with `atlas-runtime snapshot materialize|status|diff|submit` (below); publication is called by the orchestrator, not by Runtime. Managed worker starts do not use snapshots yet. Everything under "Current callers" was cited from source at `f4492cbeb0f199b0228282c507ae6f8f05b05596`; since step 2, the fresh-start base is Code's `resolve` result rather than `origin/develop` from the worker clone.

Decisions from Melle that this contract follows:
- Code is a separate local Elixir service beside Runtime, reached over authenticated loopback HTTP. The same contract can later be hosted on Atlas Server. No VM, Linux, filesystem mount or private Git server is required, and Runtime keeps working without Atlas Server.
- Code owns Git metadata, repository/provider credentials and Git operations.
- Runtime materializes snapshots into one or more temporary ordinary worker folders. Workers receive folder paths only: no Git metadata, no Code API, no credentials.
- Immutable baselines stay outside worker access. Local read-only status/diff must work offline before the current Git access is withdrawn. Text and binary bytes, deletions, executable modes and symlinks are preserved.
- Changes upload against an exact snapshot and base. Uploading does not authorize a commit, PR or release; the trusted external orchestrator authorizes publication separately. Nothing is silently rebased or overwritten.
- The first proof is the full local Code + Runtime + one external orchestrator workflow. Server and Console work stay parked. Existing trusted development-agent Git/PR access remains until the replacement is proven.

#### Current callers (implemented)

| Responsibility today | Where | Moves to |
|---|---|---|
| Validate a GitHub HTTPS URL and a new branch name; derive the managed clone path and dedicated scope | `tools/runtime/workspace/workspace.go` `workspaceRequest` (`git check-ref-format`), called by Elixir `Workspaces.repository_request` (`workspaces/workspace.ex:19`) from `Service.worker_command` start (`execution/service.ex:178`) | URL/branch validation: Code. Worker-folder path: Runtime. |
| Clone, fetch, check origin, refuse dirty state and existing branches, create the task branch at fetched `origin/develop` | `workspace.Prepare` (`workspace.go:491–628`). Git runs inside the worker's Codex sandbox prefix (`host.go:497–506`) with `credential.helper=!gh auth git-credential`, writing `.git/atlas-runtime-repository.json` | Code (resolve, snapshot). The clone and branch disappear from worker folders. |
| Repository scope, canonical root and Git metadata location | `workspace.Scope` (`workspace.go:291`) and `DedicatedScope` (`:143`, `network_hosts: github.com, api.github.com`); Elixir `Workspaces.permission_scope` at start and continuation (`service.ex:201,229`) | Runtime (folder scope only; the Git fields drop out) |
| Saved Claude cwd/branch/origin identity for continuation | `workspace.Context` (`workspace.go:176`) via `host.saveContext` (`claude.go:385`); `claude-context.json` read at `service.ex:235` | Runtime, against a snapshot ID instead of a branch/origin |
| Directory ownership | `workspace.Lock` (`workspace.go:394`), held by `native-host` until the group is reaped (`host.go:179`) | Runtime (unchanged) |
| Worker GitHub network access | Codex profile `github.com`/`api.github.com` (`host/codex.go:50`); Claude `allowedDomains` from `network_hosts` plus the macOS trustd allowance (`host/claude.go:245–273`). Workers use the user's `gh` login | Removed once Code publishes |
| Handoff identity | `handoff_records.ex:11,193`: `repository_url`, `branch`, `base_sha`, `head_sha`, `pr_url` declared by the coordinator and bound to saved repository metadata | Orchestrator declares; Code later verifies against the change and publication |
| Atlas-connected path | `integrations/atlas_server/*` and `providers/claude.ex` contain no Git or GitHub calls (searched) | No change |
| Run metadata | Saved `repository: {url, branch, base_sha}` (`command_admissions.ex:200–207`); `runtime.repository_prepared` (`host/native.ex:217`) | Adds `snapshot_id` |
| CLI | `atlas-runtime start --repo URL --branch NAME --permissions dedicated-repository` (`tools/runtime/main.go`) | Unchanged in step 2 |
| Credentials | Only the user's existing `gh` login, read through Git's credential helper. No token is stored by Runtime | Code only |
| Local diff | Native agents and the coordinator run `git status`/`git diff` in the worker clone; Runtime has none | Runtime, offline against the baseline |
| Workflow authorization | The external coordinator (inbox workflow) | Orchestrator, unchanged |
| Snapshots and change uploads | None | Code stores them; Runtime materializes and uploads |
| Publication and release | Development agents push with `gh`; the coordinator merges | Code, authorized only by the orchestrator |
| Uncommitted bytes across continuation | `Prepare` keeps them, refusing branch drift (`workspace.go:584–592`) | Runtime keeps the worker folder per execution |
| Exact base | `base_sha` from `rev-parse refs/remotes/origin/develop` (`workspace.go:618`) | Code `resolve` |
| Repository allow-list | Regex accepts any `github.com/OWNER/REPO` | Code configuration lists allowed repositories |
| macOS trustd allowance | Required for worker `gh` | Removable once workers no longer contact GitHub (verify first) |
| Multi-repository | One repository per execution | Manifest with several repositories, each at its own path |

#### Who does what

| | Code | Runtime | Orchestrator |
|---|---|---|---|
| Resolve a ref to an exact commit | performs | requests | chooses repository and ref |
| Snapshot (manifest and archive) | creates and serves | downloads and materializes into worker folders, keeps an immutable baseline outside worker access | — |
| Local status/diff | — | computes offline: worker folder against baseline | reads |
| Change upload | stores against the exact base | builds entries from the diff and uploads them | — |
| Publication (branch, PR) and release (merge) | performs | — | authorizes each one explicitly |
| Credentials and Git metadata | only holder | never | never |

Workers only ever see their folders.

#### Transport and errors (proposed)

Code listens only on `127.0.0.1` with a configured port, using OTP `:inets` `httpd`; Runtime calls it with `:httpc`. Neither needs a new dependency. Requests carry `Authorization: Bearer <token>`.

There are two tokens, each in an owner-only (0600) file under the Code home:
- the **runtime token** allows resolve, snapshot and change operations;
- the **orchestrator token** additionally allows publication and release.

Runtime never passes either token to native workers; `Agent.Native` already strips all but a fixed environment list.

**Known limit:** a same-user token file is not hidden from a worker that can read the user's home directory, e.g. a Codex read-only sandbox. This proposal does not claim worker isolation from Code; that belongs to the later isolation work.

Every error response is `{"error": {"code": "<code>", "message": "<text>", "details": {}}}` with the HTTP status shown:

| Status | Codes |
|---|---|
| 400 | `invalid_request` |
| 401 | `unauthorized` |
| 403 | `forbidden` (wrong token or repository not allowed) |
| 404 | `not_found`, `unknown_ref` |
| 409 | `base_mismatch`, `branch_exists`, `conflict` |
| 422 | `incomplete_upload` |
| 503 | `provider_unavailable` |

Responses are JSON, except archive and blob bodies, which are bytes.

#### Endpoints (1–7 implemented, 8 proposed)

1. **Health.** `GET /v1/health` → `{"service": "atlas-code", "version": "…"}`.
2. **Exact-revision preparation.** `POST /v1/revisions/resolve`
   - Request: `{"repository": "github.com/eyra/atlas", "ref": "develop"}`.
   - Response: `{"repository": …, "ref": …, "commit": "<40/64 hex>"}`.
   - This is read-only (`git ls-remote` or a fetch into Code's own clone).
3. **Multi-repository snapshot.** `POST /v1/snapshots`
   - Request: `{"repositories": [{"repository": "github.com/eyra/atlas", "commit": "<sha>", "path": "atlas"}]}`.
   - Paths are relative, unique and non-overlapping.
   - Response: `{"snapshot_id": "sha256:<digest of the canonical manifest>", "repositories": [{"repository", "commit", "path"}]}`.
   - Idempotent: the same request returns the same ID. An unknown commit is a 404.
4. **Snapshot manifest.** `GET /v1/snapshots/{id}/manifest` → `{"snapshot_id", "entries": [{"repository", "path", "kind": "file|symlink", "mode": "100644|100755|120000", "size", "sha256", "target"?}]}`. The `target` field is present for symlinks only.
5. **Snapshot archive.** `GET /v1/snapshots/{id}/archive?path=atlas` → a tar stream of the working tree only: no `.git`, no credentials, modes and symlinks preserved. Runtime verifies each entry against the manifest before materializing it.

Snapshots as implemented:
- **Cache:** Code keeps one private bare repository per allowed repository under `$ATLAS_CODE_HOME/cache/`. It fetches all branches with its credential helper when a requested commit is missing. Only commits reachable from a branch can be snapshotted; anything else is a 404. Snapshot manifests are stored once, atomically, under `$ATLAS_CODE_HOME/snapshots/`.
- **Identity:** the snapshot ID is the sha256 of the canonical (sorted, compact) `{"entries", "repositories"}` JSON. Request order does not matter, and the commits are part of the identity. The manifest response also returns `repositories`, so Runtime can recompute the ID.
- **Exact bytes:** manifest digests and archive contents are Git blob bytes as stored. `.gitattributes` effects (export-subst, export-ignore, filters, line-ending conversion) are never applied, which is why Code builds the archive itself instead of using `git archive`.
- **Archive:** tar member names are relative to the repository root. Files have mode 0644 or 0755 and symlinks are tar symlinks. There are no directory entries and no `.git`. Headers are deterministic (mtime 0, uid/gid 0, pax for names over 100 bytes). The archive is streamed blob by blob with a `Content-Length`.
- **Refused content:** `422 unsupported_content`, listing every offending entry, for:
  - submodules (gitlinks);
  - symlinks whose target is absolute, empty, not UTF-8 or escapes the repository root;
  - file paths that are not UTF-8, contain control characters or backslashes, or have a `.git` segment;
  - any other mode.
- **Request errors:** unsafe snapshot paths and duplicate or nested paths are `400 invalid_request`, with the offending paths in `details`.
- **LFS:** pointer files are ordinary bytes and are not expanded.
- **Limits:** no timeout on Code's `git fetch`; archive reads time out after 60 s without data. Concurrent snapshots of the same repository are serialized but were not stress-tested. Files of 8 GiB or more are untested.
6. **Change submission.** Three requests:
   1. `POST /v1/changes` with `{"change_id": "<caller UUID>", "snapshot_id", "repository", "base_commit", "entries": [{"path", "op": "write|delete", "kind", "mode", "size", "sha256", "target"?}]}`.
      - `base_commit` must equal that repository's commit in the snapshot; otherwise `409 base_mismatch`.
      - The response lists missing blob digests.
      - Repeating with the same `change_id` and identical body is idempotent; a different body is `409 conflict`.
   2. `PUT /v1/changes/{id}/blobs/{sha256}` with the bytes. Code verifies the digest and size. Re-uploading the same blob is a no-op.
   3. `POST /v1/changes/{id}/seal`.
      - Refuses with `422 incomplete_upload` and the missing digests until every blob is present.
      - Then builds a commit whose parent is exactly `base_commit` on a Code-private ref, and returns `{"change_id", "state": "sealed", "commit"}`.
   - Open (unsealed) changes are never visible to publication and may expire; sealing is the only transition.

   Change submission as implemented:
   - **Body limits:** change IDs are canonical lowercase UUIDs. JSON bodies are capped at 16 KiB, except `POST /v1/changes` at 1 MiB; blobs are capped at 64 MiB, and anything larger gets `413 payload_too_large`.
   - **Entry paths** are repository-relative and pass the same path check as snapshots.
   - **Entry shapes:**
     - delete: `{path, op}`;
     - file write: `{…, kind: "file", mode: 100644|100755, size, sha256}`;
     - symlink write: `{…, kind: "symlink", mode: 120000, target, size, sha256}`, where size and digest are those of the target bytes. Code stores the target itself, so symlinks are never listed in `missing`.
   - **Deletes** must name a file or symlink in the base.
   - **Replacements must be explicit:** writing a file where a base directory had entries, or writing under a base file, requires deleting every replaced base path. Otherwise the request is `400` with the conflicting paths.
   - **Written symlink targets** use the snapshot symlink rule; a violation is `422 unsupported_content`.
   - **Repeats:**
     - an identical body (entry order ignored) returns the current state;
     - a different body is `409 conflict`;
     - a blob upload is verified for size and digest and is a no-op when repeated;
     - an unreferenced digest is `404`.
   - **Seal:**
     - Builds the tree in Code's private cache with a temporary index (no checkout, no `.gitattributes` filters), then runs `commit-tree -p <base_commit>`.
     - Author and committer are `Atlas Code <atlas-code@localhost>`, with the base commit's committer date, so the same change always produces the same commit. The message is `Atlas change <id>`.
     - Creates the private ref `refs/atlas/changes/<id>` without overwriting. A repeated seal returns the recorded commit.
     - Nothing is pushed and `refs/heads` is never touched; a moved source branch does not change the parent.
   - **Limits:**
     - a blob upload is held in memory (up to 64 MiB) before its size is checked;
     - a body over 64 MiB gets httpd's HTML 413 page;
     - a Git failure during seal returns a plain 500;
     - open changes are never cleaned up, and there is no `GET /v1/changes/{id}`; repeat the `POST` instead;
     - concurrency and a crash during seal were not tested.
7. **Publication.** `POST /v1/publications`, orchestrator token only.
   - Request: `{"publication_id", "change_id", "branch": "work/…", "pull_request": {"base": "develop", "title", "body"}?}`.
   - Code pushes the sealed commit to a new branch: create-only, never forced (`409 branch_exists`). It opens the PR when one is requested.
   - Response: `{"publication_id", "branch", "commit", "pr_url"?}`.
   - If `develop` has moved, the PR shows the conflict; Code does not rebase.

   Publication as implemented:
   - **Authorization:** an optional `$ATLAS_CODE_HOME/orchestrator.token` (regular file, not a symlink, mode 0600 or stricter, non-empty, different from the runtime token; otherwise start is refused) enables publication. The orchestrator token is accepted on every endpoint. The runtime token gets `403 forbidden` "Publication requires the orchestrator token". Without an orchestrator token, publication is `403` "Publication is not configured". Tokens are compared as SHA-256 digests in constant time.
   - **Request rules:**
     - Unknown keys are refused, and the body is capped at 16 KiB.
     - `branch` must start with `work/` and be a valid branch name.
     - PR `title` must be one line of at most 256 characters, and the PR `body` must contain "Written by an AI agent".
     - Repository, base and commit come only from the stored change. Unknown changes are `404`, open changes `409 change_not_sealed`, and repositories no longer allow-listed `403`.
     - A PR on a remote that is not `https://github.com/OWNER/REPO(.git)` is `422 unsupported_provider`, refused before anything is recorded or pushed.
   - **Create-only push:** `git push --porcelain --force-with-lease=refs/heads/B: URL COMMIT:refs/heads/B` from Code's cache. Only a "new branch" result counts. The lease does not refuse a branch already at the same commit (Git reports it as up to date), so Code treats that, and any rejection, as `409 branch_exists`.
     - Existing remote branches are never moved, including fast-forwards.
     - Another publication ID that already claimed the same repository and branch is also `409 branch_exists`.
     - No merge, rebase or `develop` change; the cache's `refs/heads` are untouched.
   - **Phases and retries:** `publications/<id>.json` records the request and phase atomically before each remote effect. The phases are `pushing` → `pushed` → `published`, or `failed`.
     - An identical repeat resumes from the recorded phase; a different body under the same ID is `409 conflict`.
     - A repeat in `pushing` first checks the remote. At the sealed commit, it counts as Code's own earlier push (a third party creating the same branch at the same commit looks identical and is harmless). Absent, it pushes again, create-only. At any other commit, `failed`.
     - With a PR requested, `pushed` first adopts exactly one existing PR for the branch (`gh pr list --state all`), otherwise runs `gh pr create` (`GH_PROMPT_DISABLED=1`, body from a temp file). Any `gh` failure stays at `pushed` and returns `502 publication_incomplete` with `{phase, branch, commit}`; it is never reported as success.
     - Git failures are `503 provider_unavailable` with the exit status only; raw Git or `gh` output never reaches a response.
   - **Configuration:** `config.json` may set `"gh"` to the `gh` executable; the default is `gh` on PATH, using Code's own `gh` login.
   - **Limits:**
     - All publications are serialized by one lock, including remote calls.
     - A failed publication's branch claim is permanent.
     - The fixture tests prove PR creation and adoption only against a fixture `gh`. The coordinator's real local cycle then published real PR #178 through Code from a Runtime-submitted sealed change (`dfaa38cc96fa209b9696ce1a621ec50ae811274a`), verified the exact head and merged it at `760891d6b9bf13fb87d0a12f79afbf99f564087e` (evidence `/Users/melle/.dv-mtwh41yj/verification/local-development-cycle.json`). That proves publication, not worker-profile security.
8. **Release.** `POST /v1/releases`, orchestrator token only.
   - Request: `{"release_id", "pr_url", "expected_head": "<sha>"}`.
   - Code merges only if the PR head equals `expected_head` and GitHub reports it mergeable; otherwise `409 conflict`.
   - This is the last step and is proposed for after the local workflow proof.

All mutating requests carry caller-chosen IDs. A repeated identical request returns the recorded result, the same rule as Runtime admissions.

#### Step 2: smallest runnable extraction (implemented)

Scope:
- A new `beam/apps/atlas_code` application, started as its own local service (its own home, port and token files). It does not start Runtime.
- It implements only `GET /v1/health` and `POST /v1/revisions/resolve`, using its own credential helper call (`gh auth git-credential`, as `Prepare` uses today) and a repository allow-list.
- Runtime's managed-repository start calls `resolve` before preparation. `Prepare` checks out the returned commit instead of `rev-parse refs/remotes/origin/develop` (`workspace.go:618`), and records it as `base_sha`.
- Clone/fetch inside the worker clone stays unchanged in step 2.
- If Code is unconfigured, unreachable or refuses, the start fails with a `Code service unavailable: …` error before anything is cloned or launched. There is no local fallback, embedded Code or Atlas Server use.
- Continuation and `--cwd` runs never call Code.

Acceptance proof:
- Code and Runtime start and stop independently.
- A real managed start records `base_sha` equal to Code's `resolve` result, which equals `git ls-remote origin develop`.
- With Code stopped, the same start fails with the explicit error, with no clone and no native process.
- Wrong token and a disallowed repository are refused.
- Continuation of an existing managed turn still works with Code stopped.

As implemented:
- **Startup:** `cd beam/apps/atlas_code && ATLAS_CODE_HOME=/abs/home mix atlas_code.server`. It runs as its own BEAM process, binds only `127.0.0.1`, prints `Code ready on 127.0.0.1:PORT` and starts no Runtime, Bus or State.
- **Code configuration:** `$ATLAS_CODE_HOME/config.json` is `{"port": N, "repositories": {"github.com/OWNER/REPO": "<git remote URL or path>"}}`. Its keys are the allow-list.
- **Token:** `$ATLAS_CODE_HOME/runtime.token` must be a regular file with mode 0600 or stricter, otherwise start is refused. An optional `orchestrator.token` with the same rules enables publication (endpoint 7).
- **Runtime configuration:** Runtime reads `<runtime state dir>/code.json`, i.e. `{"url": "http://127.0.0.1:PORT", "token_file": "/abs/path"}`. The Go CLI strips `ATLAS_*` from the daemon environment, which is why this is a file rather than environment variables.
- **Managed start:** Runtime resolves `develop` of the normalized repository before reserving an admission or creating anything. The fresh repository record carries `resolved_commit`. `Prepare` checks that commit exists after its existing fetch, branches from it, and saves it as `base_sha`. Saved runs and continuations keep `{url, branch, base_sha}`.
- **Remaining Git responsibilities:** clone, fetch, origin and dirty checks still run inside the worker's sandboxed clone with the user's `gh` credential helper. Code only runs `ls-remote` through the same helper.
- **Limits:** Code has no timeout of its own on a hanging `ls-remote` (Runtime gives up after 15 s). Oversized bodies get httpd's HTML 413. Runtime does not check `token_file` permissions. Same-user processes, including workers, can read the token file.

Runtime snapshot materialization (implemented, Go package `tools/runtime/snapshot`):
- **Command:** `atlas-runtime snapshot materialize --snapshot sha256:<hex> --dest NEW_PATH` runs in the CLI process, not the daemon. It reads `<runtime home>/code.json` and talks to Code with the Go standard library (loopback only, no proxy or redirects). It prints `{"snapshot_id", "destination", "baseline", "repositories"}`.
- **Verification:** the manifest must re-encode to the requested ID (the same canonical JSON as Code). All repository and entry paths must be safe and non-overlapping, with no `.git`. Symlink targets must resolve inside their repository even through other symlinks; this is stricter than Code, so some Code-accepted snapshots are refused. Every archive member must match its manifest entry's path, kind, size, sha256, mode and link target. Unexpected, duplicate or missing members, hardlinks and other member types are refused.
- **Writing:** files are created with `O_EXCL|O_NOFOLLOW`, and a directory the run did not create is refused. Everything is staged in a private (0700) folder next to the destination. The folder is published with an exclusive rename (`renameatx_np RENAME_EXCL` on macOS, `renameat2 RENAME_NOREPLACE` on Linux; other platforms are refused). An existing destination is never touched. A failure before publication removes all staging.
- **Baseline:** an immutable, read-only copy is kept at `<runtime home>/snapshots/<hex>/` (`manifest.json`, `complete`, `tree/`). It is reused for later materializations of the same snapshot. `<runtime home>/materializations/<sha256(dest)>.json` records `{destination, snapshot_id, materialized_at}` after publication. Runtime runs no `git`, and no credentials or Git metadata reach the destination or the baseline.
- **Limits:** a killed process leaves its 0700 staging folders. A reused baseline is trusted by its `complete` marker, not re-hashed. NFC/NFD name collisions are not modelled. There is no manifest size cap. Linux publishing has only been cross-compiled, not run.

Offline status and diff (implemented, `tools/runtime/snapshot/inspect.go`):
- **Commands:** `atlas-runtime snapshot status --dest PATH [--path REPO_PATH]...` and `atlas-runtime snapshot diff --dest PATH [--path REPO_PATH]...` run in the CLI process with no daemon, Code request or Git.
- **Output:** `{snapshot_id, destination, clean, changes}`. Each change has `repository`, `path` (relative to the destination) and `change`:
  - `added`, `deleted` or `modified`, with `binary: true` for binary content;
  - `mode`, with `old_mode`/`new_mode`;
  - `symlink`, with `old_target`/`new_target`;
  - `kind`, with `old_kind`/`new_kind`.

  A content change that also flips the executable bit is one `modified` entry carrying both mode fields. `diff` adds a unified `diff` string to each text change (`a/`/`b/` headers, `/dev/null` for added or deleted files).
- **Verification:** the destination's materialization record, the baseline `complete` marker and the manifest hash must all match the snapshot ID, and the manifest must pass the materialization checks. A baseline file is re-hashed when it is read for a diff. Any mismatch or missing piece is an explicit error, never a clean result.
- **Symlinks** are compared as links and never followed.
- **Files outside repository paths** are reported as `added` with `repository: ""` unless `--path` restricts the walk.
- **Never written:** neither the destination nor the baseline.
- **Limits:** every selected file is hashed on each run (no stat cache). Files over 1 MiB are reported without binary/text classification or diff. More than 2000 changed lines gives no text diff. Empty directories are not reported. Hunks can differ from GNU diff on ties.

Folder submission (implemented, `tools/runtime/snapshot/submit.go`):
- **Command:** `atlas-runtime snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID` submits one repository of a materialized folder. `--path` may be omitted only when the folder has a single repository. The change ID must be a lowercase UUID chosen by the caller; reuse it to repeat or resume.
- **Identity:** snapshot, repository and base come from the verified record, baseline and manifest (the same checks as `status`). Changes come from the same offline comparison. No Git runs.
- **Conversion** (paths relative to the repository root):
  - added or modified files become file writes with their exact bytes and mode; a mode-only change rewrites the same bytes with the new mode;
  - symlinks are written with their target;
  - deletions become deletes, and file, directory and link replacements carry the explicit deletes Code requires;
  - empty directories cannot be represented and are ignored.
- **Refused locally, never silently omitted:** FIFOs, sockets and devices; `.git` paths; absolute or escaping symlinks; a repository folder replaced by a non-directory; blobs over 64 MiB; a request over 1 MiB. Nothing is sent to Code.
- **Consistency:** every written file is copied (opened `O_NOFOLLOW`) into a private 0700 folder under `<runtime home>/submissions/`. Entries are built from those copies, and the folder is scanned again. Any difference refuses with `folder … changed during submission; nothing was sent to Code`. Uploads come from the copies, which are removed afterwards. Neither the destination nor the baseline is written, and the baseline is never "advanced".
- **Flow:** `POST /v1/changes`, `PUT` each missing blob, then `POST …/seal`.
  - A clean repository returns `state: "clean", commit: null` without contacting Code.
  - Success returns `{snapshot_id, repository, path, base_commit, change_id, state: "sealed", commit}`.
  - An identical repeat returns the same commit; an already-sealed change needs only the POST. Changed content under the same ID surfaces Code's `409 conflict`.
  - Any failure after or during the POST says the change is not confirmed sealed, that nothing was published, and to repeat the same command to resume. A resume uploads only what is still missing.
  - No local submission record is kept; Code's state answers repeats.
- **Limits:** a file that changes and changes back between the copy and the rescan is not detected (only identical bytes could pass). Path checks refuse at the first problem rather than listing all. Each Code read times out after 60 s, and a slower seal is reported as unavailable with the resume hint.

Materialized-folder profile (implemented for Codex and Claude):
- **Command:** `atlas-runtime start --worker W --backend codex|claude --cwd DEST --permissions materialized-folder ASSIGNMENT`, where `DEST` is a folder produced by `snapshot materialize` **outside the Runtime home**. It cannot be combined with `--sandbox` or `--repo`/`--branch`. Claude also accepts `--questions` with it. There is no fallback to broader permissions, and legacy `dedicated-repository` is unchanged.
- **Supported layout:** the folder scope refuses a `DEST` that equals, lies inside or contains the Runtime home: `Materialized folder <DEST> overlaps the Runtime home <HOME>; materialize it outside the Runtime home`. Because start, continuation and the native host all compute the scope, this happens before any native process. A saved turn in such a folder fails to continue with the same message, and nothing is moved. (Inside the denied home, the sandbox blocks `lstat` of the folder's parent, so offline inspection could not work.)
- **Inspector contract:** worker commands get `ATLAS_RUNTIME_EXECUTABLE`, the resolved absolute path of the `atlas-runtime` that launched them. Workers inspect with `"$ATLAS_RUNTIME_EXECUTABLE" snapshot status|diff --dest DEST`. A bare `atlas-runtime` is not part of the contract: a login shell can select another installation earlier on `PATH`, and older CLIs fail inside the sandbox.
  - If the executable lies inside a path the profile denies (for example a deployment that keeps it in the Runtime home), that single file gets read access: a Codex `"<exe>"="read"` entry, or a Claude `allowRead` entry. The rest of the home stays denied.
  - An executable inside `DEST`, the Codex scratch folder or the Claude private temp is refused (`Runtime executable … is inside worker-writable …`), because a worker could replace it.
- **Scope without Git:** the internal `atlas-runtime workspace folder-scope DEST HOME` verifies the materialization exactly as `snapshot status` does. It refuses a non-canonical `DEST`, a `.git` entry in `DEST` or any ancestor (so the trusted native Codex never finds a Git repository), and project or ancestor `.codex/config.toml`. The scope binds `{profile, version, root, snapshot_id, repositories, home, record, baseline}`. Start, continuation and the native host recompute it and require equality, so a re-recorded or replaced snapshot refuses continuation. No Git, Code request or pre-exec wrapper runs, and the directory lock is held until the process group is reaped.
- **Effective Codex profile** (`extends=":read-only"`, `network.enabled=false`, no proxy):
  - `DEST` and a private `HOME/scratch/<turn>` are writable;
  - the Runtime `HOME` is `none`, except read access to this snapshot's record and baseline;
  - `DEST/.git` and each `DEST/<repo>/.git` are `none`;
  - the Code token file and its directory (from `code.json`), `$CODEX_HOME`, and known credential paths are `none`: `~/.codex`, `~/.config/gh`, `~/.ssh`, `~/.aws`, `~/.docker`, `~/Library/Keychains`, `~/.git-credentials`, `~/.config/git`, `~/.netrc`, `~/.gitconfig`, `~/.claude`, `~/.claude.json`, and the default Runtime home.

  Paths are resolved through symlinks before mapping. `process.json` records the exact arguments.
- **Worker environment:** the existing minimal environment, plus `ATLAS_RUNTIME_EXECUTABLE` (the inspector contract), `ATLAS_RUNTIME_HOME`, the executable's directory prepended to `PATH` (convenience only), and `TMPDIR`/`GOCACHE`/`GOTMPDIR`/`XDG_CACHE_HOME`/`npm_config_cache` in the scratch folder, which is removed after reaping. `snapshot status|diff` do not create or chmod the Runtime home, so they work read-only inside the sandbox.
- **Limits:**
  - The base is still `:read-only`, so credential protection is a deny-list: secrets in unlisted locations (for example `~/.npmrc` or `~/.kube`) stay readable, and other non-credential home files are readable.
  - `GOMODCACHE` is not redirected, so builds need modules already cached.
  - Workers can create `.git` in unmapped subfolders; these are reported by `status`.
  - This is provider-sandbox confinement, not hostile-host isolation.

Claude with the materialized-folder profile:
- **Same scope, lock and continuation identity as Codex.** The Runtime host runs no Git and no pre-exec child. `claude-context.json` is written Git-free as `{cwd: DEST, git: null, permissions: scope}` and compared on continuation, so a rebound snapshot is refused. Native session/model confirmation and opt-in questions are unchanged.
- **Temp:** Claude's existing private temp (`~/.ac-XXXXXXXX`, under the 44-byte child-temp limit) is used as `CLAUDE_CODE_TMPDIR`, `TMPDIR` and cache base. It is removed after reaping. `DEST` inside a system temp root, or inside a protected path, is refused.
- **Tools:** `Bash,Read,Glob,Grep`, plus `AskUserQuestion` with `--questions`. Edits go through Bash; the file tools are confined to the working directory by `--restricted`.
- **Settings** (`--settings`):
  - sandbox enabled, `failIfUnavailable`, no unsandboxed commands;
  - `allowWrite` = `DEST` and the private temp;
  - `denyWrite` = system temp roots, the protected paths, and the record and baseline;
  - `denyRead` = the protected paths: the Runtime home, `DEST/.git` and each `DEST/<repo>/.git`, the Code token file and its directory, `~/.claude`, `~/.claude.json`, `~/.codex`, `~/.config/gh`, `~/.ssh`, `~/.aws`, `~/.docker`, `~/Library/Keychains`, `~/.git-credentials`, `~/.config/git`, `~/.netrc`, `~/.gitconfig` and the default Runtime home;
  - `allowRead` = this snapshot's record and baseline, `~/.claude/shell-snapshots` and `~/.claude/session-env` (which Claude's Bash needs), and the inspector executable when it lies inside a protected path;
  - network: empty `allowedDomains` with `strictAllowlist`, no local binding or Unix sockets, no trustd allowance;
  - `permissions.deny` holds a `Read(//path)` rule for each protected path, which also governs Read/Glob/Grep.
- **Limits (in addition to the shared deny-list limits):**
  - The trusted native Claude CLI itself runs `git remote`/`git ls-files` probes in `DEST` at each launch. They find no repository, but they are Git invocations by the provider, not by Runtime.
  - Claude creates `DEST/.claude/.cc-writes`, which `snapshot status` without `--path` reports.
  - `shell-snapshots` (the user's shell aliases and functions) are readable.
  - Claude Code blocks long foreground `sleep`-style commands on its own.
  - Verified with Claude Code 2.1.280.

Later bounded steps, each a separate assignment:
1. Use materialized snapshots for worker starts automatically (orchestration).
2. Proof of the full local workflow, including real GitHub publication through Code. Only after that: withdraw worker GitHub access, remove the macOS trustd allowance where verified, then release (endpoint 8).

Open questions:
- How the orchestrator token is provisioned to the external coordinator.
- Snapshot retention limits.
- Whether `resolve` uses `ls-remote` or a persistent Code clone. Step 2 can use `ls-remote`; snapshots need a clone.
- Whether a worker-visible read-only status/diff is exposed as a Runtime command or as a file Runtime writes into the turn artifacts.

### TLS relationship and limits

The current macOS Claude trust-service allowance is a verified compatibility fix, not the final isolation design. A trusted GitHub component could perform certificate verification outside the agent sandbox, allowing removal of that allowance from agents if no other required tools depend on it. Verify those dependencies before removal; never disable TLS verification.

Centralized access reduces credential exposure but is not sufficient by itself to prevent data leaving the machine. Its operation surface must not permit arbitrary destinations, repositories or accounts. Approved publishing operations can still transmit workspace content; authorization must constrain where and what may be published.

## Domain concepts

| Concept | Responsibility and boundary |
|---|---|
| Worker | Stable identity across assignments. Identifies the current execution; does not select work from a queue. |
| Assignment | Explicit work request: instructions, repository, base revision and required capabilities. An assignment is not a native conversation. |
| Execution | One attempt to perform an assignment. Owns lifecycle, cancellation, outcome and failure. Distinct from worker identity. |
| Conversation | Provider-bound native session and continuation context. May be reused only when its identity, workspace and permissions remain compatible. |
| Interaction | A question and its answer, including admission, delivery, processing and invalidation evidence, bound to exact executions. |
| Workspace | Repository acquisition, fresh branches, ownership and continuation compatibility. Does not choose assignments or merge work. |
| Execution policy | Local provider/model selection, quota eligibility, fallback and capability requirements. Cannot silently weaken permissions or required capabilities. |
| Handoff | Declared completion or PR result, revisions, verification evidence, limits and remaining processes. A handoff is not acceptance or merge. |

Events and persistence support these concepts. They should not become the primary organizing idea of the architecture.

## Layers and dependencies

```mermaid
flowchart TD
    Entry["Entry points: CLI / Atlas Server"]
    Operations["Runtime operations: assign, start, answer, stop, continue, inspect"]
    Domain["Workers · Assignments · Executions · Conversations · Interactions · Workspaces · Handoffs"]
    Ports["Provider, workspace, execution-host and storage contracts"]
    Adapters["Claude · Codex · Git · OS processes/sandbox · Filesystem"]
    Entry --> Operations
    Operations --> Domain
    Operations --> Ports
    Adapters -. implement .-> Ports
```

The arrows describe dependencies, not a requirement that every request traverse every box. Domain rules must not import provider implementations, subprocess protocols or transport formats. Adapters implement contracts owned by the Runtime core.

### 1. Domain: what Runtime means

The domain defines identity, state transitions and invariants:

- A worker has at most one active execution.
- An answer targets one question in one exact execution; it must not reach a replacement attempt implicitly.
- Continuation preserves a compatible conversation, workspace and permission scope.
- Stopping an execution invalidates its pending interactions.
- Execution completion does not imply task acceptance or successful verification.
- Recording a handoff does not merge a PR or issue a new assignment.
- Delivery, native processing and verified task success are distinct facts.
- Unknown outcomes remain unknown; they are not permission to replay side effects.

No provider names, shell commands, socket formats or filesystem serialization belong in these rules.

### 2. Runtime operations: what callers can do

Application operations coordinate domain transitions and infrastructure:

- Admit an explicit assignment and start execution.
- Continue a compatible conversation.
- Answer an exact pending question.
- Stop an owned execution.
- Submit or inspect a handoff.
- Inspect execution state, output and history.
- Reconstruct durable state after reconnect.

This layer handles request identity, admission ordering and deduplication. Those rules must not be reimplemented separately in provider adapters. Durable admission is not proof that a provider executed a task, and uncertain launch outcomes must not cause automatic redispatch.

It does not select backlog work, approve results, merge PRs or deploy. Those remain orchestration responsibilities.

### 3. Contracts: what Runtime requires from infrastructure

The provider contract should cover the complete execution and interaction lifecycle:

- Describe capabilities before admission.
- Start or resume a native conversation.
- Emit normalized identity, output, question, completion and failure events.
- Deliver an answer to the exact native interaction and report the evidence the provider actually exposes.
- Stop execution through the owned execution-host mechanism.

Runtime asks whether a provider supports active questions; it must not encode that rule as `backend == "claude"`. Claude and Codex translate their native protocols into the same Runtime interaction contract. They must not introduce separate question stores or parallel public APIs.

Capability differences remain explicit. A provider that cannot satisfy an assignment's required interaction or permission contract must refuse before execution where possible. Fallback cannot silently discard those requirements. Changing providers starts a new conversation with an explicit handoff; it is not continuation of the old native session.

Separate infrastructure contracts cover workspace preparation, execution hosting and storage. These are dependency boundaries, not justification for a plugin platform or generic framework.

### 4. Adapters: how execution happens

| Adapter | Responsibility |
|---|---|
| Claude | Translate Claude's native protocol, session configuration and interaction evidence into Runtime contracts. |
| Codex | Translate Codex's native protocol, session configuration and interaction evidence into the same contracts. |
| Git workspace | Prepare repositories and branches, and inspect ownership and compatibility. |
| Execution host | Own OS processes and process groups, signals, environment setup and application of the authorized sandbox. |
| Storage | Persist domain records and event replay with explicit durability and retention limits. |

Provider-specific sandbox configuration may require provider-specific translation, but the authorized scope and enforcement contract must remain explicit. An adapter must not expand permissions to make an operation succeed.

The implementation is Elixir and Go: Elixir owns lifecycle and state; Go owns the native integration responsibilities. Python was removed one bounded, runnable slice at a time and is no longer part of Runtime build, execution or tests; no Rust is introduced. A language rewrite is not a substitute for establishing the boundary first.

### 5. Entry points: how callers reach Runtime

The CLI and Atlas Server-facing transport translate requests into the same application operations and expose their results. They should not each implement a worker manager, provider-selection policy or interaction lifecycle.

Transport-specific parsing and presentation remain at the edge. A truncated status summary must not substitute for full output or a structured handoff record.

## Current implementation versus this target

The current layout groups both execution paths by responsibility without treating their different contracts as interchangeable:

```text
beam/apps/atlas_runtime/lib/atlas_runtime/
  application.ex
  entrypoints/socket.ex
  execution/{service,command_admissions,backend_policy,identity,engine,turn,settings,faults}.ex
  interactions/{commands,native_question,question_records,peer_question_records,guidance,output}.ex
  handoffs/{commands,handoff_records}.ex
  persistence/{history,execution_events}.ex
  workspaces/workspace.ex
  host/native.ex
  providers/{agent,input,native_events,claude,fake_inbox,stub}.ex
  integrations/atlas_server/{talk,output_endpoint,broker,commands}.ex

tools/runtime/
  go.mod
  main.go
  host/{host,protocol,codex,claude,claude_questions}.go and their tests
  workspace/{workspace,workspace_test}.go
```

Existing public Elixir module names remain stable where their contracts remain valid. The standalone `AtlasRuntime.Service` is still the serialized execution owner, and `AtlasRuntime.Agent.Native` still owns its port, process monitoring and cancellation. Their source locations no longer imply that socket framing, workspace validation, provider interpretation and every durable operation belong inside those two modules.

Dependencies and responsibilities:

- The Go CLI sends commands through `Entrypoints.Socket` to `Service`. Socket framing, connection ownership and response-before-shutdown remain at the edge.
- `Service` selects backends and admits, starts and stops executions. Interaction commands own question admission, native delivery and peer correlation; handoff commands own declaration submission and inspection. Neither operation module calls back into `Service`.
- `Persistence.History` owns recovery, saved-turn ownership checks, historical projections, output reads and ordered terminal checkpoints. Record modules retain their bounded storage, outboxes and publication rules. Persistence does not dispatch commands.
- `Workspaces` calls the launching executable's Go workspace command directly. Admission no longer depends on the native provider host for path, scope or repository-request validation.
- The native host delegates pending-question validation, timers and delivery evidence to `Interactions.NativeQuestion`, and native identity/output/result interpretation to `Providers.NativeEvents`. `Agent.Native` writes Claude's `answer.txt` from each forwarded string result before terminal notification; a failed write fails the turn. Codex still writes its answer natively. `Providers.Codex` reads Codex model evidence from this invocation's native rollout records, using the launch time, workspace and Codex home the native host reports for its child. The lookup runs on the host's non-stopped process-end record, so identity is recorded before terminal completion. The host clears question controls on terminal provider state; provider interpretation does not own cancellation.
- `Agent.Native` spawns every native execution through the launching executable's internal `atlas-runtime native-host` (Go package `tools/runtime/host`). Python is no longer part of Runtime execution. The host receives positional arguments and speaks stdout records, stop/answer control and `Native runner:` diagnostics. It owns the process group, control transport, JSONL framing, sandbox arguments and settings, Claude private temp, pre-exec workspace preparation, scope and saved-context checks, directory-lock lifetime, cleanup and launch metadata. In its single event loop, each native record goes through the Claude question transport first and provider session/model confirmation second, and is forwarded only after both. Refusals therefore never reach Elixir. Answers from Elixir are handled in the same loop and written to native stdin under the existing 1 MiB bound and 3 s stall deadline. The host calls the `workspace` package in process, including cwd/Git identity discovery. It removes Claude's private temp and only then releases the lock, after the group is reaped.
- The Go CLI imports the dependency-free local `workspace` package. That package does not import the CLI or choose a provider.

`Engine`, `Turn`, engine settings and test-environment fault injection belong to execution lifecycle, not a `connected/` mode bucket. `Guidance` owns exact-attempt queued-input reconciliation; `Output` owns bounded ephemeral public-output retention, not durable history. They live under `interactions/`. The existing provider and proof adapters live beside the `Agent` contract in `providers/`.

Only actual Atlas communication remains under `integrations/atlas_server/`: State read/fact transport (`Talk`), the address-validated Bus/BFF output endpoint, the Atlas command broker, and Atlas-only command setup. `Commands` owns Atlas prompts, help discovery, bridge configuration and the confined command environment/wrapper/profile previously embedded in the Claude adapter. The adapter retains Claude argv, event interpretation and process lifecycle, consumes that setup, and has no forwarding copies of the extracted helpers. The command setup uses the broker and never calls the provider; the output endpoint reads the independent output buffer.

These execution paths remain distinct. `Engine` reconciles ownership and leases through Atlas facts and starts `Turn`; standalone `Service` admits explicitly requested native executions and stores its own history. Grouping them by responsibility does not add a shared workflow engine, unify queued guidance with native questions, or enable either protocol on the other adapter. Existing module APIs for unchanged responsibilities remain stable. Standalone startup still requires neither Atlas Server nor Flow.

## Implemented workspace boundary

Workspace preparation, identity discovery and ownership live in `tools/runtime/workspace/workspace.go`, exposed through internal `atlas-runtime workspace` operations. The package owns canonical-path and repository-request validation, exclusive repository locking, clone/fetch/fresh-branch preparation and continuation preservation. Both Claude and Codex use the same workspace implementation.

The launching CLI passes its own executable path to the daemon through `ATLAS_RUNTIME_EXECUTABLE`; workspace calls never discover a different installed binary or compile code during execution. Elixir invokes the Go command directly for admission queries, and the native host links the same package.

Preparation accepts the existing scope/repository records, creation flag and explicit sandbox command prefix. Go owns Git arguments and validation, not provider selection or sandbox translation. It returns the prepared record, including fetched base SHA, or refuses without resetting, stashing or overwriting work. Git subprocesses inherit the existing execution process group.

The workspace package's `Context` returns canonical `cwd` and either `git: null` for a plain directory or the repository root, full symbolic branch (detached HEAD uses its revision), and ordered origin URLs. Broken Git metadata and inspection failures refuse rather than becoming a plain-directory identity. Discovery is read-only and does not acquire or release ownership. The native host's Claude provider calls it in process, adds the unchanged permission scope, compares the saved context and writes the same `claude-context.json` before native execution. The internal `workspace` CLI exposes only the `path`, `scope` and `request` queries Elixir admission uses; preparation, context and locking run in process inside `native-host`.

The workspace and native-host Go translations are complete; Runtime execution no longer uses Python. Lifecycle and durable state stay in Elixir.

The shared provider capability and interaction contract remains a separate architectural goal. Claude-only question admission is still explicit, and Codex question support is not part of this extraction. Execution identity, permission checks, error handling, delivery evidence and durable records retain their existing contracts. The proposed Code service contract above remains future work, not an implemented service or dependency.

## Authorized macOS Claude TLS allowance

Claude dedicated-repository settings allow only `com.apple.trustd.agent` through `sandbox.network.allowMachLookup` on macOS. This fixes the observed native `gh` certificate-validation failure without disabling TLS verification or the sandbox. Other platforms receive no Mach lookup allowance.

The allowance applies to every sandboxed command, not only `gh`. Access to the host trust service permits service-mediated networking, so effective isolation is weaker than a strict GitHub-only network boundary. The existing allowed domains, filesystem restrictions, fail-closed setting and prohibition on unsandboxed commands remain unchanged. This is one explicitly authorized allowance, not permission for adapters to widen scope automatically.

## Explicit non-goals

- Orchestration or LLM-interpreted workflow authority inside Runtime.
- Automatic assignment, merge, release or retry of uncertain side effects.
- Additional permission expansion beyond the explicitly authorized TLS allowance, new providers or a generic plugin framework.
- Claims of exactly-once provider execution or automatic crash restoration.
- Treating coordinator-routed peer records as authenticated native peer delivery.
- Treating stored declarations as independently verified results.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
