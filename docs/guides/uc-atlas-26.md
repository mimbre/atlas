# Try UC-Atlas-26: See each pull request's title and state from GitHub

What you can do: see, for every linked pull request, its title and whether it is open, a draft, merged or closed, as GitHub says. Nobody types these; Atlas's GitHub connector reads them, and never writes anything to GitHub.

## Start

```sh
atlas
```

This is prod, where the plan's pull requests are. After the merge, the first start (or `atlas-ops restart`) runs the connector. It reads every linked pull request that is not merged or closed yet, at once and then every 5 minutes. It uses the token of `gh auth token`, so `gh` must be logged in.

Test has no GitHub connector: in test, connectors do nothing (d-0003). The end-to-end test reads a stand-in GitHub instead (below).

## Try

| Step | Keys | What you should see |
|---|---|---|
| An issue with a merged pull request | open `IS-Atlas-01` (`SC-Atlas-01` → its use case → the issue) | Under **Pull requests**, the row shows the title (its first 40 characters), then its code and state: `UC-Atlas-01: manage scenes in the TUI (B  PR-eyra-atlas-1 · Merged`. |
| The pull request | `enter` on that row | Title, State `Merged`, Draft `no`, the URL, and `Last read  2026-11-03 14:05 UTC from GitHub`. All of it is GitHub's: `u Update pull request` only moves it to another issue (UC-Atlas-30). |
| One linked a moment ago | in an issue, `c`, a pull request URL, `ctrl-s` | `✓ Stored as PR-…`; within a few seconds its title replaces the URL and its state shows. |
| One merged on GitHub | merge an open pull request on GitHub, keep its issue open in Atlas | Within 5 minutes its row says `Merged`, without anyone touching Atlas. |

A draft shows as `Open · draft`. A pull request whose read failed (no network, rate limit, no access) keeps what was stored. Its page says so, for example `Last read  … from GitHub; the read at … failed: GitHub answered 404 (no such pull, or no access); it is tried again`. The core's log (`atlas-ops logs`) has the same line, never the token.

## What changed for this

- **rela's description:** `rela/atlas.json` gives the pull request a `connector`: system `github`, address `url`, the fields it fills (`title` ← `title`, `state` ← `state`, `draft` ← `isDraft`, as `gh` names them), and `until` (`state` merged or closed: read no more). It also makes `title` the primary, so a list shows the title and the URL only while there is no title yet.
- **Facts:** its first connector, at its edge (`AtlasFacts.Connector`). It is generic: which kinds and fields it fills comes from the description. It reads and stores over the Bus like any layer. Only a difference becomes a fact, a change with its cause (`GitHub connector, read at …`), which Facts keeps with its answer and sends along with the hint. When each pull request was last read, and why the last read failed, is kept beside the facts (`copies.dets` in Facts' data folder), not as a fact. The GitHub part (`AtlasFacts.Connector.GitHub`) is the only code that knows GitHub: GET requests on GitHub's REST API, the token from `gh auth token` for each round, held in memory only.
- **Settings:** `connectors.github` in `env/prod.json` (`api`, `token_command`, `every_seconds`: 300). An environment without it has no GitHub connector.
- **Control:** a fact whose primary is empty is labelled by the property its id is made from. A copy's page shows `Last read`. No kind is named.
- **The end-to-end test:** `e2e/scenarios/uc-atlas-26.exs` follows this guide against a stand-in GitHub (`AtlasE2E.GitHub`), read every 2 seconds. It also checks that every request was a GET with the token, and that a merged pull request is read no more.
