# Try UC-Atlas-35: The BFF contract says which pages and endpoints Control serves

What you can do: read in one file every page Control serves and every call a client can make, and see an old client told it is too old instead of breaking (IS-Atlas-70, IS-Atlas-71, IS-Atlas-72; ADR 0002).

## Try

| Step | Where | What you should see |
|---|---|---|
| The pages | `bff/targets/json/blocks.json`, `"pages"` | Every page Control serves, by name and path with its parameters: `/`, `/_kinds`, `/k/:kind`, `/k/:kind/new`, `/k/:kind/:key`, `…/edit`, `…/delete`, `…/links/:relation`, … No kind is named; kind is a parameter. |
| The endpoints | the same file, `"endpoints"` | Every call: each page's `open`; the form submits (`create`, `update`, `delete`, `link`, `accept`, `reopen`, …), each with what it takes (`values`) and its replies (`stored`, `refused`); `hello` (replies `welcome` or `bye`), `refresh`, what Control sends unasked (`page` by hint, `notice`, `bye`), and the agent's `ask`, `run`, `cancel`, `stop`. |
| A page Control does not serve | `atlas get` a made-up path, or a link to one | "No such page". The TUI does not even ask for a destination that is no page. |
| The TUI | `atlas tui --env test`: create (`c`), update (`u`), delete (`d`) | As before. A form's `submit_to` now names its endpoint and params (`{"endpoint": "update", "params": {"kind": …, "key": …}}`), and the TUI sends them as they are. |
| An old client | a TUI built before this contract, against Control after it | It is told: `This client implements contract 0.10.0; Control test speaks 0.11.0. It is too old: update it (atlas starts the newest build).` It shows that and closes, without breaking. |

## What changed for this

- **The contract** (`bff/contract/lib/contract.ex`, composing the existing 0.14.0 contract): `pages.ex` declares pages, `endpoints.ex` declares other calls, and `models/presentation.ex` declares session payloads (`hello`, `welcome`, `bye`, `notice`, `ask`, `run`) and the `call` used by `submit_to`/`confirm_to`.
- **The generator**: `defpage` and `defendpoint`, the rules of paths (`AtlasBFF.Paths`), a map type (`{:map, :string}`); the targets give `pages`, `match`, `path`, `endpoints`, `endpoint`.
- **Control** serves exactly the contract's pages, takes submits only at its submit endpoints, and checks the version in each hello.
- **The end-to-end test**: `e2e/scenarios/uc-atlas-35.exs` follows this guide.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
