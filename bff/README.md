# Control's BFF

Native shell metadata is an ordinary typed endpoint: see
[native shell boot](../docs/adr/0004-native-shell-boot.md) (IS-Atlas-119).

Control is a spec-driven backend for frontend (architecture, section 14). The spec says which blocks Control sends and every client renders. Clients know blocks, never entities: what a block shows comes from rela's description through Control.

mica-bff (`~/projects/nova/mica-bff`) was the inspiration for the format. Atlas shares no code, catalogue or package with it (d-0009).

## Generator, contract, targets

The BFF is in three parts, as in prism (ADR [0001](../docs/adr/0001-generator-contract-targets.md)):

| Part | Where | What |
|---|---|---|
| Generator | `bff/generator/` (Mix app `atlas_bff`) | The DSL (`AtlasBFF.Schema`: `version`, `defblock`, `defmodel`, `defmarkup`, `defpage`, `defendpoint`, `defoperation`, `field`) and its compile-time checks; markup/page rules; targets and `mix atlas.gen`. No Atlas values: it is tested independently on neutral contracts. |
| Contract | `bff/contract/` (Mix app `atlas_bff_contract`) | `lib/contract.ex`, `AtlasBFFContract.Contract`, composes presentation declarations, payload models and explicit Control/Runtime wire APIs. Edit the owning declaration file, not generated output. |
| Targets | see below | What the contract becomes, for each consumer. |

A contract compiles to one function, `__schema__/0`: plain data, documented in `AtlasBFF.Schema`. Every target reads only that (a test refuses a target that calls into the DSL).

| Target | Kind | Gives |
|---|---|---|
| `AtlasBFF.Targets.Server` | compile time | `AtlasControl.Blocks` (`use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract`): a builder macro per block, model and kind of markup, and `view_model/2`. |
| `AtlasBFF.Targets.Client` | compile time | `AtlasTui.Blocks`: a struct per block, model and kind of markup, `decode/1` with a fallback, and `view_model/1`. |
| `AtlasBFF.Targets.Json` | file | `bff/targets/json/blocks.json`, the contract as data for clients in other languages. Never edit it. |

Control and the TUI depend on the contract by path, and read it when they compile: changing the contract recompiles them, and no Elixir code is generated into files. A Swift package for iOS will be a file target under `bff/targets/swift/`.

A block in the contract:

```elixir
defblock :form do
  field :title, :string, required: true
  field :inputs, {:list, :input}, required: true
  field :submit_label, :string, required: true
  field :submit_to, :string, required: true
  field :cancel_to, :string
  field :errors, {:list, :string}
end
```

Types are `:string`, `:integer`, `:boolean`, a model (`defmodel`), or `{:list, type}`. A mistake fails the build and points at its line:

- in the contract: an unknown type, a name or field defined twice, a block that holds a block, a field that holds markup, a name that is not snake_case, an option other than `required:`, a missing `version`;
- in Control's code: a builder call (`Blocks.form(title: ..., ...)`) that leaves out a required prop or names one the block does not have. The builders are macros, so a caller writes `require AtlasControl.Blocks, as: Blocks`. A wrong value, or a required prop that is `nil` at run time, raises when the block is built.

Change the contract, run `cd bff/contract && mix atlas.gen`, commit the contract and `bff/targets/`. CI runs `mix atlas.gen --check`, which fails on a file that would change and on a generated file no target writes any more. Every generated file starts with a header that says so and names the contract file; `mix atlas.gen` never overwrites a file without it. Then check the TUI still knows every block and kind of markup (`AtlasTui.View.known/0`; its tests fail otherwise).

The DSL is plain macros, not Spark: a contract of a few blocks, models and kinds of markup needs only entries, typed fields and a handful of checks, and plain macros keep it without a dependency.

### Source ownership

- `lib/contract.ex`: root composition and existing presentation version.
- `lib/blocks.ex`: blocks and markup only; `lib/pages.ex` and `lib/endpoints.ex`: page paths and endpoint declarations.
- `lib/models/{runtime,workers,presentation}.ex`: shared payload types. These describe transmitted values, not Rela's stored entities and relationships.
- `lib/wire/control/{session,discovery,workers}.ex`: client–Server session/steer vocabulary, exact-machine discovery and worker operations.
- `lib/wire/runtime.ex`: Runtime worker/machine/attachment control and Server–Runtime output reads. The existing on-wire `channel` strings do not change with source ownership.

Declare each wire operation with `defoperation :name, descriptor`. Use `protocol_from(ContractModule)` to import an already compiled wire contract and `models_from(ContractModule)` for shared models. Blocks, pages and endpoints use ordinary Elixir declaration fragments; the root validates their combined references. There is still one generator and one root JSON target. Individual generated codecs keep their original operation subsets; a worker codec does not accept arbitrary session commands.

This source split preserves wire versions, generated data and declaration order. Only the generated provenance header names the new root file.

Direct declarations report their file and line. Imported wire/model contracts and presentation fragments report the importing call site, with the invalid operation, field or declaration named in the error.

## View model (contract 0.14.0)

Control sends a view model, not a data model: its **content**, a flat list of blocks, and its **markup**, entries that cover a stretch of those blocks. Every block has an id, stable for as long as the page shows the same thing; markup points at ids, never at positions, so inserting, deleting or moving a block (or a hint that changes one) never shifts other markup.

### Blocks

| Block | Shows | The user can |
|---|---|---|
| `list` | rows, an empty text, actions; a title, unless a section carries it | move, open a row, run an action, open the selected row's link |
| `item` | a title and labelled values | run an action (change, delete), open a link |
| `form` | a title, inputs (text, multiline, choice, boolean, readonly), errors | fill it in, submit or cancel; a long text wraps; a multiline input takes several lines (enter starts a new line); a readonly input is shown, never changed |
| `confirm` | a question, or without `confirm_to` only why something cannot be done | confirm or go back |
| `plan` | what an agent proposes for a request, and then does: the request, who planned, what it says, its steps; a `title` that says how far it is; `before`, what became of the previous plan after a refusal | keep, edit or drop each proposed step, run the kept ones, cancel, stop a run |

Models that blocks hold: `action` (label, key, to), `link` (label, key, url), `row` (id, label, detail, to, links), `pair`, `input`, `choice`, `step` (n, label: the title of the form it fills, state, why, detail, inputs: that form's inputs with the step's values). No block holds another block; grouping is markup.

A row starts with its id, in a column of its own (IS-Atlas-57): a client lines the ids of a list up, as wide as the longest, then the labels, then the details. The detail does not repeat the id.

An action opens a page of Control's (`to`), except one whose `to` is `agent:<intent>`: that one asks the agent about the page it is on, as `:` does, with that intent (`x Overrule` on a step the agent took: `agent:overrule`). The description adds such actions per kind (`actions` in `rela/atlas.json`). A link opens a web address outside the client, in a browser (`url`); an `item` has links, and so does a `row`, for while it is selected. A client opens only http and https addresses. Control gives a fact a link when the description marks the type of one of its fields as a web address (`types.<name>.format: "url"` in `rela/atlas.json`).

On the wire a block is `{"id": "item", "type": "list", "props": {...}}`. An optional prop without a value is left out. A client ignores unknown keys, and shows an unknown or broken block as a fallback while the rest of the page still renders.

### Markup

Markup says what a stretch of blocks means, never how it looks. Each client turns meaning into layout as suits its screen: the TUI draws boxes and columns, a phone may show one part after the other or behind a tab. Ask of every new kind: does it name a meaning, or an appearance? (Contract 0.7.0 replaced the appearance kinds `border` and `columns` with `part`, IS-Atlas-66.)

| Kind | Props | Means | The TUI draws |
|---|---|---|---|
| `part` | `title`, `role` (`main`, `related`, `todo`) | a top-level division of a view: `main` is the item itself, `related` what it links to, `todo` what its owner is to do (only for the owner, first; IS-Atlas-54). Parts do not nest in parts; sections nest in parts | a box with its title. Two or more parts over a whole page: side by side from 120 columns, else one above the other with the related part given room first; each with its own room and scrolling, tab moves the focus between them |
| `section` | `title`, `collapsible` | a titled stretch | a heading with a rule, above its blocks |
| `highlight` | `tone` (info, ok, error, pending) | the blocks in a tone | not yet: its blocks show as they are |

On the wire an entry is `{"kind": "section", "start": "<block id>", "end": "<block id>", "props": {...}}`, covering `start` to `end`, both included, with `"group"` on the pieces of split markup.

All markup nests, of every kind, as in XML: two entries share no block, or one covers all of the other. Entries over the same stretch nest in list order, the first outermost. So a view model's markup is one well-formed tree, which a client renders top down. Markup that would cross (a highlight over the end of one section and the start of the next) is placed as pieces that each nest and share a group id. The rules, as functions with tests, are `AtlasBFF.Markup` in the generator (`bff/generator/lib/atlas_bff/markup.ex`):

- `check/2`: refuses crossing markup, an unknown block id, an end before its start, an id used twice. Control's `Blocks.view_model/2` raises on it, so Control never sends bad markup; a client leaves out markup that fails it and shows the blocks flat.
- `tree/2`: the tree a client renders.
- `delete/3`: a deleted boundary block moves the boundary to its neighbour inside the stretch; an entry left empty is dropped.
- `move/4`: a moved block keeps an entry only while it stays inside the stretch, and joins those it lands inside; markup of the block alone moves with it.
- `place/3`: adds an entry, split into grouped pieces where it would cross.

An item page is in two parts (IS-Atlas-48, IS-Atlas-66), and for its owner a third one first, `todo` titled "What to do" (IS-Atlas-54): a `part` with role `main` titled "Content" over the item (later also what is said about it, such as comments) and a `part` with role `related` titled "References" over its related lists and the facts it points at, each list in a `section` carrying its title (a scene: the scene in Content; its "Use cases" in References; a use case also lists "In scene" there, to open its scene from). The rows of all lists on a page are one selection.

The names (view model, markup) live in one place: `AtlasBFF.Names`, plus the `defmarkup` macro and the module name `AtlasBFF.Markup`.

## Protocol

JSON, one message per line, over TCP to the environment's Control address in `env/<env>.json`.

Client to Control:

| Message | Meaning |
|---|---|
| `{"op":"hello","env":"test","client":"tui","spec":"0.14.0"}` | First message, with the contract version the client implements; an agent may add `"as"`: the key of the fact it is (`coordinator`), so it is the owner of what is assigned to it (IS-Atlas-54; `ATLAS_AS` for `atlas`). Control of another environment answers `bye` and closes; so does Control on a newer contract than the client's (or when the client says none): `This client implements contract 0.10.0; Control test speaks 0.11.0. It is too old: …`. A newer client is welcomed: it shows what it knows, the rest as fallbacks. |
| `{"op":"open","to":"/k/<kind>/<key>"}` | Show the page at this path. |
| `{"op":"submit","endpoint":"update","params":{"kind":"issue","key":"IS-Atlas-01"},"values":{...}}` | Submit a form or a confirm: the endpoint and params its `submit_to` or `confirm_to` (a `call`) names, one of the contract's submit endpoints (create, create_under, update, delete, link, accept, reopen); values travel as text. A client that knows only paths may send `"to"` with the endpoint's path instead. Anything else is refused, unsent. |
| `{"op":"turn"}` | Read the agent's single running turn and its original item, using `runtime.turn`. |
| `{"op":"turn_end","key":"<turn>","outcome":"<text>"}` | Record the current owner's nonempty outcome; Runtime reads the fact and ends the turn. |
| `{"op":"refresh"}` | Reconcile: read the page again from Facts. Clients send it on an interval. |

Control to client:

| Message | Meaning |
|---|---|
| `{"op":"welcome","env":"test","spec":"0.14.0"}` | Answer to hello, with Control's contract version. |
| `{"op":"page","path","title","back","blocks","markup","reason","position","at"}` | A page: a view model (`blocks` and `markup`) with its path, title and `back`: the page it belongs under (its owner, or its kind's list). Console's Back (`esc`, Left, `b`) does not follow `back`: it is always declared, and a client returns to the page its user came from, in its own history (the TUI keeps the selected row and scroll of each). `reason` is `open`, `hint` (a change stored by anyone), `reconcile`, `stored` (your change) or `refused`. `position` is Facts' position the page is as of. On a page without a form, a `refused` page also has `refused`: Facts' reasons. When the client's user has a start page of assignments, every page has `count`: what waits for them, in the description's words, for the header. |
| `{"op":"notice","tone":"pending\|ok\|error\|info","text","at"}` | A line for the status bar. `pending` until Facts answers. |
| `{"op":"bye","text"}` | Control closes the connection. |
| `{"op":"turn","key":"<turn>","on":"<item>"}` | Current turn context; errors have `error` instead of the keys. An outcome is acknowledged with a stored page. |

Every message here is an endpoint of the contract (`defendpoint`, its call the message's `op`; ADR 0002), with what it takes and what it replies, and `blocks.json` lists them: hello, refresh, the pages' `open`, the submits, what Control sends unasked (`page` by hint, `notice`, `bye`), and the agent's `ask`, `run`, `cancel` and `stop`.

Paths are the contract's pages (`defpage`, ADR [0002](../docs/adr/0002-pages-and-endpoints.md)): `/`, `/_kinds`, `/k/:kind`, `/k/:kind/new`, `/k/:kind/new/:relation/:parent`, `/k/:kind/:key` and its `/edit`, `/delete`, `/links/:relation`, `/set/:relation`, `/answer/:answer`, `/remove/:relation`; in the test environment only, the failure pages `/faults`, `/k/:kind/:key/faults`, `/fault/:fault` and `/k/:kind/:key/fault/:fault` (IS-Atlas-23: what can be made to fail there, and the confirm that causes it). Control serves those and nothing else (a path outside them gets "No such page"); `blocks.json` lists them, and the targets give every Elixir consumer `pages/0`, `match/1` and `path/2` (`AtlasBFF.Paths`). A client with a screen only follows them.

A client without a screen, such as the agents' command line (`clients/agent`), knows only codes. Three paths are for such a client, and Control works out the rest from rela's description:

- `/k/_/<key>` (and `/edit`, `/delete`): the fact with that key. Its kind is the one whose id prefix the key has.
- `/k/<kind>/new/_parent/<key>`: the create form under the fact with that key, through the kind's one at-most-one relation.
- `/_kinds`: one `item` per kind, with what a create asks, how its id is made, what it belongs under, what hangs under it and its fields, and its actions as every page names them (`Create scene`, `Update scene`, `Delete scene`; `<key>` in their paths stands for a key).

The page Control answers has the concrete path, such as `/k/issue/IS-Atlas-01`.

### The agent behind `:`

A plan block comes, for now, from the agent the TUI starts (`atlas steer`), not from Control. They talk in JSON lines on its stdin and stdout: the client sends `ask` (request, the page's path), `run` (the kept steps' numbers and values), `cancel` and `stop`. The agent answers `plan` (the whole block, after every change) and `notice`. The full table is in `AtlasAgent.Steer`. The agent is a Control client of its own and writes only on `run`, only the steps it proposed. Once Runtime runs agents (SC-Atlas-02), Control sends the same block.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0015).</sub>

### Compile-time protocol payloads

`use AtlasBFF.Targets.Protocol, contract: MyContract, channel: :my_channel` exposes `version/0`,
`pages/0`, `endpoints/0`, `path/2`, `match/1` and `endpoint_path/3` from
`__schema__/0`. `payload(call, name, props)` validates an endpoint's `takes`
and returns JSON-ready string keys, including nested models, lists and maps.
Unknown fields, missing required values and wrong types raise `ArgumentError`;
optional nil values are omitted. Dynamic `:values` are maps of text inputs.

`message(call, name, props)` encodes an explicitly selected pathless endpoint.
When wire descriptors exist it checks the operation is a request on Control.
`request(name, props, channel)` constructs the declared envelope;
`classify(name, message, channel)` returns its declared reply or push,
with effect `complete`, `progress`, `error`, or `terminal`. Incoming additive fields
are tolerated; declared required envelope fields and present optional fields are
checked. The channel argument defaults to the consumer’s configured `channel:`
option (the agent selects `:control`); the target embeds no channel name. Unknown messages are skipped under the same total deadline.

`protocol [...]` supplies these plain descriptors to `__schema__/0` and the JSON
target; each endpoint's `wire:` names its descriptor (page endpoints use `open`).
The validator rejects unclassified endpoints, invalid direction/channel, missing
completion, contradictory/overlapping selectors and invalid prerequisites.
Selectors contain only literal `op`/other string discriminants and field presence
or absence, never executable predicates. Required/optional envelope fields use
primitive types, lists, objects or maps of primitives. Typed endpoint payload
models remain available through `payload/3`.

The agent keeps one outstanding request on each passive socket. Its handwritten
transport uses the descriptors for hello (welcome **then** initial page), open,
submit, turn and turn_end. All handshake stages share one 10-second deadline;
open has 10 seconds and submit/turn have 60 seconds. Notices, hints and reconciles
are progress, never acknowledgements, and cannot extend those deadlines. A bye,
malformed JSON, invalid required reply, EOF or timeout closes the connection.
Semantic turn errors preserve the existing error adapter. No write is replayed.
Sockets and caller-owned successful connections remain handwritten.

Turn_end has three actual replies: `page+stored`, `turn+error`, and `page+refused`.
A stored outcome acknowledges Facts; Runtime ending the turn and Flow handing it
over still happen independently. Owner, stale-turn and outcome validation remain
on the server. Refresh is explicitly a stream requiring an adapter: it sends no
page while editing a form. Local steer operations are also streams on their own
channel, with handwritten policy and lifecycle, and server pushes cannot be sent
as Control commands.

IS-101 keeps wire version **0.14.0**: it describes the existing server protocol and
corrects semantic metadata without changing bytes sent by Control. Existing
0.14.0 clients remain usable in either delivery order; no negotiation change or
client-before-server deployment is needed for this slice. Deployments still go
through coordinator review. A later version bump must distribute compatible
clients before advancing Control, since older versions are refused at hello.

### Worker Control contract

`contract/lib/wire/control/workers.ex` declares versioned worker inspection, exact-turn guidance,
query, history and receipt messages on the Control channel. It reuses Runtime's
execution identity; `Contract` composes the wire APIs and shared payload models. Existing
list/item/form blocks implement the worker pages, so the block wire version remains
0.14.0; typed worker messages independently require version 0.1.0.

Generate with the same `mix atlas.gen` command. Named actor grants, durable outcome
semantics, bounds, generic-page limits and the outstanding Runtime integration are
documented in [the guidance contract](../docs/contracts/guidance.md#control-worker-access-and-guidance).


<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0026).</sub>

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
