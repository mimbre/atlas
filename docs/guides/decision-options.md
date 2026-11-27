# Decide by selecting one option

New decisions ask a short question and offer concrete alternatives. Choosing an
option makes the decision. An `adopt` option applies only its exact `rule` and
`consequences`, using the existing decider authority. Declining selects no option
and ends nothing (D-0106): it gives an alternative and sends the decision back to
its proposer (see [Decline, ask, hand over, leave](#decline-ask-hand-over-leave)).
Recommendations and labels never grant permission. Adoption alone starts
existing supersession and follow-through. Classification and supersedes links on
the decision apply to all its adopting options; author the set under that authority.

Create a decision through the existing CLI or creation form. Supply `options` as
JSON; `--options-file` reads it from a file. The private example at
`products/software_factory/e2e/fixtures/decision-options.json` shows the complete format. Each option has a
distinct stable lowercase ID, exact text, details, explicit effect, rule and
consequences. A `decline` option, which an older definition may hold, has empty
rule and consequences and is offered no answer: its text explains what declining
keeps. There must be one `recommended` ID, first in the options array, and a short
`rationale`. The definition contains at least one option to adopt (one proposal,
or alternatives) and exactly one selection; a decline is never demanded, as the
decider can always decline.

```sh
atlas put decision --env test --title 'Example storage' \
  --decision 'Choose how to store this example' \
  --options-file /path/to/options.json --category product \
  --scope software --reversibility two_way --force direction
```

The example command creates a proposal; it does not select anything. In the TUI,
the recommended alternative is choice 1, followed by the remaining alternatives.
`0` submits the same semantic answer as `1`; it is never a stored alternative.
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
A selected definition and selection cannot be rewritten. An offer back with its
proposer (`revising`, `answering`) is unanswered: its proposer may edit it.
Accepted decisions keep the existing permitted no_work, tally and supersession
maintenance without changing what was offered or chosen.

No option entities, parallel database or new event stream are introduced. Facts'
existing retry ledger retains acknowledgements rather than complete old values.
`option_history` therefore retains prior complete offer revisions on the decision,
derived in the same Facts write; callers cannot replace this history. The selected
snapshot is also present on the decision itself and survives reload.
Options are optional. A decision created without them, and every historical
decision, keeps its existing rule and status without invented alternatives or
selections; its decider has the same answers (Accept instead of Choose), and an
alternative given when declining it stays in its `alternative` field only.
Decisions that ended `rejected` before D-0106 stay so.

The native model's semantic answer IDs include the displayed revision and stable
option ID. Control shows the offer as a stack of simple blocks (D-0104): a
`header` (YOUR DECISION, the key, the question), a `text` (Why: the rationale),
then the options to adopt (contract 0.39.0). One proposal is one `option` card
(`alone`: no answer, badge or number on it, its Rule and Consequences in full) and below it an `answers` block: Accept (`main`, the
proposal's answer) and Decline (`decline`). Several alternatives are a card each, the
recommended one first: its number, its text, a badge (`★ Recommended`, or
`melle's alternative` on one a decider added when declining), its Rule and Consequences and
its own Choose (the recommended `main`, the rest `other`); below them Decline all
(`decline`). Decline is always offered and asks "What is your alternative?"; a
decline option of the definition is no card: its text is the Decline answer's
`detail`, shown with it. Then the quiet answers, each `other` with its `icon`: Ask
a question (`question`), Hand over (`hand_over`) and Leave it to the proposer
(`delegate`). Every answer sends exactly its option's answer. No Mac button says
what follows its click (no "…", no "· note"); the TUI's key line keeps "· note"
(`f Decline · note`). A radio, dropdown or cards renderer can use the same answers
without a model, schema or Flow change. Keyboard shortcuts are projection data.
The TUI invokes a generic declared call and does not recognize decision kinds or
interpret option effects. It draws each option as a filled card (rounded with
half blocks, no lines; without truecolor, a left bar ▌), the selected one on a
primary-tinted surface and marked ▸; ↑/↓ select an option, starting on the
recommended one, and never answer; Enter answers the selected one exactly as its
key does, so a decline still opens its note form. The Mac shows each option as a
card with its own button, and the quiet answers as plain buttons with their icon
(SF Symbols `questionmark.bubble`, `person.and.arrow.left.and.arrow.right`,
`arrow.uturn.backward`) in the primary colour.

The single-choice mechanism in `products/software_factory/model/generator` (`RelaDSL.DecisionOptions`) is generic:
it knows no decision fields, statuses or wording. A kind passes them in with its
`decision_options` annotation, which `products/software_factory/model/contract/foundation/decision.ex` gives
for decisions. Next to the fields holding the definition, selection, snapshot,
revision and history, the annotation gives `adopt` (which option payload goes into
which field: `rule` into `decision`, `consequences` into `consequences`),
`answered_at` and `answered_by` (`decided_at` and the `decided_by` relation),
`status` (the status field, its open, adopt and decline values, which statuses
may still become superseded, and `returned`: those an unanswered offer is back with
its proposer in), `alternative` (the field whose text, written with the revising
status, becomes a new adopt option), `delegated` (the relation naming who left the
choice to its proposer), `content` and `content_links` (the fields and
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

## Decline, ask, hand over, leave

A proposed decision's decider (D-0106) answers in one of five ways; nothing ends it
declined.

- **Accept / Choose:** it ends `accepted`, as above.
- **Decline:** asks "What is your alternative?" (an empty one asks again). In the
  same Facts write the status becomes `revising`, the alternative is stored in
  `alternative`, and it is added to the options as a new adopt option (`id`
  `alternative`, `alternative-2`, …): its text, rule and consequences the decider's
  words, marked as theirs (`by`). The previous offer stays in `option_history`; the
  recommendation stays. `decided_by` names the one who declined.
- **Ask a question:** asks "What do you need to know?"; the status becomes
  `answering` with the question in `question`. The history says "asked: …".
- **Hand over:** the page's Hand to…, under this label: another person decides.
- **Leave it to the proposer** (not offered under a fixed person rule): sets
  `delegated_by` to the decider and `left_to_proposer`. Only that person, from their
  own session, may: Control refuses an agent acting on their behalf or another
  person, and Facts refuses an agent or anyone else setting `delegated_by`. Flow asks
  the gate again (`accept_decision` version 2: a delegation is the one route to an
  agent; principles and production releases still go to a person), and the proposer
  chooses, recorded as "decided by coordinator on behalf of ada, delegated". Its
  choice links `decided_by` to the proposer, even where the decider is linked there
  already (they declined or asked first): Facts lets the one the assignment names
  replace the decider there only while `delegated_by` names exactly that decider
  (`only_target.delegated` on `decided_by`), and refuses anyone else, saying so.

A revising or answering decision goes to its proposer: `proposed_by`, the person
who created it (set on create when a person creates it), else the coordinator,
which answers on the decision page; never a worker agent. Revising, the proposer
words the alternative and sets the recommendation with Update, then **Propose
again** (`p`). Answering, they may add what answers the question to the decision,
then **Answer** (`a`) with a note ("answered: …" in the history; stored in
`answer`). Either sets `returned`; Flow puts it back to `proposed` and asks the gate
again, which brings it back to whoever declined or asked (`decided_by`). A timeout
no longer hands a decision to an agent; the answer limit (48 hours, five minutes on
test) still asks the gate again.
