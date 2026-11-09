# Versioned description

`schema.yaml` selects native rela 26.11.2 includes. Foundation owns actors,
Assignments and turns; optional foundation audit owns requests/steps; module
`software` owns Issue/PR and compatibility fields; module `eyra` owns Scene/Use Case and
hierarchy/acceptance. The composition owns the complete `assignment` relation.
Includes are relative to the selected schema root, including nested includes.
Every definition has one owner; no overrides or property augmentation.

Operational scripts require Python 3.9+ and PyYAML. In a virtual environment:

```sh
python3 -m venv ~/.local/share/atlas/config-python
~/.local/share/atlas/config-python/bin/pip install -r rela/scripts/requirements.txt
export ATLAS_CONFIG_PYTHON="$HOME/.local/share/atlas/config-python/bin/python"
```

For ordinary `atlas` commands, an executable `.venv-config/bin/python` at the
repository root is discovered automatically when `ATLAS_CONFIG_PYTHON` is unset.
Create it from the repository root with `python3 -m venv .venv-config`, then run
`.venv-config/bin/pip install -r rela/scripts/requirements.txt`. No activation is
needed. An explicit override takes precedence; otherwise the existing `python3`
fallback remains for CI and Fly. Direct scripts can still use the override above.

CI installs the pinned requirement; the rela image uses Debian's `python3-yaml`.
Startup copies the selected closure, comparison checks every included byte, and
fits scans a private data copy against the resolved description. Old included
files may remain on disk, but only the selected closure is loaded. Data folders
are never part of packaging. Fly preflight uses a resolved flat equivalent so it
also works against the previous deployed image, which has no Python. The new
image starts rela with native includes. No data migration is needed.

Run `python3 -m unittest discover -s rela/tests -v`, pinned `rela --project rela
validate`, and private e2e before delivery. `tests/fixtures/baseline-schema.yaml`
is the delivered #79 schema: tests lock definitions and property/form order.

**Generated from the model.** Every file here but `data-entry.yaml` (rela-server's
setting), the scripts and the tests is written by `mix model.gen` from the model in
`model/contract` (Rela DSL design, slice 2): `schema.yaml`, `modules/**/schema.yaml`,
`compositions/atlas-eyra/bindings.yaml`, `acl.yaml`, `atlas.json`, `flow-runtime.json`,
`flows.yaml` and `atlas.manifest.json`. Do not edit them: change the concept, module
or composition that declares the definition and regenerate (CI runs `--check`):

```sh
cd model/contract && mix model.gen           # write rela/ and model/targets/
cd model/contract && mix model.gen --check   # fail on a stale, missing or left-over file
```

A file under `modules/` or `compositions/` that the model does not write is left over:
the task removes it, and `--check` fails on it. The model's checks are those the
assembler had, now at compile time of the composition: each `atlas.json` leaf has one
author (even identical duplicates fail), no key without a construct, no dangling
fields, relations, types or values, no ambiguous parents, overlapping flows or shortcut
collisions, and every legacy flow is sound. With `ATLAS_RELA_BIN` set, the task also has
the pinned rela validate the generated description with the generated `flows.yaml`.
Actor existence is reconciled by Flow.

The schema YAML keeps the one style of slice 0, which the writer now holds: two-space
block maps and block lists (`- ` at the key's indent), no anchors or aliases, a plain
scalar where that is safe and a single-quoted one otherwise, never folded across lines,
multi-line text as a `|` block, no blank lines. The order is the concept order: a
module's file holds its concepts' types, then their entities, then their relations, in
the order the module lists the concepts; properties keep their form order. `atlas.json`
is written with sorted keys, so its bytes depend only on what the model says.

`flows.yaml` holds the subflows; `acl.yaml` the roles the flows name, so rela can check
them. Rela defines and checks the flows; Atlas Flow runs them (D-0068). Neither file is
part of the selected closure, so startup never copies them into a running rela's data
(which runs without an `acl.yaml`, and would refuse flows that name roles). The core
image holds `rela/flows.yaml` for Flow (`fly/core.Dockerfile`); the rela image does not.
`flow-runtime.json` maps the durable runs; its migrations come from the `migrate`
declarations beside each subflow, which `model/targets/proof/digests.json` proves.

`atlas.manifest.json` records the hash of every file of the selected closure and of
`data-entry.yaml`, of `atlas.json` (`output_sha256`) and of `flows.yaml` (`flows`). CI
checks freshness; startup/images check the packaged hashes without needing Elixir or
PyYAML in the core image (`scripts/verify.py`). Packaging copies the same closure and
generated extension, never work facts. Fly delivery checks both image labels/provenance
and rela's copied schema before client smoke, with each app's own token. This is an
internal consistency check within the existing merge-driven promotion route.

The private foundation-only and incident compositions are profiles of the model
(`model/contract/profiles`, compiled with `MIX_ENV=test` only); the e2e writes one with
`mix model.gen --contract Model.Profiles.Foundation --out DIR`. They are dependency
proofs, not installed workflows. Foundation omits audit/software/`eyra`; incident reuses
foundation/audit/software and selects independent person service resolution, with no
Scene, Use Case or accepted_by. Its e2e uses private stores, Control, a GitHub stand-in
and Runtime stub only. Existing populated `eyra` stores cannot switch to these fixtures;
fits must continue refusing stranded data.
