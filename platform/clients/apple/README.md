# Apple clients

Hand-written Swift for the macOS app (and later iOS), as
[docs/design/apple-clients.md](../../../docs/design/apple-clients.md) describes. The contract
is the generated package `AtlasControlKit` (`platform/atlas_control/backend/targets/swift`), used by path; nothing
here is generated, and nothing here knows a kind, a relation or a flow: the app shows what
Control's `boot` and pages send.

| Target | What |
|---|---|
| `ControlSession` | The session with Control, no UI: `LineConnection` on Network.framework (`NetworkLineConnection`, lines up to 4 MB), `SessionState` (the rules, plain state and effects), `Session` (an `@Observable` façade that runs them on an injected `LineConnector` and `SessionClock`), and the view models `ShellViewModel` and `StatusViewModel`. macOS and iOS. |
| `BlockViews` | SwiftUI for a page's blocks, in Prism's styling (`Prism.swift`, tokens copied from Prism @370696e7). It shows `list` rows (a row opens its `to`), `item` cards and `single_choice` blocks, and actions as buttons in Control's order (the first prominent, each with its key): a block's own under the block, the page's (`page: true`) with the page's title (`PageActions.ofPage`). `ActionPageView` shows an action's page: a `confirm` (Confirm, Cancel), a `form` (text, multiline, choice and read-only inputs, Control's errors, Save with ⌘S, Cancel), or more actions (More…). Other blocks appear as fallbacks with their type. A page's top-level `section` markup groups its blocks: a collapsible one is a disclosure, folded by default per page path; other markup, or markup that is not one tree, leaves the blocks flat. macOS and iOS. |
| `AppUpdate` | The app's update from the release feed (IS-Atlas-66), no UI: `InstalledApp` (the release a bundle's `Info.plist` names), `AppRelease` (the feed's entry), `UpdateDecision` (a later build is taken; the same or an earlier one is not; closed as too old with no later build, it waits; an unreachable feed is said), `UpdateStatus` (its texts: the status bar's `Updating to <revision>…`, and what the app says in place of Control's bare "too old"), and `Updater`, on an injected `ReleaseFeed` and `ReleaseInstaller`. Foundation only. |
| `AtlasMac` (`Mac/`) | The macOS app: three columns (tabs from `boot`, the tab's index page, the opened page), the title and environment in the title bar (production as the inverted badge), `⌘1`–`⌘9`, and the status bar. The index page's own actions are in the window's toolbar; the opened page's are next to its title at its top. An action's page (or any page with a form or confirm) is a sheet over the columns; when Control stores it the sheet closes and the stored page shows. The keys Control gives the shown page's actions take them, whichever column has the focus. A release updates itself: `BundleInstaller` downloads the newer release, checks its digest and its signature against this app's designated requirement, swaps the bundle and starts it again on the page shown (`--to`). |

Slice S1 of the design. Later slices add pages, history and the cache (S2), markup (S3),
forms (S4), `ConsoleKit` (S5), `WorkerViews` (S6), the agent (S7), and the launcher with an
Xcode app target and signing (S8). The macOS app is built as a SwiftPM executable;
the small local development bundle helper below provides Finder/Dock launch before S8.

## Build, test, run

```
swift build
swift test                                   # unit tests; ControlIntegration is skipped
xcodebuild -scheme ControlSession -destination 'generic/platform=iOS Simulator' build
swift run AtlasMac --env test --host 127.0.0.1 --port <Control port>
```

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
