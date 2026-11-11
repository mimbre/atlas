# Try UC-Atlas-28: My work on the front page

This guide grows with the use case. IS-Atlas-55: **Assigned to you** shows your Assignments (IS-Atlas-78), each shown as the open fact it belongs to. Each row shows what is expected; the fact's page shows since when and why (UC-Atlas-44: a Console row is one line). Console boot supplies the configured tabs and initial view; the header counts assignments on every page.

## Start

```sh
atlas tui --env test
```

The TUI's user is `tui_user` in `env/<env>.json` (`melle`), and a person of that name must exist (`atlas put person --name Melle --env test`). Select the configured **Assigned to you** tab if it is not the initial view.

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| Empty | `atlas tui --env test`, select **Assigned to you** | With no assignments, the list explains that nothing is assigned to you. The header says `Atlas Console · test · 0 assigned to you`. Existing open assignments to `melle` appear here when present. |
| One for you | in a second terminal: `atlas set UC-Atlas-NN assigned_to=melle --cause "all its issues are completed" --env test` | Within a second, in every open TUI, one line: `UC-Atlas-NN  Its title  Build it`. The header says `1 assigned to you`. Its page says why: **What to do: Build it**, **Why** `all its issues are completed`, `since 3 Nov 19:14 · by agent`. |
| Newest first | assign a second one | It comes first. |
| Moved away | `atlas set UC-Atlas-NN assigned_to=coordinator --cause … --env test` | Gone, in every TUI; the count goes down. |
| The scenes | `s` | The scenes list, with the count in the header; `esc` comes back. |
| Open one | `↵` on a row | The fact's page (not its Assignment's), with **Assigned to** `melle` and the same since and cause. |
| Done | accept it (`a`, `y`), or merge an issue's pull request | Gone from the list: only open facts are there. Flow also takes the owner off its Assignment (IS-Atlas-75). |

Since IS-Atlas-75 Flow writes owners itself: a use case whose issues are all done becomes yours to test, with Flow's cause, and shows here by itself.

A session that is not a person (an agent on the command line, a migration) opens on the plan, as before.

## How it works

- **The start page is data:** `start.assigned` in `rela/atlas.json`:
  - `relation`: the association whose inverse it reads, `assigned_to`;
  - `title`: "Assigned to you";
  - `count`: "{count} assigned to you", for the header;
  - `empty`: what fills it.
  - A kind's `start: {key, label}` puts its key on the start page. The scenes have `s Scenes`, and the agent's requests keep `w What the agent did`.
  - Every word comes from there, so naming these things (d-0022) is a change to `rela/atlas.json` only. No noun is in code.
- **Control:**
  - For a session whose user is a fact of a kind `assigned_to` points at (a person at the TUI), `/` is what points at it: its Assignments, one kind (IS-Atlas-78).
  - Each Assignment shows as the fact it belongs to: Control reads the kinds the component association (`assignment`) starts at, then joins their facts only to the user's selected Assignments. This avoids fetching the full Assignment list again for every owner kind. Unassigned and completed facts are left out.
  - It sorts them by the time of the fact that set the link, newest first.
  - Each row has the fact's title, its expected action (the field the flow writes, on the Assignment since the flow is `on` it), and the since and cause of that link.
  - No kind is named: the relation is the description's `start.assigned.relation`, and the rest follows from the `component` mark.
  - Every page message carries `count`, which a client shows in its header. Control reads it again after a hint of any kind; the page itself follows every hint, as the start page always did.
- **TUI:** the header shows the count. A row is one line: its summary keeps what is expected and leaves out Control's ` · since …` and cause, which the fact's page shows whole (UC-Atlas-44). A list's empty text wraps.

## What changed for this

- **rela/atlas.json:** `start.assigned`; `start` on the scene kind.
- **Control:** the start page of assignments, and `count` on every page.
- **TUI:** the header count; long row details; wrapped empty text.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-28.exs`.
- **Changes to the e2e for every scenario:** `home()` presses `s` when the start page is the assignments, so every other scenario goes on from the scenes as before. Checks of the header title allow the count before it. UC-32 accepts a `melle` that exists already.

## IS-Atlas-54: What to do, the owner's part of a fact's page

What you can see: open a fact that is yours, from Assigned to you or anywhere. Above its content and references, a part **What to do** says:
- **What to do: Test it**: what is expected of you;
- **Why**: why it came to you, the cause of the fact that made you its owner (`Flow test_and_accept: all under it is completed → melle`), with since and by;
- **How**: the instructions of the state it is in;
- for a use case to test, **Melle can test**: that section of its description;
- **Answers**: the actions you can answer with (`a Accept`), also shown in the `?` key legend.

Nobody else sees the part. `atlas get` shows it to a client that is the owner: an agent says which one it is with `ATLAS_AS`, as in `ATLAS_AS=coordinator atlas get IS-Atlas-NN --env test`.

### Try

| Step | Keys / command | What you should see |
|---|---|---|
| A use case to test | a use case whose issues are all done (its pull requests merged); Flow makes it yours | On Assigned to you: `UC-Atlas-NN  …  Test it`. |
| Its page | `↵` on it | **What to do: Test it** first, with Why, How (`Try the test below, then accept it, or reject it with a note.`), **Melle can test** with the text from its description, and **Answers** `a Accept   f Reject` (IS-Atlas-56). |
| Not yours | a fact the coordinator owns | No What to do part. |
| An agent's | `ATLAS_AS=coordinator atlas get IS-Atlas-NN --env test` on an open issue | `What to do: Build it`, `Why: …`, `How: Build it in one pull request and get that merged; link the pull request to it.`, before the issue itself. Without `ATLAS_AS`, no such part. |

### How it works

- **The flow definitions say it all** (`rela/atlas.json`, `flows`):
  - each definition has `state_field`, the field it writes the state's name in (`flow_state`, on the Assignment);
  - each open state has `todo`: `instructions`, `section` (`{field, heading}`: the fact's field and the heading the text starts at, to the next `#` heading) and `answers` (`[{key, label}]`);
  - the part's own words are the top-level `todo` (`title`, `why`, `instructions`, `answers`).
- **Flow** writes the state's name on the Assignment with what is expected, `by: flow`. Writing only the name never counts as a move, so an owner a person set stays.
- **State** checks that a definition's `state_field` exists on the kind it writes on.
- **Control:**
  - It shows the part when the client is the owner (the flow's `owner_relation` on the Assignment points at it) and the state has a `todo`.
  - The part is an `item` block in a `part` of role `todo`, first in the page's markup.
  - The state's field is not shown as a field.
- **Contract 0.12.0:** the role `todo`, and `as` in hello: the fact an agent client is. The TUI gives the todo part its room first.
- **No kind is named** in BEAM, the TUI or the agent; no new page or endpoint.

### What changed for this

- **rela:** `flow_state` on the Assignment.
- **rela/atlas.json:** `state_field` and `todo` in the three flow definitions; the top-level `todo` words.
- **Flow:** writes the state's name. **State:** checks `state_field`.
- **Control:** the What to do part; `as` in hello.
- **Contract:** 0.12.0. **TUI:** room for the todo part first. **Agent:** `ATLAS_AS`; `atlas get` prints the part first and has `todo` in `--json`.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-28-todo.exs`.
- **Prod at merge:** restart rela and the core (rela gets `flow_state`; `atlas-ops restart` does both). Flow writes each state's name within its first round.
