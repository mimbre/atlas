# Clients: one design

**One design, two ways of interacting: buttons on the Mac, keys in the TUI.**

The macOS app (`platform/clients/apple`) and the TUI (`platform/clients/tui`) show the same
pages from Control, laid out by the same rule, in the same colours, with the same actions.
They differ only in how a person acts: the Mac with the mouse and buttons, the TUI with
keys. This document is the design both follow, as built (PRs #643–#651, D-0104, D-0105).
Platform specifics stay in [apple-clients.md](apple-clients.md) (the Mac and iOS) and in
`AtlasTui.Columns`'s moduledoc (the TUI's cells and focus keys).

## 1. Shell and content

What a client knows without Control is **shell**: the connection (connecting, connected,
retrying every 2 s), its own contract version and Control's, the tunnel `bin/atlas` opens,
and self-update (the TUI started by `atlas` takes the newest build; the Mac app reads its
release feed). The shell is shown in the **status line** (the Mac's sidebar foot, the TUI's
status line), never in the content area.

Everything else is **content**: tabs, counts, pages, blocks, actions, their labels and keys
all come from Control (`boot`, `open`, hints). A client has no tabs, labels or semantics
of its own. Without content (before `boot`, after a failed `open`) the content area stays
empty and the status line says why.

## 2. Block pages (D-0104)

A page is a stack of simple blocks, in Control's order; a client draws each block by its
type and role and does not compose pages itself.

- **List pages** are rows: one row block per item (the tab's list, a group's list).
- **Item pages** are the item's **main blocks** (header, why, options or steps, answers,
  other actions, what went wrong) plus **groups**: the details (a `part` of role
  `details`, or `related`), which a client places by room (§4): beside the main blocks
  when there is room, under them when not.

A decision, a to-do's steps and stuck work are such stacks (`header`, `text` id `why`,
`text` role `error`, `option` / `instruction`, `answers`, `actions`); see
`platform/atlas_control/backend/README.md`.

The **Machines** tab (contract 0.43.0; Runtimes in the code) is such a stack when there is
one machine: its page is the tab's page (`header` MACHINE · its key, the state line,
Health, Slots, Queue, Recently finished, Upgrades, Edit configuration in the toolbar and
Details). Desired but unverified slots and an unavailable queue are marked unknown. If
attempts cannot be read, slot activity and recently finished work are unknown, not empty.
Recently finished includes lost attempts even when boot repair could not establish an end time;
these sort after dated attempts and have no invented timestamp or duration. A recent poll is
**Seen**, not proof the Runtime is open; the first observation is relative to current health
tracking, which can restart separately from the core. Unavailable Flow or upgrade facts make
its state unknown. Unavailable upgrade facts also make the upgrade list unknown and prevent an offer
or confirmation. Machines offers an upgrade only when the core's candidate build is published and
proven newer than the installed build, and no upgrade is underway. Page renders cache this
proof for five minutes and globally limit new pair checks to one per 150 seconds to protect
the unauthenticated GitHub quota. A throttled or expired proof is unknown, never stale success.
Submit requires Workers submit authorization and fresh proof and fact reads, and fails closed
when these are unknown. A client shows a tab page with a `header` as an
opened page, without a list column. With more than one machine the tab is a simple list
of them for now; the compact overview per machine, grouped, comes
when a second Runtime exists.

## 3. Tolerant clients (D-0105)

Since contract 0.33.0 Control welcomes a client of any version and says its own.

- A client reads every block property as optional: a missing or mistyped one is left out,
  never a crash. It skips markup it does not know.
- A block of a type it does not know shows plainly: its title or label and its texts.
- A version difference is a warning in the status line (shell, §1): the TUI says
  `prod speaks 0.34, this TUI 0.33 · updating`; the Mac app
  `prod is newer (0.34 vs 0.33); some parts may look plain`. The client keeps working
  while it updates.
- What a client sends is checked by Control as before.

## 4. Layout A

Columns are anchored from the **left**, each right after the one before: no centring, no
gutter between them. Room left over is only at the **far right**, after the last column.

| Column | Mac | TUI |
|---|---|---|
| Sidebar: top-level tabs and their counts | fixed, about 240 pt | 24 cells, from 290 columns (else the tab bar) |
| List: the tab's filters and rows | fixed, about 360 pt | 60 cells |
| Page: the item's main blocks | at most 720 pt (100 characters of the body font) | at most 100 cells |
| Details: the page's details group | 280–720 pt (as wide as the page at most), growing with the room | 40–100 cells, growing with the room |

What gives way as the room narrows, in this order:

1. **The sidebar.** TUI: below 290 columns the tabs move to the tab bar. Filters
   stay on the list at every width: bracketed labels and counts, a coloured `•` on the
   active filter, and `[` / `]` keys for previous / next.
   Mac: the sidebar stays until step 3.
2. **The details** go under the main blocks. Mac: beside while the page's column holds
   720 + 280 pt (a window of about 1600 pt), else as a recessed card under the page.
   TUI: beside from 210 columns (from 140 in one column), else as the page's last blocks.
3. **The list.** Mac: below a window of 1080 pt the split view folds its sidebar into the
   sidebar toggle (macOS's three-column split view cannot hide its middle column). TUI:
   below 144 columns, one column at a time (Enter opens the page, Esc returns).
   The originating tab stays selected; an opened page shows a breadcrumb from its
   navigation history beneath the tab bar.

Below 80 columns a TUI row keeps its icon, key and title only. Chrome (title bar, toolbar,
status and key lines) is not a column and takes the full width. Text wraps at its
column's width.
The focused TUI column has a primary-colour heading and a ▸ marker in both themes.

Where the rule lives: `AtlasTui.Columns` (applied by `AtlasTui.View` and
`AtlasTui.ConsoleView`); `WindowLayout` in BlockViews (applied by `PageView` and
`ShellView`). Tests: `AtlasTui.ColumnsTest`, `AtlasTui.ColumnsSidebarTest`,
`AtlasTuiTest`, `PresentationTest`; `WindowLayoutTests`.

## 5. Block roles

| Role (block) | Mac renders | TUI renders |
|---|---|---|
| Title / eyebrow (`header`) | On the page, no card: eyebrow and key in small caps in the accent's text colour (`TO DO FOR YOU · TD-12`), the title as the page title; the page's own actions beside it | Eyebrow with the key (`◆ YOUR DECISION · D-0104`) bold in the eyebrow colour, title under it |
| Intro / text (`text`) | On the page, muted, no label (the why is an intro paragraph): `… · 3h ago`, its age kept current | Dim paragraph (after its label when it has one), with its age |
| Option (`option`) | A calm card: number as Prism's `StepIndicator`, text, badge in its tone (★ Recommended success; `melle's alternative` neutral), Rule/Then rows (a field without a text shows no section: an alternative not worked out yet has only its title), its own Choose as a Prism button (recommended `primary`, others `secondary`); none when `alone` (Accept answers it) | A filled card (selected one on the selected surface, marked ▸): number, text, badge, fields, then its answer on its key |
| Step (`instruction`) | A calm card per step, number in a badge, lines in order | A filled card per step, numbers aligned, lines in order; text bold |
| Command (in a step) | A light inset with a copy icon right after the command, in the primary colour at the action icons' 16pt; after a copy a brief ✓, also primary | Plain behind a bar; the selected one highlighted (`c` copies, `y`) |
| Route (in a step) | Muted ⌘, parts as small labels with › between | Muted ⌘, parts bold in the route colour |
| Answers (`answers`) | A Prism button per answer in Control's order by its weight: `main` `primary`, `decline` `secondary`; labels say nothing of what follows (no `…`, no `· note`); a `detail` small under the buttons. On the opened item the page's bottom keeps only these (a Choose per card and Decline all, Accept and Decline, Done and Won't do): its `other` answers are in the window's toolbar (below); in a sheet they stay `plain` buttons with their icon | The key line: each answer on its key, the main one and the decline in the primary colour, without a `· note` suffix; a `detail` dim under it |
| Other actions (`actions`) | The opened item's in the window's toolbar at the right, never on the page, in this order at the same spacing: its actions (Update first), then its `other` answers in Control's order (each taken as its key takes it: its call, else its page or note form), then Delete last; each its SF Symbol (edit `pencil`, question `questionmark.bubble`, hand_over `person.and.arrow.left.and.arrow.right`, delegate `arrow.uturn.backward`, faults `exclamationmark.triangle`, …) in the primary colour, Delete's red; Update and Delete their icon alone, every other its short label too (Ask, Delegate, Hand to, Failures), whatever the toolbar's display setting; its tooltip Control's `help`, else its label. The same in the page's context menu and the Actions menu; none when nothing is open. Elsewhere (a sheet) one row of quiet icon buttons. A dangerous one opens Control's confirm | In the answers' key line, muted, after the answers (else a key line of its own) |
| What went wrong (`text` role `error`) | Prism's `MessageBar` in danger: label as heading, text under it | A card, label as a heading in the error colour over its text |
| Details (part `details`/`related`) | Own column, or a recessed card (grey5) under the page | Own column, or a compact card under its heading at the page's end |
| Row card (list row) | A small card: the kind's icon (grey; primary on the selected card while the list has the focus), kind and key in small caps (`DECISION · D-0104`) and age, the title on at most a few lines, the state under it on a line of its own; no status dot | One line: status-coloured kind icon, key, age, title (state dropped below 80) |
| Kind icon (row, `header`, `panel`, sidebar tab and group `icon`) | One SF Symbol per kind, the same everywhere (names what it shows, never the kind: `scales` for a decision `checkmark.seal`, `checklist` for a to-do `checklist`, `frame` `rectangle.stack`, `route` `list.bullet.rectangle`, `ticket` `smallcircle.filled.circle`, …); an unknown name draws none and keeps its place on a card | Filled glyphs for common kinds (`scales` `◆`, `checklist` `■`, `frame` `▰`, `route` `▲`); an unknown kind with a known tone uses a dot |
| Status / age (row `tone`, `since`) | No dot: the state line says it in words; age as `15d`, `6h`, `46m`, `today` | The kind icon carries the tone, including when selected; age uses the same compact form |

Tones (Control decides, the client only shows): red needs the viewer, orange under way,
blue planned or waiting, green done. An unknown tone uses the row's text colour.

## 6. Colours and type

- Every colour is a **Prism token** (Eyra's design system): the Mac through
  prism-swift (0.7.0), the TUI through `AtlasTui.Palette`'s copy of Prism's tokens.
- **Meaning never by colour alone**: a dot has its words, an error its label, a badge
  its text, a selection its ▸ mark.
- **Contrast**: text at least 4.5:1 on its surface; shapes (dots, frames, focus rings,
  column lines) at least 3:1. Where a token falls short, the client takes the nearest
  shade or the theme's text colour; the words still say what it is.
- Every text of the Mac's own views is in a **Prism typography**
  (`.prism(Prism.Typography.…)`), as Prism's components are: one type system, no SwiftUI
  text style and no size of Atlas's own (`TypographyTests` keeps it so). Atlas takes
  **one set from the smaller end of Prism's range**, the same on every page, list and
  sheet: nothing that acts or is copied (a button, a command) is larger than the text that
  explains it. A **macOS density** is a pending Prism change, which the Mac takes when
  Prism ships it (Atlas keeps no smaller scale of its own).

| Role | Prism typography (Mac) |
|---|---|
| Page title (`PageHeader`, a sheet's title) | `title6` (20) |
| Panel, option, list and item titles; a row card's title | `title7` (16) |
| Running text (why, a step's text, an option's Rule and Consequences, a plan's text and steps, a confirm's text, details values, a panel's rows and checks, a box, an error, a block said in plain words; a form's labels and text fields) | `bodysmall` (16/24), the body font (Layout A's measure) |
| Section and details headings | `title6` (20); aligned with their cards, and with the main content when alongside |
| Labels (a field's label, the selected panel row, a check's name, a plan step's name; sidebar tabs, the sidebar's icons) | `label` (16) |
| Eyebrows in small caps (`TO DO FOR YOU · TD-12`), a route's parts, a state chip; sidebar groups and the person's name (in the sidebar's foot) | `labelsmall` (14) |
| Meta lines (a byline, "Asked:", "By", "Sending…", an empty list; a row card's top line, age and state; the sidebar's foot: the assistant line under the person's name when Control sends one ("assistant: coordinator"), then on one line the environment (production as the plain word "Production", no tag; any other environment as a small Prism warning tag, its name capitalised: "Test") · the connection in plain words, the last notice in its popover) | `caption` (14) |
| The sidebar's section headings (WORK, BROWSE: eyebrows as a card's top line, uppercase, spaced, muted, more space above) | `labelsmall` |
| A count's badge in the sidebar | `captionsmall` (12), strong |
| Native buttons (a sheet's Cancel, Save, Confirm, Run; the page's and the toolbar's actions) | the system's control font: see the gaps |
| Prism's buttons (answers, options' Choose, Accept/Decline, other actions, the icon buttons beside a title, a sheet's Prism buttons) | Prism's `small` size (`buttonsmall`, 16; about 32pt tall), one size everywhere (`TypographyTests` keeps it so) |
| Commands (in a step; the launch hints) | `monosmall` (16/24, SF Mono), never larger than the step's text |

Prism gaps, and where Atlas's temporary shims live:

| Gap | Shim |
|---|---|
| No dark tokens | Mac: `PrismDarkGap.swift` (the one place a colour depends on appearance); TUI: the dark theme in `palette.ex` |
| No card surfaces | TUI: `palette.ex` `@card_surfaces` (card, card selected, per theme); Mac: `PrismDarkGap` (calm, raised, recessed cards) |
| Success and warning too faint as text on white | TUI: dark text on warninglight in light; Mac: the badge as Prism's `Tag` in its tone |
| White on primary is 4.30:1 | `primaryshade` (primary at 97%, 4.51:1) in `palette.ex`; `PrismDarkGap.accentText` on the Mac |
| Plain button's size and dark label | Mac: other actions as unpadded plain buttons, label in `PrismDarkGap.text` in dark (`PrismDarkGap.buttonStyle`) |
| `mono` named the system (proportional) font before 0.8.0 | Mac: a panel row's key and a fallback's type in the system's monospaced face (`.monospaced()`) |
| `Tag` has one size (28pt), too tall for a line of meta text; it needs a `size: small` as `Button` has | Mac: the sidebar foot's environment tag as `PrismDarkGap.smallTag` (Prism's tag look in its tone at `labelsmall`, less padding), until Prism's Tag has `size: small` |
| No macOS density: Prism's sizes are iOS's and the web's | Mac: Prism's smaller end, until Prism's macOS density |
| No typography for native controls | Mac: a form's labels and text fields in `bodysmall` (SwiftUI takes the font there); the system's own font where it does not: native push buttons (a sheet's Cancel, Save, Confirm, Run; the page's and the toolbar's actions), a picker's value and pop-up menu, the window title and subtitle, the menu bar and the Actions menu |

Delete each shim when Prism ships the token.

## 7. Actions

Control sends each action's **label**, its **weight** and its **key**; a client decides
nothing about an action, only how it is triggered.

| Weight | What it is | Mac | TUI |
|---|---|---|---|
| Main answer | the first of `answers` (or an option's Choose): the next step | `primary` button (success) | key in green |
| Decline | weight `decline` (`no`, deprecated): Won't do, Decline, Decline all | `secondary` button; Decline all under several alternatives (icon `decline`) a quiet `plain` button with a blue `xmark.circle`; one with `note` opens the note form on click, its label unchanged | key in the primary colour; its label stays unchanged when a note is needed |
| Other answer | weight `other`: Ask, Delegate (a decision, D-0106: its form chooses the proposer or another person), Pick up | the opened item's in the window's toolbar after its actions, its icon and short label; in a sheet a `plain` button with its icon | in the key line, in order |
| Other action | the `actions` block: change, hand over, delete, create under, Failures… (test only) | the opened item's in the window's toolbar, never a button on the page; its icon in the primary colour (dark: PrismDarkGap's readable primary), Delete red and last | muted in the key line |

- **Mac**: the main answer and the decline as buttons at the page's bottom; everything
  else for the opened item (its actions and `other` answers) in the window's toolbar at the
  right (and its context menu); a list's own actions (Create to-do) in the list column's
  toolbar above it, a quiet `+`. No toolbar item is a prominent capsule. The menu bar's
  **Actions** menu lists the shown page's
  actions with their keys. Keys are invisible on the page but work whichever column has
  the focus. Every action's and answer's button and toolbar item has a tooltip: Control's
  `help` (contract 0.41.0), else its label. A pending action shows a spinner on its button.
- **Mac forms** (contract 0.41.0): an input with `shown_when` is shown, required and sent
  only while the input it names holds that value; a required choice without a value starts
  with none chosen, as radio buttons, each choice's `help` its tooltip; Save waits until
  every shown required input has a value.
- **TUI**: the **key line** under the page names each action on its key, in Control's
  order, with the keys of the column that has the focus.
