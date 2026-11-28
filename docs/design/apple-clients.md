# Apple clients: macOS first, iOS next

Native Swift/SwiftUI apps with the same functions as the TUI (`platform/clients/tui`), talking to
Control the way the TUI does: JSON lines over TCP, `hello`/`welcome`, `boot`, `open`,
`submit`, `refresh`, and the pushed `page`, `notice` and `bye` ([platform/atlas_control/backend/README.md](../../platform/atlas_control/backend/README.md)).
macOS comes first; iOS comes after it and shares everything except a thin platform shell.

The rule does not change: **a client has no semantics.** It shows blocks and markup and
follows the paths, endpoints and actions Control sends. It never knows a kind, a relation
or a flow, never builds a path Control did not give it, and never decides what a row
means. Every rule below is about blocks, markup, pages and messages.

## 1. What exists: the generated package (slice 0)

`platform/atlas_control/backend/targets/swift/` is the Swift package `AtlasControlKit`, a file target of the contract
(`AtlasBFF.Targets.Swift`, written by `bin/generate atlas`). It is build output, not kept in
git, except the fixtures it tests on (`Tests/Fixtures`, kept by hand). Platforms `.macOS(.v14)` and `.iOS(.v17)`, Swift 6 language mode,
Foundation only (no AppKit, UIKit, SwiftUI or Network), so one package serves both apps.

It is published in [github.com/mimbre/atlas-swift](https://github.com/mimbre/atlas-swift),
one tag per contract version (the `version` of
`platform/atlas_control/backend/contract/lib/contract.ex`, as `blocks.json` carries it).
CI's `deploy-swift-package` publishes it on each release (a push to master) when its
version's tag is not there yet, and otherwise does nothing, with
`platform/clients/apple/tools/atlas_swift.py`: a tag, once published, stays as it is, so a
change to the package reaches the app with a new contract version.

```
platform/atlas_control/backend/targets/swift/
  Package.swift                      library AtlasControlKit, test target AtlasControlKitTests
  Sources/AtlasControlKit/
    Contract.swift                   Contract.version, the contract's version
    JSONValue.swift                  any JSON value: untyped fields, what cannot be shown
    Fallback.swift                   a block or markup entry that cannot be shown, and why
    Models.swift                     <Name>Model per model (ActionModel, RowModel, ShellTabModel, …)
    Blocks.swift                     <Name>Block per block; Block {id, content}, content .fallback
    Markup.swift                     <Name>Markup per kind; MarkupEntry {start, end, group, content}
    Pages.swift                      Page (a case per page): template, params, path(_:), match(_:)
    Messages.swift                   ControlRequest / ControlMessage, SteerRequest / SteerMessage,
                                     their field structs (PageMessage, BootShellMessage, …), WireLine
  Tests/AtlasControlKitTests/
    ContractTests.swift              generated: every block, kind, page and message on samples
    FixtureTests.swift               generated: decodes and round-trips Tests/Fixtures/<channel>/*
  Tests/Fixtures/{control,steer}/{sent,received}.jsonl
                                     kept by hand: lines a Control test session and the agent sent
```

What it gives an app:

- **Types.** A `Codable`, `Sendable`, `Equatable` struct per model, block and kind of
  markup; required fields are non-optional, optional ones are optionals that are left
  out when encoded. Wire names stay snake_case (`submit_label`); Swift names are
  camelCase (`submitLabel`). The suffixes (`ListBlock`, `LinkModel`, `SectionMarkup`) keep
  them clear of SwiftUI's `List`, `Link`, `Section` and `Form`.
- **The fallback.** `[Block]` and `[MarkupEntry]` always decode. A block of an unknown
  type, or one that fails to decode, is `.fallback(Fallback)` with a `Fallback.Reason`, a case and the path of
  the field that failed (`.missing(path: ["rows"])`, `.unknownType`), and the JSON it came
  as, which it encodes back unchanged. Code and tests compare the case and the path; its
  `description` is only for showing. A newer Control therefore never breaks an older app.
- **Messages.** For each channel of the wire descriptors the endpoints name: the requests
  a client sends and the messages it receives, keyed on `op` and the descriptors' other
  selectors (`reason`, a field's presence). Six page reasons are six cases sharing
  `PageMessage`. An unknown message decodes as `.unknown(JSONValue)`, and one whose
  selector matches a case but whose fields do not decode (a newer Control changed a field)
  as `.undecodable(JSONValue, Fallback.Reason)`; decoding a received line never throws
  for either. A client skips both, except that an undecodable message still answers what
  the session waits for, by its `op`, as a failure (§2, `SessionState`). An unknown
  request does not decode. A field the descriptor leaves untyped takes
  the endpoint's type: `PageMessage.blocks: [Block]`, `markup: [MarkupEntry]`,
  `BootShellMessage.tabs: [ShellTabModel]`, `PlanMessage.block: Block`,
  `RunRequest.steps: [RunStepModel]`. `WireLine` reads and writes one message per line.
- **Pages.** `Page.match("/k/x/y")` and `Page.item.path(["kind": …, "key": …])`, by the
  rules of `AtlasBFF.Paths` (percent-encoding, a literal beats a parameter). A client
  uses them only to recognise a page mode (a worker page), never to make up a path.

Its tests (77) run in `swift test`. A channel's fixtures must be there (a missing file
fails), and the lines that carry `spec` must carry `Contract.version`, so a new contract
version fails until the fixtures are recaptured; CI's `swift` job (macos-latest) generates
it, builds, tests and builds it for the iOS Simulator. The hand-written
`platform/clients/apple` package has its own job, `apple` (macos-latest, §2).

### Gaps the next slices close

1. **Worker operations are not endpoints yet.** The TUI's worker pages use eight
   `worker_*` operations (inspect, output subscribe/next/unsubscribe, submit, query,
   history, receipts) declared as wire descriptors in `platform/atlas_control/backend/contract/lib/wire/control/workers.ex`.
   No `defendpoint` names them, so the package (which follows the endpoints, as asked)
   has no Swift messages for them. Declaring endpoints for them in the contract is enough:
   a trial generation with them builds and its 107 generated tests pass, with no
   generator change. This changes `blocks.json` (new endpoints), so it is its own slice
   (W0 below) and goes through the contract's review.
2. **The Console projection is Elixir in the contract.** Which key runs which operation,
   and the legend's groups, come from `console_action` blocks and `legend` markup, validated
   and resolved by `AtlasBFFContract.Console.Projection` (`compile`, `active`, `bindings`,
   `capture`, `resolve`; contexts, key tokens and the list of local operations are in
   `AtlasBFFContract.Console`). The apps need the same rules. Recommended: emit the
   vocabulary (contexts, key tokens, operation names) as data in the Swift package and
   port the projection's checks by hand to the shared app package, with parity tests on
   pages captured from Control and the projection's results captured from the Elixir module.
3. **Markup rules.** A client drops markup that does not nest (`AtlasBFF.Markup.check/2`)
   and renders `tree/2`. These are format rules of the generator, so `AtlasBFF.Targets.Swift`
   should emit them (like the path rules) in the renderer slice.

## 2. Shared and platform code

```
github.com/mimbre/atlas-swift          AtlasControlKit (generated): the contract, by version
platform/clients/apple/                hand-written Swift package (+ app targets from S8)
  Package.swift               products: ControlSession, BlockViews, AtlasMac (S1);
                              ConsoleKit (S5), WorkerViews (S6)
  Sources/
    ControlSession/           transport, session state and the view models, no UI
    ConsoleKit/               (S5) Console projection: actions, keys, legend groups
    BlockViews/               SwiftUI: blocks, markup, forms, plan, fallbacks, notices
    WorkerViews/              (S6) SwiftUI: worker output stream, conversation, guidance, history
  Mac/                        macOS app (AtlasMac): the three-column window, menus, keyboard
  iOS/                        iOS app target (later): iPhone tab bar and stack, iPad columns
```

Structure by purpose: each target says what it is for. Until S8 the macOS app is the
package's SwiftPM executable `AtlasMac` (`swift run AtlasMac --env … --host … --port …`);
S8 makes it an Xcode app target on the local package (an `.xcodeproj` under
`platform/clients/apple`) for signing and the launcher, and the iOS app is one from the start.
Everything that can be tested without a window is in the package and runs in `swift test`.
CI's `apple` job (macos-latest) runs `swift build` and `swift test`, and builds
`ControlSession` and `BlockViews` for the iOS Simulator.

`Package.swift` depends on AtlasControlKit from github.com/mimbre/atlas-swift at exactly
the contract's version (`contractVersion`; the `apple` job fails when it is not the
contract's). A contract change in a branch has a version that is published only when it
is released, so the `apple` job, and a local build of such a branch, build against the
package generated from the tree instead: `ATLAS_SWIFT_PACKAGE`, a folder, replaces the
published package.

```
swift build                                         # the published contract version
bin/generate atlas model                            # from the repository's root
ATLAS_SWIFT_PACKAGE=../../atlas_control/backend/targets/swift swift build
```

`swift test` needs the product's description (`ShellTabsTests` reads
`products/software_factory/model/targets/rela/atlas.json`): run `bin/generate model` first.
The release job `deploy-mac-app` builds against the published package, after
`deploy-swift-package`, and reads the contract version from the contract's source.

**ControlSession** (shared, `@MainActor`-free core with an `@Observable` façade):

- `LineConnection`: TCP JSON lines. `NetworkLineConnection` is it on Network.framework
  (`NWConnection`, `.tcp`), the same on macOS and iOS. `LineFramer` frames incoming bytes
  into lines (a line up to 4 MB, as the TUI's socket buffer); it writes `WireLine.encode`d
  requests and reports `ready`, `line`, `closed`. No Foundation socket or `Process` API,
  which are macOS-only or unsuitable on iOS.
- `SessionState`: the TUI's rules (`AtlasTui.Console`, `AtlasTui.App`) as a plain value,
  with no actor, time or socket: each input (a connection event, a line, a tick, a
  deadline, what the user does) changes it and returns effects (`connect`, `close`,
  `send`, `scheduleRetry`, the handshake and boot deadlines). It holds the handshake
  (`hello` with `Contract.version`; a `welcome` for another environment, spec or surface,
  or a `bye`, ends the session with its text), `boot` and the shell (tabs, `initial_to`,
  `active_tab`, the TUI's shell checks, a stale shell kept on a failed boot), the page on
  screen (the tab's index page and an opened page; one `open` on the wire, the newest
  wish next; only an `open` answers an `open`), the draft, the notice, the last update
  (reason, at, position) and last hint, the `count`, and `refresh` every
  `reconcile_seconds` (default 5). Retrying is part of it, not a type of its own: a closed
  connection says so, retries every 2 s (as the TUI), and on return sends `hello`, then
  `boot`, then `open` of the page it was on. A message of a known `op` that does not
  decode answers what the session waits for as a failure, as the TUI (which goes by `op`
  alone) does: a welcome ends the session, a boot reply fails the boot (the shell stays,
  stale, and the connection too), and a page answering the `open` ends it with
  `openFailure` for the foot's popover (or asks for the newer wish).
  Later slices add `history` for Back (each entry keeps its selection and scroll), the
  page cache (newest per path by `position`, at most a fixed number of paths), selection
  kept by row `key` (else `to`) and pending marks (S2). On iOS the session also closes
  when the app goes to the background and reconnects in the foreground (`scenePhase`), and
  waits for `NWPathMonitor` to report a path before retrying (I2).
- `Session`: the `@Observable` façade the views use. It runs `SessionState`'s effects on
  an injected `LineConnector` (which makes a `LineConnection`) and `SessionClock` (one-shot
  deadlines and the reconcile tick), and drops events and deadlines of a connection it
  gave up. Tests inject fakes: no real timers, no sockets in unit tests.
- The view models `ShellViewModel` (title, environment and prod badge, tabs with
  `⌘1`–`⌘9`, active tab, stale shell and boot failure, count, the two columns' pages) and
  `StatusViewModel` (connection, position, last update, last hint, reconcile interval,
  last notice, a failed `open`), built from the state, so the views are tested through
  them.
- `hello` says `client: "tui"` for now (accepted in S1): Control acts for the person only
  for that client name (`AtlasControl.Session`). A name of its own for the apps needs
  Control to know it, and is left for later.

**ConsoleKit** (shared): the projection of `console_action` blocks and `legend` markup
into the operations available in the current context, and their key tokens. The platform
decides how an operation is triggered (a key on macOS, a button or gesture on iOS); the
set of operations and when each is available is the same.

**BlockViews** (shared SwiftUI): a view per block (`list`, `item`, `form`, `confirm`,
`plan`) and the fallback (its type and reason, the rest of the page still shown); markup
as layout (`part` boxes, `section` headings with always-visible blocks, `highlight`
tones later); forms with every input kind (text that wraps, multiline, choice, boolean,
readonly), errors, submit and cancel; links opened with `openURL` (http and https only).
Layout adapts by size, not by platform: two or more parts side by side when wide, stacked
when narrow (the TUI's 120-column rule becomes a width threshold and size classes).

#### Layout, block roles, colours and actions

Shared with the TUI: [clients.md](clients.md) (shell and content, block pages, layout A,
how each block role renders, Prism colours and their gaps, actions). Mac specifics:
column widths in points live in `WindowLayout` (BlockViews), applied by `PageView` (page
and details) and `ShellView` (column widths, the sidebar's fold); `WindowLayoutTests`.

#### Columns in the TUI

The TUI's cell widths, focus and keys between its columns are in `AtlasTui.Columns`'s
moduledoc; columns are separated by one thin grey line (`:rest_frame`), and the column
with the focus has its heading lit (`:lit`, `AtlasTui.Palette`).

### The shell (approved, 2026-11-13)

This is the plan for the macOS shell and for slice S1. iPhone and iPad follow it as the
rules below say.

A standard Mac window with three columns (`NavigationSplitView`), like Mail or Notes:

| Column | Shows |
|---|---|
| Sidebar | The tabs. |
| Middle | The tab's index page. |
| Right | The page opened from a row. |

Above the columns is the title bar; there is no status bar: the shell's state is in the sidebar's foot, and the page has the window's full height (its scroll content ends with room for its last blocks).

| Part | Source in the BFF | macOS |
|---|---|---|
| Tabs | `boot`: `tabs` (`icon`, `count`, `for_you`), `active_tab`, `initial_to`, `name` | Sidebar shows only top-level tabs, their icons and counts, with the person and connection at the bottom. A page matching a tab's destination selects that tab before considering its `back` link. Up and down move the selection; `⌘1`–`⌘9` switches. |
| Title and env | `boot`: `title`, `env` | Title bar. The prod badge is the same inverted badge as in the TUI. |
| Index page of a tab | the tab's `to` and its `groups` block | Middle column. Control's groups and counts are horizontal Prism-style filter pills above the list; choosing one opens its destination in the middle column. A pending row shows `⋯ being processed`, muted. |
| Opened page | `open` on a row | Right column. Back and Forward (`⌘[` / `⌘]`, Esc) use the app's own history, as in the TUI. |
| Actions and forms | `action`/`form` blocks, `submit` | Buttons under the page. A form opens as a sheet over the right column; a confirm opens as a dialog. |
| Agent behind `:` | the steer agent | A toolbar button, and `:` or `⌘K`. Its plan shows in a panel. |
| Notices and connection | `notice`, page `position`, reconcile | Sidebar foot, one line: "● Connected", or a red warning and "Not connected"; the plain words, last notice, position, last hint and reconcile interval in the state's popover. |
| Worker page | worker blocks | Right column. State and identity are separate blocks; conversation and execution details stay visible. |

Rules:

- **No tabs of its own.** The sidebar follows only what `boot` sends; the app has no
  semantics.
- **iOS.** On iPhone the same tabs move to a tab bar, with More for the tabs beyond what
  it shows, and list → page becomes a navigation stack. iPad keeps the three columns.
- **macOS pointer.** Enabled controls, navigable rows, and permitted inline Markdown links
  use a pointing hand on hover; disabled controls and rows without a destination do not.
  Other selectable Markdown text retains its native text cursor.
- **Rejected alternative:** tabs as a segmented control in the toolbar. It breaks down once
  a description has more than about 5 tabs.
- Text blocks and item or option fields render Markdown only when `syntax` is `markdown`;
  missing or unknown syntax stays plain text. Markdown body text uses the same Prism
  `bodysmall` font and line height as plain text, retaining bold and italic emphasis;
  code uses `monosmall`. Headings use `title4`–`title7` (levels 4–6 share `title7`),
  below the page title. Code is displayed as text, and only clicked HTTP(S) links can open.
  Content with raw HTML is shown as
  literal source, not rendered or silently discarded.

What differs by platform beyond the layout stays in the platform targets:

| Concern | macOS (`Mac/`) | iOS (`iOS/`) |
|---|---|---|
| Layout | the three columns above | iPhone: tab bar and navigation stack; iPad: the three columns |
| Actions | buttons under the page; their `console_action` keys as shortcuts | buttons under the page; swipe and context menus on rows |
| Reaching Control | the local tunnel `bin/atlas` opens (§5) | the Mac mini's tunnel, over the tailnet (§6) |
| Agent behind `:` | runs `atlas steer` as a child process | hidden until Control serves plans (§6) |
| Distribution | a local build; no App Store Connect | TestFlight (D-0088, §6) |

## 3. The TUI's functions, and where they go

`Session` in this table is `ControlSession`'s pair: the rules in `SessionState`, run by the
`Session` façade (§2).

| Function | TUI module(s) | Apple |
|---|---|---|
| Connection, retry every 2 s, reopen the page on return | `AtlasTui.App`, `AtlasTui.Console` | `SessionState` (retrying is part of it), run by `Session` on `LineConnector` and `SessionClock` |
| Environment: prod by default, test when asked; `products/software_factory/environments/<env>.json` or `ATLAS_ENV_FILE` | `AtlasTui.CLI` | macOS: the launcher passes env, host, port (§5); iOS: configuration (§6) |
| Tunnel to Fly, readiness probe | `bin/atlas`, `bin/lib/tunnel.sh` | macOS: the launcher reuses it; iOS: the Mac mini's tunnel over the tailnet (§6) |
| Handshake: hello with the spec, any version welcomed (a difference is a status warning, D-0105), wrong env → bye | `AtlasTui.Console` | `Session` |
| Boot, tabs, initial page, active tab, stale shell | `AtlasTui.Console`, `AtlasTui.ConsoleView` | `Session`; sidebar (macOS, iPad), tab bar with More (iPhone) |
| Pages: open, the page on screen, the title, "No such page" | `AtlasTui.Console`, `AtlasTui.View` | `Session`, `BlockViews`; index page in the middle column, opened page on the right |
| Lists: id column, label, detail; one selection across a page's lists | `AtlasTui.Model`, `AtlasTui.View` | `BlockViews.ListView` |
| Selection kept when a page replaces the list | `AtlasTui.Selection` | `Session` (same rule, by `key` then `to`) |
| History and Back, with each page's selection and scroll | `AtlasTui.Console` | `Session.history`; Back and Forward (`⌘[` / `⌘]`, Esc) |
| Forms: text (wraps), multiline (enter = new line), choice, boolean, readonly, errors, Ctrl+S | `AtlasTui.Model`, `AtlasTui.Text`, `AtlasTui.View` | `BlockViews.FormView` in a sheet over the right column; ⌘S / Done |
| Submit, confirm, refused page (`refused`), errors on the form | `AtlasTui.Console`, `AtlasTui.Model` | `Session.submit(call, values)`; a confirm as a dialog |
| Pending marker `⋯ being processed`, pending pages | `AtlasTui.View`, `AtlasTui.Console` | `BlockViews` row marker, muted; `Session` |
| Notices with tone; status bar: connected, updated how and when, position, last hint, reconcile interval; not connected, with why and what happens next in plain words (no message in the content area or over the window) | `AtlasTui.View` (`status/3`) | the sidebar's foot, one line: the environment, then "● Connected", or a red warning sign and "Not connected"; a click on the state opens a popover with the plain words (why, what happens next), the last notice, the app's update, position, last hint and reconcile interval (`StatusViewModel.text`) |
| Hints for recent paths, refresh every `reconcile_seconds` | `AtlasTui.App`, `AtlasTui.Console` | `Session` with an injected clock |
| Page cache: newest per path, shown at once on Back and tab switch | `AtlasTui.PageCache` | `Session.cache` |
| Parts: side by side or stacked; own scroll each; tab moves focus | `AtlasTui.View`, `AtlasTui.Model` | `BlockViews.PartsLayout` |
| Sections with always-visible contents | `AtlasTui.View`, `AtlasTui.Model` | `BlockViews.PageView` |
| Links: http/https in the browser; a stand-in browser for tests | `AtlasTui.Browser` | `openURL`; an injected opener in tests |
| Worker page: output stream on its own connection, demand-driven, backoff 2–16 s | `AtlasTui.WorkerOutput`, `AtlasTui.WorkerOutputConnection`, `AtlasTui.WorkerConversation` | `WorkerViews` in the right column; a second `LineConnection` |
| Worker conversation and guidance: drafts, exact retry, durable acceptance | `AtlasTui.WorkerConversation`, `AtlasTui.WorkerGuidance` | `WorkerViews` |
| Worker history and receipts, paged | `AtlasTui.WorkerHistory` | `WorkerViews` |
| The agent behind `:`: ask, plan (keep, edit, drop steps), run, cancel, stop; `agent:<intent>` actions | `AtlasTui.App` (child process), `AtlasTui.Model`, `AtlasTui.View` | macOS: a toolbar button, `:` or `⌘K`, the plan in a panel, `Process` running `atlas steer`; iOS §6 |
| Keys from the projection, no local key table; Ctrl+C quits | `AtlasTui.Keys`, `AtlasTui.Interactions` | `ConsoleKit`; ⌘Q / system |
| The legend, from `legend` markup | `AtlasTui.Legend`, `AtlasTui.LegendView` | macOS: the keys, by group, in the Help menu; iOS: not needed |
| Palette (Prism tokens, light and dark), prod badge, header count | `AtlasTui.Palette`, `AtlasTui.ConsoleView` | asset colours from the same tokens; the inverted prod badge in the title bar; the count in the sidebar section's header |
| Cards (an option, a to-do's step, what went wrong, the details under a page): a filled surface a step off the page (`:card`, the selected one `:card_selected`, a Prism gap until Prism's dark mode has surfaces), rounded with half blocks (▗▄▖ ▝▀▘), no lines; a left bar ▌ where the terminal reports no truecolor (`COLORTERM`); the page's eyebrow bold light blue, its title bold under it | `AtlasTui.View` (`card/4`), `AtlasTui.Palette` | cards; the dark-gap shim for the dark surfaces |
| Resize: redraw, parts re-laid out | `AtlasTui.Resize` | SwiftUI layout |
| Unknown blocks and kinds shown as fallbacks | `AtlasTui.View.known/0`, `AtlasTui.Blocks` | `Fallback` view |

## 4. Slices to parity (macOS), then iOS

Every slice keeps the TUI and Control unchanged unless it says so, and adds its tests at
the lowest level that can show it.

**S1 Transport, session and the macOS shell (source integrated; acceptance below).** The `platform/clients/apple` package with
`ControlSession` (`LineConnection` on Network.framework, line framing, hello/welcome, boot,
open, refresh on an injected clock, reconnect, version refusal and bye) and the `Mac`
target with the approved shell (§2): the three-column window, the sidebar from `boot`'s
tabs, `active_tab` and `initial_to`, with counts and `⌘1`–`⌘9`; the title bar with the
title, the environment and the inverted prod badge; the tab's index page in the middle
column and an opened page on the right (blocks it does not show yet appear as fallbacks);
the sidebar's foot, one line: the environment, then "● Connected", or a red warning sign and "Not connected"; a click on the state opens a popover with the plain words (why, what happens next), the last notice, the app's update, position, last hint and reconcile interval.
*Accepted when* unit tests drive a fake connection and clock through: welcome then first
page; a too-old/wrong-env bye ends the session with its text; a dropped connection
retries every 2 s and reopens the page; refresh is sent each interval (Control answers
none while a form is being edited, and a draft is never replaced). The shell's model
shows exactly the tabs `boot` sent, in its order, up to 64, and no tab of its own; a
failed boot keeps the last good tabs; the foot's model (`StatusViewModel`) follows the session. An
integration test (§7) connects to a real Control and gets a welcome, a page and a boot
shell. `swift build` for macOS and iOS.
*Built, with these choices the coordinator accepted:* `hello` says `client: "tui"` (§2);
the macOS app is the SwiftPM executable `AtlasMac` until S8; the rules are `SessionState`
with the `Session` façade, and the views read `ShellViewModel` and `StatusViewModel`
(§2); rows already open their `to` in the right column (`BlockViews` shows `list` rows,
other blocks as fallbacks); the count is in the sidebar section's header. CI's `apple`
job builds and tests the package; the integration test runs on a Mac (§7).

*Current acceptance (2026-11-16):* the approved S1 source, including real-clock token
ownership and capture release, is integrated onto current develop. Direct Swift 6
compilation and native XCTest, shared iOS library compilation, and private loopback
Control checks are recorded in the assignment's `delivery-evidence/` outside the product
tree. The private Control proof uses actual Gateway/Session with accepted downstream
`FakeStore`/`FakeFlow` and synthetic `Shop.Shelled` data; it is not a full deployment.
The current generated Swift contract is 0.16.0; a confirmation may omit `confirm_label`
and `confirm_to`, including when Control has no restart offer. S1 treats it as a known
fallback and retains the editing guard; it implements no restart action.
Source readiness does not establish release or visual acceptance: full AtlasMac window,
entry-point lifecycle, menu/keyboard input and visual layout remain unverified because
the prior WindowServer/LaunchServices/HI sandbox denials remain unresolved. No GUI check
was retried. SwiftPM package execution, Xcode schemes and CI remain separate gates;
direct compiler checks do not prove them. iOS evidence is shared-library compilation,
not app or device execution. No signing, distribution or transport cutover is included.

*Bounded S1 renderer correction (2026-11-16):* the shared list renderer now provides
subtle hover feedback, a button covering the full padded row, and distinct persistent
selection from the actual displayed page path (including redirects, rather than pending
open intent). IDs, titles and detail summaries have line limits; received strings are
unchanged. Valid item blocks show their full headings and labeled or blank-label prose,
with wrapping, blank lines and selectable text. Unsupported actions are identified as
unsupported; malformed/unknown blocks retain their decoding reasons and other blocks
remain usable. This adds no submission, worker stream or BFF behavior.
Direct native compile/XCTest evidence is recorded outside the product tree. Actual
hover, full-row activation, selection and compactness acceptance remains for the user on
LAPTOP after independent review; model tests do not establish visual acceptance.

**S2 Pages, lists, Back and Forward.** `list` and `item` blocks, the fallback view, links,
the page cache, the app's own history (Back and Forward, `⌘[` / `⌘]`, Esc) with selection
and scroll, selection kept on replace, pending rows (`⋯ being processed`, muted).
*Accepted when* fixture tests replay captured page sequences and assert the session's
state (page on screen, cache, history, selection); a hint for another path is cached, not
drawn; Back shows the cached page at once and re-opens it; Forward returns to the page
Back left.

**S3 Markup and layout.** Markup check and tree (emitted by the generator), parts side by
side or stacked by width, and sections with always-visible contents.
*Accepted when* markup that crosses is dropped and blocks still render (unit test on
fixtures); a narrow and a wide right column give the TUI's two layouts (view tests on
the layout model, not screenshots).

**S4 Forms and submit.** Actions as buttons under the page; a form as a sheet over the
right column with every input kind, errors, submit by `call` (endpoint and params, values
as text) and cancel; a confirm as a dialog; refused and stored; notices in the sidebar's foot.
*Accepted when* a fixture form round-trips the user's values into the exact `submit` the
TUI sends (compared with captured `sent.jsonl`); a refused page shows its errors in the
sheet; a stored page closes it.

**S5 Console projection and keys.** `ConsoleKit` (the projection's rules ported,
vocabulary from the package), the actions' keys as shortcuts, the keys by group in the
Help menu.
*Accepted when* parity tests give the same active operations and bindings as
`AtlasBFFContract.Console.Projection` for captured pages; no key works that the page did
not bind.

**W0 Worker operations as endpoints (contract).** `defendpoint` for the eight worker
operations the TUI uses, so the package has their messages. Changes `blocks.json` and the
contract's version notes; reviewed as a contract change.
*Accepted when* `bin/generate atlas` writes it, the generated tests cover each worker
message, and fixtures captured from Control's worker tests decode.

**S6 Worker pages.** In the right column: output stream on its own connection
(demand-driven `next`, gap replay, backoff 2–16 s), the conversation, which scrolls, and
guidance (drafts, exact retry, acceptance), history and receipts, Details as a disclosure
group.
*Accepted when* unit tests mirror `worker_output_test.exs`, `worker_guidance_test.exs` and
`worker_history_test.exs` on the same fixtures, with an injected clock.

**S7 The agent behind `:`.** macOS only: a toolbar button, `:` or `⌘K`; `atlas steer` as a
child process (stdin/stdout JSON lines, stderr to `steer.log`); the plan block in a panel
(keep, edit, drop, run, cancel, stop); `agent:<intent>` actions.
*Accepted when* the steer fixtures replay into the plan panel's state; the process is
started on the first `:` and stopped with the app.

**S8 Launcher.** `bin/atlas mac --env test|prod` (§5), signing for a local build (no App
Store Connect), the macOS job builds the app.
*Accepted when* a person can follow §5 on a clean clone; prod is the default and shows
the badge.

**I1–I3 iOS.** *Prerequisites,* which the person behind Atlas handles through a To-Do
before I1: an Apple Developer account, a bundle ID that names no company (the repository
is public), an App Store Connect app record, and an App Store Connect API key for
unattended upload, so builds ship through TestFlight (D-0088). I1: the `iOS` target with
S2–S5's shared views (iPhone: tab bar with More, navigation stack; iPad: the three
columns), against Control over the tailnet (§6), shipped through TestFlight. I2: forms
and worker pages, with background/foreground reconnect. I3: the agent, once Control
serves plans.

## 5. Running the macOS app against test or prod

The TUI reaches an environment on Fly through `bin/atlas`: `ensure_tunnel` runs
`fly proxy` from this Mac's `control.port` to Control on the environment's private network
(WireGuard), checks Control answers (`platform/ops/control-ready.py`), then starts the TUI on
`127.0.0.1:<port>`. The app does the same through a launcher instead of opening Fly
itself (a sandboxed app cannot run `fly`):

```
bin/atlas mac              # prod: opens the tunnel, then the app on 127.0.0.1:<prod port>
bin/atlas mac --env test   # test
```

The launcher passes `--env`, host and port (from `products/software_factory/environments/<env>.json` or `ATLAS_ENV_FILE`) as
launch arguments; the app connects only there and shows the environment in its title
bar, prod as the inverted badge. Without the launcher the app asks for nothing and says
how to start it. For a local Control (`atlas-ops restart --env test`) the launcher skips
the tunnel, as `bin/atlas tui` does. The macOS app runs as a local build; it needs no App
Store Connect.

An open tunnel is shared by every client on the Mac, so when Control is only slow to
answer, `ensure_tunnel` keeps the tunnel and says so; it reopens it only once the proxy has
died or its port no longer accepts. If Control stays unreachable, close the tunnel
(`atlas-ops tunnel close --env <env>`); the next command opens a new one.

## 6. iOS: what maps differently, and how it reaches Control

- **Layout.** As the shell says (§2): on iPhone a tab bar with More, and list → page as a
  navigation stack; on iPad the three columns.
- **Keys and legend → touch.** The same operations from `ConsoleKit`, as labelled buttons
  under the page, with swipe actions and context menus on rows; tapping a row opens it (no
  separate selection step). No legend: every action carries its label.
- **Parts.** On a compact width, parts are stacked one after the other, as markup means,
  never by page type.
- **Forms.** The same `FormView`; multiline uses `TextEditor`; save is the keyboard's Done
  and a button.
- **Worker output.** The same demand-driven stream, paused in the background (the second
  connection closes) and resumed with a fresh subscription in the foreground.
- **The agent behind `:`.** iOS cannot start `atlas steer`. Until Control (through
  Runtime, SC-Atlas-02) sends the plan block itself, `agent:` actions are hidden on iOS.
  The plan view is shared, so nothing else changes when Control serves it.
- **Reaching Control (decided, 2026-11-13): over the existing Tailscale network.** The
  iPhone and the Mac mini are on the same tailnet already. The Mac mini keeps a tunnel to
  Control: a local proxy (`fly proxy`) of the same kind it already runs for the Runtime's
  prod bus link, bound to its tailnet address. The iOS app connects to `mac-mini:<port>`.
  Only tailnet devices can reach it; Control stays closed to the internet, and the
  protocol does not change. Tailscale must be on on the iPhone when the app is used.
  The Mac mini's tailnet address and the port are configuration, not part of this
  document.
  *Alternative, noted only:* Tailscale on the Fly app itself.
- **Distribution: TestFlight (D-0088).** Prerequisites, handled by the person behind
  Atlas through a To-Do: an Apple Developer account, a bundle ID that names no company
  (the repository is public), an App Store Connect app record, and an App Store Connect
  API key for unattended upload. The bundle ID is configuration, not part of this
  document.

## 7. Testing

**Unit tests against fixtures.** The generated package already decodes and round-trips
real lines (`Tests/Fixtures/control` from a Control test session on the neutral model of
Control's tests; `Tests/Fixtures/steer` from the agent's steer test harness). The app
package does the same one level up: `SessionState` is fed inputs directly, and `Session`
line sequences through a fake `LineConnector` and `SessionClock`, and both assert the
state; views are tested through their models (`ShellViewModel`, `StatusViewModel`), not
pixels. Recapture fixtures when the contract changes (a
new version fails the fixture tests until they are), by
running a session in a Control test (Gateway on port 0, `FakeStore`, the shop model) that
writes every line it sent and received, then deleting that test. The steer fixtures are
recaptured by hand, from a session of the agent's steer test harness.

**Integration against a real Control.** The e2e (`products/software_factory/e2e/`, `AtlasE2E.Instance`) starts a
private test instance (rela, core and Control on free ports, through `atlas-ops` with
`ATLAS_ENV_FILE`) and stops it with the run. A Swift test attaches to it:

- an e2e scenario starts the instance, then runs
  `swift test --filter ControlIntegration` in `platform/clients/apple` with `ATLAS_ENV_FILE`
  pointing at the instance's settings, as a child of the scenario (`System.cmd`), so the
  servers stop with the scenario;
- the Swift test (`ControlIntegrationTests`) reads Control's host and port from that file,
  connects with the real `NetworkLineConnection`, and checks hello/welcome, a page and the
  boot shell (S1); S4 adds a submit that is stored and a hint to a second session. It is
  skipped when `ATLAS_ENV_FILE` is unset, so plain `swift test` stays a unit run.

The scenario is `products/software_factory/e2e/scenarios/apple-control.exs`; on a Mac, run it with
`bin/atlas-dev e2e apple-control`. It runs `bin/generate atlas` and builds against that
package (`ATLAS_SWIFT_PACKAGE`), the contract version the run's Control speaks, published
or not. A skip there is a failure. Network.framework exists only
on Apple's platforms, so the scenario runs only on macOS with `swift`; elsewhere it passes
with a note that it did not run. CI's e2e job is Ubuntu, so a green e2e job says nothing
about the Swift client against a real Control. The `apple` job (macOS) runs the unit tests only.

*Follow-up:* a macOS integration job that installs Erlang and Elixir (erlef/setup-beam,
as the `apple` job does) and runs the scenario. With it, build the
Swift package before the instance starts (or put a timeout on the scenario's
`System.cmd`), so the build does not run inside the shared instance's time.

**A person against test or prod.** On macOS, §5: `bin/atlas mac --env test` opens the
tunnel and the app; prod is the default and wears the badge. On iOS, a TestFlight build
on a device with Tailscale on, connecting to the Mac mini's tunnel (§6).
