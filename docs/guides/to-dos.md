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
`section: [field: :instructions, label: "Instructions", steps: :step]`; `steps:` names
the integer field that keeps the current step. This is generic DSL support;
clients do not name the To-Do kind. An answer can use `"$note"` as a field value to keep
the trimmed answer note, just as `"$now"` keeps the answer time. Facts reads a component
for a choice role only when that role grants update access on the subject's kind.
Stored component links determine that role; a submitted owner link grants no role.
The compiled Facts input mapping carries component definitions, because Rela's public
schema does not include those model rules.

## Step by step

The owner sees the instructions as a panel of steps, in the TUI, the Mac app and
`atlas get`. Write the instructions in this form:

```text
Why: the hosting bill goes to this account.
1. Open the account.
$ open https://example.com/billing
2. Save the receipt in the shared folder.
$ cp ~/Downloads/receipt.pdf ~/Shared/
```

- An optional `Why:` paragraph comes first. The panel shows it with how long the
  To-Do has been the owner's.
- Numbered lines (`1.`, `2.`, …) start the steps. Text without numbered steps is
  one step.
- A line starting with `$ ` is a command of the step above it, shown without the `$ `.

The panel shows the done steps with ✓, the current step open with its commands, and
the later steps faint. The To-Do's `step` field keeps where the owner is:

| Key | Does |
| --- | --- |
| Enter | marks the current step done |
| ↓ / ↑ | goes to the next or previous step |
| `c` | copies the current step's first command |
| `C` | copies its next command |
| `y` | copies all of its commands, one per line |
| `x` / `n` | Done / Won't do, with a note |

Beside the panel, when the screen is wide enough (else under it), are the To-Do's
details: its key, status, for whom and from whom since when, what it is about or based
on, and its note, evidence and deadline once filled. Its full text is `atlas get <key>`.

The Mac app has a Copy button beside each command. The TUI copies with `pbcopy` when
it runs on the Mac itself, and otherwise with OSC 52, which the terminal must allow.
Inside tmux, OSC 52 also needs `set -g set-clipboard on` or
`set -g allow-passthrough on`.

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
