# Control's BFF

Native shell metadata is an ordinary typed endpoint: see
[native shell boot](../../../docs/adr/0004-native-shell-boot.md) (IS-Atlas-119).

Control is a spec-driven backend for frontend (architecture, section 14). The spec says which blocks Control sends and every client renders. Clients know blocks, never entities: what a block shows comes from the model Control is wired to (`AtlasControl.Model`, compiled from `products/software_factory/model/contract`) and the facts Facts answers.

mica-bff (`~/projects/nova/mica-bff`) was the inspiration for the format. Atlas shares no code, catalogue or package with it (d-0009).

## Generator, contract, targets

The BFF is in three parts, as in prism (ADR [0001](../../../docs/adr/0001-generator-contract-targets.md)):

| Part | Where | What |
|---|---|---|
| Generator | `platform/atlas_control/backend/generator/` (Mix app `atlas_bff`) | The DSL (`AtlasBFF.Schema`: `version`, `defblock`, `defmodel`, `defmarkup`, `defpage`, `defendpoint`, `defoperation`, `field`) and its compile-time checks; markup/page rules; targets and `mix atlas.gen`. No Atlas values: it is tested independently on neutral contracts. |
| Contract | `platform/atlas_control/backend/contract/` (Mix app `atlas_bff_contract`) | `lib/contract.ex`, `AtlasBFFContract.Contract`, composes presentation declarations, payload models and explicit Control/Runtime wire APIs. Edit the owning declaration file, not generated output. |
| Targets | see below | What the contract becomes, for each consumer. |

A contract compiles to one function, `__schema__/0`: plain data, documented in `AtlasBFF.Schema`. Every target reads only that (a test refuses a target that calls into the DSL).

| Target | Kind | Gives |
|---|---|---|
| `AtlasBFF.Targets.Server` | compile time | `AtlasControl.Blocks` (`use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract`): a builder macro per block, model and kind of markup, and `view_model/2`. |
| `AtlasBFF.Targets.Client` | compile time | `AtlasTui.Blocks`: a struct per block, model and kind of markup, `decode/1` with a fallback, and `view_model/1`. |
| `AtlasBFF.Targets.Json` | file | `platform/atlas_control/backend/targets/json/blocks.json`, the contract as data for clients in other languages. Never edit it. |
| `AtlasBFF.Targets.Swift` | file | `platform/atlas_control/backend/targets/swift/`, the Swift package `AtlasControlKit` (macOS 14 and iOS 17, Foundation only, Swift 6): a `Codable`, `Sendable`, `Equatable` type per model, block and kind of markup; `Block` and `MarkupEntry` with a `Fallback` for what it cannot show (its `Fallback.Reason` a case and a path, not text); `Page` with `path(_:)` and `match(_:)`; the messages of each channel the endpoints name (`ControlRequest`, `ControlMessage`, `SteerRequest`, `SteerMessage`), keyed on `op`, a received one `unknown` or `undecodable` rather than a throw; `Contract.version`; and its tests. Never edit it; only `Tests/Fixtures/` is kept by hand. |

Control and the TUI depend on the contract by path, and read it when they compile: changing the contract recompiles them, and no Elixir code is generated into files. Clients on Apple's platforms use the Swift package: `mix atlas.gen` writes it with `blocks.json`, and CI builds and tests it on macOS (`swift build`, `swift test`) and builds it for iOS. It holds generated code only, plus the message lines in `Tests/Fixtures/<channel>/{sent,received}.jsonl` that its tests decode and round-trip: lines a Control test session sent and received, on the neutral model of Control's tests. A transport and the apps are hand-written and live elsewhere ([Apple clients](../../../docs/design/apple-clients.md)).

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

Change the contract, run `cd platform/atlas_control/backend/contract && mix atlas.gen`, commit the contract and `platform/atlas_control/backend/targets/` (`targets: [json: "../targets/json", swift: {"../targets/swift", package: "AtlasControlKit", version_field: "spec"}]` in `platform/atlas_control/backend/contract/config/config.exs`). CI runs `mix atlas.gen --check`, which fails on a file that would change and on a generated file no target writes any more. Every generated file starts with a header that says so and names the contract file; `mix atlas.gen` never overwrites a file without it. Then check the TUI still knows every block and kind of markup (`AtlasTui.View.known/0`; its tests fail otherwise).

The DSL is plain macros, not Spark: a contract of a few blocks, models and kinds of markup needs only entries, typed fields and a handful of checks, and plain macros keep it without a dependency.

### Source ownership

- `lib/contract.ex`: root composition and existing presentation version.
- `lib/blocks.ex`: blocks only; `lib/markup.ex`: kinds of markup; `lib/pages.ex` and `lib/endpoints.ex`: page paths and endpoint declarations.
- `lib/models/{runtime,workers,presentation}.ex`: shared payload types. These describe transmitted values, not Rela's stored entities and relationships.
- `lib/wire/control/{session,discovery,workers}.ex`: client–Server session/steer vocabulary, exact-machine discovery and worker operations.
- `lib/wire/runtime.ex`: Runtime worker/machine/attachment control and Server–Runtime output reads. The existing on-wire `channel` strings do not change with source ownership.

Declare each wire operation with `defoperation :name, descriptor`. Use `protocol_from(ContractModule)` to import an already compiled wire contract and `models_from(ContractModule)` for shared models. Blocks, pages and endpoints use ordinary Elixir declaration fragments; the root validates their combined references. There is still one generator and one root JSON target. Individual generated codecs keep their original operation subsets; a worker codec does not accept arbitrary session commands.

This source split preserves wire versions, generated data and declaration order. Only the generated provenance header names the new root file.

Direct declarations report their file and line. Imported wire/model contracts and presentation fragments report the importing call site, with the invalid operation, field or declaration named in the error.

## View model (contract 0.16.0)

Control sends a view model, not a data model: its **content**, a flat list of blocks, and its **markup**, entries that cover a stretch of those blocks. Every block has an id, stable for as long as the page shows the same thing; markup points at ids, never at positions, so inserting, deleting or moving a block (or a hint that changes one) never shifts other markup.

### Blocks

| Block | Shows | The user can |
|---|---|---|
| `list` | rows, an empty text, actions; a title, unless a section carries it | move, open a row, run an action, open the selected row's link |
| `item` | a title and labelled values | run an action (change, delete), open a link |
| `form` | a title, inputs (text, multiline, choice, boolean, readonly), errors | fill it in, submit or cancel; a long text wraps; a multiline input takes several lines (enter starts a new line); a readonly input is shown, never changed |
| `confirm` | a question, or without `confirm_to` only why something cannot be done | confirm or go back |
| `plan` | what an agent proposes for a request, and then does: the request, who planned, what it says, its steps; a `title` that says how far it is; `before`, what became of the previous plan after a refusal | keep, edit or drop each proposed step, run the kept ones, cancel, stop a run |

Models that blocks hold: `action` (label, key, to), `link` (label, key, url), `row` (id, label, detail, to, links, key, pending), `pair`, `input`, `choice`, `step` (n, label: the title of the form it fills, state, why, detail, inputs: that form's inputs with the step's values). No block holds another block; grouping is markup.

A row starts with its id, in a column of its own (IS-Atlas-57): a client lines the ids of a list up, as wide as the longest, then the labels, then the details. The detail does not repeat the id.

A row also says which fact it opens: `key`, which Control takes from `to` (none for a row that opens no fact). A client uses it only as an opaque identity, to keep the selection when a page replaces the list (docs/design/page-freshness.md §3.1), and compares it with nothing a write said. `pending: true`, set only by Control, means a write to that fact is stored and Flow has not yet settled it; a client shows it beside the label (the TUI: `⋯ being processed`), never hides or reorders the row, and never sets or clears it. Control fills `key` from contract 0.15.0 on. It sets `pending` on every page it sends, from the moment Facts has stored a write of that client until Flow has settled past it, and sends a recently viewed page again, as it was (`reason: "pending"`), when its marks change.

An action opens a page of Control's (`to`), except one whose `to` is `agent:<intent>`: that one asks the agent about the page it is on, as `:` does, with that intent (`x Overrule` on a step the agent took: `agent:overrule`). The model adds such actions per kind (`action` in the Rela DSL). A link opens a web address outside the client, in a browser (`url`); an `item` has links, and so does a `row`, for while it is selected. A client opens only http and https addresses. Control gives a fact a link when the model marks the type of one of its fields as a web address (`type …, format: :url`).

On the wire a block is `{"id": "item", "type": "list", "props": {...}}`. An optional prop without a value is left out. A client ignores unknown keys, and shows an unknown or broken block as a fallback while the rest of the page still renders.

### Markup

Markup says what a stretch of blocks means, never how it looks. Each client turns meaning into layout as suits its screen: the TUI draws boxes and columns, a phone may show one part after the other or behind a tab. Ask of every new kind: does it name a meaning, or an appearance? (Contract 0.7.0 replaced the appearance kinds `border` and `columns` with `part`, IS-Atlas-66.)

| Kind | Props | Means | The TUI draws |
|---|---|---|---|
| `part` | `title`, `role` (`main`, `related`, `todo`) | a top-level division of a view: `main` is the item itself, `related` what it links to, `todo` what its owner is to do (only for the owner, first; IS-Atlas-54). Parts do not nest in parts; sections nest in parts | a box with its title. Two or more parts over a whole page: side by side from 120 columns, else one above the other with the related part given room first; each with its own room and scrolling, tab moves the focus between them |
| `section` | `title`, `collapsible` | a titled stretch; a collapsible one may be folded | a heading with a rule, above its blocks; a collapsible one is folded (its heading, marked ▸) until the page's `sections_toggle` action unfolds it (▾), and its lists' rows are out of the selection while folded |
| `highlight` | `tone` (info, ok, error, pending) | the blocks in a tone | not yet: its blocks show as they are |

On the wire an entry is `{"kind": "section", "start": "<block id>", "end": "<block id>", "props": {...}}`, covering `start` to `end`, both included, with `"group"` on the pieces of split markup.

All markup nests, of every kind, as in XML: two entries share no block, or one covers all of the other. Entries over the same stretch nest in list order, the first outermost. So a view model's markup is one well-formed tree, which a client renders top down. Markup that would cross (a highlight over the end of one section and the start of the next) is placed as pieces that each nest and share a group id. The rules, as functions with tests, are `AtlasBFF.Markup` in the generator (`platform/atlas_control/backend/generator/lib/atlas_bff/markup.ex`):

- `check/2`: refuses crossing markup, an unknown block id, an end before its start, an id used twice. Control's `Blocks.view_model/2` raises on it, so Control never sends bad markup; a client leaves out markup that fails it and shows the blocks flat.
- `tree/2`: the tree a client renders.
- `delete/3`: a deleted boundary block moves the boundary to its neighbour inside the stretch; an entry left empty is dropped.
- `move/4`: a moved block keeps an entry only while it stays inside the stretch, and joins those it lands inside; markup of the block alone moves with it.
- `place/3`: adds an entry, split into grouped pieces where it would cross.

An item page is in two parts (IS-Atlas-48, IS-Atlas-66), and for its owner a third one first, `todo` titled "What to do" (IS-Atlas-54): a `part` with role `main` titled "Content" over the item (later also what is said about it, such as comments) and a `part` with role `related` titled "References" over its related lists and the facts it points at, each list in a `section` carrying its title (a scene: the scene in Content; its "Use cases" in References; a use case also lists "In scene" there, to open its scene from). The rows of all lists on a page are one selection.

A page where its owner decides (the to-do has answers: accept what is proposed under it, merge, have a person decide) is one stretch in no parts, so no client splits it: first the block `todo`, an `item` whose title is the to-do and its answer keys in one line (`What to do: Accept its issues   Answers: a Accept`; a choice: `1–3   0 Recommended`), with the section of the fact the state names as its field when there is one; then what is judged: the choice's options (`single_choice`, block id `choice`) and the lists of the facts under it, each row its key and `label — first line of its first text of several lines`; then the item in full, its fields followed by the to-do's Why and How; then its other lists. Every list is in a `section` carrying its title.

The start page of what is assigned to the viewer (`/`) is calm; it is the shared convention for such overviews, in the vocabulary above (no block or markup of its own). An `item` `summary` titled "Overview" counts the work: `To do` always, `Late` and `Blocked` only when some are. Then the `list` (block id `list`) of calm rows: the item's key as the row's id (people and agents talk in keys; a client shows it first, in a column of its own) and a detail that says only, in this order, the review rule's label when the fact is to be reviewed, the short name of the flow its work is in (the model's `label:` of the subflow, such as Plan, while something is expected of its owner; never the sentence of what is expected, which the item's page says), whether it is blocked, and its deadline; never since when, why, or whose. A person's page (what is assigned, Open work, Open for you, Supervised by you) shows each item's key and no other technical details (runs, states): those are an agent's or a developer's, through `atlas get`. Open for you and Supervised by you follow the same rows; their Overview is titled with the model's count, which no pair repeats. On a group's page of either (one span of one flow) the group's name says the flow, so a row's detail says what the item belongs under (its parents' keys) in its place. On Supervised by you, a row that the viewer's running work is on (a task an agent runs for them) says that work, its kind and detail (such as `Task · Plan · Architect`), in place of the flow. Open work (the list of the kind the start's relation starts at) follows the same shape, with `Open` as the main count, `Unassigned` counted too when some are, and each row's detail starting with who it is with (the owner keys, or "unassigned"). The Workers list (`/workers`) follows the same shape: `Workers` as the main count, `Running` and `Needs attention` (the failed turns) only when some are; calm rows without ids; and, last, an `item` `details` titled "Technical details", a pair per worker, inside a collapsible `section` titled "Details", with the page's `sections_toggle` console action (key `d`). Clients fold a collapsible section by default.

The names (view model, markup) live in one place: `AtlasBFF.Names`, plus the `defmarkup` macro and the module name `AtlasBFF.Markup`.

## Protocol

JSON, one message per line, over TCP to the environment's Control address in `products/software_factory/environments/<env>.json`.

Client to Control:

| Message | Meaning |
|---|---|
| `{"op":"hello","env":"test","client":"tui","spec":"0.16.0"}` | First message, with the contract version the client implements; an agent may add `"as"`: the key of the fact it is (`coordinator`), so it is the owner of what is assigned to it (IS-Atlas-54; `ATLAS_AS` for `atlas`). Control of another environment answers `bye` and closes; so does Control on a newer contract than the client's (or when the client says none): `This client implements contract 0.10.0; Control test speaks 0.11.0. It is too old: …`. A newer client is welcomed: it shows what it knows, the rest as fallbacks. |
| `{"op":"open","to":"/k/<kind>/<key>"}` | Show the page at this path. |
| `{"op":"submit","endpoint":"update","params":{"kind":"issue","key":"IS-Atlas-01"},"values":{...}}` | Submit a form or a confirm: the endpoint and params its `submit_to` or `confirm_to` (a `call`) names, one of the contract's submit endpoints (create, create_under, update, delete, link, accept, reopen); values travel as text. A client that knows only paths may send `"to"` with the endpoint's path instead. Anything else is refused, unsent. |
| `{"op":"turn"}` | Read the agent's single running turn and its original item, using `runtime.turn`. |
| `{"op":"turn_end","key":"<turn>","outcome":"<text>"}` | Record the current owner's nonempty outcome; Runtime reads the fact and ends the turn. |
| `{"op":"refresh"}` | Reconcile: read the page again from Facts. Clients send it on an interval. |

Control to client:

| Message | Meaning |
|---|---|
| `{"op":"welcome","env":"test","spec":"0.16.0"}` | Answer to hello, with Control's contract version. |
| `{"op":"page","path","title","back","blocks","markup","reason","position","at"}` | A page: a view model (`blocks` and `markup`) with its path, title and `back`: the page it belongs under (its owner, or its kind's list). Console's Back (`esc`, Left, `b`) does not follow `back`: it is always declared, and a client returns to the page its user came from, in its own history (the TUI keeps the selected row and scroll of each). `reason` is `open`, `hint` (a change stored by anyone), `pending` (the same page with rows marked pending), `reconcile`, `stored` (your change) or `refused`. `position` is Facts' position the page is as of: the page's version for its path. A `hint` page is for the path on screen or for one of the paths the client viewed recently (the last 8; at most 3 are pushed per batch of changes). A client keeps the newest page per path (a page replaces the kept one unless both have a `position` and its own is lower), draws it only if its path is on screen, and on back or a tab switch shows the kept page at once while it asks for the page again (`open`). On a page without a form, a `refused` page also has `refused`: Facts' reasons. When the client's user has a start page of assignments, every page has `count`: what waits for them, in the model's words, for the header. |
| `{"op":"notice","tone":"pending\|ok\|error\|info","text","at"}` | A line for the status bar. `pending` until Facts answers. |
| `{"op":"bye","text"}` | Control closes the connection. |
| `{"op":"turn","key":"<turn>","on":"<item>"}` | Current turn context; errors have `error` instead of the keys. An outcome is acknowledged with a stored page. |

Every message here is an endpoint of the contract (`defendpoint`, its call the message's `op`; ADR 0002), with what it takes and what it replies, and `blocks.json` lists them: hello, refresh, the pages' `open`, the submits, what Control sends unasked (`page` by hint, `notice`, `bye`), the agent's `ask`, `run`, `cancel` and `stop`, and the worker pages' messages (below, [Worker Control contract](#worker-control-contract)). Unasked pages are the pushes `hint` and `pending`.

Paths are the contract's pages (`defpage`, ADR [0002](../../../docs/adr/0002-pages-and-endpoints.md)): `/`, `/_kinds`, `/_open`, `/_supervised`, `/k/:kind`, `/k/:kind/new`, `/k/:kind/new/:relation/:parent`, `/k/:kind/:key` and its `/edit`, `/delete`, `/links/:relation`, `/set/:relation`, `/answer/:answer`, `/remove/:relation`, `/pick_up/:run`, `/hand_over/:run`, `/retry/:run`, `/remove_item/:run`; in the test environment only, the failure pages `/faults`, `/k/:kind/:key/faults`, `/fault/:fault` and `/k/:kind/:key/fault/:fault` (IS-Atlas-23: what can be made to fail there, and the confirm that causes it). Control serves those and nothing else (a path outside them gets "No such page"); `blocks.json` lists them, and the targets give every Elixir consumer `pages/0`, `match/1` and `path/2` (`AtlasBFF.Paths`). A client with a screen only follows them.

A client without a screen, such as the agents' command line (`platform/clients/agent`), knows only codes. Three paths are for such a client, and Control works out the rest from the model:

- `/k/_/<key>` (and `/edit`, `/delete`): the fact with that key. Its kind is the one whose id prefix the key has.
- `/k/<kind>/new/_parent/<key>`: the create form under the fact with that key, through the kind's one at-most-one relation.
- `/_kinds`: one `item` per kind, with what a create asks, how its id is made, what it belongs under, what hangs under it and its fields, and its actions as every page names them (`Create scene`, `Update scene`, `Delete scene`; `<key>` in their paths stands for a key).

The page Control answers has the concrete path, such as `/k/issue/IS-Atlas-01`.

Supervision (contract 0.18.0; work acquisition decision 2026-11-17, §5.6–5.8), only for a model whose start page has `open_for_you` and `supervised_by_you`:

- `/_open` (Open for you): per supervised span, the facts whose work its subflow presents, active, in one of its states and without a human supervisor; calm, as `/`. It declares its groups first (a `groups` block, contract 0.19.0): All, then one per span, each with its count and its own page, `/_open/:subflow/:span`, which shows only that span's list (with the same groups, that one `active`). A span is named by its label; when two spans share a label, with the plural of the kind its work is on (`Break down scenes`, `Break down use cases`). The Console moves between the groups with `[` and `]` (declared `open` actions); the Mac app shows them as sub-items of the tab in its sidebar, with their counts. `/_supervised` (Supervised by you): the facts whose presented supervisor is the client while the work is still in a span, with a quiet count of the client's running work in the Overview. Both are tabs only when the model has the entry.
- On a span subject's page, `Pick up` (key `p`) opens `/k/:kind/:key/pick_up/:run`, a confirm, and `Hand over…` (key `v`) opens `/k/:kind/:key/hand_over/:run`, a form with one choice, `hand_to` (the persons but the client), above the client's running work on the flow that will stop. No note. `:run` pins the run the page was made for; a run that moved on is refused.
- Their submits, the endpoints `pick_up` and `hand_over`, are read again and checked, then sent to Facts as an input of the flow: `{"op": "pickup" | "hand_over", "by", "values": {"run", "request_id"[, "hand_to"]}}`. Only a person at the TUI (`client: "tui"`) gets the actions and may submit, and an agent that says `as` and assists someone (the environment's `assists`, IS-Atlas-47) gets Pick up: the input is the agent's, and Facts and Flow make whom it assists the supervisor, Flow's link write saying `Picked up by <agent> on behalf of <key>`. Any other session is refused before anything is sent. Hand over… is only the supervisor's, never to itself. Facts' refusals come back as reasons (`pickup_pending`, a second pickup before Flow took the first); Flow checks the input again and sets or clears the supervisor.
- `Retry` (key `y`) opens `/k/:kind/:key/retry/:run` and `Remove` (key `m`) `/k/:kind/:key/remove_item/:run`, both confirms (IS-Atlas-09). Retry is the run's supervisor's (or an assisting agent's) while the run is in a span; its submit is sent as Pick up's is, `{"op": "retry", "by", "values": {"run", "request_id"}}`, and Flow takes the run back to the first state of its span, cancels the task it held and makes a fresh one. Remove is the supervisor's in any state, or, while nobody supervises it, the configured decider's; its submit deletes the fact's work (the facts of `supervised_work`'s kind through its `of`) with what is under each through parent relations, one Delete at a time, then the fact itself, which ends its run. Anything else under the fact refuses it.
- The shell may name a `default` tab (its id): a client with no target opens on it when it has that tab, else on the first.

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

0.15.0 (page freshness, docs/design/page-freshness.md §3) is such a bump: the row fields
`key` and `pending`, `hint` pages for recently viewed paths and `pending` overlays. Control
on 0.15.0 refuses a 0.14.0 client at hello (`bye`, "too old"); a 0.15.0 TUI refuses a
Control that welcomes it with another version. There is no dual-protocol mode.

0.16.0 is a bump of the same kind: the local Console operation `sections_toggle`, which
folds and unfolds a page's collapsible sections (the worker page's Details, key `d`). A
0.15.0 TUI refuses a projection that names it, so Control on 0.16.0 refuses 0.15.0
clients at hello; distribute the 0.16.0 TUI and `atlas` before advancing Control.

0.18.0 is a bump of the same kind: the supervision pages `/_open` and `/_supervised`, and
Pick up and Hand over… with their submit endpoints (above). Control on 0.18.0 refuses
older clients at hello; distribute the 0.18.0 TUI and `atlas` (and rebuild the Apple
client) before advancing Control.

0.19.0 is a bump of the same kind: the `groups` block (a page's items by group, each a filter of the page with its count) and the page `/_open/:subflow/:span`. Control on 0.19.0 refuses older clients at hello.


### Worker Control contract

`contract/lib/wire/control/workers.ex` declares versioned worker inspection, exact-turn guidance,
query, history and receipt messages on the Control channel. It reuses Runtime's
execution identity; `Contract` composes the wire APIs and shared payload models. Existing
list/item/form blocks implement the worker pages, so they follow the block wire version
(0.16.0); typed worker messages independently require version 0.1.0.

The eight messages the TUI's worker pages exchange are endpoints of the contract too
(`lib/endpoints.ex`; each call is the message's `op`, each takes and replies a model of
`lib/models/workers.ex` that is exactly its envelope without `op`, `channel` and `version`,
which `test/worker_endpoints_test.exs` checks). Every request carries an `id`, which its
`<op>_result` or `<op>_error` repeats:

| Endpoint | Takes | Replies `result` | Replies `error` |
|---|---|---|---|
| `worker_inspect` | `id`, `execution` | `id`, `view` | `worker_error`: `id`, `error` |
| `worker_submit` | `id`, `execution`, `guidance` | `id`, `interaction` | `worker_error` |
| `worker_query` | `id`, `execution`, `client_key` | `id`, `found`, `interaction`? | `worker_error` |
| `worker_history` | `id`, `execution`, `cursor`? | `id`, `interactions`, `cursor`, `more` | `worker_error` |
| `worker_receipts` | `id`, `execution`, `interaction`, `cursor`? | `id`, `receipts`, `cursor`, `more` | `worker_error` |
| `worker_output_subscribe` | `id`, `execution`, `cursor`? | `id`, `subscription`, `view`, `stream`, `cursor`, `reset`? | `worker_output_error`: `id`, `error`, `view`?, `reset`? |
| `worker_output_next` | `id`, `subscription`, `cursor` | `id`, `subscription`, `stream`, `events`, `cursor`, `more`, `reset`?, `view`? | `worker_output_error` |
| `worker_output_unsubscribe` | `id`, `subscription` | `id`, `subscription` | `worker_output_error` |

(`?`: optional.) Control sends no worker message unasked: output is read with
`worker_output_next`, and the worker pages themselves change by the session's `hint` pages.
`worker_overview` stays an operation without an endpoint: no worker page sends it. Declaring
these endpoints changed no byte on the wire, so neither the block version (0.16.0) nor the
worker version (0.1.0) moved, and no client is refused.

Generate with the same `mix atlas.gen` command. Named actor grants, durable outcome
semantics, bounds, generic-page limits and the outstanding Runtime integration are
documented in [the guidance contract](../../../docs/contracts/guidance.md#control-worker-access-and-guidance).


<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0026).</sub>

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
