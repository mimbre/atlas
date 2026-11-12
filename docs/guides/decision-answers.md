# Decide from Assigned to you: accept or reject a decision

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
| A decision for a person | on **Assigned to you**: a proposed decision, `↵` | **What to do: Have a person decide**, with **Answers** `a Accept   f Reject`. **Deadline** is the time the answer limit ends (`for_person` only). The actions are `a Accept`, `f Reject`, `u Update` and `h Hand to…`; there is no `d Delete`. `?` lists the same. |
| Accept | `a`, `y` | Stored as one change: `status` accepted, `decided_by` you, `decided_at` now. It leaves Assigned to you; Flow moves it to accepted. |
| Reject | on another one: `f`, a note, `ctrl-s` | **Reject D-NNNN** asks only for the note; it is required. Stored as one change with the note as its cause: `status` rejected, `decided_by` you, `decided_at` now. |
| Update instead | `u`, set Status to accepted or rejected, save | Also accepted: setting a deciding status through Update names you as `decided_by` in the same change. Fill **Decided at** yourself there. |
| Not yours | a decision an agent owns (`for_agent`), or one that is someone else's | No `a`/`f` answers; Update and Hand to stay. |
| Delete anyway | a client that submits to `/k/decision/D-NNNN/delete` | Not sent; Facts refuses any delete too: "Decisions are an append-only ledger; a decision is never deleted. Record a new one that supersedes it instead." |

A refusal is said in words, for example "It changed since you opened it; open it
again and retry." or "Only the one its decided_by names may make this choice; …".

## Who owns it

- **`for_person`, `for_person_always`:** an `assigned_to` that names a person
  stays (the 23 decisions assigned to melle on prod keep that assignment). Any
  other owner, such as the coordinator, is replaced by the state default
  `person/melle`, the deciding person in both environments. A running agent turn
  on it ends first, as with every handover.
- **`deciding`, `for_agent`, `for_agent_unverified`, accepted, rejected:** as
  before. The subflow owner is the coordinator, and an owner set by hand stays
  until the state changes.

## Who may decide

The answers grant no authority. Facts checks the decider gate on every write
that sets `status` to accepted or rejected. A person may always decide. An agent
may decide only when it is `decided_by` and a fresh `accept_decision` verdict
for the decision as written permits an agent.

## Deadline

While a decision waits in `for_person`, Flow writes the run's `no_answer` due
time on its assignment's **Deadline** (48 hours in prod, five minutes in test).
The decision shows `late` after it. In every other state Flow clears it. On
decisions, Flow owns this field, so a deadline set by hand does not stay.
`for_person_always` never times out and shows no deadline.

## How it works

- **Flow contract** (`model/contract/foundation/decision.ex`): the person states declare
  `owner … default: {:person, :melle}, preserve_kind: :person`, and
  `present(answers: …)`. Each answer is `change: %{self: :decided_by, values: …}`
  (`"$now"` is filled when it is sent). Reject has `note: true`. `for_person`
  has `deadline: :no_answer`.
- **Control:** an answer is `/k/:kind/:key/answer/:answer`. It is a confirm, or
  a note form when the answer needs a note. Submitting it reads the fact again
  and checks that you are still its owner in that state.
- **Facts:** a kind with `delete_error` (here `decision`, declared in
  `model/contract/foundation/decision.ex` and generated into `rela/atlas.json`) refuses every delete with that sentence.
  Control then offers no `d`.
- **Migration:** the `migrate` declarations beside the subflow (generated into
  `rela/flow-runtime.json`) map the previous canonical digests
  (test `e2d4c41b…`, prod `d9aadf74…`) to the new ones with `preserve_entry`.
  State, entry, deadlines and pending work stay. Flow then reprojects the owner
  and the deadline.

## Prod at merge

Deploy as usual: restart the core; rela gets the regenerated description. Live
decide runs migrate on boot without moving.
