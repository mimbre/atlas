# Try UC-Atlas-01: Manage scenes

What you can do: start the TUI with `--env test`; list, create, open, change and delete scenes; a second TUI shows each change without refreshing.

Try it in test: `atlas tui --env test`. Without `--env test`, `atlas` opens prod, which holds real data; the Console header identifies the environment (`Atlas Console · prod` or `Atlas Console · test`). Nothing here touches prod, Fly or the live rela store.

## Start

In any terminal, from any folder:

```sh
atlas tui --env test
```

That is all. Test runs on Fly, so it opens the tunnel to test's Control and then the TUI (`docs/guides/test-on-fly.md`). It also updates `~/projects/eyra/atlas` to the newest develop first. `atlas` starts no rela and no core: for a private instance on this Mac (`ATLAS_ENV_FILE`), start them first with `atlas-ops restart --env test`, which also restarts a core from an older build; otherwise the TUI exits with that hint. A first start compiles for about half a minute.

For TUI 2, run `atlas tui --env test` again in a second terminal, beside the first.

More, each with `--env test`: `atlas-ops status --env test` shows what runs and which build; `atlas-ops logs --env test` follows the core's log. On a private instance, `atlas-ops stop --env test` stops the core (rela keeps running) and `atlas-ops restart --env test` restarts it.

Once, to get the commands: `~/projects/eyra/atlas/bin/atlas-ops install` (it links `~/.local/bin/atlas` and `~/.local/bin/atlas-ops` to the main clone).

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| List | (start) | **Scenes**, sorted by code. In the status bar: `connected · opened at …`. |
| Create | `c`, type a title, ↓, a description, `ctrl-s` | The form asks only for a title and a description. `… Sent to State; waiting until it is stored…`, then `✓ Stored as SC-Atlas-01 (position N)`, and the new scene opens. The code is made for you: the next free number. The rest takes its default (status Refine). |
| Open | `esc` back to the list, ↑/↓, `enter` | The scene with its fields. Flux id shows only once a Flux sync has filled it, so not for scenes made in Atlas. |
| Update | `u`, ↓ to a field, edit (backspace, type; ←/→ for a choice), `ctrl-s` | The form shows the code read-only and every field you may change. `✓ Stored …` and the changed scene. |
| Delete | `d`, then `y` | `✓ Stored …` and the list without it. |
| Quit | `q` | |

Watch TUI 2 while you do this: after every change in TUI 1 its list or scene changes by itself, and its status bar says `updated by hint at …`. Every 5 seconds both TUIs also reconcile from State (`reconciled at …`), so a lost hint would only delay the change.

Also try:

- **A refusal.** Create a scene with an empty title. The form stays, with a red line saying why (`title is required`).
- **Two at once.** Press `c` in both TUIs, give each a title, and save both. They get different codes. If both take the same number, State refuses the second, and its TUI tries the next number by itself (`… is taken; trying …`).
- **A deleted code.** Delete the newest scene and create another right away. rela keeps a deleted code reserved for a few minutes, so the TUI says the code is taken and moves on to the next number.
- **A scene with use cases.** Deleting a scene that still has use cases is refused, with the number of use cases (see UC-Atlas-02).
- **Losing Control.** Run `atlas-ops tunnel close --env test` in a third terminal (on a private instance: `atlas-ops stop --env test`). Both TUIs say `Not connected to Control. Retrying…` and show nothing old as current. Run any `atlas` command, for example `atlas list scene --env test`, which opens the tunnel again (on a private instance: `atlas-ops restart --env test`); they come back on the page they were on.

## What is underneath

```
 TUI 1    TUI 2            clients: blocks only, JSON lines over TCP (127.0.0.1:7691)
    \      /
     Control               turns rela's description into blocks (list, item, form, confirm)
        |
   ===== Bus =====         reads only envelopes; facts and reads to State, "stored" to the
        |                  sender (acknowledgement) and to every listener (hint)
      State                checks against the description, stores in rela once per id,
        |                  answers every fact with stored (and a position) or refused
   rela test               http://127.0.0.1:7690, data in ~/.local/share/atlas/test/rela
```

Nothing on the BEAM side or in the TUI knows what a scene is. The word does not occur in their code; a test checks that. Scene comes from `rela/schema.yaml`. How a scene is created (title and description only, codes `SC-Atlas-NN`, the defaults, Flux id filled only by a connector) is data in `rela/atlas.json`.
