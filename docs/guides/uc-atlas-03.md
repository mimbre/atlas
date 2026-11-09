# Try UC-Atlas-03: Manage the issues of a use case

What you can do: in a use case, add, open, change and remove issues. A second TUI shows each change without refreshing.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2 (see `docs/guides/uc-atlas-01.md` for what it starts).

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| A use case | `c` and a title for a scene, `ctrl-s`; then `c` and a title for a use case in it, `ctrl-s` | The use case, and under it **Issues**: `No issues yet.` |
| Create | `c`, a title, ↓, a description, `ctrl-s` | The form asks only for a title and a description. `✓ Stored as IS-Atlas-01 …`: the code is made for you. The issue opens with `In use case UC-Atlas-NN`, stage Specification by default, and an empty **Pull requests** list. |
| Open | `esc` back to the use case, ↑/↓, `enter` | The issue with its fields. An issue has a stage, not a status. Flux ref and Flux id show only once a Flux sync has filled them, so not for issues made in Atlas. |
| Update | `u`; ↓ to **Stage** and ←/→ to choose; `ctrl-s` | The code is shown read-only, and there are no Flux fields to fill in. `✓ Stored …` and the changed issue. In the use case its row reads `IS-Atlas-01 · Design`. An issue has no completed field: it is completed when its pull request is merged (UC-Atlas-32). |
| Remove | `d`, then `y` | `✓ Stored …`. You are back in the use case, without it. |

Keep TUI 2 open on the same use case: each change shows up there by itself (`updated by hint at …`).

Also try:

- **Deleting a use case that has an issue.** In the use case, press `d`. It is refused: `still has 1 issue. Remove it first; Atlas never deletes it along with its parent.` With two or more it says `2 issues. Remove them first`.
- **Pull requests.** An issue shows an empty **Pull requests** list; UC-Atlas-04 is about linking them.

## What changed for this

- **rela's description:** Issue, its fields and its `in_use_case` relation were already in `rela/schema.yaml`. `rela/atlas.json` says how one is made (title and description only, codes `IS-Atlas-NN`, stage Specification) and that Flux ref and Flux id are only filled by a connector.
- **Control:** a refused delete now counts in the right number ("1 issue", "2 issues") and says "it" or "them". There is nothing else on the BEAM side or in the TUI: Control builds the issue's form, its page and the related lists from the description, with the same code as for scenes and use cases.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-03.exs` follows this guide.
