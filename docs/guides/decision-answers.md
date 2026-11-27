# Decide from Assigned to you: accept, decline, ask, hand over or leave a decision

A decision created with [single-choice options](decision-options.md) is decided by
selecting an option, and `0` aliases recommended choice `1`. This guide describes the
answers of a decision without options: one created without them, or a historical
one. Existing records are not rewritten to manufacture alternatives or selections.
Both have the same answers besides Accept or Choose (D-0106): nothing ends declined.

A proposed decision that its decider gate gives to a person (`for_person`, or
`for_person_always` for a fixed person rule) is that person's: it is on their
**Assigned to you**, and its page offers the answers. The answers come from the
flow definition, as for use cases (IS-Atlas-56, [UC-Atlas-29](uc-atlas-29.md)):
actions on the fact's page and in the `?` legend, for its owner only.

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys | What you should see |
|---|---|---|
| A decision for a person | on **Assigned to you**: a proposed decision, `↵` | **What to do: Have a person decide**, with **Answers** `a Accept   f Decline   q Ask   l Delegate`. **Deadline** is the time the answer limit ends (`for_person` only). Besides them `u Update`; there is no `d Delete`. `?` lists the same. The Mac shows each answer's full words as its tooltip (`help`: "Ask the proposer a question", "Let someone else decide: the proposer or another person"). |
| Accept | `a`, `y` | Stored as one change: `status` accepted, `decided_by` you, `decided_at` now. It leaves Assigned to you; Flow moves it to accepted. |
| Decline | on another one: `f`, an alternative, `ctrl-s` | The form asks "What is your alternative?"; it is required (empty, it asks again). Stored as one change with "declined, with an alternative: …" as its cause: `status` revising, `alternative` your text, `decided_by` you. It goes to its proposer (below). |
| Ask | `q`, a question, `ctrl-s` | "What do you need to know?". Stored as `status` answering, `question` your text, `decided_by` you; the history says "asked: …". It goes to its proposer. |
| Its proposer answers | as the proposer, on its page | Revising: **Revise it with its decider's alternative**, the alternative under **Their alternative**, Update to word it, then `p Propose again`. Answering: **Their question**, then `a Answer` with a note ("answered: …", stored in `answer`). Either sets `returned`: Flow proposes it again (`status` proposed) and it comes back to you, its `decided_by`. |
| Delegate | `l`: the form "Delegate D-NNNN to…", nothing chosen; ←/→ choose, `ctrl-s` (refused until you chose, and for another person until you picked one) | **The proposer (melle) — decides on your behalf**: only from your own session, `delegated_by` you, `left_to_proposer` set; Flow asks the gate again, which gives it to its proposer, who carries out what you delegated, recorded as "decided by coordinator on behalf of melle, delegated". **Another person**, then whom: the page's Hand to… of its assignment to them; it is theirs to decide. In `for_person_always` there is no proposer to choose: `l` is the Hand to… itself. |
| Update instead | `u`, set Status to accepted, save | Also accepted: setting a deciding status through Update names you as `decided_by` in the same change. Fill **Decided at** yourself there. |
| Not yours | a decision an agent owns (`for_agent`), or one that is someone else's | None of these answers; Update and Hand to stay. |
| Delete anyway | a client that submits to `/k/decision/D-NNNN/delete` | Not sent; Facts refuses any delete too: "Decisions are an append-only ledger; a decision is never deleted. Record a new one that supersedes it instead." |

A refusal is said in words, for example "It changed since you opened it; open it
again and retry." or "Only the one its decided_by names may make this choice; …".

## Who owns it

- **`for_person`, `for_person_always`:** an `assigned_to` that names a person
  stays. Any other owner, such as the coordinator, is replaced by the one who
  declined or asked earlier (`decided_by`), else the state default `person/melle`,
  the deciding person in both environments. A running agent turn on it ends first,
  as with every handover.
- **`revising`, `answering`, `for_agent` (left to its proposer):** its proposer:
  `proposed_by`, the person who created it (set on create when a person creates
  it), else the coordinator, which answers on the decision page. Never a worker
  agent.
- **`deciding`, `for_agent_unverified`, accepted, rejected:** as before. The
  subflow owner is the coordinator, and an owner set by hand stays until the state
  changes. Decisions that ended `rejected` before D-0106 stay so.

## Who may decide

The answers grant no authority. Facts checks the decider gate (`accept_decision`,
version 2) on every write that sets `status` to accepted. A person may always
decide; agents never decide unless the decider delegates it. Delegating to the
proposer is the decider's decision: an agent may then decide only when it is
`decided_by` and a fresh verdict for the decision as written permits it
(`delegated`), carrying out what was delegated; principles and production releases
always go to a person. Only the decider, from their own session, sets
`delegated_by`: Control refuses an agent acting on their behalf or another person,
Facts refuses an agent or anyone else. A timeout never hands a decision to an agent.

## Deadline

While a decision waits in `for_person`, Flow writes the run's `no_answer` due
time on its assignment's **Deadline** (48 hours in prod, five minutes in test).
The decision shows `late` after it, and Flow asks the gate again. In every other
state Flow clears it. On decisions, Flow owns this field, so a deadline set by hand
does not stay. `for_person_always` never times out and shows no deadline.

## How it works

- **Flow contract** (`products/software_factory/model/contract/foundation/decision.ex`): the person states declare
  `owner … default: {:person, config: :decider, producer: :decided_by}, preserve_kind: :person`,
  and `present(answers: …)`. Each answer is `change: %{self: …, values: …}`
  (`"$now"` is filled when it is sent, and `"$note"`, where a value names it, with the
  note it is sent with; `self` names the relation the sender is linked by:
  `decided_by`, or `delegated_by` for Delegate). Decline and Ask have `note: true` and
  their own `prompt`; Ask and Delegate weigh `other` with an `icon` (`question`,
  `delegate`); every answer has its `help`. Delegate is `hand_over: true` with the
  `change` to the proposer and the words of both choices (`choices:`): Control's form
  sends the change, or the page's Hand to… of the assignment to the person chosen;
  under a fixed person rule it is `hand_over: true` alone, the Hand to… itself.
  `for_person` has `deadline: :no_answer`. `revising` and `answering`
  branch back to `deciding` on `returned`, which resets it, `left_to_proposer` and
  `status` proposed.
- **Control:** an answer is `/k/:kind/:key/answer/:answer`. It is a confirm, a
  note form when the answer needs a note, or Delegate's form (`to`: a required
  choice without a value; `person`: required, `shown_when` `to` is `person`).
  Submitting it reads the fact again and checks that you are still its owner in that
  state.
- **Facts:** a kind with `delete_error` (here `decision`, declared in
  `products/software_factory/model/contract/foundation/decision.ex` and generated into `products/software_factory/model/targets/rela/atlas.json`) refuses every delete with that sentence.
  Control then offers no `d`.
- **Runs:** a run keeps its flow and state by name (D-0102), so a live decide run
  continues where it is: state, entry, deadlines and pending work stay. Flow then
  reprojects the owner and the deadline.

## Prod at merge

Deploy as usual: restart the core; rela gets the regenerated description. Live
decide runs continue on boot without moving.
