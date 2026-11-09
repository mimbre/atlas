# Try UC-Atlas-25: See how far a scene and its use cases are

What you can do: see in a list how far each use case and each scene is, worked out from the issues under it. A list never says "Ready to pick up" for work that is already built and waiting for your test. Change an issue's stage and the rows above it change, in every open TUI, within a second.

## The rule

- A use case is as far as its least far issue: `Specification`, `Design`, `Development`. The count says how many of its issues are at that stage: `Development · 1/12` means one of twelve is still in Development and the rest are further.
- A scene is as far as its least far use case, counted the same way.
- `To test` when every item under it is completed and it is not: `To test · 12/12`. `Done` only when it is completed itself: accepted, or for an issue its pull request merged (UC-Atlas-32).
- An item with nothing under it shows its Flux group (`Refine`, `Ready to pick up`). That comes before any stage: a scene with one use case still in Refine shows `Refine · 1/N`.

Nothing is stored. Facts works it out from the facts on every read. The rule is data in rela's description (`progress` in `rela/atlas.json`), not code.

Flux's status stays as it is, and you can still set it for a later Flux sync. It no longer shows in lists. An item's page shows it as **Flux group**.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2. `--env test` is needed: `atlas` on its own opens prod.

## Try

| Step | Where | What you should see |
|---|---|---|
| A scene with a use case and two issues | TUI 1: `c` a scene, `c` a use case in it, `c` two issues in that, each with a title and `ctrl-s`; then `esc` back to the scene | Under **Use cases**: `UC-Atlas-NN · Specification · 2/2`. On the scenes list: `SC-Atlas-NN · Specification · 1/1`. |
| Move one issue on | in a terminal: `atlas set IS-Atlas-NN stage=development --env test` | The use case's row changes to `Specification · 1/2`: one issue is still in Specification. |
| Move the other | `atlas set IS-Atlas-MM stage=development --env test` | `Development · 2/2`, in TUI 1 and in TUI 2 on the same page, within a second (`updated by hint at …`). |

Done comes from completion, which UC-Atlas-32 changes: an issue is completed when its pull request is merged, a use case or scene when a person accepts it (`docs/guides/uc-atlas-32.md`).
| The Flux group | open the use case | `Flux group  Refine`: Flux's status, on the page only. |

In prod: open SC-Atlas-01. UC-Atlas-01 shows how far its issues are. `atlas set IS-Atlas-03 stage=design --env prod` changes its row at once. Set it back to development afterwards.

## What changed for this

- **rela's description:** `rela/atlas.json` has a `progress` rule for scenes and use cases: which relation they roll up (`over`), which field of an issue says how far it is (`field`), and which field of their own to show while nothing is under them (`own`). The top-level `progress` gives the order of the values (least far first), the field that marks an item done, and `Done`. `properties.status.label` names the status "Flux group".
- **Facts:** a read of a kind with a rule carries each fact's `progress`. It is worked out from the facts under it, at any depth, on every read (`AtlasFacts.Progress`). Nothing is stored.
- **Control:** a list row shows the progress in place of the item's own field and its completed flag. A hint from a kind that the progress rolls up redraws the list too, so an issue's change redraws the scene page and the scenes list. A page shows a field under the label the description gives it. None of this code names a kind.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-25.exs` follows this guide, with the command line on the issues and both TUIs on the use cases and the scenes.
