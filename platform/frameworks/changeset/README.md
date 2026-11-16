# platform/frameworks/changeset

`AtlasChangeset` (Mix app `atlas_changeset`) is the neutral change-set library (D42): the
shape of a change set, its canonical form and its `csf_` fingerprint. No system owns it, and
it holds no system's vocabulary. It has no dependencies, starts no process and works on plain
data (maps with atom or string keys).

```elixir
AtlasChangeset.validate(change_set)              # :ok | {:error, [message]}
AtlasChangeset.canonical(base, root, entries)    # canonical JSON of one root (binary)
AtlasChangeset.fingerprint(base, root, entries)  # "csf_" <> 64 lowercase hex
AtlasChangeset.fingerprints(change_set)          # [%{root, fingerprint}], in root order
AtlasChangeset.verify_blob(entry, enumerable)    # :ok | {:error, :size | :sha256}, streaming
```

## Shape

`%{base, roots: [%{root, entries}]}`. `root` is one top-level folder; `path` is relative to it.

- write: `%{path, op: "write", kind: "file" | "symlink", mode: "100644" | "100755" | "120000", size, sha256, target}`;
  `target` for a symlink only, and `120000` exactly for a symlink;
- delete: `%{path, op: "delete"}`, nothing else.

A `nil` value counts as absent, and a struct's `__struct__` is ignored. A path is refused when
it is empty, starts with `/`, has an empty, `.` or `..` segment, or contains a NUL.

## Canonical form and fingerprint

The fingerprint of a root is the sha256 of the canonical JSON of `{base, entries, root}`:
UTF-8, compact, keys in byte order, entries sorted by `path` in byte order, integers in
decimal. A delete is `{op, path}`, a write `{kind, mode, op, path, sha256, size}` plus
`target` for a symlink. In strings, `"` → `\"`, `\` → `\\`, U+0000–U+001F → `\u00xx`
(lowercase hex); every other code point is literal UTF-8 (`/`, U+2028 and U+2029 too).
The encoder is the library's own, never a general JSON encoder.

`priv/fixtures/canonical.json` pins it: each case has `base`, `root`, `entries` (in input
order), the exact `canonical` bytes and the `fingerprint`. The canonical strings were typed by
hand and hashed with `printf '%s' <canonical> | shasum -a 256`, not produced by this library.
Another implementation checks itself against the same file:
`Application.app_dir(:atlas_changeset, "priv/fixtures/canonical.json")`.

## Checks

```sh
MIX_ENV=test mix deps.get --check-locked && mix compile --warnings-as-errors \
  && mix format --check-formatted && MIX_ENV=test mix test --warnings-as-errors
```

CI job `frameworks-changeset` also fails when `lib`, `test` or `mix.exs` names a system.
