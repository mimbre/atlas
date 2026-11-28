# Atlas

Atlas is an agent platform on the BEAM. Work moves through a central Bus. Agents and coordinators do the work, and a person (the operator) makes the decisions. The design goal is that no coordinator or agent can stay stuck.

Why Atlas exists, and the principles it never breaks: [docs/vision.md](docs/vision.md).

Control clients keep the existing settings/Fly tunnel behavior by default. Explicit
`ATLAS_CONTROL_ENDPOINT=tls://<full-node-name>.tail8263c4.ts.net:<port>` selects verified
TLS without fallback; invalid/empty selection or certificate failures refuse access.
Optional server ingress is disabled by default and unverified on live Fly. See the
[activation prerequisites and rollback](docs/guides/prod.md#optional-control-tls-ingress-not-activated)
before considering it; this does not change Bus or Runtime transport.

The BEAM side runs the system. rela describes it. Entities, schemas, flows and the organisation are written in the model (`products/software_factory/model/contract`), which generates rela's description. The BEAM code names no entity.

## Main parts

- **Bus**: carries work between the layers. It is not the only way they talk: per [ADR 0006](docs/adr/0006-system-structure.md), co-located systems call each other's boundary target, never each other's internals, and remote clients call a backend.
- **Facts**: stores facts in rela. Connectors to outside systems sit at its edge.
- **Flow**: moves each open fact on, following a flow definition, and says what its owner should do.
- **Control**: serves clients pages and forms, described by the backend contract. It is not the only interface for clients: they call the Runtime's backend directly.
- **Runtime**: runs agent workers and their executions on a machine.
- **Code**: holds the repositories. It gives Runtime snapshots and takes back changes.
- **Clients**: the terminal Console (TUI), the agents' command line and a read-only Runtime viewer. Clients render what Control or the Runtime's backend sends. They know no entity.

## Repository layout

| Path | What |
|---|---|
| `platform/atlas_*/` | The platform's parts, one application per layer (`atlas_bus`, `atlas_facts`, `atlas_flow`, `atlas_control`, `atlas_gates`, `atlas_runtime`, `atlas_code`, `atlas_learn`), apps of the umbrella in `products/software_factory/`. |
| `platform/atlas_control/backend/` | Control's contract: the generator, the contract itself, and the generated targets. See [platform/atlas_control/backend/README.md](platform/atlas_control/backend/README.md). |
| `platform/atlas_facts/rela/` | How Facts runs rela: its scripts and their tests. See [platform/atlas_facts/rela/README.md](platform/atlas_facts/rela/README.md). |
| `platform/atlas_runtime/host/` | The Runtime CLI in Go ([platform/atlas_runtime/host/README.md](platform/atlas_runtime/host/README.md)). |
| `platform/atlas_runtime/viewer/` | The Runtime viewer ([its README](platform/atlas_runtime/viewer/README.md)). |
| `platform/clients/` | The Console (`tui/`), the agents' command line (`agent/`), the Apple clients (`apple/`) and the optional verified TLS socket transport shared only by the Control CLI and TUI clients (`platform/clients/transport/`). |
| `platform/ops/` | Images and deploy scripts for the hosted environments, and supporting tools (CI's tested-tree record in `ci/`, `plan/`, `orchestrator/`, `tests/`). |
| `products/software_factory/` | The software factory: the umbrella that builds the release (`mix.exs`, `config/`, `integration/`), the model (`model/`, below), the settings per environment (`environments/`) and the end-to-end test (`products/software_factory/e2e/`). |
| `products/software_factory/model/` | The model, one intent folder: `generator/` (the Rela DSL), `contract/` (Atlas's domain written in the Rela DSL, by module and concept: kinds, relations, subflows and gates) and `targets/`, the files generated from it (`targets/rela/`: rela's description of every entity Atlas knows, see `platform/atlas_facts/rela/README.md`; `targets/{atlas,diagrams,proof,test}/`). |
| `bin/atlas` | The `atlas` command, Control's client: the Console, the commands on facts during a turn, and provisioning. `atlas help` lists them. |
| `bin/atlas-ops` | The `atlas-ops` command: operating an environment (status, logs, restart, the tunnel, data moves, install). |
| `bin/atlas-dev` | Development and test tooling, run from the checkout and never installed. |
| `bin/generate` | Writes every generated target from its contract, with the pinned toolchain. |
| `bin/check` | Runs what CI's Linux jobs run (`.github/workflows/ci.yml`), tests included, offline: green here is green in CI. |
| `skills/` | Instructions for the agent roles that work on Atlas. |
| `docs/` | Architecture, guides, contracts and decisions. |

## Develop

You need Erlang and Elixir at the versions in `.tool-versions`, and Go for the Runtime CLI. CI pins the same Elixir patch (1.18.6) so its formatter agrees with local worktrees; install the listed Elixir build before checking or committing. The end-to-end test also needs tmux, `python3` and `curl`.

Generated targets (the model's Rela project and diagrams, Control's `blocks.json` and Swift package, the Runtime's and Code's JSON) are build output: they are not kept in git and nothing compares them. `bin/generate` writes them all from this checkout's contracts, `bin/generate model atlas` only those; run it after a fresh clone and after changing a contract or the model. The model's needs the pinned rela, which it installs into `${XDG_CACHE_HOME:-~/.cache}/atlas/rela-<version>` when missing. A deploy, `atlas-ops restart`, `bin/atlas-dev` and `bin/check` run it themselves.

`bin/check` runs every Linux job of CI here, in about 7 minutes on the Mac mini, offline: run it before handing work over (`bin/check beam` for one job, `bin/check --fast` for the static checks only). It needs what an agent's sandbox cannot install: the pinned rela in `~/.cache/atlas`, `rg`, and the Python packages of `platform/atlas_facts/rela/scripts/requirements.txt`; it says which is missing.

Credo's locked dependencies are isolated from the applications. From the repository root:

```sh
(cd tools/credo && mix deps.get)
python3 tools/credo/check.py all
python3 tools/credo/check.py staged
```

`all` reports all Credo findings in the **index**, including the existing baseline; it
exits 1 if there are any. `staged` is the Git-agent commit check: it compares the complete
indexed snapshot with HEAD and exits 1 for newly reported findings, 0 if none, and 2 on
tool or source parsing errors. It ignores unstaged changes. Both use Credo's default
checks at all priorities, on tracked `.ex` and `.exs` files under `platform/` and
`products/`, excluding `tmp`, `deps`, `_build`, `generated` and hidden directories.
Untracked files and generated/dependency output are not analyzed. No hook is installed
by this tooling; Git-agent hook setup must invoke the `staged` command separately.

The baseline is HEAD, not a list of suppressed rules. For unchanged source lines the
gate maps staged line numbers back to HEAD before comparing reported fields and
preserving duplicate counts. For cyclomatic complexity and struct field count only, a
matched finding may report a lower value; higher values still fail. A changed line, or a
finding without a line in a changed file, is treated as new. Repeated identical lines
can map ambiguously, and a genuinely new finding indistinguishable from a baseline
finding at the mapped location cannot be
distinguished. Both snapshots are analyzed in full so cross-file checks have context;
this costs more than checking changed files alone. Test the integration with
`python3 -m unittest tools/credo/test_check.py` after fetching dependencies.

```sh
bin/generate                                               # every generated target
cd products/software_factory && mix test                   # the BEAM layers
go -C platform/atlas_runtime/host test ./...               # the Runtime CLI
cd platform/clients/tui && mix test                        # the Console
cd platform/clients/agent && mix test                      # the agents' command line
cd platform/atlas_control/backend/generator && mix test        # the contract generator
cd products/software_factory/model/generator && mix test   # the Rela DSL
cd products/software_factory/e2e && mix test               # the atlas launcher's own rules
bin/atlas-dev e2e --env test                               # the end-to-end test, on a private instance
node --test platform/ops/ci/tested-tree.test.mjs           # CI's tested-tree record (Node 18+)
```

### Shared Control fixtures

For offline client presentation work, run the read-only JSON-lines Control endpoint from
the repository root (Elixir/Mix and the Control dependencies are required):

```sh
(cd platform/atlas_control && MIX_ENV=test mix deps.get)
python3 tools/control-fixtures/server.py --scenario decision --port 4747
python3 -m unittest discover -s tools/control-fixtures -p 'test_server.py'
```

The launcher forces Mix's `test` environment and does not start Control or other Atlas
applications; it does not read the caller's production environment configuration.

Choose `decision`, `scene`, `todo`, `lists`, or `empty`; the selected scenario is the
initial page, and the fixture tabs link the other examples. Connect either client to
`127.0.0.1:4747` in the `test` environment. A Console-surface hello receives Control's
actual Console action projection; a native hello receives the same unprojected content.
The fixture implements hello, boot, open and refresh only. It explicitly rejects unknown
pages and operations, including submits: the visible examples do not write any data and
are not a substitute for real-server or mutation verification. Stop it with Ctrl-C.

Four commands, each with its own purpose:

- `atlas`: Control's client. The Console (`atlas tui`), the agents' commands on facts, and provisioning (`atlas help`).
- `atlas-ops`: operating an environment: its processes, logs, tunnel and data.
- `bin/atlas-dev`: development and test tooling, from the checkout.
- `atlas-runtime`: the Runtime CLI ([platform/atlas_runtime/host/README.md](platform/atlas_runtime/host/README.md)).

They work on prod by default. Pass `--env test` to work on test. Scripts, tests and agents must always pass `--env test` or a private `ATLAS_ENV_FILE`.

```sh
atlas tui --env test           # open the Console on test
atlas-ops status --env test    # what runs, and which build
```

## Read more

- [docs/runtime-architecture.md](docs/runtime-architecture.md): Runtime and Code, their boundaries and contracts.
- [docs/guides/development.md](docs/guides/development.md): the rules the tests enforce, and how the end-to-end test works.
- [docs/guides/agent-cli.md](docs/guides/agent-cli.md): driving Atlas from an agent on the command line.
- [docs/guides/rela.md](docs/guides/rela.md): ask rela first (D-0100): Atlas builds nothing beside rela; which rela it runs and how to ask it what it offers.
- [docs/guides/](docs/guides/): the environments and how to try each use case.
- [docs/contracts/](docs/contracts/): the interfaces between components.
- [docs/adr/](docs/adr/): decisions, one short record each.

An issue is built by an agent on its supervisor's Runtime, reviewed by a second agent, fixed once when the review asks for changes, and opened as a pull request its supervisor merges.
A use case is broken down into issues the same way, and a scene into use cases: whoever picks it up and hands it to a machinery has one agent on their Runtime propose what goes under it in a file of its result; Flow makes them under it, and "Accept it" goes to that supervisor, who accepts them or answers "Not accepted" with a note: Flow then deletes what the agent proposed (what was added by hand stays), and a new round's agent reads the note.
A scene too vague to design use cases from, or a use case too vague to break down, is not guessed at: its agent writes its questions instead, Flow puts them on it, "Answer its questions" goes to its producer, and their answer starts a fresh pass that reads the questions, the answers and the item as it is then. An item's producer (`produced_by`) is the person who supervised the run that made it, set by Flow, also for the issues a review's follow-ups make. A scene, use case or issue made by hand records who made it, in the create itself: the person at the TUI, or the person the agent that creates it assists, never what a form says. A create that would record none, such as one by an agent that assists nobody, is refused. A scene's **Accept** goes to its producer. Only an item from before producers were recorded has none, and it goes to the configured decider ([docs/guides/uc-atlas-23.md](docs/guides/uc-atlas-23.md), [docs/guides/uc-atlas-24.md](docs/guides/uc-atlas-24.md)).
A use case's design is written the same way: whoever picks it up has one agent on their Runtime write the design to a file of its result; Flow puts it in the use case's Design part, and "Accept its design" goes to that supervisor, whose Accept lets the use case be broken down.
