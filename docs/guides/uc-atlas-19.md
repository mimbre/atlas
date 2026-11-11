# Try UC-Atlas-19: See and overrule what the agent did

What you can do: see every request you made with `:`, what became of it and each step of its plan. From an item the agent made or changed, reach the step and the request that caused it. Everything the agent does is kept as facts in Facts, like any other change, so it is there after a restart and can be overruled with `x` (IS-Atlas-46).

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys | What you should see |
|---|---|---|
| A request | on a scene with a description: `:`, `propose use cases from this scene's description`, `enter`; drop one step with `space`, then `enter` | The plan runs, as in UC-Atlas-17. |
| What the agent did | `esc` back to the start page, then `w` | **Agent requests**, newest first. Each row has its id (`RQ-Atlas-NN`), your request and its outcome: Done, Done without asking, Stopped, Refused, Cancelled. |
| One request | `enter` on it | Its page: the page you asked it on, who planned it (`claude -p`), its outcome, what the agent said, and **Steps**. Each step has its form's title and its state: Stored, Refused, Dropped or Not run. There is no key to create, update or delete it: only the agent writes this record. |
| One step | `enter` on a step | The values it gave, what it made (`UC-Atlas-NN`) and, for a change, the values it replaced. |
| From the item | open the use case the agent made | Its references have **What the agent did here**, with the step that made it. `enter` on it, then the step's request. |
| Cancelled | ask again, then `esc` | It is kept too, as Cancelled, at the top of the list. |

The same from the command line: `atlas list agent_request --env test`, `atlas get RQ-Atlas-NN --env test`.

### Overrule a step (IS-Atlas-46)

On a stored step, `x Overrule` proposes the steps that undo it, as a plan you accept with `enter` like any other. It never runs by itself. The agent works the plan out from the step's record, without asking a planner:

| The step | What undoes it |
|---|---|
| made an item (`Create …`) | a delete of that item: `Delete use case UC-Atlas-NN?` |
| changed an item (`Update …`) | a change back to the values it replaced, which the step kept |
| deleted an item | nothing yet: the record does not keep what was deleted, and the plan says so |

| Step | Keys | What you should see |
|---|---|---|
| Overrule | `w`, a request, a stored step, `x` | `Proposed: 1 step`. **You asked**: `Overrule ST-Atlas-NN: 1. Create use case in SC-Atlas-NN`. **By**: `Atlas, from the record of ST-Atlas-NN`. The step: `[✓] 1. Delete use case UC-Atlas-NN?` |
| Run | `enter` | `Deleted UC-Atlas-NN.`, `Done: 1 of 1 stored`. A second TUI on the scene drops the use case by hint. |
| The cause | back to the request you overruled | **Overruled by** lists the overrule. The overrule is a request of its own (`overrules` names the one it reverses, d-0016). |
| A change | `:` `rename this scene to …` (runs without asking), then `w`, that request, its step, `x`, `enter` | The scene has its old title again. |

A dropped, refused or not-run step stored nothing, so it has no `x`. If the item has changed since and something now hangs under it, the delete is blocked, with Control's reason.

## How it works

- **The record is described in rela like any kind:** an *agent request* (`RQ-Atlas-NN`) and an *agent step* under it (`ST-Atlas-NN`), in `rela/schema.yaml`. `rela/atlas.json` says what Control and the agent do with them, as data:
  - `agent`: the kinds hold the agent's record. The agent never offers them as tools.
  - `start`: requests are not on the start page; `w What the agent did` is. When the start page becomes My work plus Scenes (SC-Atlas-06), this is the line to change.
  - `order`: newest first.
  - `by_hand`: no keys to create, update or delete them.
  - `cause` on a step's `made`: an item's page lists the steps that made or changed it.
  - `add: false` on the steps of a request: no key to add one.
- **The agent writes the record through Control**, like any client:
  - the request once its plan is made;
  - each step that ran, was refused, dropped or not run, with the key it made or changed and the values it replaced;
  - the outcome at the end.
- **If keeping the record fails**, the TUI says so in a notice. It never makes the agent do more or less.

## What changed for this

- **rela:** the two kinds, their relation and the rules above.
- **Control:** the generic rules `start`, `order`, `by_hand`, `cause` and `add`. `/_kinds` also says which kinds hold the agent's record.
- **The agent:** `AtlasAgent.Record`. `atlas get` reads the exact values of a kind without an update key too.
- **Overrule (IS-Atlas-46):**
  - In the description, `actions` on the step kind: `x Overrule` while its state is stored, `to: agent:overrule`. A request's `overrules` field, marked `cause: "Overruled by"`.
  - In Control, actions from the description (with `when`), and cause lists of a fact's own kind.
  - In the TUI, an `agent:` action asks the agent.
  - In the agent, `AtlasAgent.Overrule`.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-19.exs`.
- **Prod:** rela reads `schema.yaml` when it starts, so prod's rela needs a restart for the new kinds.
