# Try UC-Atlas-24: Clarifications go to the producer

What you can do: pick up a scene that is too vague to design use cases from. Design's agent does not guess. It writes its questions, and Flow takes the scene to its producer as **Answer its questions**. You answer them, or first rewrite the scene's description. Design then continues with a fresh pass of its agent, which reads your answers and the description as it is now, and proposes use cases.

Until a scene records who produced it, its producer is the environment's configured decider (`actors.decider` in `products/software_factory/environments/<env>/core.json`), as for Accept. On test that is the TUI's user, `melle`.

## Before you start

- `atlas tui --env test`. `--env test` is needed: `atlas` on its own opens prod.
- A Runtime of yours on test that runs agent work (`platform/atlas_runtime/host/README.md`). Design's work runs only on its supervisor's Runtimes.

## Try

| Step | Where | What you should see |
|---|---|---|
| A vague scene | TUI: on **Scenes**, `c`, title `Make it better`, description `Make Atlas better.`, `ctrl-s`; or `atlas put scene --title "Make it better" --description "Make Atlas better." --env test` | `SC-Atlas-NN`, in its break-down. It is on **Open for you** under **Design**. |
| Pick it up | its page, **Pick up**; or `atlas do SC-Atlas-NN "Pick up" --env test` | `Supervised by: melle`. One agent task, `TK-SC-Atlas-NN-1`, is offered to your Runtime. Its instructions end with **Your questions**: write them to `questions.md`, and nothing else, when the scene is not clear enough. |
| Its agent asks | wait for the task to end; **Assigned to you** | `SC-Atlas-NN  …  Answer its questions`. No use cases were made under it. |
| Its To-Do | open the scene | **What to do**: *Answer its questions*, because *its agent cannot design use cases from it as it is written*, with **Its agent's questions** (the text of `questions.md`) and one answer, **Answered** (`a`), which asks for a note. The scene's description is on the same page, below. |
| Rewrite it (if you like) | `u`, change the **Description**, `ctrl-s` | The description is stored. The run waits: it is still **Answer its questions**. |
| Answer | `a`, your answers as the note (several lines if you like), `ctrl-s`; or `atlas do SC-Atlas-NN Answered --note "1. …" --env test` | Without a note it is refused. Stored: **Producer's answers** holds your note, the scene leaves Assigned to you, and it is back in its break-down, still `Supervised by: melle`. A new task, `TK-SC-Atlas-NN-2`, is offered to your Runtime. Its instructions carry `## description` (as it is now), `## questions` and `## answers`. |
| Design continues | wait for the task to end; **Assigned to you** | `SC-Atlas-NN  …  Accept its use cases`, with the use cases its agent proposed under the scene. From here it goes on as before: accept them, or send them back with a note. |

If the agent asks again, its new questions replace the old ones and it comes back to you. When the agent writes an empty `questions.md`, or none, the task ends as it did before this change: its use cases, or stuck when it proposed none.

## Who wrote what

- **The questions are Flow's.** `Its agent's questions` is a field only Flow writes (`set_by: [:flow]`): no form offers it, and Facts refuses anyone else's change to it. Flow wrote it `by flow`, with the cause `For melle: asked by TK-SC-Atlas-NN-1`. The agent writes only `questions.md` in its result. It never writes into Atlas.
- **The answers are yours.** Control writes the Answered change `by` you, with your note as its cause. Flow never writes as you.
- **Who had it.** `atlas get SC-Atlas-NN --env test` shows `Assigned to: melle (since …, by flow: Flow Design: its agent cannot design use cases from it as it is written → melle)`. Each earlier owner stays in the link's history.

Not yet visible: the `by` and cause of a field's write. Facts keeps the history of links, not of field values (it hands rela only the values), so no page shows who last wrote the questions or the answers. This needs rela's own history of a fact's changes, which is a question for rela (D-0100), not something Atlas builds.

## What changed for this

- **The model DSL** (`products/software_factory/model/generator`): a task may name `asks: [field:, file:]` beside `creates:` or `writes:`. A task with it also ends `asked`, which its `on:` maps. It must name a field of the subject, a file of its own, and no ladder.
- **Flow** (`AtlasFlow.Activities.Task`): such a task tells its agent where its questions go. Once it completed with that file there and not empty, Flow puts the file's text in the field, reads no proposal, makes nothing, and the run takes `asked`. With no such file, or an empty one, nothing changed.
- **The model** (`products/software_factory/model/contract/eyra/scene.ex`): the scene has `questions` (Flow's) and `answers` (its producer's). Design's task asks into `questions.md`, reads `questions` and `answers`, and its `asked` goes to `clarifying`, **Answer its questions**: the producer's, inside Design's supervised span, so the run keeps its supervisor. Answered writes `answers` and goes back to `break_down`. A run already in Design keeps its state and its entry (`migrate(:break_down_scene, …)`).
- **Control and Console**: nothing new. The To-Do, its section and its answer come from the generated contract.
- **Tests**: `products/software_factory/model/contract/test/clarifying_runs_test.exs` (asked → the producer's To-Do → Answered → a new task with the questions, the answers and the current description → use cases as before) and `platform/atlas_flow/test/activities/proposal_test.exs` (questions set the field, make nothing and end asked; without them, nothing changed).
