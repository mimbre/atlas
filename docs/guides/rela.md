# Ask rela first

**D-0100: Atlas uses rela's own mechanisms; it builds nothing next to them.** Before you propose or build anything that stores, syncs, schedules or queries data, ask rela what it offers and use that. Atlas builds no connector, sync, scheduler or store of its own beside rela; what rela lacks becomes a request to the rela project, not a workaround in Atlas.

This guide lists none of rela's features on purpose: they change with every release. Ask rela itself, at the moment you need it.

## Which rela

Atlas runs rela 26.11.9, pinned (version and checksums) in `platform/atlas_facts/rela/scripts/start-test.sh`. Install that binary into a folder outside the checkout with

```sh
ATLAS_RELA_BIN="${TMPDIR:-/tmp}/rela-26.11.9" platform/atlas_facts/rela/scripts/start-test.sh install
```

and check it with `"${TMPDIR:-/tmp}/rela-26.11.9/rela" version` (`rela version 26.11.9`). Another `rela` on your `PATH` may be another version: ask the pinned one.

## How to ask it

- `rela --help`: every command it has.
- `rela <command> --help`, for example `rela scheduler --help` or `rela remote pull --help`: what one command does and takes.
- `rela mcp`: its MCP server, where your agent can use MCP; run it with `--project` set to a rela project, such as `products/software_factory/model/targets/rela`.

rela's own documentation for that version is in its repository at the release tag: <https://github.com/sourcehaven-bv/rela/tree/v26.11.9/docs>.
