# Driving Atlas from an agent

Agents use the same Control as the TUI, from the command line: `atlas help`, `put`, `set`, `delete`, `get`, `list`. Nothing writes rela directly. The same rules, refusals and generated codes apply, and an open TUI shows each change at once. `atlas help` (or `atlas put --help`) lists the kinds, what a create asks, how ids are made, what a kind belongs under and its fields, all from rela's description. Every command takes `--json` and then prints one JSON value: the item, the list, or `{"refused": [...]}`. The exit status is 0 when done, 1 when refused (the reasons also go to stderr) and 2 on an error. Like `atlas`, it works on prod unless given `--env test`.

```sh
atlas put use_case --in SC-Atlas-05 --title "Read items from the command line" --description-file uc.md --env test --json
atlas set IS-Atlas-33 stage=development --env test --json
atlas set IS-Atlas-33 stage=design --cause "the design is not settled" --env test --json   # why, kept with it
atlas put pull_request --url https://github.com/mimbre/atlas/pull/14 --in IS-Atlas-33 --env test --json
```

`--in <code>` names the parent, `--<field>-file <path>` or `--<field> -` (stdin) reads text of several lines, and `atlas get <code>` and `atlas list <kind> [--in <code>]` read.

An agent that plans gets the same actions as tools: `atlas tools` lists them, made from rela's description through Control. `atlas plan --on <code> "<request>"` asks the environment's planner (`agent.planner` in `env/<env>.json`: a local `claude -p` that may only read, or any command) what it would do on that page. It answers steps, each checked against the form it would fill, and writes nothing ([uc-atlas-16.md](uc-atlas-16.md)). In the TUI, `:` asks the same agent (`atlas steer`, which the TUI starts) about the page you are on; you keep, edit or drop each step, and the kept ones run through Control ([uc-atlas-17.md](uc-atlas-17.md)).

`atlas load-plan <SCENES.md> tools/plan/links.json [--dry-run]` loads a plan from a SCENES.md file the same way. It never changes an existing item, and when a code is taken it maps it to the next one.
