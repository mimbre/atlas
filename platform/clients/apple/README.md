# Apple clients

Hand-written Swift for the macOS app (and later iOS), as
[docs/design/apple-clients.md](../../../docs/design/apple-clients.md) describes. The contract
is the generated package `AtlasControlKit`, published in
[github.com/mimbre/atlas-swift](https://github.com/mimbre/atlas-swift) with a tag per
contract version; `Package.swift` depends on the contract's version exactly
(`contractVersion`). Nothing here is generated, and nothing here knows a kind, a relation
or a flow: the app shows what Control's `boot` and pages send.

| Target | What |
|---|---|
| `ControlSession` | The session with Control, no UI: `LineConnection` on Network.framework (`NetworkLineConnection`, lines up to 4 MB), `SessionState` (the rules, plain state and effects), `Session` (an `@Observable` façade that runs them on an injected `LineConnector` and `SessionClock`), and the view models `ShellViewModel` and `StatusViewModel`. macOS and iOS. |
| `BlockViews` | SwiftUI for a page's blocks, in Prism, Eyra's design system: its Swift package (github.com/novasoftwarefoundation/prism-swift, exactly 0.7.0, the first with macOS; so the app needs macOS 26) gives the tokens and the `Tag`, `Button`, `StepIndicator`, `MessageBar` and spinner; `Prism.swift` keeps only what Atlas lays on top (the page's measure, Atlas's cards), and dark appearance, which Prism has no tokens for yet, only `PrismDarkGap.swift`, until Prism has them). No button or line shows a key: the menu bar's Actions menu lists the shown page's actions with their keys, and every button's and toolbar item's tooltip is Control's `help`, else its label (`Tooltip`, contract 0.41.0). It shows `list` rows (a row opens its `to`), `item` cards, `panel` blocks where the owner decides (`PanelView`: to accept, to merge; the heading and title in the same bar, the byline with ages, the items with the selected one's details, checks as ✓ ✗ … —, the box, the answers as a yes and a no with a note; each answer is the page's action of its key, its links open by key), the simple blocks a page is stacked of (`SimpleBlockViews.swift`; a to-do's page and a decision's are): a `header` on the page itself, in place of the page's title (its eyebrow and key in small caps over the title, the page's actions beside it), a `text` under it (the intro paragraph without a label, "… · 3h ago", the age kept current; with role `error`, what went wrong, as Prism's `MessageBar` in danger, its label as heading), each `instruction` in a calm card of its own, shown in full (its number as Prism's `StepIndicator`, its text, its routes as parts with ›, each command in a light inset with a copy icon right after it, `Clipboard`, the general pasteboard), each `option` of a decision in a calm card of its own, as tall as its text (its number as a step's, none on the only proposal, its text, its badge in its tone, its fields at the card's full width, each a section with its label as a subtitle and its text in full under it: Rule, then Consequences, a field without a text showing none (`Option.fields`: an alternative its proposer has not worked out yet has only its title); its number as Prism's `StepIndicator`, its badge as Prism's `Tag` in its tone; its own answer as Prism's `Button`: the recommended Choose `primary`, another `secondary`, none on the only proposal (`alone`, which the page's Accept answers); no button label says what follows its click (no `…`, no `· note`: Control's `button` when its label has one); `Option.action`, the page's action of the answer's key, which its key takes too, the recommended one's also on `0`), `answers` as Prism's buttons in Control's order by their weight (`main` `primary`, `decline` — `no` before contract 0.38.0 — `secondary`, the rest `plain`; Accept and Decline under one proposal, Decline all under alternatives as a quiet `plain` button with `xmark.circle`), each the page's action of its key, one asking a note opening the note form on click, each answer's `detail` small under them; on the opened item only the main answer and the decline (`AnswersView.shown`): its answers of weight `other` (Ask a question, Hand over, Leave it to the proposer, Pick up) are in the window's toolbar after its actions (`PageActions.toolbar`), taken as their keys take them; `actions`, what else can be done with the page's subject (Update, Hand to, Failures…, Delete): the opened item's not on the page (its title has the full width) but in the window's toolbar at the right (`ItemToolbar`, `PageActions.toolbar`: its actions, Update first, then its `other` answers in Control's order, Delete last, at the same spacing; each its SF Symbol in the primary colour, Delete's in the danger colour; Update and Delete their icon alone, every other its short label beside it (`PageActions.iconOnly`), whatever the toolbar's display setting; its tooltip Control's `help`, else its label (`Tooltip`)), in the page's context menu (`ItemActionsMenu`) and in the Actions menu; elsewhere (a sheet) quiet icon-only buttons in the primary colour, Delete last, a little apart, in red; the page's details (a part of role details) in a recessed grey card under the rest, without a title of their own when Control sends none; and actions as buttons in Control's order (the first prominent): a block's own under the block, the page's (`page: true`) with the page's title (`PageActions.ofPage`). `ActionPageView` shows an action's page: a `confirm` (Confirm, Cancel), a `form` (text, multiline, choice and read-only inputs, Control's errors, Save with ⌘S, Cancel; an input with `shown_when` shown, required and sent only while the input it names holds that value, a required choice without a value as radio buttons with none chosen, each choice's `help` its tooltip, Save disabled until every shown required input has a value). `PlanView` shows the steer agent's plan (keep or drop steps, Run, Cancel, Stop, Close). What the user did and Control has not answered yet (`SessionState.Pending`) marks its button and the sheet at once. Other blocks show plainly in their place (an unknown type: its title or label and its texts, `Fallback.plain`; D-0105), every property read as optional. A page's top-level `section` markup groups its blocks: a collapsible one is a disclosure, folded by default per page path; other markup, or markup that is not one tree, leaves the blocks flat. macOS and iOS. |
| `AppUpdate` | The app's update from the release feed (IS-Atlas-66), no UI: `InstalledApp` (the release a bundle's `Info.plist` names), `AppRelease` (the feed's entry), `UpdateDecision` (a later build is taken; the same or an earlier one is not; when Control's welcome says a newer contract and the feed has no later build, it waits for that release; an unreachable feed is said), `UpdateStatus` (the status bar's texts, such as `Updating to <revision>…`), and `Updater` (asks at start, every 10 minutes, and every minute once Control is newer; takes a release only while no form or confirm is open), on an injected `ReleaseFeed` and `ReleaseInstaller`. Foundation only. |
| `AtlasMac` (`Mac/`) | The macOS app: three columns (tabs from `boot`, the tab's index page, the opened page), only the page's title in the title bar; the viewer's name, the environment and the connection in the sidebar's foot (production as a small Prism danger tag; another environment plain) on one line with the short state ("● Connected"; not connected: a red warning sign), whose popover (click) holds the plain words, the last notice and the technical details; no status bar; `⌘1`–`⌘9`. The index page's own actions (Create to-do) are in the list column's toolbar above the list, as quiet icons (`PageActions.listToolbar`: a `+` in the primary colour, its tooltip Control's `help`, else its label; no toolbar item is a prominent capsule); the opened page's are next to its title at its top; what else can be done with the opened item (its `actions` blocks and its answers of weight `other`: Update, Ask a question, Hand over, Leave it to the proposer, Hand to, Failures…, Delete) is in the toolbar at the right, its page's bottom keeping only the main answer and the decline; it follows the item open (none when nothing is) and is in the page's context menu and the Actions menu too. An action's page (or any page with a form or confirm) is a sheet over the columns; when Control stores it the sheet closes and the stored page shows. The keys Control gives the shown page's actions take them (a decision's options on their answers' keys, the recommended one on `0` too), whichever column has the focus. From the click or key until Control answers, the action shows that it is pending: its button, the sheet, and the status bar ("Sending “Pick up”…"). A submit that Control answers with only a notice also ends: `ok` closes the sheet, `error` leaves it open and says why. An `agent:<intent>` action has its button and key, and asks the steer agent about its page, as the TUI does (`atlas steer --env <env>` as a child process, found through `ATLAS_ROOT`, the checkout above the app, or `atlas` on the `PATH`; stderr goes to `steer.log`). Its plan is a sheet over the window. A release updates itself: `BundleInstaller` downloads the newer release, checks its digest and its signature against this app's designated requirement, swaps the bundle and starts it again on the page shown (`--to`). |

Slice S1 of the design. Later slices add pages, history and the cache (S2), markup (S3),
forms (S4), `ConsoleKit` (S5), `WorkerViews` (S6), the agent (S7), and the launcher with an
Xcode app target and signing (S8). The macOS app is built as a SwiftPM executable;
the small local development bundle helper below provides Finder/Dock launch before S8.

## Build, test, run

```
swift build                                  # against the published contract version
swift test                                   # unit tests; ControlIntegration is skipped
xcodebuild -scheme ControlSession -destination 'generic/platform=iOS Simulator' build
swift run AtlasMac --env test --host 127.0.0.1 --port <Control port>
```

`swift test` reads the product's description (`ShellTabsTests`): run `bin/generate model`
from the repository's root first. A branch whose contract version is not published yet
builds against the package generated from its tree: run `bin/generate atlas`, then build
with `ATLAS_SWIFT_PACKAGE=../../atlas_control/backend/targets/swift` (CI's `apple` job does).
`tools/atlas_swift.py` prints the contract version (`version`) and publishes the package
(`publish`, CI's `deploy-swift-package`); its tests: `python3 -B tools/test_atlas_swift.py`.

The app connects only where its launch arguments say (`--env`, `--host`, `--port`, and
optionally `--reconcile-seconds`); without them it says how to start it. It says hello as
`client: "tui"`, the name Control gives the person's console.

## Releases

Each merge to master publishes a signed `Atlas Console.app` at its revision, and installed
apps update themselves from it. CI's `deploy-mac-app` does this with
`tools/package_release_app.py`, which writes the bundle (`bundle`) and the feed (`feed`); see
[docs/guides/prod.md](../../../docs/guides/prod.md), "The Mac app". When started without
launch arguments, a release connects where its bundle says (`AtlasControl`: prod,
127.0.0.1:7593). Tests of the packager: `python3 -B tools/test_package_release_app.py`.

## Local development Finder/Dock bundle

On the laptop, consume the current reviewed S1 `AtlasMac` already built with
`swift build --product AtlasMac`. From this directory, pass its actual binary path and
the existing source/build provenance file (exact source revision, reviewed candidate
digest and build provenance). The helper does no build, installation or app launch:

```sh
python3 tools/package_local_app.py \
  --binary '/absolute/path/to/already-built/AtlasMac' \
  --provenance '/absolute/path/to/source-build-provenance.txt' \
  --output '/absolute/path/to/staging/Atlas Console.app' \
  --env prod --host 127.0.0.1 --port 7593
```

For this candidate the source is develop
`rev_1c5df9c8b4dc337e8c8290a83e7f927e87d9064730f90519b2f588543bcdfdba`,
snapshot `57f038dc916f262b4e1015dde5e5cde00b79b124b343aff4b104b887f54d356e`,
plus the independently reviewed 32-path Apple S1 delta
`376d8e5545f57f22a1dd357d441e47f53d851c43e3653d2e4bbfffb10f5d3f76`.
The supplied provenance is copied verbatim; the helper records its digest, the binary
digest and the configured argv in `Contents/Resources/LocalPackaging.json`.
`--info-plist '/path/to/existing/Info.plist'` preserves existing public metadata,
replacing the executable entry and marking local development. Otherwise the helper
uses local-only identity `local.atlas.console`, with no invented release version.
It does not fetch signing identities, resources or dependencies. The current SwiftPM
target has no packaged resources; its product modules are statically linked. Confirm
the supplied binary is ARM64 and `otool -L` lists only system libraries/frameworks
before delivery; this helper does not bundle external libraries.

The output path must not exist. The bundle contains an unchanged copy of the supplied
binary and a tiny shell `CFBundleExecutable` that locates it relative to itself and
executes it with the explicit configuration. Normal Finder/Dock launch needs no
additional arguments. Extra launcher arguments are ignored, so they cannot override
the packaged endpoint. Configuration is transparent in the launch entry and JSON;
there are no credentials, preferences or endpoint fallback.

After independent review, the coordinator can ad-hoc sign and verify the staged
bundle with `codesign --force --sign - '/path/to/staging/Atlas Console.app'` and
`codesign --verify --strict --verbose=2 '/path/to/staging/Atlas Console.app'`.
The coordinator then copies that bundle to `~/Applications/Atlas Console.app` on the
laptop and opens it in Finder (or pins it to the Dock). Replacing an existing bundle
and handling any running instance remain coordinator actions. The existing localhost
7593 tunnel must already be available; this helper does not manage it. This is a local
development package, with no distribution identity or release claim.

### Updating the laptop's local bundle

`tools/update_local_app.py` is the replacement for the existing
`~/.local/bin/atlas-console-update` invoked by `local.atlas.console-update` every ten
minutes. It does not install or start a service. The old updater does not share a lock
with this one, so an idle check followed by replacement cannot rule out a launchd
start between those operations. Safe migration requires the coordinator to prevent
new old-updater launches, wait for an existing invocation to exit normally, then
atomically replace the executable and restore the existing schedule. This change
does not perform that service operation. Until migration the old updater remains
active and can forcibly quit Console.

The updater requires the existing signed local bundle and its recorded commit and
endpoint, fetches master into a disposable clone, refuses non-descendant revisions,
and requires a successful production gate for that exact revision, no failed or
cancelled jobs except a failed Mac publishing job, and either a successful tested-tree
record job or CI's unexpired trusted artifact for that exact Git tree. Thus a missing
distribution signing identity is not needed locally, but unexplained skipped tests do
not qualify. These gates are release signals, not proof of independent review. It
generates the model, runs Swift tests, builds the release binary, signs and verifies a
staged copy, and checks
master and the installed bundle again before an atomic exchange. It preserves the
bundle identifier, launcher, endpoint and other contents. The previous bundle remains
in a uniquely named hidden folder in Applications as `previous-bundle` (without an
`.app` extension); it is not automatically deleted. On an interrupted or failed
exchange, staging is retained as `uninstalled-or-previous-bundle` (or, if its rename
failed, `Atlas Console.app`) because it may contain the original. No credentials are
bundled.

It never quits or reopens Console: while it is running, the updater defers until the
user quits normally, so an open form or confirmation is not interrupted. A concurrent
launch at the exchange can continue using the retained old bundle. Failures exit
nonzero and are logged by the existing launch agent to
`~/Library/Logs/atlas-console-update.log`; GitHub API/network, Xcode, Swift, model
generation and a successful CI gate are required. It neither starts nor changes the
prod tunnel. Isolated fake-build, real-signature and atomic-exchange smoke:
`python3 -B tools/test_update_local_app.py`.

Private helper/launcher regression (no Swift app, GUI or Control connection):

```sh
python3 -B tools/test_package_local_app.py
```

The regression packages an argv-recording shell stand-in, relocates the bundle to a
path with spaces, and executes its actual plist-selected launch entry. The fixture
is deleted afterward and is never a delivered product executable. It also checks
metadata/provenance, binary digest, exit status, invalid configuration and overwrite
refusal. These checks establish argument forwarding, not visible-window or live
handshake acceptance.

Against a real Control (§7): `bin/atlas-dev e2e apple-control` starts a private instance and
runs `swift test --filter ControlIntegration` here with `ATLAS_ENV_FILE` set to its settings.

Current source integration (2026-11-16) uses the generated contract 0.16.0 unchanged.
Confirmations without an available action remain known fallback blocks and retain the
session's editing guard; restart handling is outside S1. Direct Swift 6/native XCTest,
shared iOS library compilation and private Control evidence live in the assignment's
`delivery-evidence/` outside the product tree. The private proof uses actual Control with
synthetic data and downstream FakeStore/FakeFlow stand-ins. Full deployment, SwiftPM/CI
execution, macOS visual/menu acceptance and iOS app execution remain open gates; see the
design's S1 acceptance note. Source readiness is not release or visual acceptance.
