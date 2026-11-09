# Try UC-Atlas-32: Completed means accepted or merged

What you can do: see who accepted a use case or scene, since when, by whom and why, without a `completed` field anywhere. Completable is an association in rela: a kind has it when it is in `accepted_by`'s `from`. The link has no attributes; the fact that set it carries when, by whom and why, and Facts answers the link with that fact.

IS-Atlas-62 added the person kind, `accepted_by`, `done_in` as history, and the migration of prod. IS-Atlas-63: Facts works out "completed", and a parent whose children are all completed is "To test". IS-Atlas-64: Accept and Reopen in the TUI, one action on `a`, for a person only.

## Start

```sh
atlas tui --env test
```

## Try

| Step | Keys / command | What you should see |
|---|---|---|
| A person | `atlas put person --name Melle --env test` | `Person melle: Melle`. The id is made from the name, in lower case. People are not on the start page; the scenes list still is. |
| Accept, too early | on a use case with an open issue, `a` | Refused, and it says which: `UC-Atlas-NN has IS-Atlas-MM open`. |
| Accept | on a use case whose issues are all completed (its row says `To test`), `a`, then `y` | `Accepted by  melle`, and under it, dim: `since 3 Nov 15:10 · by melle`. Its row on the scene: `Done · N/N`. The `?` key legend now offers `a Reopen`: one action on `a`, Accept until it is accepted, Reopen after (`r` stays refresh). `atlas get UC-Atlas-NN --env test` shows the same; `--json` gives it as `origins` (`since`, `by`, `cause`). |
| Nothing new under it | `atlas put issue --in UC-Atlas-NN --title Late --env test` | Refused: `UC-Atlas-NN is accepted; reopen it first, or put this under another use case`. A move there with `u` is refused the same way. |
| Reopen | `a` (now labelled Reopen), a note of one or more lines, `ctrl-s` | Back to `To test`; the page shows `Accepted by  —` with `… · by melle · <the note>`. Without a note it is refused. Every earlier link stays in Facts as the link's history. |
| Only a person | `atlas set UC-Atlas-NN accepted_by=melle --env test` | Refused: `Accepted by is not set here: only a person accepts.` An agent's page offers neither Accept nor Reopen, and `atlas tools` leaves them out. |
| No completed field | `atlas help use_case --env test`; `atlas help issue --env test` | No `completed` field, and issue stages are specification, design, development. `use_case` lists `Links: accepted_by: to person, at most one`. |
| History only | `atlas set IS-Atlas-NN done_in=PR-… --env test` | Refused: `Also done in is not set here: only a migration or connector sets it.` `atlas tools` does not offer it. |

### Completed, worked out (IS-Atlas-63)

| Step | Keys / command | What you should see |
|---|---|---|
| An issue whose pull request merges | link a pull request to an issue; merge it on GitHub (prod), or in the e2e on the stand-in | Within a connector round the issue's row shows `Done`, set by nobody. Its page and `atlas get IS-Atlas-NN` say why: `Progress  Done · PR-eyra-atlas-20 merged`. An issue `done_in` a merged pull request counts the same. |
| Its use case | the use case's row on its scene | `To test · 1/1`: all its issues are completed, it is not. A parent is never done because its children are. |
| Accept it | `a`, `y` on its page | Its row: `Done · 1/1`. Its page: `Progress  Done · 1/1 · accepted by melle`, and under it `since 3 Nov 15:10 · by melle`. The scene shows `To test` only once all its use cases are accepted. |

The rules are data in `rela/atlas.json`: `completion` per kind (`by` an association; `over` a fact pointing at it with a value; `through` a fact it points at with a value), and `progress.to_test` for the label.

`by` says who sent the fact: the TUI is `tui_user` from the environment's settings (`melle`), the command line is `agent`, the migration is `migration`. Only a client that is a person (its `by` is a person's id) accepts or reopens, and only as itself.

**Known limit, until there is sign-in:** a client is what its hello says (`tui`, `agent`, `migration`). Control has no sign-in, so "only a person accepts" holds only as long as clients say truthfully what they are. Anything that says `tui` acts as the environment's `tui_user`.

## Prod: the migration

The one-off `atlas migrate-completion` made the person `melle`, set `accepted_by` and `done_in` from the old values, and removed the old `completed` values; it has since been removed.

## What changed for this

- **rela's description:** `rela/schema.yaml` has a `person` kind (name; id made from it) and two associations: `accepted_by` (scene, use case → person, at most one, inverse `accepted`) and `done_in` (issue → pull request, inverse `also_done`). `completed` and the stage `testing` are gone. `rela/atlas.json` marks the parent relations (`relations.<name>.parent`: in_scene, in_use_case, in_issue), so an association with at most one link is never taken for a parent; `done_in` is `set_by: migration`; `person` is `top: false` (not on the start page).
- **Facts:** a change may set or remove the links of the relations it names. Facts records the fact that set each link (when, position, by, cause) in `links.dets` in its data folder, and answers each link with its `origins`, and one fact with the `history` of its links.
- **Control:** a page shows each association with the fact that set it (`pair.origin` in the contract, 0.8.0). `/k/<kind>/<key>/links/<relation>` sets or removes an association's links, with a note as its cause; parents and `set_by` associations are refused there. Each fact carries `by`: who is on the session. A submit may carry a `cause`.
- **Clients:** the TUI shows the origin dim under the value. `atlas set <key> <association>=<key>` sets a link, empty removes it, and `--cause` says why (put and set). `atlas get --json` gives `origins`.
- **IS-Atlas-64:** `rela/atlas.json` gives `accepted_by` `only_target` (only one of the facts it points at sets it, to itself; `also`: the migration), `actions` (`set`: Accept, `remove`: Reopen, both on `a`, so the page has one action on it), `requires_completed_children` and `closes_parent`. Control offers the actions on the page to a person only (`/k/<kind>/<key>/set/<rel>` asks first, `/remove/<rel>` asks for a note), refuses them for anyone else, and refuses a create or move under an accepted fact. It learns the TUI's user is a person when that person exists (on hello, and on every reconcile).
- **IS-Atlas-63:** `AtlasFacts.Completion` works out why a fact is completed from its kind's `completion` rule; reads answer it as `completion`. `AtlasFacts.Progress` shows Done only for a completed fact, `To test` when all its children are and it is not. An issue has a progress rule of its own (`own: stage`), so its row shows `Done` in place of its stage. A pull request's change is a hint to every page whose progress or completion it changes. The page's `Progress` line says why it is done.
