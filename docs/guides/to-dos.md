# To-Dos

A To-Do is work for a person or an agent that the existing flow definitions do not
cover. Open To-Dos from the start page and create one with a title and instructions.
Both fields are required. Atlas assigns the next `TD-NN` id and starts it in `open`.

Hand it to a person or agent through its Assignment. Set the optional deadline there;
the To-Do has no separate deadline. The deadline marks assigned work late and does not
close it. Until it is handed on, the configured decider owns it.

The owner can choose Done with a note on how it was done, or Won't do with a note on
why. Other actors cannot close it. Neither answer is accepted without a note. Atlas
records the note on the To-Do and as the change's cause. Optional evidence can hold a
link or reference. There is no gate or review: Atlas cannot verify this work.

`done` and `wont_do` end the run. Putting the status back does not start another run;
restarting requires an explicit restart. A To-Do can link to the decisions it is based
on, and counts as work in their follow-through tally.

The model declares the whole-field instructions section with
`section: [field: :instructions, label: "Instructions", steps: true]`; `steps: true`
shows the field as its numbered steps. Nothing keeps which step is done. This is
generic DSL support;
clients do not name the To-Do kind. An answer can use `"$note"` as a field value to keep
the trimmed answer note, just as `"$now"` keeps the answer time. Facts reads a component
for a choice role only when that role grants update access on the subject's kind.
Stored component links determine that role; a submitted owner link grants no role.
The compiled Facts input mapping carries component definitions, because Rela's public
schema does not include those model rules.

## Steps

The owner sees the instructions as their steps, every step in full, in the TUI, the
Mac app and `atlas get`. Write the instructions in this form:

```text
Why: the hosting bill goes to this account.
1. Open the account.
$ open https://example.com/billing
2. Download the receipt.
> Billing > Invoices > "November > December"
3. Save the receipt in the shared folder.
$ cp ~/Downloads/receipt.pdf ~/Shared/
```

- An optional `Why:` paragraph comes first. It is shown with how long the To-Do has
  been the owner's.
- Numbered lines (`1.`, `2.`, …) start the steps. Text without numbered steps is
  one step.

A step has three kinds of line, shown in the order they are written:

- **Text**: any other line, the step's own words.
- **Command**: a line starting with `$ `, something to run. It is shown without the
  `$ ` beside a bar, and it is what the copy keys copy.
- **Route**: a line starting with `> `, the way to something in an app, its parts
  separated by ` > `: `> Keychain Access > login > My Certificates`. A part in double
  quotes is one part, even with ` > ` inside, and is shown without its quotes. The TUI
  shows a route as a muted `⌘`, then each part bold in a light colour with a muted `›`
  between them, and wraps a long route at a `›`. The Mac app shows each part as a small
  label with `›` between them. A route is never copied.

Control sends the page as a stack of simple blocks, each client stacking them as it
likes: a `header` (TO DO FOR YOU, the key and the title), a `text` (the why and its
age), one `instruction` per step (its number and its lines), the `answers` (Done and
Won't do, each with a note, and More…), then the details. The same blocks serve other
pages.

In the TUI every step is open, one under the other, their numbers in one column. ↑ and
↓ move a selection (▸) from command to command across all steps:

| Key | Does |
| --- | --- |
| ↓ / ↑ | selects the next or previous command |
| `c` | copies the selected command |
| `y` | copies all commands of the To-Do, one per line |
| `x` / `n` | Done / Won't do, with a note |

The Mac app shows the header on the page, then each step as a card of its own, each
command with a copy icon right after it, then the answers as buttons.

Beside the steps in a wide terminal (under them when narrower, and always under them
in the Mac app, as a recessed card) are the To-Do's details: its key, status, for whom
and from whom since when, what it is about or based on, and its note, evidence and
deadline once filled. Its full text is `atlas get <key>`.

The TUI copies with `pbcopy` when it runs on the Mac itself, and otherwise with OSC 52,
which the terminal must allow. Inside tmux, OSC 52 also needs `set -g set-clipboard on`
or `set -g allow-passthrough on`.

## Isolated verification

The model tests cover selection, owner answers, required notes, instructions, the one
deadline and closed imports. The native fixture
uses a private Rela dataset and Facts process, real Flow reconciliation and projection,
and a private Control listener. It creates work and closes it through the real agent
client, and verifies the actual Console detail screen and agent guidance. It exercises
person and agent owners with both closing outcomes and checks refusals for another
actor and a missing note.

After generation, from `products/software_factory/`, with the pinned Rela binaries already available:

```sh
MIX_ENV=test mix run integration/to_do_native.exs \
  /absolute/writable/private-fixture /absolute/rela-bin
```

The fixture starts and stops its private Rela and Control listener. It installs nothing and does not
use `products/software_factory/environments/test.json` or `products/software_factory/environments/prod.json`. Native execution requires the toolchain and local
socket/process permissions; a sandbox refusal is a verification limit, not a pass.
