# Gate activity and decider timeout proof

Run from the repository root after merge. Use test throughout. Production's generated pair contains `48h`; test's separate pair contains `5m`. Both carry the digest of their own YAML. Flow reads the selected pair without rewriting YAML. The explicit migration in `rela/flow-runtime.json` admits only the exact previous status-bridge definition, with no pending writes or deadlines. Historical final runs keep their cursor; a waiting bridge run enters `deciding` once. Back up the environment before deployment, as for other durable-run changes. Any other definition drift still refuses execution.

The additional `based_on` review entry and the decision's own red flag live in the runtime sidecar (`rela/flow-runtime.json`, generated from the model since Rela DSL slice 2) and are applied by Facts after the description is loaded. The confirmation relation and immutable-field exception live in foundation schema and metadata.

## Local checks and private native proof

Use the pinned, already installed Rela 26.11.2 and a Python with `rela/scripts/requirements.txt` installed:

```sh
export ATLAS_RELA_BIN="$PWD/.rela-bin"
export ATLAS_E2E_RELA_BIN="$ATLAS_RELA_BIN"
(cd model/dsl && MIX_ENV=test mix test --warnings-as-errors)
(cd model/contract && mix model.gen --check && mix test)
python3 -m unittest discover -s rela/tests -v
(cd beam && mix test apps/atlas_bus/test/boundary_test.exs \
  apps/atlas_flow/test/runs apps/atlas_flow/test/activities \
  apps/atlas_gates/test apps/atlas_facts/test/flow_inputs_test.exs \
  apps/atlas_facts/test/flow_runtime_test.exs apps/atlas_facts/test/guards_test.exs \
  apps/atlas_facts/test/review_test.exs apps/atlas_facts/test/subflows_test.exs)
(cd beam && MIX_ENV=test mix run integration/flow_gate.exs)
(cd e2e && mix test test/flow_run_test.exs)
```

The last command owns a private Rela process, Facts, Gates and a manual clock. It restarts Facts before the deadline, advances from 299,999 ms to 300,000 ms, checks the second verdict and `follows`, accepts through Facts' trusted input path, checks both review flags, confirms, supersedes, and checks that the fixed-rule wait has no timer. It stops its server on success and failure. It also retains the neutral trusted-input persistence proof. No test sleeps until a deadline.

The manual-clock Bus proof uses a memory store; it proves the Flow/Gates boundary and recovery, not Rela persistence or schema validation. Native checks must run before claiming the latter. On the development sandbox used for this change, the pinned binary was unavailable: native validation and native e2e execution were not performed. The updated decision diagram/version was reconstructed from the YAML serialization and diagram conventions of the committed fixtures; `mix model.gen --check` with the pinned binary remains the authoritative check.

## Real behaviour on the deployed test environment

These commands create demonstration facts on test. Keep the returned keys. They assume `coordinator` and `melle` already exist there; Melle runs the confirmation and overrule commands as themselves.

```sh
D=$(ATLAS_AS=coordinator bin/atlas put decision --env test --json \
  --title 'Timeout proof: unanswered direction' \
  --decision 'Exercise the five-minute decider timeout' \
  --category process --scope platform --reversibility two_way --force direction | jq -er .key)
W=$(ATLAS_AS=coordinator bin/atlas put issue --env test --json \
  --title 'Timeout proof: anchored work' --link "based_on=$D" | jq -er .key)
bin/atlas facts flow_run --env test --json | jq --arg d "$D" \
  '.facts[] | select(.values.subject_key == $d) | {key, values}'
bin/atlas facts gate_verdict --env test --json | jq --arg d "$D" \
  '.facts[] | select(.values.subject == $d) | {key, values, links}'
```

The run must be in `for_person`, with one durable `no_answer` deadline five minutes after `entered_at`, and a recorded `person` verdict. No `delegated_by` link is set. Before that deadline, this acceptance must be refused:

```sh
ATLAS_AS=coordinator bin/atlas set "$D" --env test \
  decided_by=coordinator status=accepted decided_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

After the recorded five-minute deadline, repeat the two Facts reads above. Expect `for_agent_unverified`, a second verdict with `timed_out: true`, `waited_from`, and `follows` pointing to the first verdict. Accept, then inspect both flags:

```sh
ATLAS_AS=coordinator bin/atlas set "$D" --env test \
  decided_by=coordinator status=accepted decided_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GV=$(bin/atlas facts gate_verdict --env test --json | jq -er --arg d "$D" \
  '.facts[] | select(.values.subject == $d and .values.verdict == "agent_unverified") | .key')
bin/atlas get "$D" --env test
bin/atlas get "$W" --env test
```

Expect “🔴 Unverified decision” on the decision and “Based on unverified decisions” on the work. Confirm, then repeat both `get` commands after Flow reconciles. Both flags must clear; the stored decision field becomes `unverified: false`:

```sh
ATLAS_AS=melle bin/atlas set "$GV" --env test reviewed_by=melle
bin/atlas facts decision "$D" --env test --json
bin/atlas get "$D" --env test
bin/atlas get "$W" --env test
```

To demonstrate overrule, create a replacement, wait for its run to reach a `for_*` state, and accept it as Melle. The existing replacement rule changes the original decision to `superseded`; its work now shows “Review: based on a superseded decision”. The review is recorded on the original verdict:

```sh
NEW=$(ATLAS_AS=melle bin/atlas put decision --env test --json \
  --title 'Timeout proof: replacement' --decision 'Replace the demonstration direction' \
  --category process --scope platform --reversibility two_way --force direction \
  --link "supersedes=$D" | jq -er .key)
bin/atlas facts flow_run --env test --json | jq --arg d "$NEW" \
  '.facts[] | select(.values.subject_key == $d) | {key, values}'
ATLAS_AS=melle bin/atlas set "$NEW" --env test \
  decided_by=melle status=accepted decided_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
ATLAS_AS=melle bin/atlas set "$GV" --env test \
  overruled_by=melle overrule_reason="Superseded by $NEW"
bin/atlas get "$W" --env test
```

Finally create a principle and leave it past five minutes. Its run must remain `for_person_always` with an empty timer list and one verdict:

```sh
P=$(ATLAS_AS=melle bin/atlas put decision --env test --json \
  --title 'Timeout proof: fixed rule' --decision 'Demonstrate the fixed-rule wait' \
  --category process --scope platform --reversibility two_way --force principle \
  --enforced_by 'Manual timeout proof' | jq -er .key)
bin/atlas facts flow_run --env test --json | jq --arg d "$P" \
  '.facts[] | select(.values.subject_key == $d) | {key, values}'
bin/atlas facts gate_verdict --env test --json | jq --arg d "$P" \
  '.facts[] | select(.values.subject == $d) | {key, values, links}'
```

These demonstrations leave their ledger facts as recorded history. Stop any locally owned test environment when finished. No real test deployment was contacted during implementation.

## Implementation verification

On 2026-11-12, the final focused checks passed with both a physical TMPDIR and a TMPDIR reached through a newly created symlink. Both paths resolved to the same physical directory.

| Check | Result per pass |
| --- | --- |
| Flow generator | 146 tests reported, 0 failures, 3 native tests excluded |
| Flow contract and generated-pair freshness | 28 tests reported, 0 failures, 1 native test excluded; pairs current |
| Focused BEAM suites (Bus boundary, Flow, Gates, Facts inputs/runtime/guards/review/subflows/description) | 147 tests, 0 failures |
| Manual-clock Flow/Gates Bus proof | 3 tests, 0 failures |
| Rela config inventories/closure and provenance verification | 4 tests passed; native class skipped; provenance verified |
| Native e2e wrapper | 2 tests skipped because the pinned binary was unavailable |
| CI generator boundary greps | No output; BEAM boundary tests also passed |

An earlier broader Facts run reported three failures in connector_test.exs: the GitHub fixture reads returned FunctionClauseError. That source was not changed by this slice. These failures remain unresolved; no full CI pass is claimed. No native schema/flow validation, native persistence proof, Docker build, deployment or real test-environment proof was run. The diagram/version still needs the authoritative pinned-Rela generation check described above.

## Changed paths

Paths are relative to the repository root.

- `beam/apps/atlas_facts/lib/atlas_facts/flow_inputs.ex`
- `beam/apps/atlas_facts/lib/atlas_facts/flow_runtime.ex`
- `beam/apps/atlas_facts/lib/atlas_facts/guards.ex`
- `beam/apps/atlas_facts/lib/atlas_facts/review.ex`
- `beam/apps/atlas_facts/lib/atlas_facts/server.ex`
- `beam/apps/atlas_facts/lib/atlas_facts/subflows.ex`
- `beam/apps/atlas_facts/test/flow_inputs_test.exs`
- `beam/apps/atlas_facts/test/review_test.exs`
- `beam/apps/atlas_facts/test/subflows_test.exs`
- `beam/apps/atlas_flow/lib/atlas_flow/activities/gate.ex`
- `beam/apps/atlas_flow/lib/atlas_flow/generated.ex`
- `beam/apps/atlas_flow/lib/atlas_flow/runs/run.ex`
- `beam/apps/atlas_flow/lib/atlas_flow/runs/store.ex`
- `beam/apps/atlas_flow/lib/atlas_flow/talk.ex`
- `beam/apps/atlas_flow/test/activities/gate_test.exs`
- `beam/apps/atlas_flow/test/runs/run_test.exs`
- `beam/apps/atlas_gates/lib/atlas_gates/application.ex`
- `beam/apps/atlas_gates/lib/atlas_gates/endpoint.ex`
- `beam/apps/atlas_gates/lib/atlas_gates/facts/bus.ex`
- `beam/apps/atlas_gates/lib/atlas_gates/record.ex`
- `beam/apps/atlas_gates/lib/atlas_gates/request.ex`
- `beam/apps/atlas_gates/mix.exs`
- `beam/apps/atlas_gates/test/endpoint_test.exs`
- `beam/config/runtime.exs`
- `beam/config/test.exs`
- `beam/integration/flow_gate.exs`
- `beam/integration/flow_gate_native.exs`
- `beam/mix.exs`
- `docs/guides/flow-gate-timeout-proof.md`
- `e2e/test/flow_run_test.exs`
- `model/contract/config/config.exs`
- `model/contract/lib/decision.ex`
- `model/contract/lib/gates.ex`
- `model/contract/test/decider_test.exs`
- `model/contract/test/golden/decision.flows.yaml`
- `model/contract/test/golden_test.exs`
- `model/contract/test/presentation_test.exs`
- `model/dsl/lib/limits.ex`
- `model/dsl/lib/mix/tasks/model.gen.ex`
- `model/dsl/lib/rela.ex`
- `model/dsl/lib/schema.ex`
- `model/dsl/test/limits_test.exs`
- `model/targets/atlas/flows.json`
- `model/targets/diagrams/decide.md`
- `model/targets/rela/flows.yaml`
- `model/targets/test/atlas/flows.json`
- `model/targets/test/rela/flows.yaml`
- `fly/core.Dockerfile`
- `rela/atlas.json`
- `rela/atlas.manifest.json`
- `rela/flow-runtime.json`
- `rela/flows.yaml`
- `rela/modules/foundation/atlas.json`
- `rela/modules/foundation/schema.yaml`
- `rela/tests/fixtures/baseline-schema.yaml`
- `rela/tests/test_assembly.py`
- `rela/tests/test_config.py`
