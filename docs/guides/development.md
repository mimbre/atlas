# Development

How to build and run the tests: see the Develop section of the [README](../../README.md).

## Rules the tests check

- Layers talk only over the Bus: no layer depends on, calls or names another (`beam/apps/atlas_bus/test/boundary_test.exs`).
- Nothing on the BEAM side, in the TUI or in the agents' command line names an entity; entities live in the model (`model/contract`) and the description it generates (`rela/`) only (same test).
- The generated files match the contract, and none is left over (`mix atlas.gen --check` in `bff/contract`).
- The generator holds none of Atlas's values and compiles without the contract; its targets read only `__schema__/0`.

## The end-to-end test

`bin/atlas-dev e2e` starts a private test instance of its own: the pinned rela with a fresh, empty dataset on free ports, and the core, through `ATLAS_ENV_FILE` and `--env test`. It never touches `env/test.json`'s or `env/prod.json`'s instance, and refuses `--env prod`. Then it opens two real TUIs in tmux, drives them with keys and reads their screens. `e2e/scenarios/` holds only the flows that must never break; everything else is covered by unit and feature tests. `bin/atlas-dev e2e --env test <scenario>` runs one scenario.

It needs no setup beyond Elixir, tmux, `python3` and `curl`. On its first run it installs the pinned rela (version and checksum in `rela/scripts/start-test.sh`) into `~/.cache/atlas/rela-<version>` (`$XDG_CACHE_HOME/atlas` when set), and, unless `python3` already has `rela/scripts/requirements.txt`, a private Python for rela's scripts into `~/.cache/atlas/python`; later runs reuse both. Settings you give win: `ATLAS_E2E_RELA_BIN` names a folder with rela's binaries (installed there when missing), and `ATLAS_CONFIG_PYTHON` (or a `.venv-config` at the root) names the Python. A bare `cd e2e && mix atlas.e2e` does none of this setup.

A step fails when TUI 1 takes longer than 1 second after the key to show its stored change, or TUI 2 to show it by hint. The 5-second reconcile is a fallback, not the path. On a failure both screens, the logs and the error go to `e2e/artifacts/` (an artifact in CI). CI runs it on every pull request and on develop and master. A new use case adds its scenario in the same pull request as its code.
