# Try UC-Atlas-23: Every item has a producer

What you can do: make a use case or an issue by hand and see that it records its producer, as a scene does. Have a review's follow-ups become issues produced by the build's supervisor. See that nothing makes a scene, use case or issue without a producer (SC-Atlas-09).

Every scene, use case and issue records its producer (`produced_by`). That is the supervisor of the flow that made it, or, for one made by hand, the person who made it. When an agent makes it, that is the person the agent assists, and the history says the agent wrote it on their behalf. Questions about an item go to its producer. It is never empty: a create that would record none is refused and nothing is stored, and so is any write that would leave an item without one. Items from before producers were recorded got theirs from their history, by a one-off migration ([Items from before](#items-from-before)). Their questions and their **Accept** go to that producer, never to the configured decider in their place ([uc-atlas-24.md](uc-atlas-24.md)).

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

`atlas migrate-producer` links every scene, use case and issue that records no producer, once, as the `migration` client (which `produced_by`, `set_by: [:flow, :migration]`, allows). It reads what Facts records of the write that made each item: the oldest entry of the links its create set (its parent, `in_scene` or `in_use_case`, and its Assignment). Facts keeps every entry of a link, with who sent it and why. From that entry:

| What the history records | Its producer | The link's cause |
|---|---|---|
| Made by Flow, cause `For <person>: proposed by …` (a break-down, or a review's follow-ups) | that person, the run's supervisor | `backfilled (UC-Atlas-23): made by flow, "For bob: proposed by TK-SC-Atlas-01-1 …": bob` |
| Put in by an agent, cause `… on behalf of <person>` | that person | `backfilled (UC-Atlas-23): put in by coordinator, "Put in by coordinator on behalf of melle": melle` |
| Made by hand by a person | that person | `backfilled (UC-Atlas-23): put in by adrienne by hand: adrienne` |
| Made by an agent that assists someone (`assists` in the environment's `core.json`) | the person it assists | `backfilled (UC-Atlas-23): put in by coordinator, who assists melle: melle` |
| Nothing: no such entry, or one by a migration, a connector or an agent that assists nobody | the configured decider (`actors.decider`) | `backfilled (UC-Atlas-23): its history names nobody who made it (made by migration): the configured decider, melle` |

Each item's page then shows **Produced by** with that origin: `by migration`, and the cause. Run it on a copy, as any migration (`docs/guides/test-on-fly.md`, "A migration"), with this build on the private instance:

```sh
atlas migrate-producer --env test --dry-run   # prints every step; writes nothing
atlas migrate-producer --env test             # writes them through Control, as the migration
atlas migrate-producer --env test --dry-run   # again: 0 steps
```

It must run before this build serves the data. Facts now refuses every write to a scene, use case or issue without a producer (`requires`), Flow's too, so an item left without one would hold its runs up. A write the migration cannot make stops the run and names the item and why, and a second run carries on.

**rela first** (D-0100). Asked of the pinned rela 26.11.9: `rela migrate data` runs hand-written data migrations, whose `lua` step (`function migrate(entity)`, with `rela.get_entity`, `get_faces` and `get_relations`) rewrites an entity's properties. It sets no relation: a returned relation is dropped while the step reports the record changed. `rela history` and `rela relation-history` exist only in its postgres build, and test runs SQLite. And rela records no Atlas writer: Facts is its only writer, so its history could not say who made an item anyway. So the migration reads Facts' own record of each link, which Control's `facts_read` now answers with `history`, and writes through Control. Requests for the rela project: a data-migration step that sets relations, with a cause that rela keeps; and a fact's version history in the SQLite build, with the acting client's name.

## What changed for this

- **rela first** (D-0100). The pinned rela 26.11.9 records no creator on an entity (see [uc-atlas-24.md](uc-atlas-24.md)). Its relations know `min_outgoing`, but only `rela analyze cardinality` reports it, after the fact (`⚠ SC-… must have at least 1 'produced_by' relation(s), has 0`). A create without the link is stored. Atlas keeps using Facts' write rules, as for the scene. A `min_outgoing` that rela enforces at write time, with the links of the same create, while facts from before stay readable, is a request for the rela project.
- **The model** (`products/software_factory/model/contract/eyra/use_case.ex`; the issue in `compositions/atlas_eyra.ex`, whose relation it is): the use case's and the issue's `create` name `producer: :produced_by`, as the scene's does. They are written into the extension as `entities.<kind>.create.producer`.
- **Facts** (`products/software_factory/model/generator/lib/facts/writes.ex`): a create of a kind whose `create.producer` names a relation, and that links nobody through it, is refused with that reason, whoever writes it, Flow included. Who may set the link is unchanged: the person who creates it, or whom the agent assists, on that create only. Flow may set it too.
- **Control** (`platform/atlas_control/lib/atlas_control/pages.ex` `put_in_by/4`): a create by a client that is no person and assists nobody is refused before anything is sent, for every kind whose create names a producer. Before, it went through with no link.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/activities/task.ex` `make/9`): what a review's follow-ups make (`follow_ups:` in `Model.Delivery`) is linked to the run's supervisor, as a proposal's creates are. A kind the producer relation leads from is never made while the run has no supervisor. The task's end waits, as it does while Facts does not answer, and the items are made once the run has a supervisor.
- **Items from before** (since): `platform/ops/plan/lib/atlas_plan/producer.ex` (`atlas migrate-producer`, `bin/atlas`), with Control's `facts_read` taking `history` (`platform/atlas_control/lib/atlas_control/session.ex`, its wire contract, and `AtlasAgent.Client.facts/4`).
- **Never empty** (since): the composition gives the scene, the use case and the issue a `requires` rule on `produced_by`. `requires` now takes `links`, and a rule without `when` holds for every fact (`generator/lib/facts/writes.ex`, checked in `description/check.ex`). Facts refuses any write that would leave one of them without a producer, whoever sends it. The producer-owned states, Design's and Plan's `clarifying` and Accept the scene's `to_accept`, are owned by `{:person, producer: :produced_by}`, with no decider: the DSL's `{kind, config: role, producer: relation}` is gone (`generator/lib/schema.ex`), and `AtlasFlow.Model.owner/3` resolves a producer owner to the producer, or to nobody (`platform/atlas_flow/lib/atlas_flow/model.ex`).
- **Tests**: `products/software_factory/model/contract/test/item_producer_test.exs` covers the real Facts on its in-memory rela and Control's create. A use case under a scene and issues under a use case, by a person and by an assisting agent, each show **Produced by** with its origin on the page. An agent that assists nobody is refused by Control and by Facts for a scene, a use case and an issue, and nothing is stored. A person's create that links nobody is refused, and so is Flow's create without the link. `issue_runs_test.exs` checks that the follow-up issue is produced by the build's supervisor. `platform/atlas_flow/test/activities/proposal_test.exs` checks that a review's follow-ups are produced by the run's supervisor, and that they are not made while the run has none and are made once it has one. `scene_producer_test.exs`, `open_for_you_test.exs` and `platform/atlas_control/test/session_test.exs` were updated for the refusal. For items from before: `platform/ops/plan/test/producer_test.exs` covers the migration's choices (Flow's cause, by hand, by an assisting agent, on whose behalf, nothing known), its causes, a dry run, a second run that does nothing, and a refused write. `products/software_factory/model/contract/test/producer_migration_test.exs` runs it on the real Facts over a store from before, with Facts' link history in its data folder: no item without **Produced by** after it, each with a backfill origin by `migration`; a second run changes nothing; nobody clears it again; and the producer states then go to the producer, never the decider. The removed fallback is in `scene_producer_test.exs`, `sent_back_runs_test.exs`, `supervision_test.exs`, `decider_test.exs`, `pipeline_runs_test.exs`, `platform/atlas_flow/test/supervised_owner_test.exs` and `products/software_factory/model/generator/test/{schema_test,supervision_test,facts/guards_test,description/checks_test}.exs`.

<sub>Written by an AI agent (Claude Opus 5.5).</sub>
