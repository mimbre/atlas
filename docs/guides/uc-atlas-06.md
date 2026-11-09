# Try UC-Atlas-06: Hand a scene to an agent

This guide grows with the use case, one section per issue. In the end the operator can see the agents, hand a scene to one (with or without a deadline), see the scene with that agent as owner and what it is expected to do ("Break it down into use cases and issues"), and see every open item with its owner, what is expected and whether it is late.

## IS-Atlas-17: the agents, each with what is assigned to it

The agents are one key away from the start page: `g Agents`, as `w What the agent did` is. Each row counts the Assignments that point at the agent: what is assigned to it.

It is all description (`rela/atlas.json`, kind `agent`):

- `start: {key: g, label: Agents}` puts the action on the start page. The kind stays `top: false`, so the start page is still the scenes list.
- `counts: [{relation: assigned_to, text: "{count} assigned"}]` makes each row count the facts that point at it through `assigned_to`. Control reads those facts plainly, without progress: one read per kind the relation starts at. A hint of that kind refreshes the list. A count whose read failed is left out, never shown as 0.

### Try

In test (`atlas tui --env test`):

| Step | Keys / command | What you should see |
|---|---|---|
| An agent | `atlas put agent --name Ada --env test` | `ada` |
| The agents | `g` on the start page | **Agents**: `ada  Ada  0 assigned`, and the coordinator with its count |
| Assign a scene to Ada | `atlas set SC-Atlas-NN assigned_to=ada --cause "handed to Ada" --env test` | Ada's row shows `1 assigned` at once, in every open TUI |
| What is assigned | `enter` on Ada | **Agent ada: Ada**, with the scene's Assignment under **Assignments** |

Since IS-Atlas-83 a fact can be handed over at once: Flow's first look on a new fact writes what is expected and leaves an owner set by hand. Hand to… (`h`) sets the owner and a deadline in one action.

In prod the coordinator's count includes the facts that were done before IS-Atlas-75. They kept the owner the IS-Atlas-52 migration gave them. Flow leaves a fact that becomes done from now on with no owner.

`e2e/scenarios/uc-atlas-06.exs` follows these steps.

## IS-Atlas-14: an optional deadline on the Assignment; late on read

The Assignment has an optional `deadline`, a date and time in UTC. Late is worked out on every read, as Progress is, and never stored. An Assignment is late while its deadline has passed and something is still expected of its owner, so while its fact is not done. Nothing else changes when it is late (SC-Atlas-02 step 9).

It is description, plus one general rule in State and Control:

- **`rela/schema.yaml`:** `deadline: { type: datetime }` on the assignment.
- **`rela/atlas.json`:** the assignment kind gets
  - `late: {after: deadline, while: expected, label: late}`;
  - `by_hand: "update"`: its page offers `u` to change it, and nothing to make or delete one, because an Assignment goes with its fact.
- **State:** it answers `late` with every fact of a kind with a late rule, plain reads too, and refuses a deadline that is not a date and time. rela itself would store one with only a warning.
- **Control:**
  - a page shows `Deadline  2026-11-04 17:00 UTC · late`;
  - a list row supplies `Late · deadline 2026-11-04 17:00`, with late first; the TUI clips the date to fit its compact summary column;
  - a form takes `2026-11-04 17:00` (UTC) or any RFC 3339 time.

### Try

In test, with the scene from IS-Atlas-17 assigned to Ada:

| Step | Keys / command | What you should see |
|---|---|---|
| A deadline that has passed | `atlas set AS-SC-Atlas-NN deadline="2020-01-02 12:00" --env test` | On Ada's page (`g`, `enter` on Ada) the Assignment row starts with `Late · deadline`; the date may end in `…`. `atlas get SC-Atlas-NN --env test` says `Deadline: 2020-01-02 12:00 UTC · late`. |
| One still to come | `atlas set AS-SC-Atlas-NN deadline=2099-01-02T12:00:00Z --env test` | The Assignment row starts with `Deadline 2099`, not late; its detail page shows the full deadline. |
| No time | `atlas set AS-SC-Atlas-NN deadline=tomorrow --env test` | Refused: `deadline must be a date and time, e.g. 2026-11-04T17:00:00Z` |
| By hand in the TUI | `enter` on the Assignment, `u` | **Update AS-SC-Atlas-NN** with **Deadline** (`2026-11-04 17:00`, UTC). Empty removes it. No `d`: an Assignment goes with its fact. |
| Done | accept the scene | Not late any more: nothing is expected once it is done. |

A page that is open when the deadline passes shows late from its next read: `r`, a hint, or the reconcile. Hand to… (IS-Atlas-83) will set the owner and the deadline in one action.

## IS-Atlas-83: Hand to…, the owner and a deadline in one action

Every assignable fact (scene, use case, issue, pull request) has `h Hand to…`. It opens one form:
- **To:** an agent or a person, `←→` to choose;
- **Deadline:** optional, `2026-11-04 17:00`, UTC;
- **Note:** optional.

`ctrl-s` stores the owner and the deadline on the fact's Assignment in one change. The cause is "handed to ada by melle", or the note when you give one.

Flow keeps that owner while the state holds (IS-Atlas-75). A brand-new fact can be handed over at once: Flow's first look writes what is expected and leaves an owner set by hand. Before IS-Atlas-83, that first look counted as a change of state and moved the owner.

It is description, plus one general rule in Control. The association `assigned_to` has

```json
"actions": { "change": { "label": "Hand to…", "key": "h", "with": ["deadline"], "cause": "handed to {to} by {by}" } }
```

- **`change`:** an action shown whether a link is there or not.
- **`with`:** the fields of the fact that holds the link (the Assignment) that the form also asks.
- **`cause`:** used when the note is empty. A note is the cause as it is given, so `atlas set … assigned_to=… --cause …` keeps its own words.

### Try

| Step | Keys | What you should see |
|---|---|---|
| A new scene | `c` on the scenes list, a title, `ctrl-s` | the scene's page, with `h Hand to…` |
| Hand it over at once | `h`, `→` until **To** is `ada`, `↓`, `2099-03-04 09:30`, `ctrl-s` | the Assignment's page: **Assigned to** `ada` (handed to ada by …), **Deadline** `2099-03-04 09:30 UTC` |
| Flow leaves it | wait a moment, `r` on the scene | **Expected** `Build it`, **Assigned to** still `ada` |
| Ada's count | `g` | `ada  Ada  N assigned`, one more |

`e2e/scenarios/uc-atlas-06.exs` follows these steps.

## IS-Atlas-84: a scene with nothing under it is to be broken down

A scene with no use cases is in the scene flow's new first open state, `break_down`. It stays there until something comes under it:
- **Expected:** "Break it down into use cases and issues".
- **Owner:** whoever it was handed to (Hand to…), else the coordinator.

This is "the state its process records" in UC-Atlas-06. Once a use case is under it, the scene is in `building` ("Build it"). A new state moves the owner, so the owner becomes the coordinator. What happens in between (the agent breaking it down) is UC-Atlas-08.

It is description, plus one general condition in Flow:

- **`rela/atlas.json`** (flow `test_and_accept`): `break_down` comes before `building`, with `when: {empty: in_scene}`.
- **Flow:** `empty: <relation>` holds when nothing is under the fact through that parent relation. It never holds for a kind nothing belongs under through it. So a use case (nothing is `in_scene` under a use case) is never in `break_down`, and a use case without issues stays "Build it".
- **State's check:** an `empty` must name a parent relation that puts something under one of the flow's kinds.

In prod, after the merge, every scene without use cases moves from "Build it" to "Break it down into use cases and issues". The owner stays the coordinator, or whoever it was handed to.

### Try

| Step | Keys / command | What you should see |
|---|---|---|
| A new scene | `c` on the scenes list | **Expected** `Break it down into use cases and issues`, **Assigned to** coordinator (`atlas get SC-Atlas-NN --env test`) |
| Hand it to Ada | `h`, `ada`, `ctrl-s` | Ada, and still Break it down |
| A use case under it | `c` on the scene | **Expected** `Build it`, **Assigned to** coordinator (Flow test_and_accept: not all under it is completed) |

`e2e/scenarios/uc-atlas-06.exs` follows these steps.

## IS-Atlas-85: Open work, every open fact with its owner, what is expected, its deadline and late

`l Open work` on the start page lists every open fact: one that someone is assigned to, or of which something is expected. Each row shows
- who it is assigned to (`—` for nobody),
- what is expected,
- its deadline, or `Late · deadline …`,
- since when it is theirs.

Late ones come first, then the newest. `enter` opens the fact. SC-Atlas-02's "Done when" asks for this at every moment.

My work (IS-Atlas-55, the start page "Assigned to you") is the same list, filtered on you: the same reads and the same rows, without the owner. My work now shows the deadline too.

It is description, plus Control's list of the kind the start's relation starts at:

- **`rela/atlas.json`:**
  - `start.open = {title: "Open work", empty: …}`;
  - the assignment kind has `start: {key: l, label: Open work}`.
- **Control:**
  - the list of the Assignment kind (`/k/assignment`, no new page in the contract) is Open work. It reads every Assignment and every fact they belong to, and shows the open ones.
  - `atlas list assignment` gives the same rows, one per open fact, by the fact's key.

Control gathers Open work's unfiltered collection reads in one internal State request. Within that request, State reuses successful raw collection results when progress or completion needs the same collection again; pagination, enrichment and the complete page output stay unchanged. The data is discarded when the request ends, failed reads are not cached, and every later page request reads fresh data. This does not introduce a public protocol operation or a cross-request cache.

If any required collection fails, Open work shows the existing unavailable page with the read error instead of a partial list or the empty-state message. Successful collections do not make the result complete. A later successful request restores the current rows; only a fully successful read can report that nothing is open.

### Try

| Step | Keys / command | What you should see |
|---|---|---|
| Open work | `l` on the start page | **Open work**: `SC-Atlas-NN  A scene handed over at once` with `ada · Break it down into use cases and issues · Deadline 2099-03-04 09:30 · since …`, and the coordinator's open work |
| A deadline that passes | `atlas set AS-SC-Atlas-NN deadline="2020-05-06 07:08" --env test` | The scene comes first: `ada · Break it down … · Late · deadline 2020-05-06 07:08` |
| From the command line | `atlas list assignment --env test --json` | the same rows |
| Done | accept a use case | it leaves Open work: nobody is assigned and nothing is expected |

`e2e/scenarios/uc-atlas-06.exs` follows these steps.
