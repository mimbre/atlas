# Try UC-Atlas-02: Manage the use cases of a scene

What you can do: in a scene, add, open, change and remove use cases. A second TUI shows each change without refreshing.

Start: `atlas tui --env test` in one terminal, and again in a second one (see `docs/guides/uc-atlas-01.md`).

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| A scene | `c`, a title, `ctrl-s` | The scene (say `SC-Atlas-01`), and under it **Use cases**: `No use cases yet. Press c to create one.` |
| Create | `c`, a title, ↓, a description, `ctrl-s` | The form asks only for a title and a description. `✓ Stored as UC-Atlas-01 …`: the code is made for you. The use case opens and shows `In scene SC-Atlas-01`. |
| Back | `esc` | The scene, with the use case in its list. Create a second one with `c`. |
| Open | ↑/↓ in the list, `enter` | The use case with its fields (status Refine, by default). |
| Update | `u`, edit, `ctrl-s` | The code is shown read-only. `✓ Stored …` and the changed use case. |
| Remove | `d`, then `y` | `✓ Stored …`. You are back in the scene, without it. |

Keep TUI 2 open on the same scene: every use case you add, change or remove in TUI 1 shows up there by itself (`updated by hint at …`).

Also try:

- **No title.** Add a use case with an empty title. Facts refuses it (`title is required`). The form keeps what you typed.
- **Deleting a scene that has use cases.** In the scene, press `d`. It is refused: `still has 2 use cases. Remove them first` (with one: `still has 1 use case. Remove it first`). Atlas never deletes use cases along with their scene.
- **Issues.** A use case shows an **Issues** list, with `c` to create one (UC-Atlas-03).

## What changed for this

- **rela's description:** Use case is described there, with the same fields as Scene, and in an `in_scene` relation, at most one scene per use case.
- **Control:** a page of any fact now lists the facts that point at it, adds new ones already pointing at it, and names the fact it points at.
- **Facts:** writes and reads links between facts, for any relation the description has.

Nothing in the Bus changed. No code anywhere names a use case.
