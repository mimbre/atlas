# Try UC-Atlas-24: Design asks the scene's producer instead of guessing

What you can do: pick up a scene that is too vague to design use cases from, and see Design ask instead of guessing. Its agent writes its questions. Flow puts them on the scene and gives the scene's producer a To-Do, **Answer its questions**. The producer answers, rewriting the description first if they want, and Design runs its agent again with the answers. A question about an item goes to its producer (SC-Atlas-09), while the run keeps its supervisor.

## The rule

- Design's agent may write `questions.md` instead of `use_cases.json` when the scene is too vague. When the task completes and its result has that file, with text, Flow puts the text in the scene's **Its agent's questions** (`questions`). It makes no use case, and the task ends `asked`. Without the file, or with an empty one, nothing changes: its use cases are made and **Accept it** follows.
- The agent never writes into Atlas, and neither questions nor answers are written by a person on Flow's behalf. Flow writes the questions (`by flow`, cause `For <supervisor>: asked by TK-SC-Atlas-NN-1`). The producer writes the answers (**Its producer's answers**, `answers`), through Control, as themselves.
- **Answer its questions** (`clarifying`) is the scene's producer's. A scene records no producer yet, so that is the configured decider (`actors.decider` in `products/software_factory/environments/test/core.json`), as for Accept. Inside Design's supervised span it never goes to the supervisor in the producer's place (`producer: true` on its owner). The run keeps its supervisor, and the next agent work runs on the supervisor's Runtimes.
- **Answered**, with a note, takes the run back to **Break it down into use cases** and offers fresh agent work. The new task reads the scene's title, its description as it is then, the questions and the answers.

## Start

```sh
atlas tui --env test
```

You need a Runtime of yours enrolled on test, so the picked-up Design has somewhere to run (`platform/atlas_runtime/host/README.md`). In this guide you are both the supervisor and, as the configured decider, the producer. With someone else as decider, the To-Do is theirs, not yours.

## Try

| Step | Where | What you should see |
|---|---|---|
| A vague scene | `atlas put scene --title "Reports" --description "Something with reports." --env test` | `SC-Atlas-NN`, in phase **Break down**: Design has it. |
| Pick it up | its page in the TUI, **Pick up**, or `atlas do SC-Atlas-NN "Pick up" --env test` | **Break it down into use cases**, supervised by you. One task, `TK-SC-Atlas-NN-1`, is offered to your Runtime. Its instructions end with **Your questions**: write them to `questions.md` when the scene is not clear enough, and write no proposal. |
| Its agent asks | wait until the task ends | The scene has no use cases. Its page shows **Its agent's questions** with the agent's text. **Assigned to you** lists it as **Answer its questions**, and its Design run is still supervised by you. |
| The To-Do | **Assigned to you**, `↵` on the scene | **What to do: Answer its questions**, **Its agent's questions** with the questions, and the scene in full below, its description included. **Answers**: `a Answered`. |
| Rewrite the description (optional) | `u` on the scene, change **Description**, `ctrl-s` | Stored. The To-Do stays: only Answered moves it on. |
| Answer | `a`, a note of one or more lines, `ctrl-s`; or `atlas do SC-Atlas-NN Answered --note "The cost per scene, read by its supervisor." --env test` | Without a note it is refused. With one, the note is the scene's **Its producer's answers**, the To-Do leaves Assigned to you, and the scene is back in **Break it down into use cases**. |
| Design continues | wait for the new task, `TK-SC-Atlas-NN-2`, on your Runtime | Its instructions hold the scene's description as you left it, **Its agent's questions** and **Its producer's answers**. This time it proposes use cases: they appear under the scene, and **Accept it** comes to you as before. |
| A clear scene | `atlas put scene --title "Newcomers" --description "A newcomer reads the README, installs atlas and opens the Console on test." --env test`, then pick it up | No questions. Its use cases are made and **Accept it** follows, as before this change. |

### Who wrote what

The questions are written by Flow and the answers by you. Flow's write says `by flow` and names its task in its cause (`For <you>: asked by TK-SC-Atlas-NN-1`). Your answer is your own write through Control. The To-Do's **why** line shows Flow handing the scene to you (`since … · by flow`).

A scene's page does not yet list who wrote each field. Facts keeps that with each write (its ledger and its hints), but no page or command shows a field's history. Until one does, you see it in the tests (`products/software_factory/model/contract/test/clarifying_runs_test.exs` checks both writers), not on test. Per D-0100 a value history is rela's to offer, not something to build beside it.

## What changed for this

- **The model DSL** (`products/software_factory/model/generator`): a task may name `asks: [field:, file:]` beside `creates:` or `writes:`. It then also ends `asked`, which its `on:` must map. Its field must be the subject's, and its file is not the proposal's. A state's owner may say `producer: true`, with a configured default: the subject's producer owns that state, never the run's supervisor in their stead.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/activities/task.ex`): with `asks`, the agent's instructions end with **Your questions**. A completed task whose result has that file, with text, has Flow write it to the subject's field and nothing else, and ends `asked`; its result keeps nothing to discard. `AtlasFlow.Runs.Projection` leaves a `producer: true` state with its configured actor inside a span.
- **The model** (`products/software_factory/model/contract/eyra/scene.ex`): the scene's `questions` (Flow's) and `answers` (its producer's). Design's task asks (`asks: [field: :questions, file: "questions.md"]`), reads both and tells its agent when to ask. Its new state **Answer its questions** (`clarifying`) lies in Design's span, is its producer's, shows the questions and offers **Answered**, with a note into `answers`, back to its break-down. A migration keeps every run where it is, its entry included.
- **Control and Console**: nothing new. The To-Do, its section and its answer come from the generated contract.
- **Tests**: `clarifying_runs_test.exs` (the model, end to end on Flow's work source), `proposal_test.exs` and `supervised_owner_test.exs` (Flow), `schema_test.exs` (the DSL).
