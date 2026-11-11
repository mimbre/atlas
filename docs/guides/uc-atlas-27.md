# Try UC-Atlas-27: Every fact has an owner, and Flow moves it

This guide grows with the use case, one section per issue.

## IS-Atlas-52: the owner, `assigned_to`

This guide grows with the use case. IS-Atlas-52: the owner is an association in rela, `assigned_to`. It goes from every assignable kind (scene, use case, issue, pull request) to a person or an agent, one at most. The link has no attributes: when, by whom and why are the fact that set it, and pages and `atlas get` show them with it. IS-Atlas-53 (Flow) moves owners later.

### Try

In prod, after the migration below, every fact has an owner:

| Step | Where | What you should see |
|---|---|---|
| An owner | `atlas get UC-Atlas-01 --env prod` | `Assigned to: coordinator (since 3 Nov …, by migration: owner introduced)`, and under it the list **Assigned to** with `coordinator  Agent`. `--json` gives `origins["Assigned to"]`: `since`, `by` and `cause`. |
| On its page | any scene, use case, issue or pull request in the TUI | **Assigned to** in the content, with since, by and cause, and in the references, the owner as a row. |
| The owner's page | `enter` on that row, or `atlas get coordinator --env prod` | **Agent coordinator**, with what is assigned to it, one list per kind: **Assignments: Scenes**, **Assignments: Use cases**, … A person's page (`atlas get melle`) the same for that person. |
| Change it | `atlas set UC-Atlas-01 assigned_to=melle --cause "all 12 issues completed" --env test`, or `u` on the page (**Assigned to**, a person or an agent, `ctrl-s`) | One owner, the new one, with its own since, by and cause. The earlier owner stays in the facts as history. |
| Only who can own | `atlas set UC-Atlas-01 assigned_to=nobody --env test` | Refused: `nobody is not a person or agent`. |

Try changes in test (`--env test`), not prod: prod is real data.

### The prod data

The one-off `atlas migrate-owner` gave every fact that existed then the coordinator as its owner, with the cause "owner introduced"; it has since been removed.

### How it works

- **rela's description:**
  - `rela/schema.yaml` has an `agent` kind next to `person` (made from a name, not on the start page; `rela/atlas.json`).
  - It has `assigned_to` from scene, use case, issue and pull request to person and agent, with `max_outgoing: 1` and the inverse `assignments`.
  - A kind is assignable by being in `assigned_to`'s `from`; adding one is a change to the description only.
- **A relation to several kinds:**
  - rela links each key with its kind, but answers only the keys. State finds out which kind a key is by reading it in each kind the relation points at, both on a write and when it answers one fact (`link_kinds`).
  - A key of none is refused. Control opens it as that kind, and offers the facts of every such kind on the links page.
- **A relation from several kinds:** the page it points at has one list per kind (`Assignments: Scenes`, …). As for any association, a list shows only when it has something.
- **A key without an id prefix** (`melle`, `coordinator`): when more than one kind has no prefix, Control asks State which one has it, for `atlas get <key>`.
- **No kind is named** in BEAM, the TUI or the agent. The words a page shows ("Assigned to", "Assignments") are the relation's label and inverse label in the description, so naming them otherwise (d-0022) is a one-line change there.

### What changed for this

- **rela:** `agent`; `assigned_to`.
- **State:** relations to several kinds; `link_kinds` in a fact's answer.
- **Control:** lists per kind for a relation from several; rows and the links page for one to several; keys without a prefix.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-27-owner.exs`.
- **Prod:** restart rela (it reads `schema.yaml` when it starts) and the core, then run the migration.

## IS-Atlas-53: Flow moves a fact on (the first slice)

What you can see: a use case or scene says what its owner is expected to do next, and Flow keeps that true by itself. While not all under it is completed it says `Build it`. Once all is, it says `Test it`. Once it is accepted, nothing is expected. Once it is reopened, it says `Rework: <the note>`. Flow never completes anything: done is accepted (UC-Atlas-32). Nobody types what is expected; it is a fact Flow stores, with its cause.

The owner itself comes with IS-Atlas-52 (`assigned_to`). This slice already knows who it is (`melle` to test, the coordinator to build and rework) and writes it once that association exists.

### Start

```sh
atlas tui --env test
```

### Try

| Step | Keys / command | What you should see |
|---|---|---|
| A use case with an open issue | `c` a scene, `c` a use case in it, `c` an issue in that | The use case's page: `Expected  Build it`; the scene says the same. |
| Its pull request merges | link a pull request to the issue and merge it on GitHub (in the e2e: the stand-in) | Within a connector round its row shows Done, and within a second after that the use case says `Expected  Test it`, in every open TUI. Its progress says `To test · 1/1`: Flow does not accept it. |
| Accept | `a`, `y` | `Expected` is gone: done, nothing is expected of anyone. |
| Reopen | `a` (Reopen), a note, `ctrl-s` | `Expected  Rework: <the note>`. |
| Rework starts | `c` a new issue under it | `Expected  Build it` again. |

In prod, after the merge and a restart, every open scene and use case gets its `Expected`, one change each, by `flow`, with the cause, such as `Flow test_and_accept: all under it is completed → melle`.

### How it works

- **The definition** is data in `rela/atlas.json`, under `flows`. `test_and_accept` runs on scenes and use cases and writes `expected`. Its states are in order, and a fact is in the first that holds:
  1. `done` (completed);
  2. `rework` (the newest fact about `accepted_by` removed it, and nothing came under the fact since; `{note}` is that fact's cause);
  3. `to_test` (its progress is `to_test`);
  4. `building` (otherwise).

  Each open state names its owner, what is expected, why, and its next states.
- **The check:** State checks every definition before anyone runs it (`AtlasState.Flows`). Every state that is not done has an owner and a way out to a next state, every state reaches done, the last state holds when no other does, and the kinds, field and owner relation exist. The description State answers carries `flow_problems`, and Flow runs only a sound definition. A unit test checks the definitions in `rela/atlas.json`, so CI refuses an unsound one.
- **The engine:** Flow is its own BEAM application, `atlas_flow`, beside Bus, State and Control, and it talks only over the Bus.
  - It runs one supervised process per open fact (`AtlasFlow.Item`), registered by kind and key, so a second one cannot start. Each process has a timer in every state (every minute; `flow.tick_seconds` in the environment's settings, or a state's `every_seconds`).
  - On its timer, and at once on any hint, a process reads its fact and what hangs under it, works out the state, and stores only what differs (safe to repeat). It stops once its fact is done or gone. It keeps nothing State does not hold, so a crashed process is started again and goes on from State.
  - At boot, and every round, the engine starts a process for every open fact without one. A hint of a new fact starts its process at once. Nobody depends on a hint.
- No kind is named in BEAM, TUI or agent code; the boundary test covers `atlas_flow` too.

`e2e/scenarios/uc-atlas-27.exs` follows these steps on a private instance.

## IS-Atlas-78: every assignable thing has an Assignment

What you can see: every scene, use case, issue and pull request page shows **Assigned to** and **Expected** as before, with since, by and why. Both are now its Assignment's (d-0022): a fact of its own, `AS-` plus the item's key, made in the same write as the item and deleted with it. In the references, **Assignment** opens it, and **Assigned to** opens the owner.

### Try

| Step | Where | What you should see |
|---|---|---|
| A new item has its Assignment | `c` a use case, or `atlas put use_case --in SC-Atlas-01 --title "…" --env test` | `atlas get AS-<key>`: **Assignment AS-UC-Atlas-…: UC-Atlas-…**. `atlas list assignment` lists one per open item: since IS-Atlas-85 it is Open work. |
| Its owner, as the item's | `atlas set UC-Atlas-01 assigned_to=melle --cause "ready to test" --env test` | The use case's page and `atlas get UC-Atlas-01`: `Assigned to: melle (since …, by agent: ready to test)`, in every open TUI by hint. The link is the Assignment's: `atlas set` on the item sets it there. |
| What is expected | the use case's page | `Expected  Build it` (or Test it, Rework): Flow writes it on the Assignment now. |
| The Assignment's page | `enter` on **Assignment** in the references | **Assignment AS-UC-Atlas-01: UC-Atlas-01**: Of, Expected, Assigned to, and **Assignment of: Use cases** with the use case. `esc` goes back to the use case. |
| Deleted together | `d` on the use case | The confirm says `…, with its Assignment AS-UC-Atlas-…`. Deleting the Assignment alone is refused: `AS-… goes with UC-…; delete that instead.` |
| The owner's page | `enter` on the owner, `atlas get melle` | **Assignments**: one list, of Assignments, each named by its item. |

### The prod data

The one-off `atlas migrate-assignment` gave every item that existed then its Assignment and moved its owner there; it has since been removed.

### How it works

- **rela's description:**
  - The `assignment` kind (`of`, the item's key, and `expected`) in `rela/schema.yaml`.
  - The association `assignment`, from scene, use case, issue and pull request, one each way (inverse `assignment of`). A kind is assignable by being in its `from`.
  - `assigned_to` now starts at the Assignment, and `expected` left the scene and use case.
- **`rela/atlas.json`:**
  - `relations.assignment.component` = `{key: "AS-{key}", values: {of: "{key}"}}`: the mark that makes it part of the item. It is `set_by: migration`: nobody links it by hand.
  - The flow `test_and_accept` has `"on": "assignment"`: Flow writes on the fact that relation points at.
- **State** (`AtlasState.Components`):
  - A create of a fact with a component makes the component first, then the fact with its link, in one write with one cause. When the fact is refused, the component goes again.
  - A delete deletes the component too. Deleting a component alone is refused while its fact exists.
- **Control:**
  - A fact's page reads its component and shows the component's fields and associations (with since, by, cause) as its own, and the component's links in the references.
  - An association that starts at the component's kind and not at the fact's (`assigned_to`) is set on the component: `/k/_/UC-Atlas-01/links/assigned_to` is the Assignment's links page.
  - A hint about a component refreshes its fact's page, and the component's page goes back to its fact.
- **Flow:**
  - A definition with `on` reads the fact that relation points at, and writes `field` (and later `owner_relation`) there.
  - It writes `by: flow`, so the engine still passes over its own hints.
  - State's check looks for the field and the owner relation on that kind, and refuses a rule that depends on them through `on`.
- **No kind is named** in BEAM, the TUI or the agent. There is no new page or endpoint: the Assignment's pages are the generic ones.

### What changed for this

- **rela:** the `assignment` kind and association; `assigned_to` starts at it; `expected` moved there.
- **State:** components; Flow's check with `on`.
- **Control:** a fact's page shows its components; associations go to them; the delete confirm says so.
- **Flow:** `on`.
- **The end-to-end test:**
  - `e2e/scenarios/uc-atlas-27-assignment.exs` is new.
  - `uc-atlas-27.exs` checks Flow's last move on the Assignment's page.
  - `uc-atlas-27-owner.exs` reads the owner's list of Assignments.
  - `uc-atlas-20.exs` gives its first TUI 4 rows more, the room the Assignment's row in the references takes.
- **Prod:** the migration above.

## IS-Atlas-75: Flow writes the owner

Flow now writes the owner too, on each fact's Assignment (IS-Atlas-78), together with what is expected, in one change with its cause, by `flow`. Each flow state names its owner with its kind (`"owner": {"kind": "agent", "key": "coordinator"}`), and State's check refuses a definition whose owner relation does not allow that kind.

What each kind gets, from the flows in `rela/atlas.json`:

| Kind | State | Owner | Expected |
|---|---|---|---|
| Scene, use case (`test_and_accept`) | not all under it is completed | coordinator | Build it |
| | all under it is completed (To test) | melle | Test it |
| | reopened, nothing new under it yet | coordinator | Rework: \<the note\> |
| | accepted (done) | nobody | nothing |
| Issue (`build_and_merge`) | its pull request is not merged | coordinator | Build it |
| | completed: its pull request merged (done) | nobody | nothing |
| Pull request (`review_and_merge`) | open | coordinator | Review and merge it |
| | merged or closed (done) | nobody | nothing |

So a new scene, use case, issue or pull request gets its owner within moments of being made. IS-Atlas-79, made without one, gets the coordinator.

- **An owner set by hand stays.** Within a state, an owner a person or an agent set (`atlas set … assigned_to=…`, or `u`) stays. Flow moves the owner when the state changes (what is expected changes), or when Flow, a migration or nobody set it.
- **The owner must exist.** When the owner a state names does not exist yet, only what is expected is written, and the owner follows as soon as it is made.
- **Done facts from before:** facts that were already done have no Flow process, so they keep the owner the IS-Atlas-52 migration gave them (the coordinator).

| Step | Keys / command | What you should see |
|---|---|---|
| A new item | `atlas put issue --in UC-Atlas-NN --title … --env test` | `Assigned to: coordinator (… by flow: Flow build_and_merge: its pull request is not merged → coordinator)`, and `Expected: Build it`. |
| All of a use case done | merge the last issue's pull request | The use case shows `Assigned to: melle` and `Expected: Test it` within a second; the merged pull request and its issue have no owner (`Assigned to: —`). |
| Accept | `a`, `y` | No owner, nothing expected. |
| Reopen | `a`, a note, `ctrl-s` | The coordinator, with `Rework: <the note>`. |

`e2e/scenarios/uc-atlas-27.exs` follows these steps. `uc-atlas-27-owner.exs` checks that a new fact gets its owner from Flow.

## IS-Atlas-88: a done fact has no owner (`atlas migrate-done-owner`)

Facts that were done before IS-Atlas-75 kept the coordinator the IS-Atlas-52 migration gave them. A done fact has no Flow process, so Flow never took it away. In prod the coordinator's row in the agents list (IS-Atlas-17) counted 163, mostly done work.

`atlas migrate-done-owner` removes those owners. One change per Assignment, by `migration`, with the cause "done: no owner (IS-Atlas-75's rule)".

- **Done is what Flow says.** Flow writes Expected on every open fact and clears it once the fact is done. So an Assignment with an owner and nothing expected belongs to a done fact.
- **Only an owner a migration set goes.** One set by hand or by Flow stays.
  - The IS-Atlas-78 migration moved every owner onto its Assignment, by `migration`, and kept who had set it in its cause ("moved from X, set … by who"). That earlier setter counts.
  - An owner whose cause does not say who set it is kept, and the run lists it as `kept`.
- **Nothing is lost if an open fact is caught** (Flow had not done its round yet): Flow gives it its owner again on its next look.
- **A rerun has 0 steps.**

The coordinator runs it after the merge, after a backup, on test and prod:

```sh
atlas migrate-done-owner --env prod --dry-run   # prints every step; writes nothing
atlas migrate-done-owner --env prod             # writes them through Control, as the migration
atlas migrate-done-owner --env prod --dry-run   # again: 0 steps
```

Afterwards the coordinator's count in the agents list (`g`) is its open work only.

`e2e/scenarios/uc-atlas-27-done-owner.exs` follows this:
1. A merged pull request and its issue are left with nobody by Flow.
2. A migration gives the issue the coordinator, and a user gives the pull request one.
3. The one-off removes only the issue's owner, and a rerun has 0 steps.
