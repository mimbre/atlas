# Decide by selecting one option

New decisions ask a short question and offer concrete alternatives. Choosing an
option makes the decision. An `adopt` option applies only its exact `rule` and
`consequences`, using the existing decider authority. A `decline` option adopts
nothing. Recommendations and labels never grant permission. Adoption alone starts
existing supersession and follow-through. Classification and supersedes links on
the decision apply to all its adopting options; author the set under that authority.

Create a decision through the existing CLI or creation form. Supply `options` as
JSON; `--options-file` reads it from a file. The private example at
`products/software_factory/e2e/fixtures/decision-options.json` shows the complete format. Each option has a
distinct stable lowercase ID, exact text, details, explicit effect, rule and
consequences. Decline has empty rule and consequences. There must be one
`recommended` ID, first in the options array, and a short `rationale`.
The definition contains at least two alternatives, at least one of them a
decline, and exactly one selection. Like the a/f Reject, a decline is given with
a note saying why: its key opens a form that asks for the note.

```sh
atlas put decision --env test --title 'Example storage' \
  --decision 'Choose how to store this example' \
  --options-file /path/to/options.json --category product \
  --scope software --reversibility two_way --force direction
```

The example command creates a proposal; it does not select anything. In the TUI,
the recommended alternative is choice 1, followed by the remaining alternatives.
`0` submits the same semantic answer as `1`; it is never a stored alternative.
When the recommended alternative is a decline, `0`, like `1`, opens its note form.
`2` and `3` choose the second and third alternatives. Invalid numbers, displaying
the recommendation and waiting do not decide. Numeric shortcuts are active only
while browsing; digits remain text in editing contexts. Tabs use Tab/Shift+Tab.
When a page supplies multi-digit shortcuts, type the complete number and press
Enter; Esc cancels the pending number. No timeout submits it.

`options` is one authoritative Facts value owned by its decision. An answer stores
`selected_option`, the exact `selected_definition`, and `selected_revision` together
with existing decided_by/decided_at evidence. Its revision covers the definition
and presented authorization content, including supersedes targets. Editing an
unanswered proposal invalidates old semantic answer calls. Facts independently
checks snapshot membership, revision, typed effect and actor authority, including
direct writes. An answer cannot change its offer or classification while selecting.
An answered definition and selection cannot be rewritten, including after decline.
Accepted decisions keep the existing permitted no_work, tally and supersession
maintenance without changing what was offered or chosen.

No option entities, parallel database or new event stream are introduced. Facts'
existing retry ledger retains acknowledgements rather than complete old values.
`option_history` therefore retains prior complete offer revisions on the decision,
derived in the same Facts write; callers cannot replace this history. The selected
snapshot is also present on the decision itself and survives reload.
Options are optional. A decision created without them, and every historical
decision, keeps its existing rule, status and a/f answers without invented
alternatives or selections.

The native model's semantic answer IDs include the displayed revision and stable
option ID. Control shows the offer as a stack of simple blocks (D-0104): a
`header` (YOUR DECISION, the key, the question), a `text` (Why: the rationale),
then one `option` block per option in order, the recommended one first: its
number, its text, a badge (`★ Recommended`, or `Decline · note` for an option
given with a note), its Rule and Then (a decline: its Details) and its own
answer, the page's action on the option's key (Choose, or Decline… which opens
the note form). A radio, dropdown or cards renderer can use the same answers
without a model, schema or Flow change. Keyboard shortcuts are projection data.
The TUI invokes a generic declared call and does not recognize decision kinds or
interpret option effects. It draws each option as a filled card (rounded with
half blocks, no lines; without truecolor, a left bar ▌), the selected one on a
primary-tinted surface and marked ▸; ↑/↓ select an option, starting on the
recommended one, and never answer; Enter answers the selected one exactly as its
key does, so a decline still opens its note form. The Mac shows each option as a
card with its own button.

The single-choice mechanism in `products/software_factory/model/generator` (`RelaDSL.DecisionOptions`) is generic:
it knows no decision fields, statuses or wording. A kind passes them in with its
`decision_options` annotation, which `products/software_factory/model/contract/foundation/decision.ex` gives
for decisions. Next to the fields holding the definition, selection, snapshot,
revision and history, the annotation gives `adopt` (which option payload goes into
which field: `rule` into `decision`, `consequences` into `consequences`),
`answered_at` and `answered_by` (`decided_at` and the `decided_by` relation),
`status` (the status field, its open, adopt and decline values, and which statuses
may still become superseded), `content` and `content_links` (the fields and
relations an offer revision covers), `legacy_fingerprint` (the gate fingerprint
that decisions without options keep matching) and `errors` (the wording of the
refusals; the DSL has neutral fallbacks).

Private native acceptance is `products/software_factory/e2e/decision_choices_native.exs`, run from
`products/software_factory/model/contract` with the supported Elixir and `mix run --no-start`, the assigned
private scratch path and prepared Rela bin directory. It creates only private
fixture actors/data. Read its current delivery evidence for execution status;
source code alone is not evidence of a passed terminal/persistence proof.

Some pages where the owner decides also carry a `panel` block, declared per state
by the kind's `panel(...)` rule; Control fills it and names no kinds. ◆ TO ACCEPT
(a use case or scene in accepting) lists what is to be built, with What / Done /
Needs per item. ◆ TO MERGE (an issue in merging) shows CI, the review's verdict and
GitHub's state, with only the keys the page has (open on GitHub, full review).
Every answer is one of the page's existing actions with its own key; Not
accepted is `n`, and a no answer opens the note form. Stuck work (a panel with
`choose`) is no panel but the same stack as a decision: YOUR DECISION and its
title, the task, the failed attempt and how long it has been stuck, the recorded
failure in a "What went wrong" text with role error (Mac: a red-tinted card; TUI:
a card, its heading in the error colour), then each answer as an `option`, the
first recommended, with what it does (Then), and the agent's log among the other
answers.
