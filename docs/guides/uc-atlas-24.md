# Try UC-Atlas-24: Clarifications go to the producer

What you can do: pick up a scene that is too vague to design use cases from, and see that Design does not guess. Its agent asks its questions, and they go to the scene's producer as a To-Do. The producer answers them, or rewrites the scene, and Design carries on with a fresh pass of its agent. The run keeps its supervisor the whole time. Flow writes the questions, the producer writes the answers, and the history says so (SC-Atlas-09).

Until a scene records its producer, its producer is the environment's configured decider (`actors.decider` in `products/software_factory/environments/test/core.json`), the same person who accepts a scene. On test that is also usually the one who picks the scene up, but the two roles stay separate. The To-Do goes to the decider even when someone else supervises the run, and the run's agent work still runs on the supervisor's Runtimes.

## Start

```sh
atlas tui --env test
```

You need a Runtime of yours connected to test, as for any pickup (`docs/guides/agent-cli.md`). `--env test` is needed: `atlas` on its own opens prod.

## Try

| Step | Where | What you should see |
|---|---|---|
| A vague scene | TUI: `c` a scene, title `Things`, description `Make it better.`, `ctrl-s` | `SC-Atlas-NN`, phase **Break down**, state **Break it down into use cases**. Nothing runs yet. |
| Pick it up | `atlas do SC-Atlas-NN "Pick up" --env test` | `Supervised by  <you>`. One task, `TK-SC-Atlas-NN-1`, is offered to your Runtimes. Its instructions, as its agent gets them, end with **If you cannot propose yet**: write the questions to `questions.md` and no proposal. |
| Its agent asks | wait for the task to end | The scene is in **Answer its questions**. **Its agent's questions** holds what the agent wrote, and no use cases are under the scene. The task ended `completed`, and the run took its `asked` branch. `Supervised by` has not changed. |
| The producer's To-Do | the producer's (the decider's) **Assigned to you**: the scene, `↵` | **What to do: Answer its questions**. **Why** says how it came to you, and **Its agent's questions** shows the questions. The page also shows the scene's description. **Answers**: `a Answered`. |
| Rewrite it (optional) | `u` on the scene, rewrite the description (say: who it is for and what they do), `ctrl-s` | The description is saved. The run stays in **Answer its questions**: rewriting does not answer. |
| Answer | `a` and a note with the answers, `ctrl-s`. Or from the command line: `atlas do SC-Atlas-NN Answered --note "Newcomers to the team; they read the README first." --env test` | **Its producer's answers** holds the note, and the scene goes back to **Break it down into use cases** in the same run (the same generation, the same supervisor). A fresh task, `TK-SC-Atlas-NN-2`, goes to your Runtimes. Its instructions carry, under their own headings, the `description` as it is now, the `questions` and the `answers`. |
| Design continues | wait for the task to end | Use cases under the scene, designed, and **Accept it** for the supervisor, as before. If the agent still finds the scene too vague, it asks again and the To-Do comes back. |
| Who wrote what | the To-Do's **Why** line, and each write's answer from Facts (in the TUI's `updated by hint` and in rela's history of the scene) | The questions were written by `flow`, cause `For <supervisor>: asked by TK-SC-Atlas-NN-1`, never by the agent. The answers, and any rewritten description, were written by the producer. Atlas keeps no history of its own (D-0100): ask the pinned rela (`docs/guides/rela.md`) how it shows a fact's changes. |

## What changed for this

- **The model DSL** (`products/software_factory/model/generator/lib/schema.ex`): a task that proposes (`creates:` or `writes:`) may also name `asks: [field:, file:]`. Such a task has one more result, `asked`, which its `on:` maps. The compile refuses `asks:` without a proposal, inside a ladder, or naming its proposal's file, and the description check refuses a field the subject lacks. An owner default may be `{kind, config: role, supervisor: false}`: the configured actor even inside a supervised span, for a state that asks someone other than the run's supervisor.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/activities/task.ex`): the agent's instructions explain the questions file. When the task completed and its result has that file with any text in it, Flow, the only writer, puts the text in the subject's field, by `flow` and with the run's supervisor in its cause. It makes nothing of any proposal, records nothing to discard, and the task ends `asked`. If the file is missing or empty, nothing changes from before. `AtlasFlow.Model.owner/3` keeps a `supervisor: false` default with its configured actor.
- **The model** (`products/software_factory/model/contract/eyra/scene.ex`): the scene has `questions` (Flow's only, `set_by: [:flow]`) and `answers` (the producer's). Design's task asks to `questions.md` and reads `title`, `description`, `questions` and `answers`. Its new state `clarifying`, **Answer its questions**, lies in Design's span, so the run keeps its supervisor. It is owned by the configured decider, not the supervisor, shows the questions, and offers **Answered** with a note into `answers`, which goes back to `break_down`. There is no migration: since D-0102 a run continues in its state by name, and a new state needs none.
- **Control and the Console**: nothing new. The To-Do, its section and its answer come from the generated contract.
- **Tests**: `products/software_factory/model/contract/test/pipeline_runs_test.exs` and `sent_back_runs_test.exs` (the run end to end: asked, the producer's To-Do, Answered, a fresh pass with the questions, answers and current description, then use cases as before), `platform/atlas_flow/test/activities/proposal_test.exs` (questions set the field and make nothing; no file or an empty one, as before), `platform/atlas_flow/test/supervised_owner_test.exs`, and `products/software_factory/model/generator/test/schema_test.exs`.

<sub>Written by an AI agent (Claude Opus 5.5).</sub>
