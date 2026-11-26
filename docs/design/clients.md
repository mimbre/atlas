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
release feed). The shell is shown in the **status line** (the Mac's status bar, the TUI's
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
| Sidebar: the tabs, their counts and groups | fixed, about 240 pt | 24 cells, from 290 columns (else the tab bar) |
| List: the tab's rows | fixed, about 360 pt | 60 cells |
| Page: the item's main blocks | at most 720 pt (100 characters of the body font) | at most 100 cells |
| Details: the page's details group | 280–480 pt, growing with the room | 40–100 cells, growing with the room |

What gives way as the room narrows, in this order:

1. **The sidebar.** TUI: below 290 columns the tabs move to the tab bar (from 210 with a
   row of the active tab's groups and counts under it). Mac: the sidebar stays until
   step 3.
2. **The details** go under the main blocks. Mac: beside while the page's column holds
   720 + 280 pt (a window of about 1600 pt), else as a recessed card under the page.
   TUI: beside from 210 columns (from 140 in one column), else as the page's last blocks.
3. **The list.** Mac: below a window of 1080 pt the split view folds its sidebar into the
   sidebar toggle (macOS's three-column split view cannot hide its middle column). TUI:
   below 144 columns, one column at a time (Enter opens the page, Esc returns).

Below 80 columns a TUI row keeps its dot, key and title only. Chrome (title bar, toolbar,
status and key lines) is not a column and takes the full width. Text wraps at its
column's width.

Where the rule lives: `AtlasTui.Columns` (applied by `AtlasTui.View` and
`AtlasTui.ConsoleView`); `WindowLayout` in BlockViews (applied by `PageView` and
`ShellView`). Tests: `AtlasTui.ColumnsTest`, `AtlasTui.ColumnsSidebarTest`,
`AtlasTuiTest`, `PresentationTest`; `WindowLayoutTests`.

## 5. Block roles

| Role (block) | Mac renders | TUI renders |
|---|---|---|
| Title / eyebrow (`header`) | On the page, no card: eyebrow and key in small caps in the accent's text colour (`TO DO FOR YOU · TD-12`), the title as the page title; the page's own actions beside it | Eyebrow with the key (`◆ YOUR DECISION · D-0104`) bold in the eyebrow colour, title under it |
| Why / text (`text`) | On the page, muted: `Why: … · 3h ago`, its age kept current | Dim paragraph after its label, with its age |
| Option (`option`) | A calm card: number as Prism's `StepIndicator`, text, badge in its tone (★ Recommended success), Rule/Then rows, its own Choose as a Prism button (recommended `primary`, others `secondary`); none when `alone` (Accept answers it) | A filled card (selected one on the selected surface, marked ▸): number, text, badge, fields, then its answer on its key |
| Step (`instruction`) | A calm card per step, number in a badge, lines in order | A filled card per step, numbers aligned, lines in order; text bold |
| Command (in a step) | A light inset with a copy icon after it | Plain behind a bar; the selected one highlighted (`c` copies, `y`) |
| Route (in a step) | Muted ⌘, parts as small labels with › between | Muted ⌘, parts bold in the route colour |
| Answers (`answers`) | A Prism button per answer in Control's order by its weight: `main` `primary`, `decline` `secondary`, others `plain`; labels say nothing of what follows (no `…`, no `· note`); a `detail` small under the buttons | The key line: each answer on its key, the main one and the decline in the primary colour, a note answer `· note`; a `detail` dim under it |
| Other actions (`actions`) | One row of `plain` buttons, unpadded, quieter than the answers; a dangerous one opens Control's confirm | In the answers' key line, muted, after the answers (else a key line of its own) |
| What went wrong (`text` role `error`) | Prism's `MessageBar` in danger: label as heading, text under it | A card, label as a heading in the error colour over its text |
| Details (part `details`/`related`) | Own column, or a recessed card (grey5) under the page | Own column, or a compact card under its heading at the page's end |
| Row card (list row) | A small card: kind and key in small caps (`DECISION · D-0104`), state, title on at most a few lines | One line: dot, key, age, title (state dropped below 80) |
| Status dot / age (row `tone`, `since`) | Dot in the tone's colour with its meaning in words (tooltip/accessibility); age as `15d`, `6h`, `46m`, `today` | Dot before the key in the tone's colour; age column in the same compact form |

Tones (Control decides, the client only shows): red needs the viewer, orange under way,
blue planned or waiting, green done. An unknown tone is no dot.

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
  text style and no size of Atlas's own (`TypographyTests` keeps it so). Things are as
  large as Prism makes them; a **macOS density** is a pending Prism change, which the Mac
  takes when Prism ships it (Atlas keeps no smaller scale of its own).

| Role | Prism typography (Mac) |
|---|---|
| Page title (`PageHeader`, a sheet's title) | `title6` |
| Panel, option, list, item and section titles | `title7` (section `label`) |
| Eyebrow, in small caps (`TO DO FOR YOU · TD-12`) | `labelsmall` |
| Running text (a plan's text, a block said in plain words, an error) | `bodysmall`, the body font (Layout A's measure) |
| Meta lines (why, byline, a step's text, "Sending…", details) | `caption`; a row card's top line and age, the status bar: `captionsmall` |
| Labels and data (a row card's title, a field's label; a panel's rows, checks) | `labelsmall`; `tablerow`, the selected row and a check's name `tablehead` |
| Sidebar tabs and their groups; the sidebar's headings, counts and foot; the environment in the title bar | `label`, groups `labelsmall`; `captionsmall` (a count's strong), the name `labelsmall`; `caption` (production `labelsmall`) |
| Commands | `mono`, in the system's monospaced face |

Prism gaps, and where Atlas's temporary shims live:

| Gap | Shim |
|---|---|
| No dark tokens | Mac: `PrismDarkGap.swift` (the one place a colour depends on appearance); TUI: the dark theme in `palette.ex` |
| No card surfaces | TUI: `palette.ex` `@card_surfaces` (card, card selected, per theme); Mac: `PrismDarkGap` (calm, raised, recessed cards) |
| Success and warning too faint as text on white | TUI: dark text on warninglight in light; Mac: the badge as Prism's `Tag` in its tone |
| White on primary is 4.30:1 | `primaryshade` (primary at 97%, 4.51:1) in `palette.ex`; `PrismDarkGap.accentText` on the Mac |
| Plain button's size and dark label | Mac: other actions as unpadded plain buttons, label in `PrismDarkGap.text` in dark (`PrismDarkGap.buttonStyle`) |
| `mono` names the system (proportional) font | Mac: commands (and a panel row's key, a fallback's type) in the system's monospaced face at Prism's size (`.monospaced()`) |
| No macOS density: Prism's sizes are iOS's and the web's | Mac: Prism's sizes as they are, until Prism's macOS density |
| No typography for native controls | Mac: the system's control font on the native controls (sheet and toolbar buttons, form fields, pickers, toggles, disclosure, window title, menus) |

Delete each shim when Prism ships the token.

## 7. Actions

Control sends each action's **label**, its **weight** and its **key**; a client decides
nothing about an action, only how it is triggered.

| Weight | What it is | Mac | TUI |
|---|---|---|---|
| Main answer | the first of `answers` (or an option's Choose): the next step | `primary` button (success) | key in green |
| Decline | weight `decline` (`no`, deprecated): Won't do, Decline, Decline all | `secondary` button; one with `note` opens the note form on click, its label unchanged | key in the primary colour, `· note` when it asks one |
| Other action | the `actions` block: change, hand over, delete, create under | `plain` button, quieter | muted in the key line |

- **Mac**: buttons on the page, and the menu bar's **Actions** menu lists the shown page's
  actions with their keys. Keys are invisible on the page (a button's tooltip names its
  key) but work whichever column has the focus. A pending action shows a spinner on its
  button.
- **TUI**: the **key line** under the page names each action on its key, in Control's
  order, with the keys of the column that has the focus.
