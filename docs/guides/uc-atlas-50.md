# Try UC-Atlas-50: A Runtime is installed, configured, upgraded and sandboxed through Atlas

This guide grows with the use case, one section per issue.

## IS-Atlas-26: a supervisor upgrades a Runtime through Atlas

A Runtime's upgrade is one supervised flow its supervisor starts from Control, for a machinery's Runtime, naming the released build. The Runtime drains, waits until no slot is busy, installs the build with its one update command, is restarted by its launch agent, and Flow verifies it: `service status` shows the new `runtime_build`, a new incarnation and mode `open`, and the Runtime offers work again. The upgrade ends `done`, or `failed` with the step and why. Nobody types a command on the machine, and two upgrades never run on one Runtime at once. This also covers the update part of IS-Atlas-116: one update command for `~/.local/bin/atlas-runtime` that refuses while a slot is busy.

### Before: once per machine

- The Runtime runs a release, the build Atlas publishes: CI publishes `atlas-runtime-<commit>` (darwin/arm64) for every push to develop and master (`deploy-runtime-release` in `.github/workflows/ci.yml`). A machine still on a checkout build gets its first release by hand, with `atlas-runtime update --build <commit>` built from this revision or later (`go -C platform/atlas_runtime/host build -o ~/.local/bin/atlas-runtime .`), or through Control once its binary has `update`.
- `machine.json` names where the releases are: `"releases": "https://github.com/OWNER/REPO/releases/download"`. `start.sh` passes it to the service, so `install.sh` and a restart through the launch agent (`launchctl kickstart gui/$UID/com.mimbre.atlas-runtime`) once. A private repository's release downloads need credentials this does not hold (see Open, below).

### Try

| Step | Where | What you should see |
|---|---|---|
| Start a turn | any task the Runtime `mac-mini` picks up, on test | `atlas-runtime service status` on the machine shows its slot `"busy": true` (only to look; nothing is typed there) |
| Start the upgrade | `atlas put runtime_upgrade --in mac-mini --build <commit> --env test`, or in the Console: the machinery `mac-mini`, its **upgrades** list, the create key, **build** | `RU-01`, `state` Open, `step` Requested; its run says **Wait for the Runtime to take it** |
| It drains and waits | `atlas get RU-01 --env test` after the next poll (at most 25 s) | `step` Draining, `busy` the busy slot; the run says **Wait until no slot is busy**, why: *the Runtime takes no new work while its running turns end* |
| A second upgrade | `atlas put runtime_upgrade --in mac-mini --build <other> --env test` | Refused: `mac-mini is being upgraded already: RU-01; start another once it ends` |
| The turn ends | — | `step` Updating, then Verifying |
| It comes back | `atlas get RU-01 --env test` | `step` Done, `state` Ended, `from_build` and `from_incarnation` the old ones, `incarnation` the new one; `service status` shows `runtime_build` `<commit>`, mode `open` |
| It accepts work | start a new task for the Runtime | its turn runs on the new build (its provenance's `runtime_build`) |
| By hand, while a slot is busy | `atlas-runtime update --build <commit>` on the machine | exit 1: `update refused: slot busy: dev1; drain the Runtime (atlas-runtime service drain) and wait until service status shows no busy slot`, with `"busy": ["dev1"]` |
| By hand, during an update | the same, while one runs | exit 1: `update refused: another update holds update.lock (pid N); wait until it ends` |
| A failure | an upgrade to a build that was never published | `step` Failed, `failed_step` update, `reason` `fetch: …: HTTP 404`; the Runtime is open again on its old build |

### How it works

- **The model** (`products/software_factory/model/contract/foundation/runtime_upgrade.ex`): the kind `runtime_upgrade` (`RU-nn`) under its machinery (`upgrades`, a parent relation), with `build` (asked), `state` (Open when made, Ended at the end) and Flow's fields `step`, `busy`, `failed_step`, `reason`, `from_build`, `from_incarnation`, `incarnation`. The relation's `limit` (one with `state` Open per machinery) is the refusal of a second upgrade. The subflow `runtime_upgrade` follows `step` (requested, draining, updating, verifying, done, failed); each state presents what it waits for. Flow's work source receiver (`flow/delivery`) is a sender of Flow's writer for `runtime_upgrade` and `machinery` (`flow_runtime` in `foundation/flow_run.ex`).
- **The contract** (`platform/atlas_runtime/boundary/contract/lib/work_source.ex`, 0.5.0; backend `work_source_api` 0.4.0): `polled.upgrade` (`id`, `build`) and `poll_input.upgrade` (`id`, `step`, `busy`, `mode`, `failed_step`, `reason`), both optional.
- **Flow** (`platform/atlas_flow/lib/atlas_flow/work_source/upgrade.ex`): on each poll, beside the configuration step, finds the machinery's open upgrade, writes the step the poll reports, verifies the restarted Runtime (build, new incarnation, mode open, an offer of at least one slot) and serves the upgrade until it ends.
- **The Runtime** (`platform/atlas_runtime/lib/atlas_runtime/upgrade.ex`, from the source's puller): drains, waits, runs `atlas-runtime update --build B --detach`, and after the restart opens again; the steps are kept in `upgrade.json`.
- **The update command and the release** (`platform/atlas_runtime/host/update.go`, `release.sh`): see the Runtime README, [Update to a released build](../../platform/atlas_runtime/host/README.md#update-to-a-released-build).

### Verified

- Unit and contract tests: Go (`update_test.go`: busy slot named, lock, install and restart, a mode it did not set, bad sha256, mislabelled release), Runtime ExUnit (`test/sources/upgrade_poll_test.exs`: drain, busy, update, restart, open; failed update; another build; another source), Flow (`test/work_source/upgrade_test.exs`, `router_test.exs`), the contracts and the model (`test/runtime_upgrade_test.exs`: the create, the refusal of a second, Flow's fields, the run).
- On a Mac, with throwaway paths: `release.sh` built two releases; `update` installed the first onto a stopped Runtime, which started from the release without Mix and reported its build; `update` took the running Runtime from one release to the other (drain, stop, install, start, resume: 2.4 s, new incarnation, mode open); `--detach` did the same, and an update started meanwhile was refused naming the holder's pid.

### Open

- Not run on the test environment: the done-when (a turn running, the upgrade waiting for it, the Runtime back on the released build taking a new task) needs this deployed to test, a published release, and a Runtime on a release build with `releases` in its `machine.json`.
- The `runtime_upgrade` diagram (`model/targets/diagrams/runtime_upgrade.md`) and the `flows.yaml` validation need the pinned rela: run `mix model.gen` with `ATLAS_RELA_BIN` set.
- A private repository's release assets need an authenticated download; `update` sends no credentials.
- An upgrade has no deadline and no cancel: a Runtime that never polls leaves it Requested, and one whose turn never ends leaves it Draining. Ending it by hand is setting its `state` to Ended (Flow then serves it no more; a Runtime that drained stays draining until `atlas-runtime service resume`).
