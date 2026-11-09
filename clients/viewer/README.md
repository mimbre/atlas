# Atlas Runtime viewer

A local, read-only browser view of a standalone Runtime: workers, turns with their
metadata, activity, results and answers, public output and the execution-event journal.
It reads only `<runtime home>/read.sock` through `runtime.read/1`
([contract](../../docs/contracts/runtime-read.md)) and needs neither Atlas Server nor Code.
There are no start, stop, continue, answer or orchestration controls; opening or closing
the viewer does not change any worker.

## Run

```sh
cd clients/viewer
mix atlas_viewer.serve                 # $ATLAS_RUNTIME_HOME or ~/.local/state/atlas-runtime
mix atlas_viewer.serve --home DIR --port 4100
```

It prints `http://127.0.0.1:PORT/#token=…`; open exactly that URL. The page removes the
token from the address bar and keeps it only in memory, so a reload needs the printed URL
again. Ctrl-C stops the viewer, never Runtime.

Requires Elixir 1.18 and OTP's `inets` and `crypto` applications; there are no Hex
dependencies.

## What it shows

- **Live / reconnecting.** Polls every two seconds. When the viewer backend or Runtime is
  unreachable, or a read times out (10 s), it says which, keeps the last data marked with
  its time, and retries with backoff up to 15 s. A wrong token (a restarted viewer) stops
  polling.
- **Gaps.** A `reset` (`retention_gap` with its sequences, or `epoch_changed`) appears in
  the event or output list where the loss is. A refused cursor is reported and reading
  restarts from the oldest retained position.
- **Expired output.** `output_unavailable` is shown as such: output is lost when the
  service exits and expires 15 minutes after the turn ends. Result and answer stay.
- `ended` output means the producer closed the stream, not that the turn completed;
  activity is not evidence the worker still runs; `execution_finished` is not verification.

Runtime text is placed as text, never as HTML. Worker and turn selection are native
buttons (Tab, Enter/Space).

## Boundary

The backend is OTP `:inets` httpd bound to 127.0.0.1. It forwards only the five
`runtime.read/1` operations and their fields, sets `api` itself, connects to nothing but
`read.sock` and keeps no state between requests. Cursors are Runtime's, held opaquely in
the page. `POST /api/read` needs the per-launch bearer token, `Host` 127.0.0.1 or
localhost with the viewer's port (the default HTTP port 80 may be omitted) and the matching
`Origin`. Application responses carry a strict Content-Security-Policy, `nosniff`,
`no-store` and no CORS headers. The launch URL prints the token; request logging is not configured.

## Assets

`priv/static/app.css` and `priv/static/prism/` (Prism's fonts) are built from Nova Prism
(`@novasoftwarefoundation/prism` 0.1.7) and Tailwind CSS 3.4.17, and committed so the
viewer runs offline:

```sh
cd clients/viewer/assets
npm ci          # package-lock.json pins both
npm run build   # node build.js
```

A Runtime worker folder gets these dependencies from the orchestrator before the worker starts, with
`atlas-runtime snapshot prepare --dest DEST --npm-ci atlas/clients/viewer/assets` (where the snapshot mounts
Atlas at `atlas`; scripts disabled, public
registry only; see [the Runtime CLI](../../tools/runtime/README.md#explicit-folder-preparation-npm-ci)).
Workers have no network for `npm ci` themselves. The orchestrator can then prove the committed assets rebuild
from the snapshot, with no network, by running the build as a declared preparation:
`atlas-runtime snapshot prepare --dest DEST --npm-run atlas/clients/viewer/assets --script build --output
atlas/clients/viewer/priv/static/app.css --output atlas/clients/viewer/priv/static/prism --output
atlas/clients/viewer/assets/.build`. It fails unless `app.css` and `prism/` come out byte-identical to the
committed files ([details](../../tools/runtime/README.md#network-off-generation-npm-run)).

`build.js` inlines Prism's `css/base.css` and `css/components.css` with their `@import`s,
copies every `url()` asset they reference into `priv/static/prism/`, rewrites those URLs to
`/assets/prism/…`, then runs Tailwind with Prism's preset over `assets/app.css`. It fails on
other versions, remote or missing assets, unresolved or conditional imports, and output
missing any Prism class the page uses. The viewer refuses to start without the built files.

The build preserves Prism's MIT license and the fonts' OFL license beside the bundled assets.
Tailwind's reset precedes Prism components so it cannot erase their styling.
