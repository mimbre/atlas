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

Control and the TUI depend on the contract by path, and read it when they compile: changing the contract recompiles them, and no Elixir code is generated into files. Clients on Apple's platforms use the Swift package: `mix atlas.gen` writes it with `blocks.json`, CI builds and tests it on macOS (`swift build`, `swift test`) and builds it for iOS, and a release publishes it to github.com/mimbre/atlas-swift, tagged with the contract's version, which the Apple clients depend on. It holds generated code only, plus the message lines in `Tests/Fixtures/<channel>/{sent,received}.jsonl` that its tests decode and round-trip: lines a Control test session sent and received, on the neutral model of Control's tests. Those fixtures are the only files of `targets/` kept in git. A transport and the apps are hand-written and live elsewhere ([Apple clients](../../../docs/design/apple-clients.md)).

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

Change the contract and commit it. The targets are build output, not kept in git (`targets: [json: "../targets/json", swift: {"../targets/swift", package: "AtlasControlKit", version_field: "spec"}]` in `platform/atlas_control/backend/contract/config/config.exs`): `bin/generate atlas` (or `mix atlas.gen` here) writes them where a build needs them, and nothing compares them with earlier output. Every generated file starts with a header that says so and names the contract file; `mix atlas.gen` never overwrites a file without it, and removes a generated file no target writes any more. Then check the TUI still knows every block and kind of markup (`AtlasTui.View.known/0`; its tests fail otherwise).

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
| `panel` | where its owner decides, as the model's `panel` for the state declares it: a heading (what is asked: to accept, to merge), a title and an aside, a byline (parts, one with the age of the work), what it is judged on (items, each with details; checks with their state; a framed box) and the answers, each the page's action of the same key (a yes, or a no given with a note) | select an item and open it; answer by key; open what it refers to (its actions and links) |
| `header` | a page's own heading, first in a stack of simple blocks: an eyebrow (what is asked: TO DO FOR YOU), the fact's key and a title | — |
| `text` | a paragraph: a label (Why), its text and, with `since`, how long ago that was; `role` error: what went wrong | — |
| `instruction` | one numbered step of instructions, in full: its number and its lines in the order written (`instruction_line`: `text`, `command` or `route`) | copy a command |
| `answers` | the page's answers, each on its key (`panel_answer`; one may ask a note), each with its `weight`: `main` (exactly one per page, the positive answer: Done, Accept, Retry), `decline` (at most one: Won't do, Not accepted, Decline, Decline all; `no` before contract 0.38.0, deprecated, means the same) or `other` (contract 0.36.0); a client styles an answer by its weight, never by its note; `detail` a short explanation shown with it, `button` what a button says when not its label (no `…`; contract 0.38.0); `icon` what it does, by name (question, hand_over, delegate, decline: Decline all under several alternatives; contract 0.39.0), shown as an action's icon is, none for a name the client does not know; `help` what it does in full, a client's tooltip (contract 0.41.0) | answer by key |
| `actions` | what else can be done with the page's subject (change it, hand it over, delete it, create under it; in the test environment `! Failures…`, icon `faults`, last), each an `action` on its key with its `icon` (edit, hand_over, delete, create, open, faults; contract 0.36.0), below the answers and quieter than they are; never one of the page's own actions; none, no block (contract 0.34.0, in place of More…); the Mac app shows the opened item's in the window's toolbar | open it by key or button |
| `option` | one option to adopt of a decision: its number, text, a badge in its tone (★ Recommended; on one its decider added when declining, `melle's alternative`), its Rule and Consequences (each only when it has a text: an alternative its proposer has not worked out yet has neither) and its own answer (`panel_answer`: Choose; the recommended `main`, another `other`); `alone` the only proposal (no badge; clients show no number), answered by the answers' Accept (contract 0.38.0: a decline is no option but the answers' Decline or Decline all) | answer it by its key or button; select options with the arrows, Enter answers the selected one; `0` the recommended one |

Models that blocks hold: `action` (label, key, to, icon, help), `link` (label, key, url), `row` (id, label, detail, to, links, key, pending, tone, since), `pair`, `input` (with `shown_when`), `choice` (with `help`), `step` (n, label: the title of the form it fills, state, why, detail, inputs: that form's inputs with the step's values). No block holds another block; grouping is markup.

A row starts with its id, in a column of its own (IS-Atlas-57): a client lines the ids of a list up, as wide as the longest, then the labels, then the details. The detail does not repeat the id.

A row also says which fact it opens: `key`, which Control takes from `to` (none for a row that opens no fact). A client uses it only as an opaque identity, to keep the selection when a page replaces the list (docs/design/page-freshness.md §3.1), and compares it with nothing a write said. `pending: true`, set only by Control, means a write to that fact is stored and Flow has not yet settled it; a client shows it beside the label (the TUI: `⋯ being processed`), never hides or reorders the row, and never sets or clears it. Control fills `key` from contract 0.15.0 on. It sets `pending` on every page it sends, from the moment Facts has stored a write of that client until Flow has settled past it, and sends a recently viewed page again, as it was (`reason: "pending"`), when its marks change.

A row also says where its work stands, with one meaning on every list: `tone`, which Control decides, and `since`, when the row entered that state (ISO 8601, UTC). Control decides it from Facts' presentation of the work (on the fact's component, its Assignment, or on the fact): `attention` when the next step is the viewer's (or it was handed to them by hand), or its run is blocked and the viewer owns or supervises it; `active` (under way) when the viewer's running work is on it, its next step is someone else's in a flow someone supervises, or Flow is at it; `waiting` when it was reopened, waits for another fact, is blocked on someone else, or its next step is nobody's or someone's in a flow nobody supervises; `done` when the fact is completed (and no run is still at it) or its run ended. `since` is when the presenting run entered its state (its `entered_at`, which Facts' presentation carries as `since`), else when the row was assigned; for a completed fact, when it was completed. Control leaves both out where nothing says (an agent's row, say). A kind's list reads its components' presentation as a lookup for this; an item page's related lists say only what the facts themselves say (completed). A client shows the tone as a mark beside the row (the TUI: a dot before the id, red, orange, blue or green), never instead of the row's words, and may show how long (the TUI: `15d`, `6h`, `46m`, `today`) and mute a done row. These are optional fields of 0.24.0: a client that does not know them ignores them, so there is no bump.

A row also says what kind of thing it opens: `kind`, the kind's label, and `icon`, the semantic icon name the model gives the kind (`icon :scales` inside its `entity`: what the icon shows, never the kind's name). One kind has one icon everywhere: Control sends the same name on the kind's rows, on the `header` or `panel` of a page about one of its facts, and on a shell tab that lists the kind (when the model names no icon for the tab). A client maps the names it knows (the Mac app to SF Symbols, the TUI to one glyph) and shows none for any other.

A list whose rows (two or more) all have the same detail sends none: the detail would say on every row what the list already says (every to-do "Open"). Where the details differ, every row keeps its own. A row names the kind of what it opens in plain words (`kind`, the kind's label, "Decision"), so a client can say what each row is.

A state never carries its item kind's name: a to-do's open state is "Open", not "To do".

An action is its block's, or the page's (`page: true`, contract 0.24.0): what is done with the page's subject (a list page's Create, a fact's next step, the worker page's actions), which a client shows with the page's title (the Mac app: the window's toolbar for the middle column, the header of the page on the right) rather than under the block; the TUI and the Console's keys treat both alike. An action opens a page of Control's (`to`), except one whose `to` is `agent:<intent>`: that one asks the agent about the page it is on, as `:` does, with that intent (`x Overrule` on a step the agent took: `agent:overrule`). The model adds such actions per kind (`action` in the Rela DSL). A link opens a web address outside the client, in a browser (`url`); an `item` has links, and so does a `row`, for while it is selected. A client opens only http and https addresses. Control gives a fact a link when the model marks the type of one of its fields as a web address (`type …, format: :url`).

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

A page where its owner decides (the to-do has answers: accept what is proposed under it, merge, have a person decide) is one stretch in no parts, so no client splits it: first the block `todo`, an `item` whose title is the to-do and its answer keys in one line (`What to do: Accept its issues   Answers: a Accept`), with the section of the fact the state names as its field when there is one; then what is judged: the lists of the facts under it that anyone may put there (a parent relation without `set_by`; its runs, which only Flow links, are among its other lists), each row its key and `label — first line of its first text of several lines`; then the item in full, its fields followed by the to-do's Why and How; then its other lists. Every list is in a `section` carrying its title.

When the kind's `panel` (in the model, per state of its work; `RelaDSL.Description`) declares one for the state the work is in, that page opens with the `panel` block (block id `panel`) instead of the `todo` line, also without answers (Merge it). Control fills its texts from the fact, the facts that point at it and the latest of its records (`records`: by key, with `where` values), in the model's words; a value that is not recorded leaves its byline part out and shows "—" elsewhere. The facts it lists as items are not listed again below it; its links replace the item's of the same key.

A panel may declare `detail_groups`: ordered titles with field and relation names. Control emits each populated group as a standalone item, then an item retaining ungrouped pairs and links; related lists stay accessible. For Use case Plan acceptance these groups are Use case, Plan discussion, People and Progress. Empty groups are omitted. The proposal panel, its full-proposal action, the owner's answers and other viewers remain unchanged.
On the Issue Merge owner's page, the remaining detail pairs are stacked as Issue, Pull request, and Build and checks blocks, in that order, omitting empty groups. Other pairs and the item's remaining links and actions stay on the item; related lists and the merge panel are unchanged. This grouping applies only to that panel, not other Issue states or viewers.

Every action and answer Control sends says what it does in full (`help`, contract 0.41.0), which a client shows as its tooltip (without it, its label): the model's words for its own (an answer's, an action's or a relation action's `help:`), else its label; Control's for the rest (Update, Delete, Create, Pick up, Hand over…, Retry, Remove, Failures…, Health, Workers, a list's way to another, a panel's record, Choose, Accept, Decline all). A form's input may be shown and asked only while another input holds a value (`shown_when`); a required input needs a value before a client sends the form, which keeps its submit disabled until each shown one has one, and a required choice without a `value` has nothing chosen until the user chooses. A decision's Delegate (D-0106) is one answer whose page is such a form, "Delegate D-NNNN to…": `to` (`proposer`: the proposer, who decides on the decider's behalf, `delegated_by`; or `other`) and `whom` (shown when `to` is `other`, labelled as the kind the description's `delegate_kinds` name, its facts but the viewer; every word of the choices the model's). Submitting it sends the answer's own change, or the page's own Hand to… of its assignment to the one chosen; without a choice it offered, nothing (`Pages.delegate_submit/2`).

A decision is a stack of simple blocks instead (D-0104), in place of the `todo` line or the panel: for a choice (the to-do's `choice`), `header` (id `header`: eyebrow YOUR DECISION, the key, the question) and `text` (id `why`: the rationale, no label); for stuck work (a panel with `choose`), `header` (the panel's heading and title), `text` (id `why`: its byline, `since` its age) and `text` (id `failure`: label What went wrong, role `error`, the recorded failure; "—" when none). Then one `option` block per option to adopt (ids `option-1`, `option-2`, …), the recommended one first, each with its number, text, badge (`★ Recommended` in tone success; one a decider added when declining, `by`, says whose alternative it is), its fields (a choice: Rule and Consequences, each only when it has a text; stuck work: Consequences, the panel's `details`) and its own answer: the page's action of the same key, labelled Choose. A decider's alternative is added with its title only and the note `<by>'s alternative, to be worked out by the proposer` (its `details`); its rule and consequences stay empty until its proposer works them out while revising, and Facts refuses proposing it again before (`unworded`). A decline is no card (contract 0.38.0). With one option to adopt, its card is `alone` (no answer and no badge on it) and `answers` starts with Accept (`main`, its answer) and Decline (`decline`, `note`: it opens the note form first); with more, each card has its Choose and `answers` starts with Decline all. A decision's Decline is always offered (D-0106, contract 0.39.0): its note form asks "What is your alternative?" (the input's label), with nothing beside it (no `detail`, contract 0.41.0); a definition holds alternatives only, no decline option; stuck work's decline is its option given with a note. Then in `answers` (id `answers`) the page's other next steps, each `other` (a decision: Ask and Delegate, with their `icon`; stuck work: the panel's actions first, the agent's log); `0`, the recommended option again, is in neither. Then `actions` (id `actions`) with everything else the page offers, when there is any. The item in front of the details follows, without actions.

For a kind whose single-choice rule declares `details`, Control groups the named fields in model order, leaving absent fields out. Prior offer revisions show their question, rationale, recommendation, option substance, recorded content and links; revisions with identical definitions but different content remain distinct. The exact stored definition, selected definition, revision and history remain in separate standalone blocks after the grouped details, with no collapsible section or nested Details card. Clients render the same blocks at narrow and wide widths without interpreting the kind or the stored JSON.

Where the state shows a field as steps (the model's `section: [..., steps: true]`, a To-Do's instructions), its owner's page is a stack of simple blocks instead: `header` (id `header`: eyebrow TO DO FOR YOU, the key, the work's title), `text` (id `why`: no label, the lead paragraph with its `Why:` taken off, `since` when it came to them; none without a lead), one `instruction` per step (ids `step-1`, `step-2`, …; `AtlasControl.Steps`: each numbered line, `1.`, starts one; in a step a line starting `$ ` is a command, sent without the `$ `, and one starting `> ` a route, sent as its parts between the ` > ` (a part in double quotes is one); text without numbered steps is one step), `answers` (id `answers`: the page's next steps and its answers, each on its key), `actions` (id `actions`: everything else, when there is any), then what is judged and the details, without the field the steps show. When the kind declares page details groups, those existing pairs appear as standalone item blocks in model order, followed by an Other details block for remaining pairs and links; empty blocks are omitted. A To-Do declares Status, Outcome (note and evidence), and Assignment; product-specific references remain in Other details. Related lists follow as before; a step page without groups retains its details part. Every step is shown in full; nothing keeps which step is done. A client may copy a step's commands; that is the client's own.

Kinds may declare a block page with state fields, an intro, ordered text sections and a primary child relation. Control shows its header, complete intro, populated sections, the related list and its completion count, the existing to-do or proposal panel and available actions, then the full item and other relations. A page may group its item pairs into ordered, titled detail blocks by field and relation; pairs not named and the item's links remain in Other details. These groups are ordinary standalone blocks, not nested or collapsible. The existing proposal panel retains its full-proposal action. A failed child read remains visible in its list; it is not represented as an empty successful read. This changes presentation only, not the answers, authorization or stored data.

The start page of what is assigned to the viewer (`/`) is calm; it is the shared convention for such overviews, in the vocabulary above (no block or markup of its own). It has no Overview: its tab and its groups carry the counts. It declares its groups (one per kind, only those with items), then the `list` (block id `list`) of calm rows: the item's key as the row's id (people and agents talk in keys; a client shows it first, in a column of its own) and a detail that says only, in this order, the review rule's label when the fact is to be reviewed, the short name of the flow its work is in (the model's `label:` of the subflow, such as Plan, while something is expected of its owner; never the sentence of what is expected, which the item's page says), whether it is blocked, and its deadline; never since when, why, or whose. A person's page (what is assigned, Open for you, Supervised by you; Open work, which only `atlas list` shows, follows the same rule) shows each item's key and no other technical details (runs, states): those are an agent's or a developer's, through `atlas get`. Open for you and Supervised by you follow the same rows; their Overview is titled with the model's count, which no pair repeats. On a group's page of either (one span of one flow) the group's name says the flow, so a row's detail says what the item belongs under (its parents' keys) in its place. On Supervised by you, a row that the viewer's running work is on (a task an agent runs for them) says that work, its kind and detail (such as `Task · Plan · Architect`), in place of the flow. Open work (the list of the kind the start's relation starts at) follows the same shape, with `Open` as the main count, `Unassigned` counted too when some are, and each row's detail starting with who it is with (the owner keys, or "unassigned"). The Workers list (`/workers`) follows the same shape: `Workers` as the main count, `Running` and `Needs attention` (the failed turns) only when some are; calm rows without ids; and, last, an `item` `details` titled "Technical details", a pair per worker, inside a collapsible `section` titled "Details", with the page's `sections_toggle` console action (key `d`). Clients fold a collapsible section by default. Its Overview carries the page action Health (key `h`), which opens the core's health (`/health`, IS-Atlas-117): an Overview (`Checks`, and `Late` when some are), then an `item` per group (Core, Syncs, Runtimes), a pair per check whose value starts `late · ` past its limit, and a `highlight` in tone `error` over each group with a late check.

Control decides the order of every list; a client shows rows in the order it gets them and never re-sorts them. The work lists (Assigned to you, Open for you, Supervised by you, and each of their groups) are in work order: rows with a deadline first (the `deadline` Facts presents on the work, else the field the kind's late rule names), soonest at the top; then the rest by how long each has waited (the row's `since`), oldest first, a row without one last; ties by key. Browse lists (a kind's list) keep their own order.

The names (view model, markup) live in one place: `AtlasBFF.Names`, plus the `defmarkup` macro and the module name `AtlasBFF.Markup`.

## Protocol

JSON, one message per line, over TCP to the environment's Control address in `products/software_factory/environments/<env>.json`.

Client to Control:

| Message | Meaning |
|---|---|
| `{"op":"hello","env":"test","client":"tui","spec":"0.16.0"}` | First message, with the contract version the client implements; an agent may add `"as"`: the key of the fact it is (`coordinator`), so it is the owner of what is assigned to it (IS-Atlas-54; `ATLAS_AS` for `atlas`). Control of another environment answers `bye` and closes. Any contract version, older, newer or none, is welcomed (D-0105): Control records both versions (its log says a difference) and its welcome says its own; the client shows what it knows and the rest plainly, and says the difference in its status line. What it sends is checked as any client's: an answer its page does not offer is refused. A TUI started by `atlas` that meets a newer Control takes the newest build and starts again on the same page (IS-Atlas-76). |
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
| `{"op":"bye","text"}` | Control closes the connection. `reason` and `spec` are deprecated: until 0.32.0 they closed a client older than Control ("too_old"); Control no longer sends them. |
| `{"op":"turn","key":"<turn>","on":"<item>"}` | Current turn context; errors have `error` instead of the keys. An outcome is acknowledged with a stored page. |

Every message here is an endpoint of the contract (`defendpoint`, its call the message's `op`; ADR 0002), with what it takes and what it replies, and `blocks.json` lists them: hello, refresh, the pages' `open`, the submits, what Control sends unasked (`page` by hint, `notice`, `bye`), the agent's `ask`, `run`, `cancel` and `stop`, and the worker pages' messages (below, [Worker Control contract](#worker-control-contract)). Unasked pages are the pushes `hint` and `pending`.

Paths are the contract's pages (`defpage`, ADR [0002](../../../docs/adr/0002-pages-and-endpoints.md)): `/`, `/_kinds`, `/_open`, `/_supervised`, `/k/:kind`, `/k/:kind/new`, `/k/:kind/new/:relation/:parent`, `/k/:kind/:key` and its `/edit`, `/delete`, `/links/:relation`, `/set/:relation`, `/answer/:answer`, `/remove/:relation`, `/pick_up/:run`, `/hand_over/:run`, `/retry/:run`, `/remove_item/:run`; in the test environment only, the failure pages `/faults`, `/k/:kind/:key/faults`, `/fault/:fault` and `/k/:kind/:key/fault/:fault` (IS-Atlas-23: what can be made to fail there, and the confirm that causes it). Control serves those and nothing else (a path outside them gets "No such page"); `blocks.json` lists them, and the targets give every Elixir consumer `pages/0`, `match/1` and `path/2` (`AtlasBFF.Paths`). A client with a screen only follows them.

A client without a screen, such as the agents' command line (`platform/clients/agent`), knows only codes. Three paths are for such a client, and Control works out the rest from the model:

- `/k/_/<key>` (and `/edit`, `/delete`): the fact with that key. Its kind is the one whose id prefix the key has.
- `/k/<kind>/new/_parent/<key>`: the create form under the fact with that key, through the kind's one at-most-one relation.
- `/_kinds`: one `item` per kind, with what a create asks, how its id is made, what it belongs under, what hangs under it and its fields, and its actions as every page names them (`Create scene`, `Update scene`, `Delete scene`; `<key>` in their paths stands for a key).

The page Control answers has the concrete path, such as `/k/issue/IS-Atlas-01`.

Supervision (contract 0.18.0; work acquisition decision 2026-11-17, §5.6–5.8), only for a model whose start page has `open_for_you` and `supervised_by_you`:

- `/_open` (Open for you): per supervised span, the facts whose work its subflow presents, active, in one of its states, without a human supervisor and waiting for no other (a selection's `order`: of the numbered facts under one parent only the first not finished is picked up; a fact without a number never waits; the other numbered ones show `Waiting for` that one on their page, without Pick up, and Flow refuses their pickup); calm, as `/`. It declares its groups first (a `groups` block, contract 0.19.0): All, then one per span that has items (and the one shown), each with its count and its own page, `/_open/:subflow/:span`, which shows only that span's list (with the same groups, that one `active`). A span is named by its label; when two spans share a label, with the plural of the kind its work is on (`Break down scenes`, `Break down use cases`). The Console moves between the groups with `[` and `]` (declared `open` actions); clients show the page's groups with their counts. `/_supervised` (Supervised by you): the facts whose presented supervisor is the client while the work is still in a span, with a quiet count of the client's running work in the Overview. Both are tabs only when the model has the entry.
- On a span subject's page, `Pick up` (key `p`) opens `/k/:kind/:key/pick_up/:run`, a confirm, and `Hand over…` (key `v`) opens `/k/:kind/:key/hand_over/:run`, a form with one choice, `hand_to` (the persons but the client), above the client's running work on the flow that will stop. No note. `:run` pins the run the page was made for; a run that moved on is refused.
- Their submits, the endpoints `pick_up` and `hand_over`, are read again and checked, then sent to Facts as an input of the flow: `{"op": "pickup" | "hand_over", "by", "values": {"run", "request_id"[, "hand_to"]}}`. Only a person at the TUI (`client: "tui"`) gets the actions and may submit, and an agent that says `as` and assists someone (the environment's `assists`, IS-Atlas-47) gets Pick up: the input is the agent's, and Facts and Flow make whom it assists the supervisor, Flow's link write saying `Picked up by <agent> on behalf of <key>`. Any other session is refused before anything is sent. Hand over… is only the supervisor's, never to itself. Facts' refusals come back as reasons (`pickup_pending`, a second pickup before Flow took the first); Flow checks the input again and sets or clears the supervisor.
- `Retry` (key `y`) opens `/k/:kind/:key/retry/:run` and `Remove` (key `m`) `/k/:kind/:key/remove_item/:run`, both confirms (IS-Atlas-09). Retry is the run's supervisor's (or an assisting agent's) while the run is in a span; its submit is sent as Pick up's is, `{"op": "retry", "by", "values": {"run", "request_id"}}`, and Flow takes the run back to the first state of its span, cancels the task it held and makes a fresh one. Remove is the supervisor's in any state, or, while nobody supervises it, the configured decider's; its submit deletes the fact's work (the facts of `supervised_work`'s kind through its `of`) with what is under each through parent relations, one Delete at a time, then the fact itself, which ends its run. Anything else under the fact refuses it.
- The shell may name a `default` tab (its id): a client with no target opens on it when it has that tab, else on the first.
- Each tab names its `section` (contract 0.23.0): `work` (what needs a person: Assigned to you, Supervised by you, Open for you; the tabs Tab and Shift+Tab cycle through) or `browse` (reference: Scenes, Agents, To-Dos, What the agent did, Workers). A browse tab may name its own `key`, a two-key sequence (`g s`, `g a`, `g t`, `g d`, `g w`), which the Console projects as an `open` action; a view key that is the sequence's first key takes it on that page. The Mac app shows the two sections under their own headings; the TUI shows the browse tabs after a separator. Boot contains only top-level tabs, with their All counts once read just after boot; group destinations and counts are in each list page's `groups` block. A group boot target selects its parent tab. A list does not repeat its page's title. The person pages (`/`, `/_open`, `/_supervised`) have no Overview; a row shows its holder only once someone supervises it or set it by hand, never Flow's default holder of unpicked work; on Open for you each span's list is titled with its flow, so its rows do not repeat it.

The assigned list has no separate list title, including on a filtered group page; the
page title and group filters retain the context and counts.

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
through coordinator review. Until 0.33.0 a version bump had to distribute compatible
clients before advancing Control, since older versions were refused at hello (the notes
below); from 0.33.0 on no client is refused for its version (D-0105, below).

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

0.23.0 is a bump of the same kind: each shell tab's `section` and a browse tab's `key`, a two-key sequence that older clients refuse. Control on 0.23.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.24.0 is a bump of the same kind: an action's `page` (the page's action, not its block's). Control on 0.24.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.25.0 is a bump of the same kind: a list row's `tone` and `since`, so the Mac app, which reads Control through the AtlasControlKit published per contract version, can show them. Control on 0.25.0 refuses older clients at hello; release the TUI and the Mac app with it.
0.27.0 is a bump of the same kind: the `steps` block (a to-do's instructions step by step, each `instruction_step` with its text and commands) and the page and submit `/k/:kind/:key/step/:step`. Control on 0.27.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.28.0 is a bump of the same kind: the `panel` block (to accept, to merge, a decision on stuck work, with its `clause`, `panel_item`, `check`, `box` and `panel_answer`). Control on 0.28.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.29.0 is a bump of the same kind: an `instruction_step`'s `routes` and its `lines` in the order written (`instruction_line`, kind `text`, `command` or `route`). Control on 0.29.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.30.0 is a bump of the same kind: the `key` of a `panel`, `steps` and `single_choice` block (the fact it is about, shown beside its title where the client shows the panel in place of the page's title). Control on 0.30.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.31.0 is a bump of the same kind: the to-do page as a stack of simple blocks, `header`, `text`, `instruction` and `answers`, in place of the `steps` block (and its `instruction_step`); the page and submit `/k/:kind/:key/step/:step` are gone, as nothing keeps a to-do's step. Control on 0.31.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.32.0 is a bump of the same kind: a decision as a stack of simple blocks, one `option` block per option (its number, text, badge, Rule and Then or a decline's Details, and its own answer) and a `text` block's `role` (error: what went wrong), in place of the `single_choice` block (and its `choice_option`) and a panel's `choose` (and a `panel_answer`'s `recommended` and `detail`). Control on 0.32.0 refuses older clients at hello; release the TUI and the Mac app with it.

0.33.0 (D-0105) ends such bumps. Clients are tolerant readers: they skip markup they do not know, read every block property as optional (`required` binds Control, which must send it; a missing or mistyped property is left out, never a crash) and show a block of a type they do not know plainly (its title or label and its texts). Control welcomes a client of any version and says its own; a difference is a warning in the client's status line ("prod speaks 0.34, this TUI 0.33 · updating"; the Mac app: "prod is newer (0.34 vs 0.33); some parts may look plain"). What clients send stays checked by Control exactly as before. So a contract change is additive: a new block, model, kind of markup or field is safe; one is removed or retyped only after a published version marked it `deprecated` (AtlasBFF.Schema). CI warns on a pull request whose contract is not additive to master's (`platform/ops/contract-additive.py`; D-0103: it warns, never blocks). `bye`'s `reason` and `spec` are deprecated.


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
