# Try UC-Atlas-23: Every item has a producer

What you can do: make a use case or an issue by hand and see that it records its producer, as a scene does. Have a review's follow-ups become issues produced by the build's supervisor. See that nothing makes a scene, use case or issue without a producer (SC-Atlas-09).

Every scene, use case and issue records its producer (`produced_by`). That is the supervisor of the flow that made it, or, for one made by hand, the person who made it. When an agent makes it, that is the person the agent assists, and the history says the agent wrote it on their behalf. Questions about an item go to its producer. A new one is never without: a create that would record none is refused and nothing is stored. Only an item from before producers were recorded has none. It keeps working, and the configured decider counts as its producer ([Items from before](#items-from-before)).

## Start

```sh
atlas tui --env test
```

You need a person of test at their own Console (their machine's `tui_user`; `docs/guides/agent-cli.md`); call them A. You also need an agent that assists someone (`assists` in `products/software_factory/environments/test/core.json`: `coordinator` assists `melle`), and, for the follow-ups, a Runtime of A's connected to test. `--env test` is needed: `atlas` on its own opens prod.

## Try

| Step | Who, where | What you should see |
|---|---|---|
| A use case by hand | A: the list of use cases, `c`, a title and a scene to put it under, `ctrl-s` (a scene's own page offers no Create of a use case, which Design makes) | `UC-Atlas-NN`. Its page shows **Produced by  A**, set by A in the same write (`atlas get UC-Atlas-NN --env test`: `Produced by: A (since …, by A)`). Nothing in the form asked for it. |
| An issue by hand | A: the list of issues, `c`, a title and that use case to put it under, `ctrl-s` | `IS-Atlas-MM`, its page showing **Produced by  A**, set by A. |
| By an agent | `ATLAS_AS=coordinator atlas put issue --in UC-Atlas-NN --title "Wrap it" --env test` (or `put use_case --in SC-Atlas-…`) | `atlas get` shows `Produced by: melle (since …, by coordinator: Put in by coordinator on behalf of melle)`. The write is the agent's, on behalf of its person. |
| An agent that assists nobody | `ATLAS_AS=breaker atlas put issue --in UC-Atlas-NN --title x --env test` (any agent missing from `assists`), and the same for `put scene` and `put use_case` | Refused, and nothing is stored: `breaker is no person and assists nobody, so a new issue would record no producer (produced_by): create it as a person, or as an agent that assists one`. Control refuses it before anything is sent. A client that sends the create to Facts anyway is refused there too: `a new issue records its producer (produced_by): … this create by breaker links nobody`. |
| Setting it yourself | `--produced_by A`, `--link produced_by=A`, or `atlas set … produced_by=A` | Refused, as for a scene ([uc-atlas-24.md](uc-atlas-24.md#a-scene-records-who-put-it-in)). |
| A review's follow-ups | A: `atlas do IS-Atlas-MM "Pick up" --env test`, and wait for its review | When the review returns follow-ups, each is a new issue under the issue's use case. Each page shows **Produced by  A**, set by `flow`, cause `For A: proposed by TK-IS-Atlas-MM-2 in the review of IS-Atlas-MM`. Their questions go to A, who supervised the build that found them. |

## Items from before

An item made before producers were recorded is not migrated (IS-Atlas-164, Melle's decision). It keeps working as it is: Facts refuses no write to it, Flow's or a person's, for want of a producer. Wherever its producer is needed, the configured decider (`actors.decider`) counts as its producer: "Answer its questions" and a scene's **Accept** go to them ([uc-atlas-24.md](uc-atlas-24.md)).

| Step | Who, where | What you should see |
|---|---|---|
| An old scene | anyone: open a scene from before (its page shows no **Produced by**), edit its title, `ctrl-s` | Stored, as before. Flow's writes to it are stored too. |
| Its Accept | its use cases all accepted | **Accept** is on the configured decider's **Assigned to you**. |

## What changed for this

- **rela first** (D-0100). The pinned rela 26.11.9 records no creator on an entity (see [uc-atlas-24.md](uc-atlas-24.md)). Its relations know `min_outgoing`, but only `rela analyze cardinality` reports it, after the fact (`⚠ SC-… must have at least 1 'produced_by' relation(s), has 0`). A create without the link is stored. Atlas keeps using Facts' write rules, as for the scene. A `min_outgoing` that rela enforces at write time, with the links of the same create, while facts from before stay readable, is a request for the rela project.
- **The model** (`products/software_factory/model/contract/eyra/use_case.ex`; the issue in `compositions/atlas_eyra.ex`, whose relation it is): the use case's and the issue's `create` name `producer: :produced_by`, as the scene's does. They are written into the extension as `entities.<kind>.create.producer`.
- **Facts** (`products/software_factory/model/generator/lib/facts/writes.ex`): a create of a kind whose `create.producer` names a relation, and that links nobody through it, is refused with that reason, whoever writes it, Flow included. Who may set the link is unchanged: the person who creates it, or whom the agent assists, on that create only. Flow may set it too.
- **Control** (`platform/atlas_control/lib/atlas_control/pages.ex` `put_in_by/4`): a create by a client that is no person and assists nobody is refused before anything is sent, for every kind whose create names a producer. Before, it went through with no link.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/activities/task.ex` `make/9`): what a review's follow-ups make (`follow_ups:` in `Model.Delivery`) is linked to the run's supervisor, as a proposal's creates are. A kind the producer relation leads from is never made while the run has no supervisor. The task's end waits, as it does while Facts does not answer, and the items are made once the run has a supervisor.
- **Tests**: `products/software_factory/model/contract/test/item_producer_test.exs` covers the real Facts on its in-memory rela and Control's create. A use case under a scene and issues under a use case, by a person and by an assisting agent, each show **Produced by** with its origin on the page. An agent that assists nobody is refused by Control and by Facts for a scene, a use case and an issue, and nothing is stored. A person's create that links nobody is refused, and so is Flow's create without the link. `issue_runs_test.exs` checks that the follow-up issue is produced by the build's supervisor. `platform/atlas_flow/test/activities/proposal_test.exs` checks that a review's follow-ups are produced by the run's supervisor, and that they are not made while the run has none and are made once it has one. `scene_producer_test.exs`, `open_for_you_test.exs` and `platform/atlas_control/test/session_test.exs` were updated for the refusal.

<sub>Written by an AI agent (Claude Opus 5.5).</sub>
