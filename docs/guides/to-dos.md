# To-Dos

A To-Do is work for a person or an agent that the existing flow definitions do not
cover. Open To-Dos from the start page and create one with a title and instructions.
Both fields are required. Atlas assigns the next `TD-NN` id and starts it in `open`.

Hand it to a person or agent through its Assignment. Set the optional deadline there;
the To-Do has no separate deadline. The deadline marks assigned work late and does not
close it. Until it is handed on, the configured decider owns it.

The owner sees the complete instructions in the page's What to do section, including
Console detail and the agent's item guidance. The owner can choose Done with a note on
how it was done, or Won't do with a note on why. Other actors cannot close it. Neither
answer is accepted without a note. Atlas records the note on the To-Do and as the
change's cause. Optional evidence can hold a link or reference. There is no gate or
review: Atlas cannot verify this work.

`done` and `wont_do` end the run. Putting the status back does not start another run;
restarting requires an explicit restart. A To-Do can link to the decisions it is based
on, and counts as work in their follow-through tally.

The model declares the whole-field instructions section with
`section: [field: :instructions, label: "Instructions"]`. This is generic DSL support;
clients do not name the To-Do kind. An answer can use `"$note"` as a field value to keep
the trimmed answer note, just as `"$now"` keeps the answer time. Facts reads a component
for a choice role only when that role grants update access on the subject's kind.
Stored component links determine that role; a submitted owner link grants no role.
The compiled Facts input mapping carries component definitions, because Rela's public
schema does not include those model rules.

## Isolated verification

The model tests cover selection, owner answers, required notes, instructions, the one
deadline, closed imports, and exact slice14 identities and history. The native fixture
uses a private Rela dataset and Facts process, real Flow reconciliation and projection,
and a private Control listener. It creates work and closes it through the real agent
client, and verifies the actual Console detail screen and agent guidance. It exercises
person and agent owners with both closing outcomes and checks refusals for another
actor and a missing note.

After generation, from `beam/`, with the pinned Rela binaries already available:

```sh
MIX_ENV=test mix run integration/to_do_native.exs \
  /absolute/writable/private-fixture /absolute/rela-bin \
  ../model/contract/test/fixtures/slice14-digests.json
```

The fixture starts and stops its private Rela and Control listener. It installs nothing and does not
use `env/test.json` or `env/prod.json`. Native execution requires the toolchain and local
socket/process permissions; a sandbox refusal is a verification limit, not a pass.
