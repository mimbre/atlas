# Try UC-Atlas-04: Link the pull requests of an issue

What you can do: in an issue, link a GitHub pull request by its URL, open it and remove it. A second TUI shows each change without refreshing.

## Start

```sh
atlas tui --env test
```

Run it again in a second terminal for TUI 2. `--env test` is needed: `atlas` on its own opens prod.

## Try

In TUI 1:

| Step | Keys | What you should see |
|---|---|---|
| An issue | a scene (`c`), a use case in it (`c`), an issue in that (`c`), each with a title and `ctrl-s` | The issue, and under it **Pull requests**: `No pull requests yet. Press c to create one.` |
| Link | `c`, paste or type `https://github.com/eyra/atlas/pull/12`, `ctrl-s` | The form asks only for the URL. `✓ Stored as PR-eyra-atlas-12`: the id is made from the URL (owner, repository, number; a `.` in a name becomes `_`). The pull request opens, labelled by its URL, with `In issue IS-Atlas-NN`. |
| Open | `esc` back to the issue, ↑/↓, `enter` | The pull request. The URL is what it is, and title, state and draft are GitHub's, filled by a GitHub connector later. They show only once filled. `u Update pull request` only moves it to another issue (IS-Atlas-59, see UC-Atlas-30). |
| Open in the browser (IS-Atlas-47) | on the pull request's page, or on its row in the issue's list, `o` | The `?` key legend shows `o Open in browser`. The browser shows the pull request on GitHub, and the TUI says `Opened https://… in the browser`. Only http and https addresses are opened. |
| Remove | `d`, then `y` | `✓ Stored …`. You are back in the issue, without it. |

Keep TUI 2 open on the same issue: each link and removal shows up there by itself (`updated by hint at …`).

Also try:

- **The same URL twice.** Link the same URL again from the same issue. It is the same pull request: `✓ Stored`, and the issue still lists it once.
- **The same URL from another issue.** It is refused: `PR-eyra-atlas-12 already exists`. A pull request belongs to one issue.
- **Not a GitHub pull request.** Link `https://gitlab.com/eyra/atlas/-/merge_requests/3`. Nothing is sent. The form says `url must be a GitHub pull request URL, e.g. …` and keeps what you typed.
- **Deleting an issue with a pull request.** It is refused: `still has 1 pull request. Remove it first`.
- **A removed URL again, right away.** rela keeps a deleted id reserved for a few minutes, so linking the same URL again at once is refused (`… was deleted a moment ago`). Try again later.

## What changed for this

- **rela's description:** `rela/atlas.json` says how a pull request's id is made: `create.id.from: "url"`, with a pattern, the template `PR-{1}-{2}-{3}` and `.` → `_`. It also marks title, state and draft as set by a connector. Pull requests are always GitHub's (d-0012).
- **Control:** an id made from a property is the same for the same value. So a taken id is never retried with the next number, and a value that does not fit the pattern is never sent to State. A change form shows that property read-only. A kind without a primary property is labelled by it. A kind with nothing a person may change and no parent to move to has no Change action. None of this code names a kind.
- **Open in the browser (IS-Atlas-47):** `rela/atlas.json` marks the type of a pull request's url as a web address (`types.github_pull_url.format: "url"`; rela has no such type). Control then gives every fact with such a field a link (`o Open in browser`), on its page and on its row in a list; the TUI opens it with `open` (macOS) or `xdg-open`, never anything but http and https. The contextual key legend lists the active bindings and scrolls when they exceed its viewport.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-04.exs` follows this guide. Its browser is a stand-in (`"browser"` in the run's settings) that only records the address.
