# Try UC-Atlas-30: Lists and actions read the same everywhere

What you can do: every action has the name and key of its CRUD operation, the same on every page: `c` Create, `u` Update, `d` Delete, and `enter` opens (IS-Atlas-58). And Update moves an item to another parent. An issue goes to another use case, a use case to another scene, a pull request to another issue (IS-Atlas-59). Both parents show it at once, in every open TUI.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2 (see `docs/guides/uc-atlas-01.md` for what it starts).

## Try

### The same actions everywhere (IS-Atlas-58)

| Where | Keys | What you should see |
|---|---|---|
| The scenes list | `?` | The key legend includes `c Create scene`. With no scenes: `No scenes yet. Press c to create one.` Close the legend with Esc before acting. |
| Create | `c` | The form is called `Create scene`, its button `[ Create ]`. |
| A scene | `enter` on a row, then `?` | The key legend offers `u Update scene`, `d Delete scene` and `c Create use case`. The empty list says `Press c to create one.` Close the legend with Esc before acting. |
| Update | `u` | The form is called `Update SC-Atlas-NN`, its button `[ Update ]`. |
| A use case, an issue | `enter` | The same words: `u Update use case`, `d Delete use case`, `c Create issue`; on an issue `c Create pull request`. |

Other actions keep their own names: `o Open in browser`, `:` ask. `atlas tools` names its tools the same way (`Create use case`, `Update use case`); the command line keeps its verbs (`put`, `set`, `get`).

### Move an item (IS-Atlas-59)

Make a scene with two use cases and an issue in the first one (`c`, `c`, `c`, as in UC-Atlas-02 and UC-Atlas-03). Keep TUI 2 open on the second use case.

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| Open the issue | ↑/↓, `enter` | `In use case UC-Atlas-NN`: the first use case. |
| Update | `u` | The form ends with **In use case**, a choice of every use case (`‹ UC-Atlas-NN: its title ›`), the current one selected. |
| Move | `tab` until **In use case**, then ←/→ to the second use case, `ctrl-s` | `✓ Stored …`, and the issue shows the second use case. TUI 2 lists the issue within a second (`updated by hint at …`). |
| Back | `esc` | You are in the second use case, with the issue in its list. The first use case has no issues left, and the scene's progress follows. |

From the command line, as an agent:

```sh
atlas set IS-Atlas-NN in_use_case=UC-Atlas-MM --env test   # moves it; prints the issue
atlas help issue --env test                                # Fields: in_use_case: the key of a use_case; a change moves it there
```

Also try:

- **A move to nothing.** `atlas set IS-Atlas-NN in_use_case= --env test` is refused: `in_use_case cannot be empty; choose where it goes`. An item never loses its parent by a change.
- **A move to an item that does not exist.** `in_use_case=UC-Atlas-99` is refused: `UC-Atlas-99 does not exist`.
- **A use case or a pull request.** The same works one level up (`in_scene`) and down (`in_issue`). A pull request has nothing else a person may set, and now has `u` too, to move it.

## What changed for this

- **rela's description:** nothing. The choices are the relations with `max_outgoing: 1` that a kind has (`in_scene`, `in_use_case`, `in_issue`), read from `rela/schema.yaml`.
- **State:** a change may carry links, as a create does. Each relation named is replaced in rela, in the same write as the fields; State checks first that the new parent exists. The move is stored with its cause (`Moved from UC-Atlas-01 to UC-Atlas-30 (in_use_case), by a change in Control`), and its hint goes to every page that lists the kind: the old parent's and the new one's.
- **Control:** the change form offers a choice per parent relation, of every item of the parent's kind; only a parent that differs is sent. `/_kinds` lists the relation among the fields, so `atlas help` and `atlas tools` offer it.
- **Action names (IS-Atlas-58):** one function in Control, `AtlasControl.Pages.operation/3`, gives every action its words and key from the operation and the kind (`{"Create use case", "c"}`); lists, item pages, forms and buttons take them from it. `/_kinds` carries each kind's actions, and `atlas tools` takes its titles from there. A page with a second related list creates there with `s`, `x` or `z`; `a` and `r` stay free for Accept and Reopen.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-30.exs` follows this guide.
