# Try UC-Atlas-29: Test a use case from My work: accept or reject

This guide grows with the use case. IS-Atlas-56: the answers an owner can give come from the flow definition, as actions on the fact's page and in its `?` key legend, for its owner only. Accept is IS-Atlas-64's (UC-Atlas-32), reused. Reject asks only for a note. Each answer is a change with its cause, and Flow moves the fact on.

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| A use case to test | on **Assigned to you**: a use case whose issues are all done (Flow made it yours: `Test it`) | Its row, with `Test it · since … · Flow test_and_accept: all under it is completed → melle`. |
| Its page | `↵` on it | **What to do: Test it**, with **Answers** `a Accept   f Reject`. The `?` key legend also lists Accept and Reject with their declared keys. |
| Reject | `f`, a note (several lines if you like), `ctrl-s` | **Reject UC-Atlas-NN** asks only for the note. Stored: the use case is the coordinator's again, `Expected: Rework: <your note>`, and it leaves Assigned to you. Its answers are gone from its page, since it is no longer yours. |
| Accept | on another one: `a`, `y` | `Done · … · accepted by melle`, and it leaves Assigned to you. Flow takes the owner off: nothing is expected of anyone. |
| Not yours | a use case the coordinator owns | No `f Reject`; `a Accept` stays as IS-Atlas-64 has it (only a person accepts, as themself). |

## How it works

- **The answers are data:** each state's `todo.answers` in `rela/atlas.json` (`flows`), `[{key, label, set | remove}]`:
  - `set: accepted_by` is an action to the association's set page, IS-Atlas-64's Accept;
  - `remove: accepted_by` is one to its remove page (a note, as its cause).
  - The to_test state has `a Accept` and `f Reject`. A key or label is a one-line change there.
- **Control:**
  - On the fact's page, the owner's answers are actions, before the others; an action on the same key gives way to one (Accept is both).
  - Anyone else gets the page's actions as before.
  - The remove page reads what the fact's page reads, so it knows the state. An answer that removes may do so also when nothing is set: rejecting before anything was accepted.
- **Facts** keeps that removal as the newest fact about `accepted_by`, with the note as its cause. Flow's `reopened` condition reads it, so the use case goes to the rework state: the coordinator's, with `Rework: <note>`.
- **No kind is named** in BEAM, the TUI or the agent; no new page or endpoint.

## What changed for this

- **rela/atlas.json:** `set`/`remove` on the to_test answers, and `f Reject`.
- **Control:** the owner's answers as actions; the remove page for an answer.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-29.exs`.
- **Prod at merge:** restart the core; rela needs nothing.
