# Try UC-Atlas-18: Run, follow and stop the steps

What you can do: after `enter` on a plan (UC-Atlas-17), watch each step go, one at a time, in both TUIs, and stop the agent with `esc` before its next step. The steps already stored stay.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2, on the same scene.

## Try

| Step | Keys | What you should see |
|---|---|---|
| A plan | on a scene whose description lists a few use cases: `:`, `propose use cases from this scene's description`, `enter` | `Proposed: N steps`. |
| Run | `enter` | The step being run shows `[…]`. Each stored step turns `[✓] … Stored as UC-Atlas-NN.`, and the title counts: `Running: 1 of N stored`. TUI 2 shows each use case by hint as it is stored. Once the last one is stored: `Done: N of N stored`, without the pause between steps. |
| Stop | ask again, `enter`, then `esc` while it runs | `Stopping after this step…`, then `Stopped: 1 of N stored`. The steps not run show `[-] … Not run: stopped before it.` Only the stored ones are in the scene. |

Nothing is rolled back by itself: undoing a stored step is an overrule (UC-Atlas-19).

### A refused step

When Facts refuses a step, the run stops there, and the agent proposes what next as a new plan. That plan runs only on `enter`, like any other. The agent never retries a refused step by itself.

| Step | Keys | What you should see |
|---|---|---|
| The item is gone | ask on a scene, then in TUI 2 delete that scene (`d`, `y`) before you press `enter` in TUI 1 | Step 1 is refused: `SC-Atlas-NN does not exist`. Then `Planning…`, and the new plan says **Before**: `Step 1 (Create use case in SC-Atlas-NN) was refused: SC-Atlas-NN does not exist. Nothing was stored. Not run: step 2, step 3.` What the agent proposes there cannot run either: its steps show `[!] … SC-Atlas-NN is not a scene in Atlas`. `esc`. |
| A step that breaks a rule | ask, `e` on step 2, clear its title, `ctrl-s`, `enter` | Step 1 is stored. Step 2 is refused (`title is required`), and the rest is not run. The new plan's **Before** says so and proposes what is left. `enter` runs it. |

With Claude as the planner, the summary says what was refused and why. Claude is told never to propose the refused step again only to get it stored.

### Small plans run without asking

A plan of at most `agent.ask_above` steps (1 by default, in `env/<env>.json`; 0 asks always) runs at once, as long as every step can run and none deletes. A plan made after a refusal always asks.

| Step | Keys | What you should see |
|---|---|---|
| One step | on a scene: `:`, `rename this scene to A day in Atlas`, `enter` | No question: `Running …, without asking`, then `Done: 1 of 1 stored, without asking`. The scene's new title shows in both TUIs. |
| More steps | `:`, `propose use cases from this scene's description` | `Proposed: N steps`: it asks, as before. |

A plan that ran by itself shows like an accepted one, so each step can still be overruled (UC-Atlas-19).

## How it works

The agent (`atlas steer`) runs one step at a time and reads its messages between steps, so a stop is seen before the next step. It waits `agent.step_pause_ms` between steps, set in `env/<env>.json` and 0 when unset. That is long enough to follow a run and to stop it. The end-to-end test uses 2000: its keys wait for a settled screen, and the TUI holds an Escape a moment (IS-Atlas-68).

## What changed for this

- **The agent:** the pause between steps; steps not run say why; after a refusal it asks the planner what next, with what happened (`before`).
- **Control's contract:** the plan block's `before` (contract 0.5.0).
- **The agent:** a plan of at most `agent.ask_above` steps runs without asking (test and prod: 1).
- **The TUI:** "Stopping after this step…" is cleared when the plan ends.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-18.exs`.
