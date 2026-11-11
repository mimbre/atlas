# Try UC-Atlas-17: Ask in the TUI and see the plan

What you can do: on any page, press `:` and say what you want. An agent reads the page and proposes a plan, one step per form it would fill. You keep, edit or drop each step, then `enter` runs the kept steps through Control, as if you had filled each form. Nothing is written before that.

The first real case comes from your own first use case in Atlas: "UCs should be created with the help of agents. Based on the Scene description."

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2. The agent is a local headless Claude session (`claude -p`) that may only read Atlas. A plan takes about ten seconds.

## Try

In TUI 1, on a scene whose description says which use cases it needs (make one with `c`, or use one of yours):

| Step | Keys | What you should see |
|---|---|---|
| Ask | `:` | A request line at the bottom. Enter sends the request; Esc cancels. In this text editor, `?` is literal input. |
| | type `propose use cases from this scene's description`, `enter` | `Planning…`, then `Proposed: N steps`: what you asked, who planned (`claude -p`), what it says, and per step `[✓] 1. Create use case in SC-Atlas-NN` with its title, description and why. TUI 2 shows no change. |
| Drop | ↑/↓ to a step, `space` | `[ ]`: the step is dropped. `space` again keeps it. |
| Edit | ↑/↓ to a step, `e` | `Step N: Create use case in SC-Atlas-NN`: the step's title and description in the form you know. Change them, `ctrl-s` keeps the edit (`esc` does not). The plan shows the new values. |
| Run | `enter` | Each kept step turns `[✓] … Stored as UC-Atlas-NN.`, then `Done: N of N stored`. TUI 2 shows the new use cases by hint, and the dropped one is not made. |
| Close | `enter` | The scene, with its new use cases. |

Also try:

- **Cancel.** Ask again, then `esc` on the plan: nothing is written. `esc` while it is still planning stops the agent.
- **Change the request.** On a proposed plan, `:` opens the line with your request in it. Change it and `enter` asks again.
- **Nothing to do.** Ask something the page gives no reason for: `No steps proposed`, and the agent says why.
- **A step that cannot run.** When a planner proposes a field a form does not ask for, the step shows `[!]` with the reason. `enter` refuses until you drop it.

Following each step closely, stopping a run with `esc` and what happens on a refusal are UC-Atlas-18. Seeing afterwards what the agent did, and overruling it, is UC-Atlas-19.

## How it works

- **The agent** is `atlas steer`, started by the TUI on the first `:` as a child process and kept while the TUI runs. It is a Control client of its own, with its own connections, like `atlas put`. The TUI and the agent talk in JSON lines (`AtlasAgent.Steer`). Its log is `steer.log` beside the environment's other logs.
- **The plan** comes from the planner of UC-Atlas-16 (`agent.planner` in `env/<env>.json`), checked against Control's forms. The agent writes only on `enter`, and only the kept steps of the plan you saw, with the values you left.
- **The plan is a block** of Control's contract: `plan` with its `step`s (contract 0.5.0). An iOS or macOS client renders the same thing. Today the agent sends it; once Runtime runs agents (SC-Atlas-02), Control will.

## What changed for this

- **Control's contract:** the `plan` block and the `step` model; `bff/targets/json/blocks.json` regenerated.
- **The TUI:** `:` (not in a form), the plan over the page (the page underneath still follows hints), the step form, and the agent as a child process. It knows no kind: steps are form titles and inputs.
- **The agents' command line:** `atlas steer`.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-17.exs` follows this guide with the scripted stand-in planner.
