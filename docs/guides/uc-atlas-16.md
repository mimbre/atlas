# Try UC-Atlas-16: The agent's tools and plans

What you can do: see the tools an agent gets, and ask an agent for a plan on a page. The tools are Control's own actions, made from rela's description. The plan says which form each step would fill, and with what. Nothing is written: the TUI shows no change.

This is the part of SC-Atlas-04 an agent sees. Asking from the TUI with `:` comes next (UC-Atlas-17, IS-Atlas-40).

## Start

```sh
atlas tui --env test
```

`--env test` is needed: `atlas` on its own opens prod. Planning in prod writes nothing either, but try it in test first.

## Try

In a second terminal, next to the TUI:

| Step | Command | What you should see |
|---|---|---|
| The tools | `atlas tools --env test` | A `put` and a `set` per kind, then `get`, `list` and `help`. A put shows the command line, what its create form asks and the kind it goes in: `atlas put use_case --in <scene key> --title <text> --description <lines>`. A set lists the fields a person may change; fields only a connector fills (the Flux id) are not there. |
| A scene to plan from | in the TUI, a scene (`c`) with a description that lists a few use cases, `ctrl-s` | The scene, with **Use cases**: `No use cases yet.` |
| A plan | `atlas plan --env test --on SC-Atlas-NN "propose use cases from this scene's description"` | After a few seconds: `Plan by claude -p for …`, what the agent says, and one step per use case: `Create use case in SC-Atlas-NN`, with its title and description and why. It ends with `Nothing was written.` |
| Nothing changed | look at the TUI | Still `No use cases yet.`, and no hint in the status line. |
| A step that does not fit | `atlas plan --env test --on SC-Atlas-NN "give it a colour field set to red"` | Claude will likely answer that no such field exists. When a planner proposes a field a form does not ask for, the step shows `✗ … does not ask for …`, before anyone could run it. |

### Delete (IS-Atlas-39)

| Step | Command | What you should see |
|---|---|---|
| Delete | `atlas delete UC-Atlas-NN --env test`, on a use case without issues | `Deleted UC-Atlas-NN.` The TUI on its scene drops it within a second, by hint. |
| Refused | `atlas delete SC-Atlas-NN --env test`, on a scene that still has use cases | `refused: SC-Atlas-NN still has 1 use case. Remove it first …`: the text the TUI shows on `d`. Exit status 1. |
| As a step | in the TUI, on a use case: `:`, `delete this use case`, `enter` | A plan of one step, `Delete use case UC-Atlas-NN?`. It asks even though it is one step, because a plan with a delete always asks. `enter` deletes it: `Deleted UC-Atlas-NN.` |

`atlas tools` lists `delete <key>` with the rest.

`--json` prints the plan as JSON: its steps with the form's `label`, the `inputs` (the same inputs the TUI's form has, with the proposed values) and a `problem` when a step cannot run.

## How it works

- **The tools** come from Control, as the TUI's pages do: `/_kinds` (what rela describes) and each kind's create form. No tool is written by hand. A kind added to rela is a new tool.
- **The planner** gets the request, the page you are on (its blocks, as Control sends them) and the tools. It answers steps, each a `put` of a kind, or a `set` or `delete` of a key. Which planner runs is a setting of the environment, `agent.planner` in `products/software_factory/environments/<env>.json`. `"claude"` is a local headless Claude session (`claude -p`) whose only tools are `atlas get`, `atlas list` and `atlas help`, on the same environment. Or it is any command that reads the input as JSON on stdin and prints the plan as JSON. The Runtime of SC-Atlas-02 takes this place later.
- **The check** opens the form each step would fill, as the TUI would, and submits nothing. An unknown kind or field, a parent that is not there or is of another kind, a missing required field: the step says so.

## What changed for this

- **The agents' command line** (`platform/clients/agent`): `atlas tools` and `atlas plan`; `AtlasAgent.Tools`, `AtlasAgent.Planner`, `AtlasAgent.Plan`. None of it names a kind.
- **Settings:** `products/software_factory/environments/test.json` and `products/software_factory/environments/prod.json` have `"agent": {"planner": "claude"}`.
- **The end-to-end test:** `products/software_factory/e2e/scenarios/uc-atlas-16.exs` follows this guide with a scripted stand-in planner (`products/software_factory/e2e/fixtures/planner.exs`), so CI needs no model.
