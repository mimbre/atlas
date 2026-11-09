# Flow runs the generated state machines

Author design. No product code changes. Paths are relative to `atlas/`.

Flow runs the machines. Rela defines and checks them. There is no planned switch to a Rela runner.

## 1. Current behaviour

| Behaviour today | File:line evidence |
| --- | --- |
| Facts merges Rela's schema with the extra description on each read. It adds generated subflows and checks the old flows. | `beam/apps/atlas_facts/lib/atlas_facts/server.ex:353-365` |
| Flow reads `_description` through Facts. Executable definitions come from `description.flows`, excluding `flow_problems`. This is the old extra-description format. | `beam/apps/atlas_flow/lib/atlas_flow/engine.ex:109-143`; `beam/apps/atlas_flow/lib/atlas_flow/definition.ex:43-56`; `rela/atlas.json:898` |
| A round lists each subject kind. An open fact gets one registered Item process. A missing process is recreated. | `beam/apps/atlas_flow/lib/atlas_flow/engine.ex:125-130,218-246`; `beam/apps/atlas_flow/lib/atlas_flow/item.ex:22-25` |
| State is the first matching predicate. It is recomputed from the subject and related facts. It is not a durable machine cursor. `next` is checked for reachability, not executed as a transition. | `beam/apps/atlas_flow/lib/atlas_flow/definition.ex:93-143`; `beam/apps/atlas_flow/lib/atlas_flow/item.ex:74-90`; `beam/apps/atlas_facts/lib/atlas_facts/flows.ex:210-232,262-281` |
| Hints wake subjects and ancestors. Deletes and new owners wake all items. The ancestor walk stops at depth eight. Flow skips its own writes. Polling recovers lost hints. | `beam/apps/atlas_flow/lib/atlas_flow/engine.ex:26-27,56-82,150-208` |
| Item uses real process timers, including a 50 ms debounce. `every_seconds` changes polling frequency. These are not state deadlines. | `beam/apps/atlas_flow/lib/atlas_flow/item.ex:19-20,49-67,85-90`; `beam/apps/atlas_flow/lib/atlas_flow/definition.ex:186-191` |
| Flow writes expected work, presentation state and owner through Facts over the Bus. It can write on a related assignment. Writes include cause and previous values. | `beam/apps/atlas_flow/lib/atlas_flow/item.ex:103-131,133-212`; `beam/apps/atlas_flow/lib/atlas_flow/talk.ex:13-46` |
| Manual ownership stays until work changes. Handover can wait for an active turn. Missing owners and unavailable Facts cause retries. | `beam/apps/atlas_flow/lib/atlas_flow/item.ex:142-186,230-281` |
| Presentation state is cleared on completion. Restart reads facts again; there is no explicit run to restore in Item. | `beam/apps/atlas_flow/lib/atlas_flow/item.ex:74-101,290-295`; `beam/apps/atlas_flow/lib/atlas_flow/application.ex:15-22` |
| Talk retries with the same envelope id within one call. Facts records answers by id. This alone cannot make an external effect execute once across Flow restarts. | `beam/apps/atlas_flow/lib/atlas_flow/talk.ex:30-46`; `beam/apps/atlas_facts/lib/atlas_facts/server.ex:272-281`; `beam/apps/atlas_facts/lib/atlas_facts/ledger.ex:3-7,19-23` |
| Facts supports optimistic writes. A conflicting version can succeed if changed fields still match `was`. | `beam/apps/atlas_facts/lib/atlas_facts/server.ex:944-967` |
| Facts already embeds the generated target for owners and presentation. Flow currently depends only on Bus. | `beam/apps/atlas_facts/lib/atlas_facts/subflows.ex:3-21`; `beam/apps/atlas_flow/mix.exs:26-27` |
| Cross-layer calls and domain names in platform sources and tests are guarded. | `beam/apps/atlas_bus/test/boundary_test.exs:17-33,45-59,109-155` |

Two differences affect cutover. Generated `decide` has three states, verdict branches and status outputs, but no timer (`flow/contract/lib/decision.ex:16-61`). Old `decide` also keeps accepted decisions open until work is based on them, or `no_work` is true (`rela/atlas.json:1239-1332`). Preserve this follow-through during migration.

The composition lists seven modules; UseCase supplies two subflows, making eight. It links outcomes and counts children (`flow/contract/lib/software.ex:20-51`; `flow/contract/lib/use_case.ex:19-29`).

## 2. Make the generated target executable

Today format 1 holds the YAML digest, gates, subject, owner, channel, initial state, labels, final markers, presentation, and mechanism kind/spec. Gate data includes `answer_within`. Evidence: `flow/generator/lib/atlas.ex:35-94`; the concrete decision entry is `flow/targets/atlas/flows.json:4-36`.

It omits start triggers, `run_as`, `per_subject`, state status, waiting roles, awaited fields, ordered branches, entry sets, creates and timers. It also omits composition links and counts. The DSL already builds that data; the JSON writer discards it. Evidence: `flow/generator/lib/schema.ex:789-812,865-880,941-977`; `flow/generator/lib/rela.ex:43-122`; `flow/generator/lib/mix/tasks/atlas.flow.gen.ex:54-82`. Activities are described, not dispatched, by this writer (`flow/generator/lib/atlas.ex:83-94`).

Extend the Atlas writer, not a runtime YAML reader. Emit format 2. Preserve branch and timer order. Emit the missing fields with explicit empty lists. Keep owner, presentation and mechanism data. Omit source line metadata. Add composition data in its own slice. Regenerate targets and goldens. Keep Rela YAML bytes stable unless the contract changes.

Runtime embeds JSON at compile time. It accepts only format 1 and exposes flows, gates, `rela_flows_sha256/0` and a hash check. That check compares supplied YAML bytes; it does not find the deployed file (`flow/generator/lib/runtime.ex:23-84`). Update reader and writer together. Rebuild all target consumers together.

Before starting generated runs, Flow reads the selected deployment's `rela/flows.yaml` and calls `check_rela_flows/1`. Missing, unreadable or mismatched YAML refuses the generated runner before any write or timer. Report expected and actual digests. Never fall back to legacy execution for a migrated subject. Explicitly unmigrated subjects may continue. A hash match is not validation. Require Rela validation in deployment checks; the current generation task can skip it when its binary is absent (`flow/generator/lib/mix/tasks/atlas.flow.gen.ex:28-35,93-110`).

## 3. Run and recovery model

The rest of this section defines new behaviour.

Use one run per `(subflow, subject kind, subject key, generation)`. `per_subject: one` permits one active generation per subflow and subject. Different subflows may run on one subject. Registry keys include subflow and generation. Finality is durable. A hint cannot reopen a final run. A new explicit start creates another generation. Predicate starts consume a persisted false-to-true edge, not each poll while true.

Add the generic `flow_run` kind to the foundation description:

| Fields | Meaning |
| --- | --- |
| `flow`, `subject_kind`, `subject_key`, `generation` | Stable identity. Use its digest as the fact key. |
| `definition_sha256` | Lowercase SHA-256 of the subflow's canonical JSON data from the published `flow/targets/<env>/atlas/flows.json` pair (production uses `flow/targets/atlas/flows.json`). Recursively sort object keys, omit insignificant whitespace, preserve array order and exact scalar values. Hash only the selected subflow, excluding the pair's header, YAML hash and unrelated flows. No Erlang term serialization or runtime struct metadata. |
| `state`, `entry`, `entered_at`, `status` | Cursor, increasing entry number, UTC entry time, active/completed/blocked. Self-transition increments entry. |
| `deadlines` | JSON text: timer name, resolved UTC due time, source entry. |
| `pending` | JSON text: remaining entry writes or activity intents, stable ids and frozen payloads. |
| `input_cursor`, `last_input` | Last consumed Facts position and accepted input or timer identity. |
| `blocked_reason` | Why safe recovery cannot proceed. |

Version the structured text fields. Do not add timer and outbox kinds yet. The kind/key tuple refers to the subject; no domain-specific run relation or form is needed. Add `flow_runtime` metadata naming the run kind and field mapping. Platform code reads it. Run records are machine-written and hidden from create menus. Facts enforces a description-driven writer rule. A UI flag alone is not authorization.

Define the kind in `rela/modules/foundation/schema.yaml`, metadata in `rela/modules/foundation/atlas.json`, and grants in `rela/acl.yaml`. Bind metadata through `rela/compositions/atlas-eyra/bindings.yaml`. Reassemble `rela/schema.yaml`, `rela/atlas.json`, `rela/atlas.manifest.json` and tracked composition outputs. Update every exact inventory. The foundation list is exact at `e2e/test/composition_test.exs:125-126`. Include `e2e/test/rela_description_test.exs`, `rela/tests/test_{assembly,config}.py`, `rela/tests/profiles.py`, and `rela/tests/fixtures/{baseline-schema.yaml,baseline-atlas.json}` where their exact expectations change. Repeat the inventory search whenever a kind, relation, form or flow changes.

The assembler rejects unknown root keys and runtime keys (`rela/scripts/assemble.py:53-55,391-395`). Keep it unchanged. Store `flow_runtime` mapping, selection and machine-writer rule in a separate description fragment, new `rela/flow-runtime.json`. Facts merges it into its answered description after the assembled extra description. Configure its path in `beam/config/runtime.exs`; include it in `fly/core.Dockerfile` and `fly/core-run.sh` deployment closure. Validate it in new pure `beam/apps/atlas_facts/lib/atlas_facts/flow_runtime.ex`, tested in `test/flow_runtime_test.exs` and called from Facts `server.ex`. Its keys refer to the assembled schema; invalid mappings refuse execution. This avoids new Python. The sidecar holds runner configuration and import data; executable domain definitions remain in the generated target. Facts verifies the Bus sender as well as the configured writer identity; changing `by` must not impersonate Flow.

Use one writer per run in this release. Claim entry changes with run version and `was`. On conflict, reread. Do not assume a transaction spanning run, subject and service. Persist the next cursor with pending entry writes first. Replay those writes with stable request ids. Clear pending after acknowledgement. Consume no further input until entry writes finish. Bootstrap historical terminal subjects before any initial resets. Never turn an accepted subject back into proposed.

At boot, load incomplete runs and pending writes. Scan selected subjects for missed starts. Restore wakeups from durable UTC deadlines. Process overdue timers immediately. Never restart their intervals. Inject a clock for now, scheduling and cancellation, including new engine rounds and debounce. Production persists UTC and uses monotonic waits. Tests advance a manual clock and drain a synchronous reconcile call. Old polling tests need not be rewritten in slice 1.

A timer has identity `(run key, entry, timer name)`. Its versioned transition consumes it. Duplicate and old-entry wakeups do nothing. Human input stored by the deadline wins; otherwise the timer wins. Break timer ties by declaration order. Reread Facts before committing a timeout. Persist source entry and due time in `last_input`; the next gate request can carry `timed_out: true` and the original wait time. Resolve `since` from its named persisted field. Missing or invalid time blocks; never substitute now.

Branches are ordered. Compile supported expressions to neutral data with a small parser. Never evaluate Elixir. Missing values mean not ready; unknown syntax refuses activation. Grow the supported grammar only when a selected contract needs it. Human choices require typed input with trusted actor and authorization evidence from Facts. A hint, an owner or user-supplied roles cannot supply that evidence.

An activity has identity `(run, entry, activity name)` and a frozen fingerprint. Store its request before sending. Match every reply to identity and fingerprint. Retry the same id. Ignore late replies for old entries or fingerprints. A timeout is not proof that the service did nothing. Enable an effect only when its receiver can return the original result for a repeated id, reject changed payload under that id, and recover a lost answer by lookup. Otherwise block for reconciliation. Facts deduplication alone is insufficient for external effects.

Pin definitions. Changed subflow data blocks its old runs until an explicit, tested state migration is supplied. Unchanged subflows continue. The YAML hash checks the deployed pair; the per-run hash checks run compatibility. Back up stores before migration. Rollback must not erase run history.

An encoding-only migration is explicit in `rela/flow-runtime.json`: an exact old/new digest pair, `rekey: true`, and identity state mappings. It changes the stored definition digest and appends a `pending.migrations` audit record. It preserves state, entry, entry time, deadlines, pending writes and frozen activity requests, including their IDs; it never re-enters the state. This also applies to completed imports. A prior definition block is cleared by restoring its saved status. Ordinary state migrations retain their quiescence checks and entry semantics; every unmatched definition change still blocks that run.

## 4. Ordered Developer assignments

Each slice is one assignment. Complete its checks and test-environment proof first. Lists name the allowed files. New files are marked new. Platform tests use neutral nouns. Domain mappings and demonstrations belong in contract tests or `e2e/`. Use manual clocks, acknowledgements and monitors. Do not wait on real timers.

Migration selection maps a generated subflow to its legacy execution and projection scope. Do not assume old and new names match. Admission conditions and the import state table are data in `rela/flow-runtime.json`. At most one runner owns a subject's assignment projection at a time. Reject overlapping admission. A completed generated phase releases projection to its next phase; it does not disable every legacy phase on that subject kind. Test this with neutral two-phase fixtures before migrating a shared subject.

### 1. One small machine beside the existing engine

Run only `decide`. This is a compatibility bridge, not the general runner.

Scope:

- `flow/generator/lib/{atlas,runtime}.ex`, `flow/generator/test/{atlas,runtime}_test.exs`, `flow/generator/test/golden/example.flows.json`: format 2 and reader rejection tests.
- `flow/contract/lib/decision.ex`, `flow/contract/test/decider_test.exs`, `flow/contract/test/golden/decision.flows.yaml`; regenerate `flow/targets/atlas/flows.json`, `flow/targets/rela/flows.yaml`, `flow/targets/diagrams/decide.md`, `rela/flows.yaml`.
- In `beam/apps/atlas_flow/`: `mix.exs`, `lib/atlas_flow/{engine,definition,item,application,talk}.ex`; new `lib/atlas_flow/generated.ex` and `lib/atlas_flow/runs/{run,store,clock}.ex`; new `test/runs/run_test.exs`, `test/support/manual_clock.ex`; extend `test/support/fake_facts.ex` and `test/engine_test.exs`. `beam/config/runtime.exs` supplies the selected deployment YAML path.
- Foundation schema, metadata, grants, bindings, generated assembly outputs and exact inventories listed in section 3. Facts `lib/atlas_facts/guards.ex` and `test/guards_test.exs` only for the generic machine-writer rule; the new mapping validator and its caller/tests named in section 3. New `e2e/test/flow_run_test.exs` for real persistence.

Execute only create start, initial/final states, ordered field-equality branches, entry sets and fixed-duration state timers. No role parser, creates, predicate starts, activities or composition. Carry all executable fields in JSON, but refuse unsupported features in any selected definition before writing. Select `decide` through description metadata, never a domain-kind conditional in Flow.

For this bridge, change the decision contract to observe already-authorized `status` with ordered equality branches: accepted or rejected leads to its matching final state. Remove the unconsumed verdict/role branches temporarily. Do not reset status or write it on final entry. Test entry sets on the neutral fixture instead. Today's Facts authority remains in force (`rela/atlas.json:354-405`; `beam/apps/atlas_facts/lib/atlas_facts/guards.ex:64-79`). Slice 3 replaces this bridge with typed verdict input. Import historical accepted/rejected subjects directly to final. Record superseded subjects as completed historical imports without rewriting their status.

This is a generated transition machine with a durable cursor. It does not infer the cursor from presentation. Remove selected subjects from legacy execution. Reuse old predicates only for post-acceptance follow-through presentation. One projection writer owns the assignment; no second Item writes it. A final run can retain a follow-through owner without reopening. Reuse existing manual-owner and deferred-handover logic. Do not delete the legacy definition yet.

Add the generator as a path dependency, as Facts does; it is not another platform app. Supply the deployed YAML path in startup options. Keep run code under `runs/`. Do not extract a general framework.

Acceptance: pure ordered-equality, finality and import tests. Store tests cover restart in a waiting entry, lost entry-write acknowledgement, duplicate create, duplicate timeout and cancelled old-entry timeout. Advance to just before and exactly at a deadline. Restart Flow while preserving fake Facts; advance beyond the original due time. Hash refusal must cause zero writes. Mixed-engine tests prove one selected writer and continued legacy operation for another neutral subject. Guard tests reject client run writes. Run boundary and exact inventory checks.

Real behaviour on test: create a proposed decision and read its run. Accept through today's authorized command. Restart Flow and read the same completed run. Show an unselected subject still advances. In a private test deployment only, generate a decision variant with a five-minute proposed-to-proposed timer. Advance the injected clock and restart on both sides of the deadline. Show exactly one new entry from the original due time. Restore the normal generated pair. No production deadline is invented: today's `decide` has none (`flow/contract/lib/decision.ex:16-61`).

Size boundary: three states, equality only, one run kind, one pending record and one timer seam. No Gates adapter or general expression interpreter. This delivers the durable timer kernel needed by decider-gate slice 3 without taking on its product behaviour.

### 2. Transition kernel and trusted inputs

Scope: new Flow `lib/atlas_flow/runs/{conditions,inputs}.ex`, `test/runs/{conditions,inputs}_test.exs`; `runs/{run,store}.ex`, `talk.ex`. New Facts `lib/atlas_facts/flow_inputs.ex`, `test/flow_inputs_test.exs`; Facts `server.ex`. Extend `flow/generator/test/atlas_test.exs` and `flow/contract/test/decider_test.exs`. Keep production selection unchanged.

Support only expressions used by the contracts: equality, inequality, numeric comparisons, conjunction, disjunction and parentheses. Pin precedence in tests. Add predicate edges, resets, `since`, and creates with stable keys per entry/output index. Facts exposes typed inputs with subject version, actor roles, changed fields and position, validated against selected ACL and role relations. Never accept client-supplied roles. Separate snapshot-driven auto branches from authenticated choices.

Persist typed inputs through Facts as a new generic foundation `flow_input` kind. Scope also includes the same schema, description, grants, bindings and exact-inventory files listed in section 3. Fields: `request_id`, run identity, source subject version, actor, validated roles, changed fields, payload digest, prepared/applied/consumed status and stored position. Prepare before the subject write, then mark applied. Recover an interrupted prepare by matching its request id and intended field values; do not silently skip it. Consume only applied inputs. This is a typed operation record, never a conversation store. It lets a restart recover choices without treating a hint as a durable queue.

Acceptance: grammar table tests, unknown syntax refusal, role refusal, replay, stale version, reset once per entry, predicate edge across restart, duplicate create and human/timer ordering. Include Facts authorization tests; fake roles alone prove nothing.

Real behaviour on test: submit authorized and unauthorized choices to a private neutral contract. Restart between input storage and consumption. Observe one allowed transition. The production decision still uses the bridge.

### 3. Gate activity and decider timeout

Needs decider-gate slice 2 evidence and enforcement. Do not assume that work is already merged. Slice 1 is useful independently.

Scope: new Flow `lib/atlas_flow/activities/gate.ex`, `test/activities/gate_test.exs`; new Gates `lib/atlas_gates/endpoint.ex`, `test/endpoint_test.exs`; Gates `application.ex`; Flow `runs/{run,store}.ex`; new `beam/integration/flow_gate.exs`. Extend gate evidence/request/record modules from decider-gate slice 2. Change `flow/contract/lib/{decision,gates}.ex` and their tests. Regenerate targets, decision diagram and assembled YAML. Apply decider-gate slice 3's foundation schema/metadata, bindings, assembly and exact-expectation changes. Extend `flow/generator/lib/{schema,rela}.ex` and their tests for gate limits.

Use a versioned Bus request/reply. Do not call Gates from Flow. Freeze evidence and record before applying `gate_result`. Replace the status bridge with deciding/for-person/for-agent states and trusted verdict choices. Resolve `{:gate_limit, gate}` from the environment's `answer_within` once per entry. Generate a concrete duration into each environment's pair; hash that pair. Test and production get separate pairs. Do not patch YAML at runtime.

Acceptance: adapter tests cover id/fingerprint fencing and refusals. Endpoint tests prove one recorded verdict after reply loss. A manual-clock integration proves person → deadline → re-ask with `timed_out` → `agent_unverified`, with `follows`. Prove `person_always` has no timer. Restart neither resets nor duplicates timeout. Complete decider-gate slice 3's red-flag, confirm, overrule and frozen-rule tests.

Real behaviour on test: with a five-minute limit, advance the clock. Show the second verdict, agent acceptance and red flags on the decision and based-on work. Confirmation clears them. A principle still waits. This is the first slice claiming the product timeout works.

### 4. Pass activity

Scope: new Flow `lib/atlas_flow/activities/pass.ex`, `test/activities/pass_test.exs`; `runs/{run,store}.ex`; new Runtime `lib/atlas_runtime/flow_passes.ex`, `test/flow_passes_test.exs`; Runtime `application.ex`; new `beam/integration/flow_pass.exs`.

Route to the current owner's Runtime. Freeze assignment, mode, permissions, vendor constraints and packet/fingerprint before dispatch. Persist pass and execution references. An offline Runtime waits; it never sends work to another owner's machine. Reuse identity on restart. Fence returned evidence. Runtime accepts or looks up the same request without starting another execution. Require packet/freeze/review contracts before enabling definitions that need them.

Acceptance: adapter tests cover routing, offline operation, duplicates, late execution, owner changes, restart and packet mismatch. Runtime tests prove one execution. Use the manual clock for retries.

Real behaviour on test: a private neutral contract starts one pass on its owner's test Runtime. Disconnect, reconnect and restart Flow. Show one execution and one outcome. Do not migrate more production subflows yet.

### 5. Effect activity

Scope: new Flow `lib/atlas_flow/activities/effect.ex`, `test/activities/effect_test.exs`; `runs/{run,store}.ex`; new `beam/integration/flow_effect.exs`. No speculative Code service files in this repository.

Implement the effect request, lookup and idempotency contract from section 3. Map declared outputs and `records` into replayable Facts writes. Integration requires the approved fingerprint. Enable create/update/integrate adapters only after their receiver passes the contract. A mock does not prove Code idempotency. Code update support is an external prerequisite, not hidden work in this assignment.

Acceptance: adapter tests cover lost response, repeated id, changed payload, stale fingerprint, partial record writes, refusal and unknown remote outcome. Require receiver contract tests before enabling each real adapter.

Real behaviour on test: lose a test receiver response and restart Flow. Lookup returns one operation and its original result. Until real Code support exists, show the private neutral receiver and mark Code migration blocked. Do not claim a safe remote PR creation from a stub.

### 6. Composition

Scope: `flow/generator/lib/{atlas,runtime}.ex`, `lib/mix/tasks/atlas.flow.gen.ex`, `test/{atlas,runtime}_test.exs`, task tests and golden JSON; `flow/contract/test/golden_test.exs`; generated JSON. New Flow `lib/atlas_flow/composition/{links,counts}.ex`, `test/composition/{links,counts}_test.exs`; `runs/{run,store}.ex`; new `beam/integration/flow_composition.exs`.

Emit and expose composition as versioned data. Implement links, stale-child rejection and counts. Use explicit current-child identity and revision/fingerprint, never wall-clock recency. Refuse ambiguous selection. Recompute counts after deletion, reparenting or missed hints. Parent writes use durable pending intents. Changed aggregates supply synthetic atlas-flow inputs. Two subflows on one subject keep separate cursors and starts.

Acceptance: pure link/count tests and fake Facts recovery tests cover replaced child, late result, duplicate completion, removed/reparented child, empty aggregate, two subflows and restart between child completion and parent write.

Real behaviour on test: a private child completes and advances its parent once. A replaced child completes late and changes nothing. Restart and rebuild counts. Production selection remains unchanged.

### 7. Migrate review and test

Scope: selection/import mappings in `rela/flow-runtime.json`; `flow/contract/lib/{pr_review,pr_test}.ex` only for parity fixes, their goldens and regenerated targets; new `e2e/test/flow_review_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select `pr_review` and `pr_test`. Import open and historical subjects through an explicit old-facts-to-entry table. Preserve owners and completed outcomes. Do not rerun historical activities. Keep legacy definitions but exclude selected subjects. Needs slices 2–6 and real pass/gate prerequisites.

Acceptance: every import row, two-writer refusal, stale replies, restart while waiting. Contract tests own domain mappings.

Real behaviour on test: complete review and test on one exact revision. Restart while waiting. Replace one child and show the older result is ignored.

### 8. Migrate the pull-request subflow

Scope: `rela/flow-runtime.json`; `flow/contract/lib/pull_request.ex`, its golden and regenerated targets only for parity fixes; new `e2e/test/flow_delivery_test.exs`; neutral import fixtures as in slice 7.

Select `pull_request`. Import without triggering integration. Activate effects only after real receiver tests pass. Preserve approved fingerprint fencing and linked outcomes.

Acceptance: import rows, review/test conjunction, refusal on changed revision, restart after remote success before acknowledgement.

Real behaviour on test: an approved, tested revision integrates once. A changed head is refused until new evidence arrives.

### 9. Migrate the issue subflow

Scope: `rela/flow-runtime.json`; `flow/contract/lib/issue.ex`, its golden and regenerated targets only for parity fixes; extend `e2e/test/flow_delivery_test.exs`; neutral import fixtures.

Select `issue`. Carry open private work, packet identity, review rounds and existing remote artifacts into explicit states. Rework updates the existing artifact. Needs the real update receiver contract.

Acceptance: each import row, failed/offline pass, changed packet invalidates advice, round limit, recovery between ready decision and create/update.

Real behaviour on test: author, review, rework and create. A later requested change updates the same artifact once. Restart at the effect boundary.

### 10. Migrate design and acceptance

Scope: `rela/flow-runtime.json`; `flow/contract/lib/use_case.ex`, its golden and regenerated targets only for parity fixes; new `e2e/test/flow_acceptance_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select only `design_and_accept`. Preserve current design work, ownership and prior acceptance. Do not manufacture passes for completed subjects. Use disjoint phase admission: the generated design phase owns presentation before design acceptance; the legacy building phase owns it afterwards. Test the handoff before enabling selection.

Acceptance: every import row, review refusal, acceptance/rejection and restart before the accepted output is acknowledged.

Real behaviour on test: design, review and accept once. Restart at acceptance. The following build flow still uses the legacy engine.

### 11. Migrate building and testing use cases

Scope: the same files as slice 10, with `test_and_accept_use_case` selection and import rows. Extend its e2e file rather than adding a test suite.

Start from accepted design exactly once. Import existing build/test work. Preserve child counts and acceptance. Do not share a cursor with the design run.

Acceptance: import rows, two subflows on one subject, predicate-start recovery, count changes and reopening through a new generation.

Real behaviour on test: accept a design, build children, then test and accept the aggregate. Restart between acceptance of the design and creation of the build run. Show one build run.

### 12. Migrate scenes

Scope: `rela/flow-runtime.json`; `flow/contract/lib/scene.ex`, its golden and regenerated targets only for parity fixes; extend `e2e/test/flow_acceptance_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select `test_and_accept_scene`. Preserve owners, child counts and completed history. Apply the declared reopening policy.

Acceptance: import rows, empty/nonempty aggregates, child reopened after parent completion, and restart in acceptance.

Real behaviour on test: build, test and accept the scene. Add open work and show the agreed new-generation policy. All eight generated subflows are now selected.

### 13. Move readers to run presentation

Scope: new Flow `lib/atlas_flow/runs/presentation.ex` and `test/runs/presentation_test.exs`; Flow `item.ex`; Facts `subflows.ex`, `server.ex`, `test/{subflows,description_read}_test.exs`; Runtime `lib/atlas_runtime/execution/engine.ex`, `lib/atlas_runtime/interactions/guidance.ex`, `test/{atlas_runtime,guidance_inbox}_test.exs`; Control `lib/atlas_control/{pages,workers,turns}.ex`, `test/{pages,worker_pages,turns}_test.exs`.

Serve a run-derived owner/presentation view through Facts. Preserve expected work, todo, state, owner and deferred handover. Move consumers to this view while old definitions still exist. No platform layer calls another directly.

The readers to replace are evidenced at Runtime `beam/apps/atlas_runtime/lib/atlas_runtime/execution/engine.ex:210` and `beam/apps/atlas_runtime/lib/atlas_runtime/interactions/guidance.ex:260`; Control `beam/apps/atlas_control/lib/atlas_control/workers.ex:342-356`, `beam/apps/atlas_control/lib/atlas_control/turns.ex:54`, and `beam/apps/atlas_control/lib/atlas_control/pages.ex:705,805,1918,1972-1988`.

Acceptance: lowest-level projection and reader tests for active/final runs, manual owner, deferred handover and no stale actionable inbox item. Boundary checks still pass.

Real behaviour on test: pages, worker routing and guidance keep working with all eight generated flows selected. A completed run does not launch another worker. The temporary accepted-decision follow-through still appears.

### 14. Remove the old flows

Scope: remove legacy `flows` from `rela/compositions/atlas-eyra/atlas.json`, `rela/tests/fixtures/baseline-atlas.json` and reassembled `rela/atlas.json`/manifest. Remove Flow `lib/atlas_flow/{definition,item}.ex`; projection now lives in `runs/presentation.ex`. Simplify `engine.ex`; retire `test/{atlas_flow,engine}_test.exs` legacy cases. Remove Facts' runtime legacy-check call from `server.ex`. Retain Facts `flows.ex` as a pure build-time validator and adjust `test/flows_test.exs`'s exact expectations; the unchanged assembler invokes that file directly (`rela/scripts/assemble.py:416-424`). It does not execute flows. Update fixture expectations and `e2e/test/{composition,rela_description,flow_run}_test.exs`. If follow-through is retained, add `flow/contract/lib/decision_follow_through.ex`, register it in `software.ex`, add its contract test/golden, selection in `rela/flow-runtime.json`, and regenerate targets.

First enumerate every reader of `flows`, `flow_problems`, `state_field`, `todo`, `expected` and `handover`. Supply needed owner/presentation views from runs. If retained by the product owner, put accepted-decision follow-through in a separately named contract subflow, with its golden, targets, selection and exact expectations. Remove the temporary projection only after replacement or explicit retirement.

Acceptance: no executable legacy definition or fallback remains. A contract change changes runtime behaviour through generation alone. Lowest-level projection tests preserve manual ownership and deferred handover. Test hash refusal, definition drift refusal, full restart and inventories. Run boundary checks, generation checks and Rela validation.

Real behaviour on test: repeat decision, review, test, delivery and acceptance proofs after deletion. Restart mid-wait and mid-effect. Show stable run ids, deadlines and one remote effect. No old Item process exists.

## 5. Risks, dependencies and product questions

Technical choices are settled above. Durable cursors, one writer, versioned writes, stable request ids, explicit imports and a manual clock make recovery testable without inventing cross-service transactions. Structure code under runs, activities and composition. Domain mappings belong in contracts, not platform code or tests. Do not weaken the boundary guard.

Main risks are dual writers, incomplete imports, changed definitions and remote success with a lost reply. Each has a refusal or recovery test above. Retain run history initially; measured archival is separate work. Outages and clock corrections can delay processing. UTC deadlines are not a promise of action at an exact instant. Recheck current evidence before a late fallback.

The supplied previous orchestration design describes passes, gates, evidence, fingerprints, effects, routing and linked flows, but contains no numbered slices 3–8. These assignments map those mechanisms onto current code. They supersede its suggestion that Rela will eventually execute flows. They do not invent missing historical assignments. Packet/freeze/review support, decider-gate slice 2, Jev advice and Code's idempotent update API are explicit prerequisites. Stubs prove Flow contracts, not those services.

Only these questions need a product owner:

1. Should an accepted decision remain owned until work is based on it or `no_work` is set? Old Flow does this; generated `decide` does not (evidence in section 1). Preserve it during migration. Resolve before slice 14 through a follow-through subflow or explicit retirement.
2. Should reopened completed work start a new generation automatically or only by explicit request? Default to explicit restart until each contract declares its policy. Resolve before slices 11–12 enable aggregate reopening.

Do not reopen timeout values or fixed-rule policy here. Use the decider-gate design's environment limits and no timeout for `person_always`. Slice 1 changes no product action merely to demonstrate the clock.

## Verification and delivery

Start with pure transition, parser, projection and adapter tests. Add a narrow Facts/Rela proof for persistence and authorization. Integrate only to prove a service boundary. No real-timer waits. Own servers inside tests/scripts and stop them on exit, including failure paths. Leave no rela-server, Facts or Control running.

Run affected checks normally, then with `TMPDIR` reached through a new symlink into private scratch. Compare canonical paths. Remove link, scratch data and build output. Keep `tmp/`, `_build` and `erl_crash.dump` out of delivered changes. Do not edit supplied inputs or tools. Add no Python.

This author assignment changes only this document. Check source references, slice order, scope and artifact cleanliness. Product tests and environment proofs above are Developer acceptance, not evidence of implemented behaviour.
