# S6 shared parity tables

S6 moves the Runtime's remaining decisions from the Go helper into Elixir (plan `s6-plan.md`). Each decision has one shared table here, in `<decision>/*.json`. Both sides assert it:

- The **Go** test runs the legacy Go decision against the table.
- The **Elixir** test runs the new module against the same table.

Both sides read the tables through one harness, which has two halves:

- Go: `host/internal/s6fixture`
- Elixir: `test/support/s6_fixture.ex` (`AtlasRuntime.S6Fixture`)

The two halves build the same tree and refuse a bad spec with the same text. The self-test in `_self/` checks this.

## Table

```json
{"version": 1, "rows": [ROW, ...]}
```

Both loaders refuse the table if:

- a top-level field other than `version` or `rows` is present;
- `version` is not 1;
- a row has a field not listed below;
- an `id` is missing, does not match `^[A-Za-z0-9][A-Za-z0-9_.-]*$`, or appears twice.

Go also refuses a row field of the wrong type (for example `env` not string to string, or `detail_has_path` not a bool); the Elixir loader checks only the conditions above.

The id rule keeps `t.Run` and ExUnit test names unchanged. H6 counts those names.

## Row (B2)

| Field | Meaning |
|---|---|
| `id` | Unique in the table. Go uses it as the `t.Run` name, Elixir in the test name. |
| `fs` | The tree to build under a fresh temporary root (see below). Optional; the default is an empty tree. |
| `env` | Environment for the decision, as string to string. Placeholders are allowed. |
| `input` | The decision's input. Placeholders are allowed. |
| `expect` | The decision's result, with placeholders. A refusal is `{"error": "<exact text>"}`, compared byte for byte (B3). The author writes it once from Go (`ATLAS_S6_WRITE=1 go test …`), then checks it in and has it reviewed. It is never regenerated from Elixir. |
| `elixir` | `"skip:<reason>"` marks a legacy-only row: Go still asserts it, Elixir skips it. Used for review-packet (B9) and for rows S5c removed (B14). |
| `change` | Marks the one kind of row where the legacy result and the new result differ on purpose, for example `"B8c"`. |
| `detail_has_path` | `true` when the refusal text contains a Runtime path (F14, RQ8). |
| `note` | Free text for reviewers. |

## Placeholders

| Placeholder | Path (`DefaultPlaces(root)` / `default_places(root)`) |
|---|---|
| `{tmp}` | the row's canonical temporary root: `$TMPDIR/s6-<12 hex>` with symlinks resolved, on both sides (`NewRoot` / `new_root!`). Its length does not depend on the row id or test name. |
| `{home}` | `{tmp}/home`, the Runtime home |
| `{user}` | `{tmp}/user`, the user's home |
| `{temporary}` | `{tmp}/temporary`, the private temp |

**Substitute** replaces every `{name}` in string values. Object keys, numbers, booleans, null and unknown placeholders are left as they are.

**Abstract** is the inverse, applied to results. A concrete placeholder path becomes `{name}` only when it stands alone as a path: the byte before it is not a name byte or `/`, and the byte after it is not a name byte. Name bytes are `A-Z a-z 0-9 . _ -`. When several paths match, the longest wins, so `{tmp}/home/x` abstracts to `{home}/x`, while `{tmp}/homework` stays `{tmp}/homework`.

## `fs` spec

`fs` is a list of entries, built in order. Every field is a string.

| `type` | Fields | Creates |
|---|---|---|
| `dir` | `mode` (default `0755`) | A directory. Several entries for the same directory are allowed: an implicit parent, a `git` entry and one explicit `dir` entry. Directory modes are applied last, children before parents, so `0500` works. |
| `file` | `mode` (default `0644`), `content` (default empty) | A regular file. |
| `symlink` | `target` (required) | A symlink. The target is written verbatim after substitution, so a relative target stays relative. Dangling targets are allowed. |
| `hardlink` | `target` (required) | A second name for an existing regular file inside the root. The target is reached through real directories only. |
| `socket` | `mode` (default `0755`) | A bound and closed Unix socket file. The budget is relative to the root: `len(root) + 1 + len(rel)` ≤ 103 bytes, where `rel` is the substituted path relative to `{tmp}` (`{home}/backend.sock` is `home/backend.sock`). |
| `git` | `head` (default `develop`) | A `.git` stub in the `path` directory, creating the directory if needed. The stub is `HEAD` (`ref: refs/heads/<head>`), a minimal `config`, and the directories `objects/`, `refs/heads/` and `refs/tags/`. `git rev-parse` accepts it. Later entries may add files inside it, for example `objects/info/alternates`. |

**Paths:**

- `path` is substituted, then made relative to the root.
- It may be relative or absolute. An absolute path must be inside `{tmp}`.
- It is refused if it is empty, is the root itself, or has an empty, `.` or `..` component.
- Missing parent directories are created with mode `0755`.
- The builder never follows a symlink while it builds. A parent that is not a real directory is refused.

**Modes** are exactly `0` followed by three octal digits. They are set with `chmod`, so the umask does not change them.

**Refusals** are `fs[<index>]: <text>`. The same texts and the same check order apply on both sides. `_self/expect.json` lists every refusal text.

## Self-test (`_self/`)

- `rows.json` holds the self-test rows.
- `expect.json` maps each row id to one of:
  - `{"listing": [ITEM, ...]}`;
  - `{"error": text}`;
  - `{"input": ...}`, the round trip of Substitute and then Abstract, added when the row has an `input`.

An `ITEM` is `{path, type, mode, target, nlink, size, sha256}`:

- `path` is relative to the root. Items are sorted by `path` in byte order.
- `type` is one of `dir`, `file`, `symlink`, `socket`, `other`.
- `mode` is null for a symlink.
- `target` is set for a symlink only, and is abstracted.
- `nlink`, `size` and `sha256` are set for a regular file only.

**Go** (`TestS6FixtureSelfTest`) compares each row with `expect.json`. With `ATLAS_S6_WRITE=1`, Go rewrites `expect.json`.

**Elixir** (`test/sandbox/fixture_self_test.exs`) compares each row with the same file. Since only Go writes the file, a match on both sides shows that both builders made byte-identical trees.

## Facts (B4)

The helper reports raw facts with `atlas-runtime workspace facts KIND [ARGUMENT]...`. It prints one JSON value and decides nothing.

**Go side:**

- Each kind is a file `host/workspace/facts_<kind>.go`.
- It calls `workspace.Register(kind, func(args []string, stdin io.Reader) (any, error))` from `init()`.

**Elixir side:**

- `AtlasRuntime.Sandbox.Facts.fetch(kind, args, input \\ nil)` runs the command named by `ATLAS_RUNTIME_EXECUTABLE`.
- It writes `input` to stdin as JSON. When `input` is nil, stdin is empty.
- It returns the decoded JSON.
- It raises the helper's stderr text when the helper exits non-zero, for example `unknown facts kind: nope`.

Name lists, such as credential paths or home names, go in through `input`, never as Go constants.

The kind `s6-echo` exists only in a binary built with `-tags s6facts`. It is used by `test/sandbox/facts_test.exs`.
