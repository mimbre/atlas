# Apple clients: macOS first, iOS next

Native Swift/SwiftUI apps with the same functions as the TUI (`clients/tui`), talking to
Control the way the TUI does: JSON lines over TCP, `hello`/`welcome`, `boot`, `open`,
`submit`, `refresh`, and the pushed `page`, `notice` and `bye` ([bff/README.md](../../bff/README.md)).
macOS comes first; iOS comes after it and shares everything except a thin platform shell.

The rule does not change: **a client has no semantics.** It shows blocks and markup and
follows the paths, endpoints and actions Control sends. It never knows a kind, a relation
or a flow, never builds a path Control did not give it, and never decides what a row
means. Every rule below is about blocks, markup, pages and messages.

## 1. What exists: the generated package (slice 0)

`bff/targets/swift/` is the Swift package `AtlasControlKit`, a file target of the contract
(`AtlasBFF.Targets.Swift`, written by `cd bff/contract && mix atlas.gen`, checked by
`mix atlas.gen --check`). Platforms `.macOS(.v14)` and `.iOS(.v17)`, Swift 6 language mode,
Foundation only (no AppKit, UIKit, SwiftUI or Network), so one package serves both apps.

```
bff/targets/swift/
  Package.swift                      library AtlasControlKit, test target AtlasControlKitTests
  Sources/AtlasControlKit/
    Contract.swift                   Contract.version ("0.16.0")
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
  for either, and a client skips both. An unknown request does not decode. A field the descriptor leaves untyped takes
  the endpoint's type: `PageMessage.blocks: [Block]`, `markup: [MarkupEntry]`,
  `BootShellMessage.tabs: [ShellTabModel]`, `PlanMessage.block: Block`,
  `RunRequest.steps: [RunStepModel]`. `WireLine` reads and writes one message per line.
- **Pages.** `Page.match("/k/x/y")` and `Page.item.path(["kind": …, "key": …])`, by the
  rules of `AtlasBFF.Paths` (percent-encoding, a literal beats a parameter). A client
  uses them only to recognise a page mode (a worker page), never to make up a path.

Its tests (77) run in `swift test`. A channel's fixtures must be there (a missing file
fails), and the lines that carry `spec` must carry `Contract.version`, so a new contract
version fails until the fixtures are recaptured; CI's `swift` job (macos-latest) builds, tests and
builds it for the iOS Simulator, and refuses a hand-written file in the package.

### Gaps the next slices close

1. **Worker operations are not endpoints yet.** The TUI's worker pages use eight
   `worker_*` operations (inspect, output subscribe/next/unsubscribe, submit, query,
   history, receipts) declared as wire descriptors in `bff/contract/lib/wire/control/workers.ex`.
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
bff/targets/swift/            AtlasControlKit (generated): the contract
clients/apple/                hand-written Swift package + app targets
  Package.swift               products: ControlSession, ConsoleKit, BlockViews, WorkerViews
  Sources/
    ControlSession/           transport and session state, no UI
    ConsoleKit/               Console projection: actions, keys, legend groups
    BlockViews/               SwiftUI: blocks, markup, forms, plan, fallbacks, notices
    WorkerViews/              SwiftUI: worker output stream, conversation, guidance, history
  Mac/                        macOS app target: the three-column window, menus, keyboard, launcher
  iOS/                        iOS app target (later): iPhone tab bar and stack, iPad columns
```

Structure by purpose: each target says what it is for. The apps are Xcode app targets
that depend on the local package (an `.xcodeproj` under `clients/apple`); everything that
can be tested without a window is in the package and runs in `swift test`.

**ControlSession** (shared, `@MainActor`-free core with an `@Observable` façade):

- `LineConnection`: TCP JSON lines on Network.framework (`NWConnection`, `.tcp`), the same
  on macOS and iOS. It frames incoming bytes into lines (a line up to 4 MB, as the TUI's
  socket buffer), writes `WireLine.encode`d requests, and reports `ready`, `line`, `closed`.
  No Foundation socket or `Process` API, which are macOS-only or unsuitable on iOS.
- `Reconnector`: on a closed connection says so, retries every 2 s (as the TUI), and on
  return sends `hello`, then `boot`, then `open` of the page it was on. On iOS it also
  closes when the app goes to the background and reconnects in the foreground
  (`scenePhase`), and waits for `NWPathMonitor` to report a path before retrying.
- `Session`: the handshake (`hello` with `Contract.version`; a `welcome` with another
  spec, or a `bye`, ends the session with its text), `boot` and the shell (tabs,
  `initial_to`, `active_tab`, a stale shell kept on a failed boot), the page on screen
  (`expected` path), `history` for Back (each entry keeps its selection and scroll), the
  page cache (newest per path by `position`, at most a fixed number of paths), selection
  kept by row `key` (else `to`) when a page replaces a list, pending marks as Control
  sends them, the notice line, the last update (reason, at, position) and last hint, the
  header `count`, and `refresh` every `reconcile_seconds` (default 5).
- Time and the connection are injected (`Clock`, `LineConnection` protocol), so tests drive
  them: no real timers, no sockets in unit tests.

**ConsoleKit** (shared): the projection of `console_action` blocks and `legend` markup
into the operations available in the current context, and their key tokens. The platform
decides how an operation is triggered (a key on macOS, a button or gesture on iOS); the
set of operations and when each is available is the same.

**BlockViews** (shared SwiftUI): a view per block (`list`, `item`, `form`, `confirm`,
`plan`) and the fallback (its type and reason, the rest of the page still shown); markup
as layout (`part` boxes, `section` headings, folded collapsible sections, `highlight`
tones later); forms with every input kind (text that wraps, multiline, choice, boolean,
readonly), errors, submit and cancel; links opened with `openURL` (http and https only).
Layout adapts by size, not by platform: two or more parts side by side when wide, stacked
when narrow (the TUI's 120-column rule becomes a width threshold and size classes).

### The shell (approved, 2026-11-13)

This is the plan for the macOS shell and for slice S1. iPhone and iPad follow it as the
rules below say.

A standard Mac window with three columns (`NavigationSplitView`), like Mail or Notes:

| Column | Shows |
|---|---|
| Sidebar | The tabs. |
| Middle | The tab's index page. |
| Right | The page opened from a row. |

Above the columns is the title bar; below them is the status bar.

| Part | Source in the BFF | macOS |
|---|---|---|
| Tabs | `boot`: `tabs`, `active_tab`, `initial_to` | Sidebar items, with the count in the label. `⌘1`–`⌘9` switches. Scales to the 64-tab limit. |
| Title and env | `boot`: `title`, `env` | Title bar. The prod badge is the same inverted badge as in the TUI. |
| Index page of a tab | the tab's `to` (a list page) | Middle column. A pending row shows `⋯ being processed`, muted. |
| Opened page | `open` on a row | Right column. Back and Forward (`⌘[` / `⌘]`, Esc) use the app's own history, as in the TUI. |
| Actions and forms | `action`/`form` blocks, `submit` | Buttons under the page. A form opens as a sheet over the right column; a confirm opens as a dialog. |
| Agent behind `:` | the steer agent | A toolbar button, and `:` or `⌘K`. Its plan shows in a panel. |
| Notices and connection | `notice`, page `position`, reconcile | Status bar: connected, position, last hint, reconcile interval, last notice. |
| Worker page | worker blocks | Right column. The conversation scrolls; Details is a disclosure group. |

Rules:

- **No tabs of its own.** The sidebar follows only what `boot` sends; the app has no
  semantics.
- **iOS.** On iPhone the same tabs move to a tab bar, with More for the tabs beyond what
  it shows, and list → page becomes a navigation stack. iPad keeps the three columns.
- **Rejected alternative:** tabs as a segmented control in the toolbar. It breaks down once
  a description has more than about 5 tabs.

What differs by platform beyond the layout stays in the platform targets:

| Concern | macOS (`Mac/`) | iOS (`iOS/`) |
|---|---|---|
| Layout | the three columns above | iPhone: tab bar and navigation stack; iPad: the three columns |
| Actions | buttons under the page; their `console_action` keys as shortcuts | buttons under the page; swipe and context menus on rows |
| Reaching Control | the local tunnel `bin/atlas` opens (§5) | the Mac mini's tunnel, over the tailnet (§6) |
| Agent behind `:` | runs `atlas steer` as a child process | hidden until Control serves plans (§6) |
| Distribution | a local build; no App Store Connect | TestFlight (D-0088, §6) |

## 3. The TUI's functions, and where they go

| Function | TUI module(s) | Apple |
|---|---|---|
| Connection, retry every 2 s, reopen the page on return | `AtlasTui.App`, `AtlasTui.Console` | `ControlSession.Reconnector` |
| Environment: prod by default, test when asked; `env/<env>.json` or `ATLAS_ENV_FILE` | `AtlasTui.CLI` | macOS: the launcher passes env, host, port (§5); iOS: configuration (§6) |
| Tunnel to Fly, readiness probe | `bin/atlas`, `bin/lib/tunnel.sh` | macOS: the launcher reuses it; iOS: the Mac mini's tunnel over the tailnet (§6) |
| Handshake: hello with the spec, refused when too old, wrong env → bye | `AtlasTui.Console` | `Session` |
| Boot, tabs, initial page, active tab, stale shell | `AtlasTui.Console`, `AtlasTui.ConsoleView` | `Session`; sidebar (macOS, iPad), tab bar with More (iPhone) |
| Pages: open, the page on screen, the title, "No such page" | `AtlasTui.Console`, `AtlasTui.View` | `Session`, `BlockViews`; index page in the middle column, opened page on the right |
| Lists: id column, label, detail; one selection across a page's lists | `AtlasTui.Model`, `AtlasTui.View` | `BlockViews.ListView` |
| Selection kept when a page replaces the list | `AtlasTui.Selection` | `Session` (same rule, by `key` then `to`) |
| History and Back, with each page's selection and scroll | `AtlasTui.Console` | `Session.history`; Back and Forward (`⌘[` / `⌘]`, Esc) |
| Forms: text (wraps), multiline (enter = new line), choice, boolean, readonly, errors, Ctrl+S | `AtlasTui.Model`, `AtlasTui.Text`, `AtlasTui.View` | `BlockViews.FormView` in a sheet over the right column; ⌘S / Done |
| Submit, confirm, refused page (`refused`), errors on the form | `AtlasTui.Console`, `AtlasTui.Model` | `Session.submit(call, values)`; a confirm as a dialog |
| Pending marker `⋯ being processed`, pending pages | `AtlasTui.View`, `AtlasTui.Console` | `BlockViews` row marker, muted; `Session` |
| Notices with tone; status bar: connected, updated how and when, position, last hint, reconcile interval | `AtlasTui.View` (`status/2`) | the status bar below the columns |
| Hints for recent paths, refresh every `reconcile_seconds` | `AtlasTui.App`, `AtlasTui.Console` | `Session` with an injected clock |
| Page cache: newest per path, shown at once on Back and tab switch | `AtlasTui.PageCache` | `Session.cache` |
| Parts: side by side or stacked; own scroll each; tab moves focus | `AtlasTui.View`, `AtlasTui.Model` | `BlockViews.PartsLayout` |
| Sections; collapsible folded until `sections_toggle` (worker Details, `d`) | `AtlasTui.View`, `AtlasTui.Model` | `DisclosureGroup`, toggled by the operation |
| Links: http/https in the browser; a stand-in browser for tests | `AtlasTui.Browser` | `openURL`; an injected opener in tests |
| Worker page: output stream on its own connection, demand-driven, backoff 2–16 s | `AtlasTui.WorkerOutput`, `AtlasTui.WorkerOutputConnection`, `AtlasTui.WorkerConversation` | `WorkerViews` in the right column; a second `LineConnection` |
| Worker conversation and guidance: drafts, exact retry, durable acceptance | `AtlasTui.WorkerConversation`, `AtlasTui.WorkerGuidance` | `WorkerViews` |
| Worker history and receipts, paged | `AtlasTui.WorkerHistory` | `WorkerViews` |
| The agent behind `:`: ask, plan (keep, edit, drop steps), run, cancel, stop; `agent:<intent>` actions | `AtlasTui.App` (child process), `AtlasTui.Model`, `AtlasTui.View` | macOS: a toolbar button, `:` or `⌘K`, the plan in a panel, `Process` running `atlas steer`; iOS §6 |
| Keys from the projection, no local key table; Ctrl+C quits | `AtlasTui.Keys`, `AtlasTui.Interactions` | `ConsoleKit`; ⌘Q / system |
| The legend, from `legend` markup | `AtlasTui.Legend`, `AtlasTui.LegendView` | macOS: the keys, by group, in the Help menu; iOS: not needed |
| Palette (Prism tokens, light and dark), prod badge, header count | `AtlasTui.Palette`, `AtlasTui.ConsoleView` | asset colours from the same tokens; the inverted prod badge in the title bar; the count in the sidebar label |
| Resize: redraw, parts re-laid out | `AtlasTui.Resize` | SwiftUI layout |
| Unknown blocks and kinds shown as fallbacks | `AtlasTui.View.known/0`, `AtlasTui.Blocks` | `Fallback` view |

## 4. Slices to parity (macOS), then iOS

Every slice keeps the TUI and Control unchanged unless it says so, and adds its tests at
the lowest level that can show it.

**S1 Transport, session and the macOS shell.** The `clients/apple` package with
`ControlSession` (`LineConnection` on Network.framework, line framing, hello/welcome, boot,
open, refresh on an injected clock, reconnect, version refusal and bye) and the `Mac`
target with the approved shell (§2): the three-column window, the sidebar from `boot`'s
tabs, `active_tab` and `initial_to`, with counts and `⌘1`–`⌘9`; the title bar with the
title, the environment and the inverted prod badge; the tab's index page in the middle
column and an opened page on the right (blocks it does not show yet appear as fallbacks);
the status bar (connected, position, last hint, reconcile interval, last notice).
*Accepted when* unit tests drive a fake connection and clock through: welcome then first
page; a too-old/wrong-env bye ends the session with its text; a dropped connection
retries every 2 s and reopens the page; refresh is sent each interval (Control answers
none while a form is being edited, and a draft is never replaced). The shell's model
shows exactly the tabs `boot` sent, in its order, up to 64, and no tab of its own; a
failed boot keeps the last good tabs; the status bar's model follows the session. An
integration test (§7) connects to a real Control and gets a welcome, a page and a boot
shell. `swift build` for macOS and iOS.

**S2 Pages, lists, Back and Forward.** `list` and `item` blocks, the fallback view, links,
the page cache, the app's own history (Back and Forward, `⌘[` / `⌘]`, Esc) with selection
and scroll, selection kept on replace, pending rows (`⋯ being processed`, muted).
*Accepted when* fixture tests replay captured page sequences and assert the session's
state (page on screen, cache, history, selection); a hint for another path is cached, not
drawn; Back shows the cached page at once and re-opens it; Forward returns to the page
Back left.

**S3 Markup and layout.** Markup check and tree (emitted by the generator), parts side by
side or stacked by width, sections, collapsible sections and `sections_toggle`.
*Accepted when* markup that crosses is dropped and blocks still render (unit test on
fixtures); a narrow and a wide right column give the TUI's two layouts (view tests on
the layout model, not screenshots).

**S4 Forms and submit.** Actions as buttons under the page; a form as a sheet over the
right column with every input kind, errors, submit by `call` (endpoint and params, values
as text) and cancel; a confirm as a dialog; refused and stored; notices in the status bar.
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
*Accepted when* `mix atlas.gen --check` passes, the generated tests cover each worker
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
(WireGuard), checks Control answers (`fly/control-ready.py`), then starts the TUI on
`127.0.0.1:<port>`. The app does the same through a launcher instead of opening Fly
itself (a sandboxed app cannot run `fly`):

```
bin/atlas mac              # prod: opens the tunnel, then the app on 127.0.0.1:<prod port>
bin/atlas mac --env test   # test
```

The launcher passes `--env`, host and port (from `env/<env>.json` or `ATLAS_ENV_FILE`) as
launch arguments; the app connects only there and shows the environment in its title
bar, prod as the inverted badge. Without the launcher the app asks for nothing and says
how to start it. For a local Control (`atlas-ops restart --env test`) the launcher skips
the tunnel, as `bin/atlas tui` does. The macOS app runs as a local build; it needs no App
Store Connect.

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
package does the same one level up: `ControlSession` is fed recorded line sequences
through a fake `LineConnection` and an injected clock, and asserts its state; views are
tested through their models, not pixels. Recapture fixtures when the contract changes (a
new version fails the fixture tests until they are), by
running a session in a Control test (Gateway on port 0, `FakeStore`, the shop model) that
writes every line it sent and received, then deleting that test. The steer fixtures are
recaptured by hand, from a session of the agent's steer test harness.

**Integration against a real Control.** The e2e (`e2e/`, `AtlasE2E.Instance`) starts a
private test instance (rela, core and Control on free ports, through `atlas-ops` with
`ATLAS_ENV_FILE`) and stops it with the run. A Swift test attaches to it:

- an e2e scenario starts the instance, then runs
  `swift test --filter ControlIntegration` in `clients/apple` with `ATLAS_ENV_FILE`
  pointing at the instance's settings, as a child of the scenario (`System.cmd`), so the
  servers stop with the scenario;
- the Swift test reads Control's host and port from that file, connects with the real
  `LineConnection`, and checks hello/welcome, boot, open, a submit that is stored and a
  hint to a second session; it is skipped when `ATLAS_ENV_FILE` is unset, so plain
  `swift test` stays a unit run.

Network.framework exists only on Apple's platforms, so this job runs on macOS: the e2e job
is Ubuntu today (erlef/setup-beam supports Ubuntu and Windows runners, not macOS), so the
macOS integration job installs Erlang and Elixir with Homebrew and rela with
`rela/scripts/start-test.sh install`. Until then the integration test runs on a Mac with
`bin/atlas-dev`.

**A person against test or prod.** On macOS, §5: `bin/atlas mac --env test` opens the
tunnel and the app; prod is the default and wears the badge. On iOS, a TestFlight build
on a device with Tailscale on, connecting to the Mac mini's tunnel (§6).
