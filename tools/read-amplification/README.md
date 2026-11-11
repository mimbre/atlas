# Private description-read investigation (GitHub86)

This probe runs actual Bus, Facts and Control against a synthetic memory backend,
tiny private DETS files and a loopback port chosen by the OS. It starts no Flow,
Runtime, model or external HTTP service. It is a diagnostic fixture, not a live
load test. The output directory is explicit and fixtures are retained.

From `beam/`:

```sh
MIX_ENV=test ELIXIR_ERL_OPTIONS='+S 1:1' \
  ATLAS_READ_PROBE_EVIDENCE=/private/output/path \
  mix run --no-start ../tools/read-amplification/reproduce.exs
```

The backend delay and release gate expose the request chain; a Router trace
records read identities and queued Facts work. Six refresh frames are a finite
private experiment, with no artificial CPU load or repeated production probes.

Observed before the fix, at source8730fac:

| Case | Observation |
| --- | --- |
| One logical description read | Two backend schema fetches instead of one |
| 300ms schema callback, 500ms wait, 1500ms logical budget | False Facts unavailable at1503ms; three distinct read IDs, five schema fetches begun |
| Six refreshes queued during one gated refresh | Seven renders, fourteen schema fetches |

After removing only the redundant entity-kind prefetch for metadata reads:

| Case | Observation |
| --- | --- |
| One logical description read | One fresh backend fetch |
| Same controlled slow callback | Successful page at321ms, one read ID and one fetch |
| Same queued refresh experiment | Seven renders, seven schema fetches |

The timings describe this private fixture, not a production SLA or root cause.
Normal unit regressions also cover later fresh metadata, explicit unavailable
responses without stale success, and refusal of a fact using the reserved kind.

The observational refresh case intentionally records the remaining non-coalesced
behavior; it is not a desired future contract. A later queue/coalescing change may
update that experiment. Fresh-ID retries, late replies, reconcile amplification
and Facts serialization remain open under [GitHub86](https://github.com/eyra/atlas/issues/86).
This slice does not redesign or claim to resolve them.

No live deployment, restart, resource/auth change or production causality is
established by a successful private run. Normal Atlas association is deferred
while planning is unavailable; the existing GitHub86/UC41 reliability scope was
explicitly authorized for this repair.

<sub>Written by an AI agent (Codex · GPT-6 · herdr-projects atlas · t-0024).</sub>
