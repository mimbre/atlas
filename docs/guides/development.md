# Development

How to build and run the tests: see the Develop section of the [README](../../README.md).

The umbrella (`products/software_factory`) runs every app's tests with `mix test`. To run single test files of one app, run `mix test test/<file>` from that app's folder (`platform/atlas_<part>`; its `mix.exs` uses the umbrella's config and `_build`). `mix test ../../platform/<app>/test/<file>` from `products/software_factory` runs the file under another app: Mix matches umbrella file arguments only under `apps/`.

## Rules the tests check

- Layers talk only over the Bus: no layer depends on, calls or names another (`platform/atlas_bus/test/boundary_test.exs`).
- Nothing on the BEAM side, in the TUI or in the agents' command line names an entity; entities live in the model (`products/software_factory/model`) and the description it generates (`products/software_factory/targets/rela/`) only (same test).
- The generated files match the contract, and none is left over (`mix atlas.gen --check` in `platform/atlas_control/bff/contract`).
- The generator holds none of Atlas's values and compiles without the contract; its targets read only `__schema__/0`.

## The end-to-end test

`bin/atlas-dev e2e` starts a private test instance of its own: the pinned rela with a fresh, empty dataset on free ports, and the core, through `ATLAS_ENV_FILE` and `--env test`. It never touches `products/software_factory/environments/test.json`'s or `products/software_factory/environments/prod.json`'s instance, and refuses `--env prod`. Then it opens two real TUIs in tmux, drives them with keys and reads their screens. `products/software_factory/e2e/scenarios/` holds only the flows that must never break; everything else is covered by unit and feature tests. `bin/atlas-dev e2e --env test <scenario>` runs one scenario.

It needs no setup beyond Elixir, tmux, `python3` and `curl`. On its first run it installs the pinned rela (version and checksum in `platform/atlas_facts/rela/scripts/start-test.sh`) into `~/.cache/atlas/rela-<version>` (`$XDG_CACHE_HOME/atlas` when set), and, unless `python3` already has `platform/atlas_facts/rela/scripts/requirements.txt`, a private Python for rela's scripts into `~/.cache/atlas/python`; later runs reuse both. Settings you give win: `ATLAS_E2E_RELA_BIN` (else `ATLAS_RELA_BIN`, else a `rela-bin` folder beside the checkout that holds `rela-server-headless-sqlite`) names a folder with rela's binaries (installed there when missing), and `ATLAS_CONFIG_PYTHON` (or a `.venv-config` at the root) names the Python. `cd products/software_factory/e2e && mix test`, `platform/atlas_facts/rela/tests` and the umbrella's rela tests look for rela in the same order. A bare `cd products/software_factory/e2e && mix atlas.e2e` does none of this setup.

### In a sandboxed worker

The tests run in a worker's sandbox as they do outside it, with nothing to set:

- **CA certificates.** `:httpc` needs a CA store even for `http`. Where the system's (the Keychain) is unreadable, `AtlasFacts.Trust` loads the bundle at `SSL_CERT_FILE`, else `/etc/ssl/cert.pem`; Facts does it when it starts, e2e and `platform/ops/plan` too.
- **Temp folders.** Every `mktemp` names its folder under `${TMPDIR:-/tmp}`; macOS's plain `mktemp` ignores `TMPDIR`.
- **Git.** Tests that run git give it a configuration of their own (`GIT_CONFIG_GLOBAL`, `GIT_CONFIG_NOSYSTEM`, no `init.templateDir`), and keep their repositories under the system temp folder, never in the checkout.
- **rela's processes.** `platform/atlas_facts/rela/scripts/stop.sh` and `status.sh` find rela by the pid file `start-bg.sh` writes, and signal only that pid, after checking it is the one listening on rela's port; nothing lists processes.
- **tmux panes.** `bin/atlas-dev e2e` puts its tmux socket in `TMPDIR`. A tmux pane needs a pseudo-terminal (`/dev/ptmx`), which a Claude `materialized-folder` worker's sandbox allows (`allowPty`, macOS only; see `platform/atlas_runtime/host/README.md`). So the two TUIs of `bin/atlas-dev e2e`, and in `cd products/software_factory/e2e && mix test` `page_freshness_test.exs` and `python_discovery_test.exs` (through `AtlasE2E.Tui.server/1`), run in such a worker once the installed Runtime has that change. Other sandboxes, a Codex worker's for one, still deny `/dev/ptmx`; there these tests run only outside the sandbox, and in CI.

A step fails when TUI 1 takes longer than 1 second after the key to show its stored change, or TUI 2 to show it by hint. The 5-second reconcile is a fallback, not the path. On a failure both screens, the logs and the error go to `products/software_factory/e2e/artifacts/` (an artifact in CI). CI runs it on every pull request and on develop and master. A new use case adds its scenario in the same pull request as its code.

Atlas pins three Rela 26.11.3 executables: `rela-server-headless-sqlite`, generic `rela` for schema generation/validation, and `rela-sqlite` for exporting a private coherent SQLite backup. The installer checks archive and executable hashes on Darwin arm64/Linux amd64 and never extracts either UI-server variant. SQLite compatibility/count checks need native `sqlite3` (the macOS system tool, or Linux's `sqlite3` package); legacy stores need neither SQLite tool. Backup/export/validation failures stop startup before the stored description is replaced. See `platform/atlas_facts/rela/README.md` for the shared snapshot path. PID/log filenames stay `rela-server.pid` and `rela-server.log`.
