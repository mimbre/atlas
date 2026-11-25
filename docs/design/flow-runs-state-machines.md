# Flow runs the generated state machines

Author design. No product code changes. Paths are relative to `atlas/`.

Flow runs the machines. Rela defines and checks them. There is no planned switch to a Rela runner.

## 1. Behaviour before the migration

The legacy Flow this design started from. Slice 14 removed it: `item.ex` and `definition.ex` no longer exist, and the line references below are to the code before that. Flow now keeps no process per fact (`AtlasFlow.Engine`).

| Behaviour then | File:line evidence |
| --- | --- |
| Facts merges Rela's schema with the extra description on each read. It adds generated subflows and checks the old flows. | `platform/atlas_facts/lib/atlas_facts/server.ex:353-365` |
| Flow reads `_description` through Facts. Executable definitions come from `description.flows`, excluding `flow_problems`. This is the old extra-description format. | `platform/atlas_flow/lib/atlas_flow/engine.ex:109-143`; `platform/atlas_flow/lib/atlas_flow/definition.ex:43-56`; `products/software_factory/model/targets/rela/atlas.json:898` |
| A round lists each subject kind. An open fact gets one registered Item process. A missing process is recreated. | `platform/atlas_flow/lib/atlas_flow/engine.ex:125-130,218-246`; `platform/atlas_flow/lib/atlas_flow/item.ex:22-25` |
| State is the first matching predicate. It is recomputed from the subject and related facts. It is not a durable machine cursor. `next` is checked for reachability, not executed as a transition. | `platform/atlas_flow/lib/atlas_flow/definition.ex:93-143`; `platform/atlas_flow/lib/atlas_flow/item.ex:74-90`; `platform/atlas_facts/lib/atlas_facts/flows.ex:210-232,262-281` |
| Hints wake subjects and ancestors. Deletes and new owners wake all items. The ancestor walk stops at depth eight. Flow skips its own writes. Polling recovers lost hints. | `platform/atlas_flow/lib/atlas_flow/engine.ex:26-27,56-82,150-208` |
| Item uses real process timers, including a 50 ms debounce. `every_seconds` changes polling frequency. These are not state deadlines. | `platform/atlas_flow/lib/atlas_flow/item.ex:19-20,49-67,85-90`; `platform/atlas_flow/lib/atlas_flow/definition.ex:186-191` |
| Flow writes expected work, presentation state and owner through Facts over the Bus. It can write on a related assignment. Writes include cause and previous values. | `platform/atlas_flow/lib/atlas_flow/item.ex:103-131,133-212`; `platform/atlas_flow/lib/atlas_flow/talk.ex:13-46` |
| Manual ownership stays until work changes. Handover can wait for an active turn. Missing owners and unavailable Facts cause retries. | `platform/atlas_flow/lib/atlas_flow/item.ex:142-186,230-281` |
| Presentation state is cleared on completion. Restart reads facts again; there is no explicit run to restore in Item. | `platform/atlas_flow/lib/atlas_flow/item.ex:74-101,290-295`; `platform/atlas_flow/lib/atlas_flow/application.ex:15-22` |
| Talk retries with the same envelope id within one call. Facts records answers by id. This alone cannot make an external effect execute once across Flow restarts. | `platform/atlas_flow/lib/atlas_flow/talk.ex:30-46`; `platform/atlas_facts/lib/atlas_facts/server.ex:272-281`; `platform/atlas_facts/lib/atlas_facts/ledger.ex:3-7,19-23` |
| Facts supports optimistic writes. A conflicting version can succeed if changed fields still match `was`. | `platform/atlas_facts/lib/atlas_facts/server.ex:944-967` |
| Facts already embeds the generated target for owners and presentation. Flow currently depends only on Bus. | `platform/atlas_facts/lib/atlas_facts/subflows.ex:3-21`; `platform/atlas_flow/mix.exs:26-27` |
| Cross-layer calls and domain names in platform sources and tests are guarded. | `platform/atlas_bus/test/boundary_test.exs:17-33,45-59,109-155` |

Two differences affect cutover. Generated `decide` has three states, verdict branches and status outputs, but no timer (`products/software_factory/model/contract/lib/decision.ex:16-61`). Old `decide` also keeps accepted decisions open until work is based on them, or `no_work` is true (`products/software_factory/model/targets/rela/atlas.json:1239-1332`). Preserve this follow-through during migration.

The composition lists seven modules; UseCase supplies two subflows, making eight. It links outcomes and counts children (`products/software_factory/model/contract/lib/software.ex:20-51`; `products/software_factory/model/contract/lib/use_case.ex:19-29`).

## 2. Make the generated target executable

Today format 1 holds gates, subject, owner, channel, initial state, labels, final markers, presentation, and mechanism kind/spec. Gate data includes `answer_within`. Evidence: `products/software_factory/model/generator/lib/atlas.ex:35-94`; the concrete decision entry is `products/software_factory/model/targets/atlas/flows.json:4-36`.

It omits start triggers, `run_as`, `per_subject`, state status, waiting roles, awaited fields, ordered branches, entry sets, creates and timers. It also omits composition links and counts. The DSL already builds that data; the JSON writer discards it. Evidence: `products/software_factory/model/generator/lib/schema.ex:789-812,865-880,941-977`; `products/software_factory/model/generator/lib/rela.ex:43-122`; `products/software_factory/model/generator/lib/mix/tasks/model.gen.ex:54-82`. Activities are described, not dispatched, by this writer (`products/software_factory/model/generator/lib/atlas.ex:83-94`).

Extend the Atlas writer, not a runtime YAML reader. Emit format 2. Preserve branch and timer order. Emit the missing fields with explicit empty lists. Keep owner, presentation and mechanism data. Omit source line metadata. Add composition data in its own slice. Regenerate targets. Keep Rela YAML bytes stable unless the contract changes.

The core runs the compiled model (`products/software_factory/mix.exs`): no component reads `flows.json` or `flows.yaml` at runtime, and no hash binds them to the running flows. Update reader and writer together. Rebuild all target consumers together.

Flow runs the compiled model's subflows. Never fall back to legacy execution for a migrated subject. Explicitly unmigrated subjects may continue. Rela validates the flows when a build generates the model's targets with the pinned rela (`bin/generate`); generated output is neither kept in git nor compared.

## 3. Run and recovery model

The rest of this section defines new behaviour.

Use one run per `(subflow, subject kind, subject key, generation)`. `per_subject: one` permits one active generation per subflow and subject. Different subflows may run on one subject. Registry keys include subflow and generation. Finality is durable. A hint cannot reopen a final run. A new explicit start creates another generation. Predicate starts consume a persisted false-to-true edge, not each poll while true.

Add the generic `flow_run` kind to the foundation description:

| Fields | Meaning |
| --- | --- |
| `flow`, `subject_kind`, `subject_key`, `generation` | Stable identity. Use its digest as the fact key. |
| `definition_sha256` | Kept in stored records; Flow neither reads nor writes it. A run is matched to its subflow by `flow` and to its state by name. |
| `state`, `entry`, `entered_at`, `status` | Cursor, increasing entry number, UTC entry time, active/completed/blocked/ended. Self-transition increments entry. A run whose subject does not exist (with or without its delete hint, when Facts refuses its writes because the subject is gone, while it is blocked in a removed state, or when a restart is asked for it) ends (`ended`, `blocked_reason` `subject_removed`), and so does a run of a subflow the model no longer selects (`flow_removed: <flow>`): one versioned write, then the task it holds is cancelled. A round does not read an ended run again and logs nothing for it; a fact made later under the same key gets the next generation, never the ended run. |
| `deadlines` | JSON text: timer name, resolved UTC due time, source entry. |
| `pending` | JSON text: remaining entry writes or activity intents, stable ids and frozen payloads. |
| `input_cursor`, `last_input` | Last consumed Facts position and accepted input or timer identity. |
| `blocked_reason` | Why a run is blocked (safe recovery cannot proceed), or why it ended. |

Version the structured text fields. Do not add timer and outbox kinds yet. The kind/key tuple refers to the subject; no domain-specific run relation or form is needed. Add `flow_runtime` metadata naming the run kind and field mapping. Platform code reads it. Run records are machine-written and hidden from create menus. Facts enforces a description-driven writer rule. A UI flag alone is not authorization.

Define the kind in `products/software_factory/model/targets/rela/modules/foundation/schema.yaml`, metadata in `products/software_factory/model/targets/rela/modules/foundation/atlas.json`, and grants in `products/software_factory/model/targets/rela/acl.yaml`. Bind metadata through `products/software_factory/model/targets/rela/compositions/atlas-eyra/bindings.yaml`. Reassemble `products/software_factory/model/targets/rela/schema.yaml`, `products/software_factory/model/targets/rela/atlas.json`, `products/software_factory/model/targets/rela/atlas.manifest.json` and tracked composition outputs. Update every exact inventory. The foundation list is exact at `products/software_factory/e2e/test/composition_test.exs:125-126`. Include `products/software_factory/e2e/test/rela_description_test.exs`, `platform/atlas_facts/rela/tests/test_{assembly,config}.py`, `platform/atlas_facts/rela/tests/profiles.py`, and `platform/atlas_facts/rela/tests/fixtures/{baseline-schema.yaml,baseline-atlas.json}` where their exact expectations change. Repeat the inventory search whenever a kind, relation, form or flow changes.

The assembler rejects unknown root keys and runtime keys (`platform/atlas_facts/rela/scripts/assemble.py:53-55,391-395`). Keep it unchanged. Store `flow_runtime` mapping, selection and machine-writer rule in a separate description fragment, new `products/software_factory/model/targets/rela/flow-runtime.json`. Facts merges it into its answered description after the assembled extra description. Configure its path in `products/software_factory/config/runtime.exs`; include it in `platform/ops/core.Dockerfile` and `platform/ops/core-run.sh` deployment closure. Validate it in new pure `platform/atlas_facts/lib/atlas_facts/flow_runtime.ex`, tested in `test/flow_runtime_test.exs` and called from Facts `server.ex`. Its keys refer to the assembled schema; invalid mappings refuse execution. This avoids new Python. The sidecar holds runner configuration and import data; executable domain definitions remain in the generated target. Facts verifies the Bus sender as well as the configured writer identity; changing `by` must not impersonate Flow.

Use one writer per run in this release. Claim entry changes with run version and `was`. On conflict, reread. Do not assume a transaction spanning run, subject and service. Persist the next cursor with pending entry writes first. Replay those writes with stable request ids. Clear pending after acknowledgement; the cleared list is stored with the run's next write, and a crash before it replays the writes under their ids. Store one reaction to one input once: transitions taken one after the other in memory are one versioned write, written sooner only before entry writes, an activity request, a consume, or an inputs read once the cursor moved. Consume no further input until entry writes finish. Bootstrap historical terminal subjects before any initial resets. Never turn an accepted subject back into proposed.

Read flow inputs only for an active run whose cursor is durable. Completed, blocked, ended and idle runs take no input; a stale prepared input left on one must not refuse reconciliation. A start or unblock is stored before reading its inputs; entry writes and consumes keep their existing recovery boundaries.

At boot, load incomplete runs and pending writes. Scan selected subjects for missed starts. Restore wakeups from durable UTC deadlines. Process overdue timers immediately. Never restart their intervals. Inject a clock for now, scheduling and cancellation, including new engine rounds and debounce. Production persists UTC and uses monotonic waits. Tests advance a manual clock and drain a synchronous reconcile call. Old polling tests need not be rewritten in slice 1.

A timer has identity `(run key, entry, timer name)`. Its versioned transition consumes it. Duplicate and old-entry wakeups do nothing. Human input stored by the deadline wins; otherwise the timer wins. Break timer ties by declaration order. Reread Facts before committing a timeout. Persist source entry and due time in `last_input`; the next gate request can carry `timed_out: true` and the original wait time. Resolve `since` from its named persisted field. Missing or invalid time blocks; never substitute now.

Branches are ordered. Compile supported expressions to neutral data with a small parser. Never evaluate Elixir. Missing values mean not ready; unknown syntax refuses activation. Grow the supported grammar only when a selected contract needs it. Human choices require typed input with trusted actor and authorization evidence from Facts. A hint, an owner or user-supplied roles cannot supply that evidence.

An activity has identity `(run, entry, activity name)` and a frozen fingerprint. Store its request before sending. Match every reply to identity and fingerprint. Retry the same id. Ignore late replies for old entries or fingerprints. A timeout is not proof that the service did nothing. Enable an effect only when its receiver can return the original result for a repeated id, reject changed payload under that id, and recover a lost answer by lookup. Otherwise block for reconciliation. Facts deduplication alone is insufficient for external effects.

A run continues by name (D-0102). Flow matches a run to its subflow by `flow` and continues it in `state` while that state is a state of the subflow, whatever else about the subflow changed; nothing pins or migrates a definition. A run in a state its subflow does not have is blocked with `blocked_reason` `state_removed: <state>`, its status kept in `pending.definition_block`, once; it is not rewritten on later rounds. A run with `pending.definition_block` whose state is a state of its subflow gets that status back, an empty `blocked_reason`, and continues; so do runs an earlier build blocked with `definition_changed`. Removing or renaming a flow or a state goes through only once no run is in it: a check before the update enforces that.

### One-time retirement of a terminal-refused tally

Fixing admission does not change an immutable Facts answer. A pending write with a
durable refused receipt continues to receive that refusal under its original ID.
Ordinary rounds never replace its ID or automatically retry it as another operation.
Completed-run restart keeps its contract.

Privileged release maintenance may explicitly call
`AtlasFlow.Engine.recover_refused_tally(server, plan)` in the existing sole writer.
This is a local maintenance call, not a Bus command, user action or scheduled retry.
The reviewed plan is a string-keyed map containing exactly `id`, `reason`, and `run`;
`run` is the entire decoded durable cursor, including key, generation, entry,
pending writes and composition. Read and review that snapshot before
constructing the plan. No production plan is shipped or automatically selected.

The implementation admits only an active non-final wait in a state of its subflow, with one
pending own-subject derived tally assignment. Its selection must declare no choices;
its state must have no mechanism or entry outputs; it must have no deadlines, frozen
activities or unconsumed prepared/applied inputs. This first maintenance operation
supports exactly one applicable tally and no composition links or child counts on
the subject. Mixed writes, negative/noninteger tallies, creates/deletes, other kinds,
multi-write outboxes and arbitrary effects are ineligible. Even a successful prefix
plus a refused suffix requires separate reviewed design; it is not retired here.

Facts' `_flow_recovery` read accepts only the existing configured machine sender and
writer. It reads the exact receipt from its own ledger and runs current normal
validation without storage. It also requires the installed field-writer metadata and
an unchanged sole own change, with no expanded component/replacement writes. The
response is authentic Facts evidence, not a permit: the eventual new write still
passes full normal admission. A missing receipt, stored receipt, unavailable read,
still-refused candidate or untrusted sender stops maintenance. The response explicitly
labels ordinary legacy receipts `legacy_unbound`; their about/position tuple does
not attest the complete historical payload. The reviewed frozen run snapshot binds
the obligation being retired without inventing a stronger historical receipt.

After these checks, Store reenters the same safe wait once, preserving run key,
generation, input cursor and last input. Entry increments and entry time
is the recovery time; there are no timers to reset. An audit record in the run's
`pending.migrations` list retains plan ID/digest/reason, old snapshot digest, old
entry/time, new entry, exact receipt and retired writes/synthetic/composition data.
Pass/effect history and earlier audit records remain. Retirement is not recorded as
successful execution.

Composition is recomputed from current related facts and raw subject storage; absent
work is not treated as stored zero. The new entry yields a new count identity through
the existing composition identity function. Before claiming the cursor, a second
Facts read validates the separately named successor candidate against current normal
admission and excludes expanded writes at its newly computed value too. This is a
read of the old receipt and a preflight of the new candidate, never another payload
submitted under the old ID. The versioned cursor, audit and fresh
outbox are committed together through Facts and reread for exact equality **before**
any successor is sent. A conflict does not send. A crash before commit leaves the
original debt; a crash after commit resumes the committed successor ID. Successful
successor receipts retain their original positions across acknowledgement loss and
restart. No ledger row or historical request is deleted, edited or relabelled.

The same plan recognizes its audit and never increments entry again; altered content
under its ID conflicts. It resumes outstanding work only in its committed recovery
entry. Later entries and completed recoveries are returned without another drain.
The Engine then uses normal reconciliation
and projection to update its state before answering the maintenance call. With stepped
rounds this is a fresh round, queued after any round already in progress; target
recovery does not waive settlement of
other subjects. A successor refusal remains a terminal refusal under that successor
ID, with no automatic fresh plan or entry. Refusal in general does not prove zero
effects (Rela can store with warnings), which is why this operation is limited to
recomputed derived assignments and never retries external activities.

The private native acceptance fixture is
`products/software_factory/integration/flow_refused_tally_recovery_native.exs`. It accepts the preserved
raw evidence and pinned historical evaluator as arguments. Only its disposable VM
loads the old evaluator, obtains the actual refusal for the exact frozen request,
then restores current admission on the same disposable ledger. No receipt is seeded
and no different payload is used under that ID. Deployment acceptance and execution
of a reviewed live plan remain separate maintenance work.

## 4. Ordered Developer assignments

Each slice is one assignment. Complete its checks and test-environment proof first. Lists name the allowed files. New files are marked new. Platform tests use neutral nouns. Domain mappings and demonstrations belong in contract tests or `products/software_factory/e2e/`. Use manual clocks, acknowledgements and monitors. Do not wait on real timers.

Migration selection maps a generated subflow to its legacy execution and projection scope. Do not assume old and new names match. Admission conditions and the import state table are data in `products/software_factory/model/targets/rela/flow-runtime.json`. At most one runner owns a subject's assignment projection at a time. Reject overlapping admission. A completed generated phase releases projection to its next phase; it does not disable every legacy phase on that subject kind. Test this with neutral two-phase fixtures before migrating a shared subject.

### 1. One small machine beside the existing engine

Run only `decide`. This is a compatibility bridge, not the general runner.

Scope:

- `products/software_factory/model/generator/lib/{atlas,runtime}.ex`, `products/software_factory/model/generator/test/{atlas,runtime}_test.exs`, `products/software_factory/model/generator/test/golden/example.flows.json`: format 2 and reader rejection tests.
- `products/software_factory/model/contract/lib/decision.ex`, `products/software_factory/model/contract/test/decider_test.exs`, `products/software_factory/model/contract/test/golden/decision.flows.yaml`; regenerate `products/software_factory/model/targets/atlas/flows.json`, `products/software_factory/model/targets/rela/flows.yaml`, `products/software_factory/model/targets/diagrams/decide.md`, `products/software_factory/model/targets/rela/flows.yaml`.
- In `platform/atlas_flow/`: `mix.exs`, `lib/atlas_flow/{engine,definition,item,application,talk}.ex`; new `lib/atlas_flow/generated.ex` and `lib/atlas_flow/runs/{run,store,clock}.ex`; new `test/runs/run_test.exs`, `test/support/manual_clock.ex`; extend `test/support/fake_facts.ex` and `test/engine_test.exs`. `products/software_factory/config/runtime.exs` supplies the selected deployment YAML path.
- Foundation schema, metadata, grants, bindings, generated assembly outputs and exact inventories listed in section 3. Facts `lib/atlas_facts/guards.ex` and `test/guards_test.exs` only for the generic machine-writer rule; the new mapping validator and its caller/tests named in section 3. New `products/software_factory/e2e/test/flow_run_test.exs` for real persistence.

Execute only create start, initial/final states, ordered field-equality branches, entry sets and fixed-duration state timers. No role parser, creates, predicate starts, activities or composition. Carry all executable fields in JSON, but refuse unsupported features in any selected definition before writing. Select `decide` through description metadata, never a domain-kind conditional in Flow.

For this bridge, change the decision contract to observe already-authorized `status` with ordered equality branches: accepted or rejected leads to its matching final state. Remove the unconsumed verdict/role branches temporarily. Do not reset status or write it on final entry. Test entry sets on the neutral fixture instead. Today's Facts authority remains in force (`products/software_factory/model/targets/rela/atlas.json:354-405`; `platform/atlas_facts/lib/atlas_facts/guards.ex:64-79`). Slice 3 replaces this bridge with typed verdict input. Import historical accepted/rejected subjects directly to final. Record superseded subjects as completed historical imports without rewriting their status.

This is a generated transition machine with a durable cursor. It does not infer the cursor from presentation. Remove selected subjects from legacy execution. Reuse old predicates only for post-acceptance follow-through presentation. One projection writer owns the assignment; no second Item writes it. A final run can retain a follow-through owner without reopening. In `for_person` and `for_person_always`, the state's own owner (`preserve_kind: :person`) keeps an assignee that names a person and otherwise assigns the state default `person/melle` in both environments, even over an agent set by hand. Reproject this owner after a presentation-only migration (`preserve_entry`), including when the expected text has not changed. A running agent turn still defers the handover until it ends. Agent states and accepted/rejected follow-through retain the existing owner rules. Reuse existing manual-owner and deferred-handover logic. Do not delete the legacy definition yet.

Add the generator as a path dependency, as Facts does; it is not another platform app. Supply the deployed YAML path in startup options. Keep run code under `runs/`. Do not extract a general framework.

Acceptance: pure ordered-equality, finality and import tests. Store tests cover restart in a waiting entry, lost entry-write acknowledgement, duplicate create, duplicate timeout and cancelled old-entry timeout. Advance to just before and exactly at a deadline. Restart Flow while preserving fake Facts; advance beyond the original due time. Hash refusal must cause zero writes. Mixed-engine tests prove one selected writer and continued legacy operation for another neutral subject. Guard tests reject client run writes. Run boundary and exact inventory checks.

Real behaviour on test: create a proposed decision and read its run. Accept through today's authorized command. Restart Flow and read the same completed run. Show an unselected subject still advances. In a private test deployment only, generate a decision variant with a five-minute proposed-to-proposed timer. Advance the injected clock and restart on both sides of the deadline. Show exactly one new entry from the original due time. Restore the normal generated pair. No production deadline is invented: today's `decide` has none (`products/software_factory/model/contract/lib/decision.ex:16-61`).

Size boundary: three states, equality only, one run kind, one pending record and one timer seam. No Gates adapter or general expression interpreter. This delivers the durable timer kernel needed by decider-gate slice 3 without taking on its product behaviour.

### 2. Transition kernel and trusted inputs

Scope: new Flow `lib/atlas_flow/runs/{conditions,inputs}.ex`, `test/runs/{conditions,inputs}_test.exs`; `runs/{run,store}.ex`, `talk.ex`. New Facts `lib/atlas_facts/flow_inputs.ex`, `test/flow_inputs_test.exs`; Facts `server.ex`. Extend `products/software_factory/model/generator/test/atlas_test.exs` and `products/software_factory/model/contract/test/decider_test.exs`. Keep production selection unchanged.

Support only expressions used by the contracts: equality, inequality, numeric comparisons, conjunction, disjunction and parentheses. Pin precedence in tests. Add predicate edges, resets, `since`, and creates with stable keys per entry/output index. Facts exposes typed inputs with subject version, actor roles, changed fields and position, validated against selected ACL and role relations. Never accept client-supplied roles. Separate snapshot-driven auto branches from authenticated choices.

Persist typed inputs through Facts as a new generic foundation `flow_input` kind. Scope also includes the same schema, description, grants, bindings and exact-inventory files listed in section 3. Fields: `request_id`, run identity, source subject version, actor, validated roles, changed fields, payload digest, prepared/applied/consumed status and stored position. Prepare before the subject write, then mark applied. Recover an interrupted prepare by matching its request id and intended field values; do not silently skip it. Consume only applied inputs. This is a typed operation record, never a conversation store. It lets a restart recover choices without treating a hint as a durable queue.

Acceptance: grammar table tests, unknown syntax refusal, role refusal, replay, stale version, reset once per entry, predicate edge across restart, duplicate create and human/timer ordering. Include Facts authorization tests; fake roles alone prove nothing.

Real behaviour on test: submit authorized and unauthorized choices to a private neutral contract. Restart between input storage and consumption. Observe one allowed transition. The production decision still uses the bridge.

### 3. Gate activity and decider timeout

Needs decider-gate slice 2 evidence and enforcement. Do not assume that work is already merged. Slice 1 is useful independently.

Scope: new Flow `lib/atlas_flow/activities/gate.ex`, `test/activities/gate_test.exs`; new Gates `lib/atlas_gates/endpoint.ex`, `test/endpoint_test.exs`; Gates `application.ex`; Flow `runs/{run,store}.ex`; new `products/software_factory/integration/flow_gate.exs`. Extend gate evidence/request/record modules from decider-gate slice 2. Change `products/software_factory/model/contract/lib/{decision,gates}.ex` and their tests. Regenerate targets, decision diagram and assembled YAML. Apply decider-gate slice 3's foundation schema/metadata, bindings, assembly and exact-expectation changes. Extend `products/software_factory/model/generator/lib/{schema,rela}.ex` and their tests for gate limits.

Use a versioned Bus request/reply. Do not call Gates from Flow. Freeze evidence and record before applying `gate_result`. Replace the status bridge with deciding/for-person/for-agent states and trusted verdict choices. Resolve `{:gate_limit, gate}` from the environment's `answer_within` once per entry. Generate a concrete duration into each environment's pair; hash that pair. Test and production get separate pairs. Do not patch YAML at runtime.

Acceptance: adapter tests cover id/fingerprint fencing and refusals. Endpoint tests prove one recorded verdict after reply loss. A manual-clock integration proves person → deadline → re-ask with `timed_out` → `agent_unverified`, with `follows`. Prove `person_always` has no timer. Restart neither resets nor duplicates timeout. Complete decider-gate slice 3's red-flag, confirm, overrule and frozen-rule tests.

Real behaviour on test: with a five-minute limit, advance the clock. Show the second verdict, agent acceptance and red flags on the decision and based-on work. Confirmation clears them. A principle still waits. This is the first slice claiming the product timeout works.

### 4. Pass activity

Scope: new Flow `lib/atlas_flow/activities/pass.ex`, `test/activities/pass_test.exs`; `runs/{run,store}.ex`; new Runtime `lib/atlas_runtime/flow_passes.ex`, `test/flow_passes_test.exs`; Runtime `application.ex`; new `products/software_factory/integration/flow_pass.exs`.

Route to the current owner's Runtime. Freeze assignment, mode, permissions, vendor constraints and packet/fingerprint before dispatch. Persist pass and execution references. An offline Runtime waits; it never sends work to another owner's machine. Reuse identity on restart. Fence returned evidence. Runtime accepts or looks up the same request without starting another execution. Require packet/freeze/review contracts before enabling definitions that need them.

Acceptance: adapter tests cover routing, offline operation, duplicates, late execution, owner changes, restart and packet mismatch. Runtime tests prove one execution. Use the manual clock for retries.

Real behaviour on test: a private neutral contract starts one pass on its owner's test Runtime. Disconnect, reconnect and restart Flow. Show one execution and one outcome. Do not migrate more production subflows yet.

Shared passes (added with the review pass). A pass with `with_person: true` and `writes: none` does not own its state: the state's choices, branches and timers go on beside it, and any of them that moves the run leaves the pass. An owner whose routing field names no machine answers by hand and nothing is frozen. Its optional `answer` maps a completed outcome to a subject field, a relation naming the owner and a role, taken as that role's choice. An outcome it does not map (`uncertain`, `failed`) and a reply Runtime marks for reconciliation answer nothing. The result is kept with the pass, the run stays active for the answer by hand and its timers, and the same binding is not asked again.

Packet binding. A `review-packet` pass takes its folder and packet from subject fields named by `packet_from` (`cwd`, `packet_id`, `fingerprint`, `revision`), each in the pass fingerprint. Runtime refuses a packet whose recorded identity or revision (`snapshot freeze --revision`) differs.

Backend selection. A pass requires an explicit `backend` allowed by its `vendors`; Flow freezes it before dispatch and Runtime forwards it unchanged. A missing backend is an invalid pass, not a request to use the receiving machine's preferences. Ordinary Service starts without a backend still follow their existing local selection policy.

Leaving a pass. A shared pass whose binding changes (owner, machine, assignment or subject fingerprint) is left, also after a no-answer result. So is one whose state is moved by a choice, branch or timer. The left pass is appended to `pending.passes` with `left: true`, its execution and its result if any, so a late reply of it is never taken. A new binding then freezes a new request. A non-shared pass whose binding changes still blocks for reconciliation.

Request id. The id is the digest of the complete frozen request before its id is added: run key, entry, pass name, subject key, owner key, machine and routing field, assignment, fingerprint definition and value, and bound execution request. One binding is one request across restarts, and another binding is another request. Intents frozen before this change keep their stored id; neither replay nor replacement rewrites journal identities.

### 5. Effect activity

Scope: new Flow `lib/atlas_flow/activities/effect.ex`, `test/activities/effect_test.exs`; `runs/{run,store}.ex`; new `products/software_factory/integration/flow_effect.exs`. No speculative Code service files in this repository.

Implement the effect request, lookup and idempotency contract from section 3. Map declared outputs and `records` into replayable Facts writes. Integration requires the approved fingerprint. Enable create/update/integrate adapters only after their receiver passes the contract. A mock does not prove Code idempotency. Code update support is an external prerequisite, not hidden work in this assignment.

Acceptance: adapter tests cover lost response, repeated id, changed payload, stale fingerprint, partial record writes, refusal and unknown remote outcome. Require receiver contract tests before enabling each real adapter.

Real behaviour on test: lose a test receiver response and restart Flow. Lookup returns one operation and its original result. Until real Code support exists, show the private neutral receiver and mark Code migration blocked. Do not claim a safe remote PR creation from a stub.

### 6. Composition

Scope: `products/software_factory/model/generator/lib/{atlas,runtime}.ex`, `lib/mix/tasks/model.gen.ex`, `test/{atlas,runtime}_test.exs`, task tests and golden JSON; `products/software_factory/model/contract/test/golden_test.exs`; generated JSON. New Flow `lib/atlas_flow/composition/{links,counts}.ex`, `test/composition/{links,counts}_test.exs`; `runs/{run,store}.ex`; new `products/software_factory/integration/flow_composition.exs`.

Emit and expose composition as versioned data. Implement links, stale-child rejection and counts. Use explicit current-child identity and revision/fingerprint, never wall-clock recency. Refuse ambiguous selection. Recompute counts after deletion, reparenting or missed hints. Parent writes use durable pending intents. Changed aggregates supply synthetic atlas-flow inputs. Two subflows on one subject keep separate cursors and starts.

Acceptance: pure link/count tests and fake Facts recovery tests cover replaced child, late result, duplicate completion, removed/reparented child, empty aggregate, two subflows and restart between child completion and parent write.

Real behaviour on test: a private child completes and advances its parent once. A replaced child completes late and changes nothing. Restart and rebuild counts. Production selection remains unchanged.

### 7. Migrate review and test

Scope: selection/import mappings in `products/software_factory/model/targets/rela/flow-runtime.json`; `products/software_factory/model/contract/lib/{pr_review,pr_test}.ex` only for parity fixes, their goldens and regenerated targets; new `products/software_factory/e2e/test/flow_review_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select `pr_review` and `pr_test`. Import open and historical subjects through an explicit old-facts-to-entry table. Preserve owners and completed outcomes. Do not rerun historical activities. Keep legacy definitions but exclude selected subjects. Needs slices 2–6 and real pass/gate prerequisites.

Acceptance: every import row, two-writer refusal, stale replies, restart while waiting. Contract tests own domain mappings.

Real behaviour on test: complete review and test on one exact revision. Restart while waiting. Replace one child and show the older result is ignored.

### 8. Migrate the pull-request subflow

Scope: `products/software_factory/model/targets/rela/flow-runtime.json`; `products/software_factory/model/contract/lib/pull_request.ex`, its golden and regenerated targets only for parity fixes; new `products/software_factory/e2e/test/flow_delivery_test.exs`; neutral import fixtures as in slice 7.

Select `pull_request`. Import without triggering integration. Activate effects only after real receiver tests pass. Preserve approved fingerprint fencing and linked outcomes.

Acceptance: import rows, review/test conjunction, refusal on changed revision, restart after remote success before acknowledgement.

Real behaviour on test: an approved, tested revision integrates once. A changed head is refused until new evidence arrives.

### 9. Migrate the issue subflow

Scope: `products/software_factory/model/targets/rela/flow-runtime.json`; `products/software_factory/model/contract/lib/issue.ex`, its golden and regenerated targets only for parity fixes; extend `products/software_factory/e2e/test/flow_delivery_test.exs`; neutral import fixtures.

Select `issue`. Carry open private work, packet identity, review rounds and existing remote artifacts into explicit states. Rework updates the existing artifact. Needs the real update receiver contract.

Acceptance: each import row, failed/offline pass, changed packet invalidates advice, round limit, recovery between ready decision and create/update.

Real behaviour on test: author, review, rework and create. A later requested change updates the same artifact once. Restart at the effect boundary.

### 10. Migrate design and acceptance

Superseded: `design_and_accept` was removed (#479) and the use case's `design_status` with it. A use case is design (D-0099): Design (Scene → Use cases) makes it designed.

Scope: `products/software_factory/model/targets/rela/flow-runtime.json`; `products/software_factory/model/contract/lib/use_case.ex`, its golden and regenerated targets only for parity fixes; new `products/software_factory/e2e/test/flow_acceptance_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select only `design_and_accept`. Preserve current design work, ownership and prior acceptance. Do not manufacture passes for completed subjects. Use disjoint phase admission: the generated design phase owns presentation before design acceptance; the legacy building phase owns it afterwards. Test the handoff before enabling selection.

Acceptance: every import row, review refusal, acceptance/rejection and restart before the accepted output is acknowledged.

Real behaviour on test: design, review and accept once. Restart at acceptance. The following build flow still uses the legacy engine.

### 11. Migrate building and testing use cases

Scope: the same files as slice 10, with `test_and_accept_use_case` selection and import rows. Extend its e2e file rather than adding a test suite.

Start from accepted design exactly once. Import existing build/test work. Preserve child counts and acceptance. Do not share a cursor with the design run.

Acceptance: import rows, two subflows on one subject, predicate-start recovery, count changes and reopening through a new generation.

Real behaviour on test: accept a design, build children, then test and accept the aggregate. Restart between acceptance of the design and creation of the build run. Show one build run.

### 12. Migrate scenes

Scope: `products/software_factory/model/targets/rela/flow-runtime.json`; `products/software_factory/model/contract/lib/scene.ex`, its golden and regenerated targets only for parity fixes; extend `products/software_factory/e2e/test/flow_acceptance_test.exs`; neutral import fixtures in Flow `test/runs/run_test.exs`.

Select `test_and_accept_scene`. Preserve owners, child counts and completed history. Apply the declared reopening policy.

Acceptance: import rows, empty/nonempty aggregates, child reopened after parent completion, and restart in acceptance.

Real behaviour on test: build, test and accept the scene. Add open work and show the agreed new-generation policy. All eight generated subflows are now selected.

### 13. Move readers to run presentation

Scope: new Flow `lib/atlas_flow/runs/presentation.ex` and `test/runs/presentation_test.exs`; Flow `item.ex`; Facts `subflows.ex`, `server.ex`, `test/{subflows,description_read}_test.exs`; Runtime `lib/atlas_runtime/execution/engine.ex`, `lib/atlas_runtime/interactions/guidance.ex`, `test/{atlas_runtime,guidance_inbox}_test.exs`; Control `lib/atlas_control/{pages,workers,turns}.ex`, `test/{pages,worker_pages,turns}_test.exs`.

Serve a run-derived owner/presentation view through Facts. Preserve expected work, todo, state, owner and deferred handover. Move consumers to this view while old definitions still exist. No platform layer calls another directly.

The readers to replace are evidenced at Runtime `platform/atlas_runtime/lib/atlas_runtime/execution/engine.ex:210` and `platform/atlas_runtime/lib/atlas_runtime/interactions/guidance.ex:260`; Control `platform/atlas_control/lib/atlas_control/workers.ex:342-356`, `platform/atlas_control/lib/atlas_control/turns.ex:54`, and `platform/atlas_control/lib/atlas_control/pages.ex:705,805,1918,1972-1988`.

Acceptance: lowest-level projection and reader tests for active/final runs, manual owner, deferred handover and no stale actionable inbox item. Boundary checks still pass.

Real behaviour on test: pages, worker routing and guidance keep working with all eight generated flows selected. A completed run does not launch another worker. The temporary accepted-decision follow-through still appears.

### 14. Remove the old flows

Scope: remove legacy `flows` from `products/software_factory/model/targets/rela/compositions/atlas-eyra/atlas.json`, `platform/atlas_facts/rela/tests/fixtures/baseline-atlas.json` and reassembled `products/software_factory/model/targets/rela/atlas.json`/manifest. Remove Flow `lib/atlas_flow/{definition,item}.ex`; projection now lives in `runs/presentation.ex`. Simplify `engine.ex`; retire `test/{atlas_flow,engine}_test.exs` legacy cases. Remove Facts' runtime legacy-check call from `server.ex`. Retain Facts `flows.ex` as a pure build-time validator and adjust `test/flows_test.exs`'s exact expectations; the unchanged assembler invokes that file directly (`platform/atlas_facts/rela/scripts/assemble.py:416-424`). It does not execute flows. Update fixture expectations and `products/software_factory/e2e/test/{composition,rela_description,flow_run}_test.exs`. If follow-through is retained, add `products/software_factory/model/contract/lib/decision_follow_through.ex`, register it in `software.ex`, add its contract test/golden, selection in `products/software_factory/model/targets/rela/flow-runtime.json`, and regenerate targets.

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
