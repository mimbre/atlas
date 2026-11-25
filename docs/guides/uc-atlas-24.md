# Try UC-Atlas-24: Clarifications go to the producer

What you can do: when Design picks up a scene that is too vague to design use cases from, its agent does not guess. It writes its questions, and Flow takes the scene to its producer. You answer them, or rewrite the scene first, and Design goes on with a fresh pass of its agent, which then proposes use cases (SC-Atlas-09: questions about an item go to its producer).

Until a scene records who produced it, its producer is the environment's configured decider (`actors.decider`, `melle` on test), as for Accept.

## Start

```sh
atlas tui --env test
```

`--env test` is needed: `atlas` on its own opens prod. You need a Runtime of yours that takes work on test (`docs/guides/agent-cli.md`), because Design's agent runs only on its supervisor's Runtimes.

## Try

| Step | Where | What you should see |
|---|---|---|
| A vague scene | TUI: `c` a scene, title `Reports`, description `Reports.`, `ctrl-s` | `SC-Atlas-NN`, in Design (`Break it down into use cases`), with nobody's work started: it waits for its pickup. |
| Pick it up | its page, **Pick up**, or `atlas do SC-Atlas-NN "Pick up" --env test` | You supervise Design. One agent task (`TK-SC-Atlas-NN-1`) is offered to your Runtimes. |
| Its agent asks | wait for the task to end; open **Assigned to you** | A To-Do on the scene: **Answer its questions**, why `its agent cannot design use cases from it without guessing`, a section **Its agent's questions** with what the agent wrote to `questions.md`, and one answer, **Answered** (`a`), which asks for a note. No use case was made under the scene. Its page shows the questions under **Its agent's questions**. You cannot edit that field: only Flow writes it. |
| Rewrite it (optional) | the scene's page, `u`, change **description**, `ctrl-s` | Stored. The To-Do stays: rewriting does not answer it. |
| Answer | `a` on the To-Do, a note such as `Monthly sales per region, for the board, as PDF.`, `ctrl-s`; or `atlas do SC-Atlas-NN Answered --note "Monthly sales per region, for the board, as PDF." --env test` | Without a note it is refused. With one, the note is the scene's **Producer's answers**, the To-Do is gone, and the scene is back in **Break it down into use cases**. A fresh task (`TK-SC-Atlas-NN-2`) is offered to the same supervisor's Runtimes: you still supervise it. |
| Design goes on | wait for that task to end | Its instructions carried the questions, your answers and the current description (`atlas get TK-SC-Atlas-NN-2 --env test`). Its proposed use cases are under the scene, and **Accept its use cases** is your To-Do, as before. If it is still too vague, it asks again, and the questions are replaced. |

## Who wrote what

The agent never writes into Atlas. Flow reads `questions.md` from the task's result, the only writer of **Its agent's questions**: its write is `by flow`, with the cause `For melle: asked by TK-SC-Atlas-NN-1`. The Answered note is written by the person who answers (`by melle`, through Control), as are any changes to the description. Facts records the `by` and `cause` of every write in its ledger, and sends them with each write's hint.

What is not there yet: no page in Atlas lists the history of a fact's *fields*. Only links have one, shown as `… · by … · cause`. So this guide cannot show "Flow wrote the questions, melle wrote the answers" on one page. That needs a field history, which D-0100 says to ask rela for first. See "Left open" below.

## What changed for this

- **The model DSL** (`products/software_factory/model/generator`): a task may name `asks: [field: :questions, file: "questions.md"]` beside `creates:` or `writes:`. It then has a result of its own, `asked`, which its `on:` must map. A ladder task cannot ask this way, and the questions file cannot be the proposal's file. The composition checks that the field is the subject's.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/activities/task.ex`): the agent's instructions end with how to ask. After a completed task whose questions file is there and not empty, Flow puts its text in the subject's field, makes no use cases, and the run takes `asked`. With no such file, or an empty one, the proposal is read as before.
- **The model** (`products/software_factory/model/contract/eyra/scene.ex`): the scene has `questions` (Flow's only) and `answers`, and Design's task reads both. Design has a new state, **Answer its questions** (`clarifying`), owned by the scene's producer and inside Design's supervised span. Its one answer, Answered, writes its note into `answers` and goes back to `break_down`. A migration (`states: :same`) keeps every run where it is. The targets are regenerated (`mix model.gen`).
- **Control and Console**: nothing new. The To-Do, its section and its answer come from the generated contract.

## Left open

- The field history (above).
- The To-Do shows one section, the questions. The scene's description is on its page, not in the To-Do, because a To-Do shows one field.
- A use case in Plan that is too vague to break down (Melle's note of 2026-11-24) still guesses. The same `asks:` is ready for `break_down_use_case`.
- The flow diagrams (`products/software_factory/model/targets/diagrams/`) are drawn by rela. They were not redrawn here; run `mix model.gen` with `ATLAS_RELA_BIN` set.

<sub>Written by an AI agent (Claude Code · claude-opus-5-5).</sub>
