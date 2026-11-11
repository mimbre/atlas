# Atlas

Atlas is an agent platform on the BEAM. Work moves through a central Bus. Agents and coordinators do the work, and a person (the operator) makes the decisions. The design goal is that no coordinator or agent can stay stuck.

Why Atlas exists, and the principles it never breaks: [docs/vision.md](docs/vision.md).

The BEAM side runs the system. rela describes it. Entities, schemas, flows and the organisation live in rela. The BEAM code names no entity.

## Main parts

- **Bus**: the only way the layers talk to each other. A layer depends on the Bus and on nothing else.
- **State**: stores facts in rela. Connectors to outside systems sit at its edge.
- **Flow**: moves each open fact on, following a flow definition, and says what its owner should do.
- **Control**: the one interface for clients. It serves pages and forms, described by the BFF contract.
- **Runtime**: runs agent workers and their executions on a machine.
- **Code**: holds the repositories. It gives Runtime snapshots and takes back changes.
- **Clients**: the terminal Console (TUI), the agents' command line and a read-only Runtime viewer. Clients render what Control sends. They know no entity.

## Repository layout

| Path | What |
|---|---|
| `beam/` | The BEAM umbrella: one application per layer (`atlas_bus`, `atlas_state`, `atlas_flow`, `atlas_control`, `atlas_runtime`, `atlas_code`). |
| `bff/` | Control's contract: the generator, the contract itself, and the generated targets. See [bff/README.md](bff/README.md). |
| `rela/` | rela's description of every entity Atlas knows. See [rela/README.md](rela/README.md). |
| `clients/` | The Console (`tui/`), the agents' command line (`agent/`) and the Runtime viewer (`viewer/`, see [its README](clients/viewer/README.md)). |
| `env/` | One settings file per environment. |
| `fly/` | Images and deploy scripts for the hosted environments. |
| `bin/atlas` | The `atlas` command, Control's client: the Console, the commands on facts during a turn, and provisioning. `atlas help` lists them. |
| `bin/atlas-ops` | The `atlas-ops` command: operating an environment (status, logs, restart, the tunnel, data moves, install). |
| `bin/atlas-dev` | Development and test tooling, run from the checkout and never installed. |
| `e2e/` | The end-to-end test: only the flows that must never break, driving real Consoles. |
| `tools/` | Supporting tools, such as the Runtime CLI in Go ([tools/runtime/README.md](tools/runtime/README.md)). |
| `skills/` | Instructions for the agent roles that work on Atlas. |
| `docs/` | Architecture, guides, contracts and decisions. |

## Develop

You need Erlang and Elixir at the versions in `.tool-versions`, and Go for the Runtime CLI. The end-to-end test also needs tmux, `python3` and `curl`.

```sh
cd beam && mix test              # the BEAM layers
go -C tools/runtime test ./...   # the Runtime CLI
cd clients/tui && mix test       # the Console
cd clients/agent && mix test     # the agents' command line
cd bff/generator && mix test     # the contract generator
cd bff/contract && mix atlas.gen # after changing the contract: regenerate bff/targets/
cd e2e && mix test               # the atlas launcher's own rules
bin/atlas-dev e2e --env test     # the end-to-end test, on a private instance
```

Four commands, each with its own purpose:

- `atlas`: Control's client. The Console (`atlas tui`), the agents' commands on facts, and provisioning (`atlas help`).
- `atlas-ops`: operating an environment: its processes, logs, tunnel and data.
- `bin/atlas-dev`: development and test tooling, from the checkout.
- `atlas-runtime`: the Runtime CLI ([tools/runtime/README.md](tools/runtime/README.md)); `atlas-runtime node` runs this machine as a node of an environment.

They work on prod by default. Pass `--env test` to work on test. Scripts, tests and agents must always pass `--env test` or a private `ATLAS_ENV_FILE`.

```sh
atlas tui --env test           # open the Console on test
atlas-ops status --env test    # what runs, and which build
```

## Read more

- [docs/runtime-architecture.md](docs/runtime-architecture.md): Runtime and Code, their boundaries and contracts.
- [docs/guides/development.md](docs/guides/development.md): the rules the tests enforce, and how the end-to-end test works.
- [docs/guides/agent-cli.md](docs/guides/agent-cli.md): driving Atlas from an agent on the command line.
- [docs/guides/](docs/guides/): the environments and how to try each use case.
- [docs/contracts/](docs/contracts/): the interfaces between components.
- [docs/adr/](docs/adr/): decisions, one short record each.
