# S6 spec tables (§12 move 2: sandbox settings and tool lists)

Package A2g owns every row here (plan `s6-plan.md`, R5). A2e adds the Elixir side and **no** rows; a missing row is an A2g follow-up. C0, C0d and C0c add rows later (`check`, Runtime-chosen `base`/`from_work`, the base store).

The row format, placeholders and `fs` spec are those of `../README.md`. This file adds what the spec rows need.

## Tables

| File | Go test | Elixir (A2e) |
|---|---|---|
| `codex.json` | `TestS6RenderParity` | `Sandbox.Spec.build/…` must produce `expect.spec` |
| `claude.json` | `TestS6RenderParity` | same |
| `codex_sandbox.json` | `TestS6RenderParity` | `Sandbox.Spec.codex_sandbox(:setup \| :pre_exec, …)` |
| `runtime_home.json` | `TestS6RenderParity` | the `runtime_home` rows (row 2a, N1) |
| `preconditions.json` | `TestS6RenderPreconditions` | none: every row is `"elixir": "skip:helper-precondition"` |

Row ids are unique across all five files; each is one `t.Run` subtest. `TestS6RenderParity` is `host/host/s6_render_parity_test.go`.

## What the Go test asserts per row

For a decision row (`codex`, `claude`, `codex_sandbox`, `runtime_home`):

1. The **legacy** Go decision runs on the built tree: `permissionArguments` / `sandboxArguments`, `claudeRepositorySettings` / `claudeFolderSettings` / `claudePacketSettings` / `claudeReadOnlySettings` with `claudeCommand`, `setupArguments` with the command assembly of `prepare.go:107-166`, and the managed-repository prefix of `host.go:697-709`. The denied home is `deniedRuntimeHome` as `run()` calls it.
2. An **instrumented builder** in the test (never in production code) reads the legacy entry lists into a spec: it calls the same `repositoryRuntimeEntries`, `runtimeEntries`, `socketEntries`, `deniedEntries`, `homeReadable` helpers and keeps their order and duplicates. For Claude, the spec's `settings` are the legacy settings JSON, decoded.
3. `render.go` renders the row's **checked-in** `expect.spec` (decoded strictly with `DecodeSpec`).

It asserts: builder == `expect.spec`, legacy == `expect.rendered`, render == `expect.rendered`. When the legacy decision itself refuses (no spec), `expect` is `{"error": text}` and the builder must refuse with the same text.

A row where legacy and render differ **on purpose** carries `change` and keeps both: `expect.legacy` (today) and `expect.rendered` (the renderer). There are two kinds:

- `home.folder-scope-other`, `change: "B8c"` (N1): legacy denies the scope's own home (`host.go:644-646`); render refuses a home other than the helper's own.
- `codex.plain-workspace-write-below-home`, `change: "B8b"`: legacy `sandboxArguments` grants a write to a plain workspace below the home (`codex.go:102-104`); render refuses a `client_named` write inside the home (B8 (b)).
- (no `change`, since the fixed P0) the managed rows `codex.managed-p0-absent`, `codex.managed-p0-present`, `codex.managed-worker-all-characters`, `codex.managed-worker-one-character`, `codex.managed-home-glob-metacharacters`, `pre_exec.claude-managed` and `pre_exec.codex-absent`: the managed repository's spec denies the atomic temps (`atomicHomeTemps`, the `.tmp` siblings of the denied home files). The fixed P0 lists them at the end of `sensitiveHomeNames`, so legacy renders them too. The builder still adds any it lacks (`withAtomicTemps`) right after the last `sensitiveHomeNames` entry, so if one leaves the legacy list these rows go red instead of freezing the gap.

**Legacy refusal texts without a row**, each deliberately left out:

- `Runtime home must be an absolute path` (`codex.go:113`) cannot be reached from an agent decision on this tree. `deniedRuntimeHome` resolves the home of a dedicated or plain turn (a relative `ATLAS_RUNTIME_HOME` is refused first, `home.env-relative`). The folder builders never call `runtimeEntries`, and legacy accepts a relative folder-scope home unchecked. The spec decoder refuses a relative `runtime_home` (`pre.decode-relative-home`).
- `Preparation requires npm on PATH` (`prepare.go`) is the setup runner's tool lookup, not a spec decision. `npm` is in the setup step's argv, which A6's plan decides. A setup spec without `npm` on `PATH` still renders, so that row would be a divergence with no decision behind it.

## `expect` shapes

| Shape | Meaning |
|---|---|
| `{"error": text}` | the decision refuses; there is no spec |
| `{"spec": S, "rendered": {"codex": [argv]}}` | a Codex agent's permission arguments |
| `{"spec": S, "rendered": {"claude": {"args": [argv], "settings": text}}}` | Claude's tool and permission flags (from `--tools` up to the session, model or goal) and its `--settings` value |
| `{"spec": S, "rendered": {"codex_sandbox": [argv]}}` | the full `codex sandbox -P … -C dir … -- argv` command |
| `{"spec": S, "rendered": {"error": text}}` | the spec exists and rendering refuses it (B8, or a path that is both write and none) |
| `{"spec": S, "legacy": …, "rendered": …}` | only with `change` |

## Row `input`

| Field | Used by | Meaning |
|---|---|---|
| `decision` | all | `agent` or `codex_sandbox` |
| `harness` | agent | `codex` or `claude` |
| `scope` | all but plain | the permission scope as the Runtime passes it (absent for a plain `sandbox`) |
| `sandbox`, `workspace` | plain | `read-only` / `workspace-write` and the turn's workspace |
| `folder` | Codex folder | the turn folder; the scratch is `<scope home>/scratch/<basename>` |
| `inspector` | folder | the Runtime executable workers run |
| `questions` | Claude | questions enabled; the question session id itself is not part of the spec (row 3a, C3) |
| `origin` | all | `runtime_chosen` or `client_named` (B13): the start form decides it, not the path |
| `platform` | Claude | `darwin` or `linux` (`allowMachLookup`) |
| `temporary_bytes` | Claude | the length of `{temporary}/claude-<uid>`, default 40 (the 44-byte rule, `claude.go:477`) |
| `temporary` | Claude | defaults to `{temporary}` |
| `code_json` | any | written as `{home}/code.json` (JSON) after substitution; an `fs` file's content is not substituted |
| `create_markers` | folder | `rebind` and/or `preparation`: the harness creates `snapshot.RebindMarker` / `PreparationResult` of the scope |
| `kind` | codex_sandbox | `setup` or `pre_exec` (`check` comes with C0) |
| `step`, `script`, `writable`, `scratch`, `dir`, `argv` | setup | `npm-ci` (network) or `npm-run`; the outputs; the preparation scratch; the run directory; the npm argv (A6 decides it) |
| `workspace`, `dir`, `argv` | pre_exec | the managed repository; `argv` is empty (the prefix ends with `--`) |

Precondition rows have `render` (`codex`, `claude`, `codex_sandbox`), a hand-written `spec`, `launch` (`dest`, `scratch`, `temporary`), and for `codex_sandbox` `dir` and `argv`; or `decode` (raw text for `DecodeSpec`).

## Defaults the harness applies before the row's `env`

- **Environment:** `HOME={user}`, `ATLAS_RUNTIME_HOME={home}`, `PATH={tmp}/bin`, `TMPDIR={tmp}/systmp`, `CODEX_HOME=""`, `CLAUDE_CONFIG_DIR=""`. An empty value means unset.
- **Directories:** `{home}`, `{user}`, `{tmp}/bin` and `{tmp}/systmp` exist.
- **Root:** the row's root is outside every system temp root (Claude refuses projects inside one), and canonical.
- **`{temporary}`:** a short path `/t…t` **outside** the root, sized by `temporary_bytes`. It stands for the private temp the helper creates in `temporary.parent` (`makeTemporary`, random name); it is never created.

## Extra tokens (spec rows only)

Beside `{tmp} {home} {user} {temporary}`:

| Token | Stands for |
|---|---|
| `{/tmp}`, `{/var/tmp}` | `/tmp` and `/var/tmp` resolved (`/private/tmp` on macOS). They appear only as whole values (in `denyWrite`). |
| `{sha256:<path>}` | the lowercase sha256 hex of the substituted `<path>`: the rebind and preparation directories of a folder |
| `(/{name}` | in a Claude rule `Tool(//path)`, the placeholder after `(/`. `Abstract` leaves a path after `/` alone, so the test abstracts this form itself. |

`$TEMPORARY` is **not** a table token. It is part of the spec: the spec is decided before the helper creates the private temp, so spec paths name it `$TEMPORARY` (`render.TemporaryToken`) and the renderer substitutes the created path.

## The spec (B7), as `render.go` decodes it

`{version: 1, harness, runner?, kind?, runtime_home, home_names?, codex? | claude?, env, scratch, temporary?, workspace}`. Decoding refuses unknown fields at every level, a second JSON value, and invalid values (texts in `preconditions.json`).

- `codex`: `{profile, base (":read-only" | ":workspace"), entries: [[path, read|write|none]] in decision order (duplicates kept; the first occurrence wins), network: {mode: none|loopback|domains, domains, unix_sockets, local_binding}, network_proxy, web_search ("" | live | disabled)}`.
- `claude`: `{tools, allowed_tools, permission_mode (dontAsk | manual), settings: the claudeSettings object ({permissions} only for a plain read-only turn)}`.
- `env`: `{set: [[name, value]] in order, unset, prefix_path, mkdirs}`. It is read from `host.go:278, 287-301` and is **not rendered** until C2. A setup run's environment is A6's plan (`preparationKept`), so its `env` only unsets `ATLAS_RUNTIME_HOME`.
- `home_names`: the names denied one by one when the home contains the workspace (the managed repository: `sensitiveHomeNames`, which ends with the atomic temps; a Claude read-only workspace in the home: the two sockets, `claude.go:483-486`).
- `workspace`: `{root, origin}`.

## B8 preconditions (`render.go`, `checkSpec`)

In this order, before anything is rendered:

- **(c)** `runtime_home` must equal the helper's own home: `ATLAS_RUNTIME_HOME` (absolute, resolved) or `$HOME/.local/state/atlas-runtime` resolved → `Runtime spec denies another home`.
- **(a)** the home is denied whole (Codex: its first entry is `none`; Claude with a Bash sandbox: in the sandbox's `denyRead`; Claude without one, the plain read-only form: a `Read(//home)` rule), or the home contains `workspace.root` and every `home_names` entry is denied → `Runtime spec does not deny the Runtime home`.
- **(b)** a write inside the home is only this turn's own scratch (`spec.scratch == launch.scratch`) or, for `origin: runtime_chosen` with `root == launch.dest`, inside the root → `Runtime spec writes inside the Runtime home`.
- **(d)** a `codex-sandbox` spec needs `codex` on `PATH` (absolute for `setup`; `pre_exec` keeps today's acceptance of a relative entry): today's texts `Preparation requires the installed Codex sandbox (codex on PATH)` and `Managed repository preparation requires the installed Codex sandbox`. There is no fallback.
