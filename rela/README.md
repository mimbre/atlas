# Versioned description

`schema.yaml` selects native rela 26.11.2 includes. Foundation owns actors,
Assignments and turns; optional foundation audit owns requests/steps; software
factory owns Issue/PR and compatibility fields; module `eyra` owns Scene/Use Case and
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
`atlas.json` remains the single extension consumed by State. It is generated from
`compositions/atlas-eyra/sources.json`; edit a listed module/composition fragment,
then run the assembler with the pinned rela CLI installed:

```sh
"$ATLAS_CONFIG_PYTHON" rela/scripts/assemble.py
"$ATLAS_CONFIG_PYTHON" rela/scripts/assemble.py --check
```

Each map leaf has one author (even identical duplicates fail). Whole arrays have
one owner. The bounded assembler rejects unknown annotation keys, schema structural
overrides, dangling fields/relations/types, ambiguous parents, overlapping flows
and shortcut collisions. It calls pinned rela validation and the actual generic
`AtlasState.Flows.check`, without starting an application. Optional `--actors file`
checks an inventory obtained through Control, shaped `{kind: [keys]}`; actor facts
are never shipped as configuration. Actor existence is also reconciled by Flow.

`atlas.manifest.json` records every selected schema/JSON input and generated output
hash. CI checks freshness; startup/images check the packaged hashes without needing
Elixir or PyYAML in the core image. Packaging copies the same closure and generated
extension, never work facts. Fly delivery checks both image labels/provenance and
rela's copied schema before client smoke, with each app's own token. This is an
internal consistency check within the existing merge-driven promotion route.

`tests/profiles.py` creates disposable foundation-only and incident compositions.
They are dependency proofs, not installed workflows. Foundation omits audit/software/
`eyra`; incident reuses foundation/audit/factory and selects independent person service
resolution, with no Scene, Use Case or accepted_by. Its e2e uses private stores,
Control, a GitHub stand-in and Runtime stub only. Existing populated `eyra` stores
cannot switch to these fixtures; fits must continue refusing stranded data.
