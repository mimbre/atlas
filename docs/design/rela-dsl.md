# Rela DSL: one model for entities and flows, compiled

Architect design under D-0083. No product code changes. Paths are relative to `atlas/`. `<org>` stands for the organisation module and composition. This checkout predates #109; where the example shows #109's ledger rule, answers and deadline, that is the state on develop.

## 0. Decisions

| # | Decision (D-0083) | In this design |
| --- | --- | --- |
| 1 | The DSL compiles to runnable Elixir behind platform behaviours | Contract modules `use RelaDSL` (`type`, `entity`, `relation`, `answer`, `subflow`, `defgate`, `migrate`). The macros generate callback implementations of `AtlasFlow.Model`, `AtlasGates.Model`, `AtlasFacts.Model`, `AtlasRuntime.Model` and `AtlasControl.Model` (§2). No `.ex` is written to disk; nothing generated is checked in except targets. |
| 2 | Runtime code never reads generated JSON, also not at compile time | §5 cuts over every reader: `AtlasFlow.Generated`, `AtlasGates.Definitions`, `AtlasFacts.Subflows`, Facts' `extra`/`flow_runtime` loading, and the description interpreters in Flow, Runtime and Control. |
| 3 | Targets are output only | `mix model.gen [--check] [--base REF]` writes Rela's inputs to `rela/`: `schema.yaml`, `modules/**/schema.yaml`, `compositions/<org>/bindings.yaml`, `acl.yaml`, `flows.yaml` and `atlas.manifest.json`. It writes proofs to `model/targets/proof/`: `description.json`, `flows.<env>.json`, `runtime.json` and `digests.json`. `--check` fails on any difference, so a macro-only change shows as a target diff. Unit tests may read proofs; runtime code may not. |
| 4 | `digest/0` per subflow, at compile time | The macro builds the same string-keyed canonical data that `flows.json` holds today and hashes it with today's canonical-JSON encoding (§3). |
| 5 | Run migrations are DSL | `migrate :decide, from:, to:, states:, rekey:, reason:` beside the subflow. `from` must occur in the **base branch's** committed `digests.json`, never only in the new one (§3). |
| 6 | Platform/domain boundary | Platform apps hold the behaviours and the generic kernel. The domain is the app `:model` (`model/contract`). The umbrella release depends on it, but no platform app does. It is wired at boot by configuration (§1). |
| 7 | No hybrid | One path per component, cut over in one slice that removes its old reader. Consumers go first (Flow, Runtime, Control), then the producer (Facts). Cutting the producer first would need a description shim (§5). |
| 8 | Done by #109 | Ledger/`delete_error`, `a` Accept / `f` Reject for the owner person, the deadline shown, and the decide run migration are not in the plan. They appear in the example as existing behaviour. |
| 9 | No named person in the contract | `owner default: {:person, config: :decider}`. The key comes from the settings file the core runs with (`actors.decider`: `fly/<env>/core.json` on Fly, a private instance's `ATLAS_ENV_FILE`; `config :atlas, actors:` via `runtime.exs`) and is resolved at boot. A missing key refuses boot. A missing person does not: the owner waits for that person (Flow logs why), and Control serves, so a fresh environment can boot and make its first person (§5, slice 7). |

## 1. Layout and wiring

```
model/
  dsl/        app :rela_dsl (was flow/generator): macros, checks, introspection (__rela__/1),
              writers, canonical digest, mix model.gen; no domain words (CI grep)
  contract/   app :model (was flow/contract): the domain, by module and concept
    foundation/{module,person,agent,assignment,turn,guidance,decision,gate_verdict,flow_run,gates}.ex
    foundation/audit/{module,agent_request,agent_step}.ex
    software/{module,issue,pull_request,pr_review,pr_test,delivery}.ex
    <org>/{module,scene,use_case}.ex
    compositions/<org>.ex        # Model.<Org>: the root module that implements the behaviours
    profiles/{foundation,incident}.ex   # compiled in MIX_ENV=test only; e2e selects them by config
  targets/proof/{description.json,flows.prod.json,flows.test.json,runtime.json,digests.json}
```

The folder is renamed from `generator` to `dsl` because it no longer generates code files.

Dependencies only point at the platform:

```
rela_dsl  ←  model  →  atlas_{flow,gates,facts,runtime,control} (behaviours only)
beam/mix.exs (release) → model          platform apps → never model
```

- **Wiring.** `config/runtime.exs` sets `config :atlas, model: Model.<Org>`, or a profile module in e2e. Each platform app reads `Application.fetch_env!(:atlas, :model)` once at boot and calls its callbacks. A missing or wrong module refuses boot.
- **Platform tests.** They use neutral test models written with `RelaDSL` (a test-only dependency on `:rela_dsl`).
- **Boundary guard.** `beam/apps/atlas_bus/test/boundary_test.exs` gains two refusals: a platform `mix.exs` that names `:model`, and platform code that names a `Model.` module.

## 2. Behaviours (platform-owned) and what the macros generate

The kernel passes `lookup`, its reader of related facts and links, so generated code never calls a platform service.

```elixir
# atlas_flow: lib/atlas_flow/model.ex
@callback subflows(env :: atom) :: [module]          # each implements AtlasFlow.Subflow
@callback migrations() :: [%{subflow: atom, from: digest, to: digest, states: map, rekey: boolean}]
@callback selection(subflow :: atom) :: %{admission: ..., imports: ..., projection: ...}
@callback actors() :: [{role :: atom, kind}]          # configured actors the model needs ([decider: "person"])
@callback composition() :: %{"version" => 1, "links" => [...], "counts" => [...]}  # flow-runs slice 6; also in flows.<env>.json

# AtlasFlow.Subflow, one compiled module per subflow and environment
@callback name() :: atom;  subject() :: String.t();  digest() :: String.t();  initial() :: atom
@callback start?(trigger, fact) :: boolean
@callback enter(state, fact) :: [output]              # resets, sets, creates, in order
@callback next(state, fact, input) :: {:to, state} | :stay   # ordered branches, compiled conditions
@callback timers(state) :: [%{name, period, to, since}]
@callback mechanism(state) :: nil | {:pass | :gate | :effect, spec}
@callback waiting_for(state) :: [role]
@callback owner(state) :: {:assignee, via, relation, default}  # default {kind, key} | {kind, config: role}
@callback present(state, fact) :: %{expected, why, instructions, section, answers, deadline}
@callback final?(state) :: boolean

# atlas_gates: lib/atlas_gates/model.ex
@callback gates() :: %{name => %{version, flavor, purpose, evidence, rule, verdicts, decide, answer_within}}

# atlas_facts: lib/atlas_facts/model.ex
@callback rela_schema() :: map                         # what rela must serve; compared at boot
@callback check(kind, change, actor, lookup) :: :ok | {:refuse, String.t()}
  # requires, authority (+decider verdict), only_target, frozen, sealed, layering, limit,
  # closes_parent, requires_completed_children, delete rules (#109 delete_error), writer (flow_run)
@callback with_change(kind, change, lookup) :: [change]   # components, replaces
@callback derived(kind, fact, lookup) :: %{completed?, progress, late?, reviews, flags}
@callback connector(kind) :: nil | %{system, address, fields, until, names}

# atlas_runtime: lib/atlas_runtime/model.ex
@callback turn() :: map;  agent() :: map;  guidance() :: map
@callback read_first(fact, lookup) :: String.t()

# atlas_control: lib/atlas_control/model.ex
@callback shell(env) :: map;  start_page() :: map;  kinds() :: [map]
@callback form(kind, :create | :edit) :: %{ask, defaults, multiline, labels, set_by}
@callback key(kind, values) :: {:ok, String.t()} | {:error, String.t()}   # create.id
@callback actions(kind, fact, viewer) :: [action]     # page, relation and delete actions
@callback todo(kind, fact, run_view, viewer) :: nil | %{expected, why, instructions, section, answers, deadline}
@callback answer(kind, key, fact, viewer) :: {:write, change} | {:refuse, String.t()}
```

`use RelaDSL.Composition` in `Model.<Org>` declares `@behaviour` for all five apps. It generates dispatch by kind or subflow to the concept modules, and it generates `__rela__/1` (introspection for `mix model.gen`). Today's `atlas.json` keys map one-to-one to DSL constructs, as in the earlier version of this design. Each now compiles to a callback, as the table shows.

| Today's key(s) | DSL | Compiles into |
| --- | --- | --- |
| `types`, `entities.*.{label,plural,aliases,id_type,id_prefix,description,properties}`, `relations.*.{label,description,from,to,max_outgoing,inverse}` | `type`, `entity`, `field`, `fields`/`use_fields`, `relation` | `rela_schema/0`; the `schema.yaml` target |
| `create.{ask,id,defaults}`, `properties.*.{set_by,multiline,label,cause}`, `primary`, `top`, `order`, `start`, `counts`, `agent`, `by_hand`, `actions` | entity macros, `field` options | `form/2`, `key/2`, `kinds/0`, `actions/3` |
| `requires`, `authority`(+`decider`), `frozen`, `replaces`, `layering`, `sealed`, `relations.*.{only_target,limit,closes_parent,requires_completed_children,set_by,component}`, #109 `delete_error` | entity/relation macros | `check/4`, `with_change/3` |
| `completion`, `progress`, top `progress`, `late`, `relations.*.review`, flow-runtime `flags`/`reviews` | `completion`, `progress`, `progress_order`, `late`, `review`, `flag` | `derived/3` |
| `connector` | `connector` | `connector/1` |
| `relations.*.{parent,add,actions}`, `todo`, `shell`, `start` | relation options, `todo_words`, `shell`, `start_page` | `actions/3`, `todo/4`, `shell/1`, `start_page/0` |
| `runtime.{turn,agent}`, `guidance`, `read_first` | `runtime`, `guidance`, `read_first` | `AtlasRuntime.Model` |
| `flows` (legacy, until flow-runs slice 14) | `legacy_flow` | `AtlasFlow.Subflow` as legacy definitions, with no JSON parser |
| flow-runtime `kind/fields/writer/inputs/selection/migrations` | `flow_runtime`, `select`, `migrate` | `selection/1`, `migrations/0`, `check/4` (writer rule) |
| `acl.yaml` roles/assignments | `role`, `assign` | `acl.yaml` target only (Rela checks flows against it) |
| test-env patch in `fly/core.Dockerfile` (`guidance.control`, Workers tab) | environment settings | `shell/1(env)`, `guidance/0` + `env/test.json` |

## 3. Digests, proofs and migrations

- **Digest.** `digest/0` is `sha256(canonical(data))`. `data` is exactly the string-keyed map that today's Atlas writer emits per subflow, with limits resolved per environment, so prod and test have separate compiled modules. `canonical/1` is today's `DefinitionDigest.canonical/1`, moved into `rela_dsl`. Nothing is read from disk.
- **Digest proof (test).** For every subflow and environment, the compiled `digest/0` equals the digest of the committed `flows.<env>.json` entry. It also equals the pinned live digests in `definition_digest_test`. In this checkout those are prod `d9aadf74…` and test `e2d4c41b…`; the test pins develop's post-#109 values. A pure move or a pure cutover must leave them all unchanged.
- **`digests.json`.** Per subflow and environment it holds the current digest and its state names, plus an append-only history of `{digest, states}`.
- **`--check --base origin/develop`** (CI) reads the base branch's `digests.json` with `git show` and refuses:
  1. a history entry that was removed or changed;
  2. a subflow whose compiled digest differs from the base's current one without a `migrate from: <base digest>, to: <compiled digest>`;
  3. a `migrate` whose `from` is absent from the base history; a `migrate` whose `to` is not a compiled digest;
  4. a `migrate` whose `states` keys are not states of `from`, or whose values are not states of `to`;
  5. `rekey: true` without identity maps.

  A change therefore cannot approve its own migration.

## 4. Example: `model/contract/foundation/decision.ex`

Today's types are unchanged and abbreviated here. Lines marked #109 are develop's existing behaviour.

```elixir
defmodule Model.Decision do
  use RelaDSL

  type :decision_status, values: [:proposed, :accepted, :rejected, :superseded], labels: [...]
  type :decision_force, values: [:direction, :guideline, :guardrail, :principle], descriptions: [...]
  # decision_category, decision_scope, decision_reversibility: as today

  entity :decision, label: "Decision", plural: "decisions", aliases: ["dr"], id: :manual,
    id_prefix: "D-", description: "One decision record in the append-only ledger: ..." do
    field :title, :string, required: true, doc: "The decision in a few words"
    field :decision, :string, required: true, doc: "The rule, in one or two sentences", multiline: true
    field :context, :string, doc: "Why it was decided", multiline: true
    field :consequences, :string, doc: "What changes because of it", multiline: true
    field :category, :decision_category;  field :scope, :decision_scope
    field :reversibility, :decision_reversibility;  field :force, :decision_force
    field :enforced_by, :string, label: "Enforced by"
    field :status, :decision_status
    field :decided_at, :datetime, label: "Decided at"
    field :no_work, :boolean, label: "No work needed"
    field :unverified, :boolean, label: "Unverified", set_by: [:flow]
    field :gate_result, :string, label: "Gate result", set_by: [:flow]
    field :verdict, :string

    primary :title;  order :newest
    create ask: [:title, :decision, :context, :consequences, :category, :scope, :reversibility,
                 :force, :enforced_by, :no_work],
           id: [prefix: "D-", digits: 4, first: 24], defaults: [status: :proposed]
    delete_error "a decision is a ledger record and is never deleted"            # #109
    requires when: [force: [:principle]], fields: [:enforced_by], error: "a principle names ..."
    authority when: [status: [:accepted]], by: :decided_by, kind: :person, agent_kind: :agent,
      decider: [gate: :accept_decision, relation: :about, kind: :gate_verdict],  # fingerprint from the gate
      writes: [status: [:accepted, :rejected]], error: "...", writer_error: "..."
    frozen when: [status: [:accepted, :superseded]],
      only: [unverified: [false], status: [:superseded], no_work: [true]], error: "..."
    replaces relation: :supersedes, when: [status: [:accepted]],
      of: [status: [:accepted, :superseded]], set: [status: :superseded], error: "..."
    layering relation: :follows_from, field: :scope, not: [platform: [:software, :instance]], error: "..."
    flag :unverified, value: true, label: "🔴 Unverified decision"              # was flow-runtime.json

    answer :accept, key: "a", label: "Accept", for: :person,                     # #109
      writes: [status: :accepted], as: :decided_by, stamp: :decided_at
    answer :reject, key: "f", label: "Reject", for: :person,                     # #109
      writes: [status: :rejected], as: :decided_by, stamp: :decided_at, note: :required
  end

  relation :decided_by, from: :decision, to: [:person, :agent], one: true, label: "decided by",
    inverse: {"decided", "decided"}, only_target: [error: "only the one who decides ...", also: [:migration]]
  relation :delegated_by, from: :decision, to: [:person], one: true, label: "delegated by",
    inverse: {"delegated", "delegated"}, only_target: [error: "...", also: [:migration]]
  relation :supersedes, from: :decision, to: [:decision], inverse: {"superseded_by", "superseded by"}
  relation :follows_from, from: :decision, to: [:decision], inverse: {"elaborated_by", "elaborated by"}

  defgate :accept_decision, version: 1, flavor: :rule, purpose: :decider, fixed: :person_always,
    fingerprint: [fields: [:title, :decision, :category, :scope, :reversibility, :force],
                  relations: [:supersedes]],
    evidence: [...], rule: [...], verdicts: [...], decide: [...], answer_within: [...]   # as today

  subflow :decide, label: "Decide", subject: :decision do
    run_as "system:atlas-flow"
    owner via: :assignment, relation: :assigned_to, default: {:agent, :coordinator}
    channel :debate
    start :create
    initial :deciding

    state :deciding, label: "Who decides" do
      gate :accept_decision, person_always: :for_person_always, person: :for_person,
        agent: :for_agent, agent_unverified: :for_agent_unverified
    end

    state :for_person_always, label: "A person decides" do
      owner default: {:person, config: :decider}         # slice 7; #109 names a person here
      wait_for [:principle_authority, :decider], on: :status, reset: false,
        accepted: :accepted, rejected: :rejected
      present expected: "Have a person decide", why: "a fixed person rule holds",
        instructions: "...", answers: [:accept, :reject]                          # #109
    end

    state :for_person, label: "Waiting for a person" do
      owner default: {:person, config: :decider}         # slice 7
      wait_for :decider, on: :status, reset: false, accepted: :accepted, rejected: :rejected
      timer :no_answer, {:gate_limit, :accept_decision}, to: :deciding
      present expected: "Have a person decide", why: "the decider gate requires a person",
        instructions: "...", answers: [:accept, :reject], deadline: :no_answer   # #109
    end

    state :for_agent, label: "An agent may decide" do
      wait_for [:delegate, :decider], on: :status, reset: false, accepted: :accepted, rejected: :rejected
      present expected: "Have it decided", why: "the recorded gate permits an agent", instructions: "..."
    end

    state :for_agent_unverified, label: "Unverified agent decision" do
      set unverified: true
      wait_for [:delegate, :decider], on: :status, reset: false, accepted: :accepted, rejected: :rejected
      present expected: "Have it decided (unverified)", why: "a person did not answer in time", instructions: "..."
    end

    final :accepted, label: "Accepted"
    final :rejected, label: "Rejected"
  end

  select :decide, choices: [:status], admission: [status: [:proposed, :accepted, :rejected, :superseded]],
    imports: [[when: [status: [:accepted]], state: :accepted], ...],              # was flow-runtime.json
    projection: [on: :assignment, state_field: :flow_state, handover_field: :handover,
                 owner_relation: :assigned_to, field: :expected]

  migrate :decide, from: "118c1cf3…", to: "d9aadf74…", rekey: true, states: :same,
    reason: "Canonical JSON identity; unchanged prod subflow data"               # history, as today
  # … the other entries of today's flow-runtime.json, and #109's
end
```

A sketch of the compiled callbacks (simplified):

```elixir
# AtlasFacts.Model, via Model.<Org>.check/4 → Model.Decision.__facts_check__/4
def __facts_check__("decision", %{op: :delete}, _actor, _lookup),
  do: {:refuse, "a decision is a ledger record and is never deleted"}
def __facts_check__("decision", %{after: a} = change, actor, lookup) do
  with :ok <- requires(a),                                   # force == "principle" → enforced_by
       :ok <- frozen(change),                                # accepted/superseded: only listed sets
       :ok <- only_target(change, actor, ~w(decided_by delegated_by)),
       :ok <- authority(change, actor, lookup),              # status → accepted|rejected only from decided_by;
                                                             # agent only under fresh accept_decision verdict
       do: layering(change, lookup)
end

# AtlasFlow.Subflow: Model.Decision.Decide.Prod (and .Test, with the test limits)
def digest, do: "d9aadf74d08e0fb4ee4ada4d17980c10aafd4424f251061779cbd61b1c01c7aa"   # computed at compile time
def next(:for_person, %{"status" => "accepted"}, %{roles: r}) when "decider" in r, do: {:to, :accepted}
def next(:for_person, %{"status" => "rejected"}, %{roles: r}) when "decider" in r, do: {:to, :rejected}
def next(:for_person, _fact, _input), do: :stay
def timers(:for_person), do: [%{name: :no_answer, period: "48h", to: :deciding, since: nil}]
def owner(:for_person), do: {:assignee, "assignment", "assigned_to", {"person", config: :decider}}

# AtlasControl.Model
def answer("decision", "a", fact, %{kind: "person", key: me}),
  do: {:write, %{set: %{"status" => "accepted", "decided_at" => :now}, link: {"decided_by", me}}}
```

Compile-time checks:

- every name resolves in the composition: kinds, fields, values, relations, roles, gates and answers;
- answer writes in `authority.writes` require `as: authority.by` and a `for:` kind that authority allows;
- the decider gate has `purpose: :decider`, and its relation leads from `gate_verdict` to `decision`;
- `select` refers to `wait_for` fields and states that exist;
- `owner default: {:person, config: r}` adds `r` to `actors/0`;
- the `digests.json` rules of §3.

## 5. Slices

Each slice is mergeable alone and green; runs keep their identity unless a slice says otherwise.

| # | Slice | Deletes | Proof |
| --- | --- | --- | --- |
| 0 | **Normalise sources.** The hand YAML gets one style and canonical order (foundation's 8 flow-style lists, the `turn_state` position, scalar folding). `assemble.py` gets `sort_keys=True`. Hand sources only. | nothing | `jq -S` equality of `rela/atlas.json`; `config.py resolved` equality; `rela validate`; e2e description restart keeps data |
| 1 | **Move `flow/` → `model/`.** Apps `rela_dsl`/`model`, `mix model.gen`, all references (CI, `fly/core.Dockerfile`, `beam/apps/*/mix.exs` paths, `runtime.exs`, docs). Runtime readers stay as they are, on the new paths. | `flow/` | digests and Rela versions unchanged (`definition_digest_test`, `golden_test`); only headers and `rela_flows_sha256` change |
| 2 | **Entity DSL; every target from the model; runtime untouched.** Concept and module files, the composition, profiles, `migrate`/`select`, introspection, all checks. `mix model.gen` writes the Rela inputs and the proofs, and still writes `rela/atlas.json` and `rela/flow-runtime.json` byte-for-byte for Facts, the only remaining reader until slice 6. | `rela/scripts/assemble.py`, `rela/modules/**/atlas.json`, `rela/compositions/<org>/{atlas.json,sources.json}`, the hand-written YAML and `acl.yaml` (now generated), the hand `flow-runtime.json` (now from `migrate`/`select`), `rela/tests/{test_assembly.py,profiles.py,fixtures/baseline-atlas.json}`, `flow/targets/rela/` copy | safety net: every generated file is byte-for-byte today's committed file (below its header). Introspection equals the proofs per entity and subflow. The digest proof (§3). |
| 3 | **Flow + Gates cutover.** `AtlasFlow.Model`/`Subflow` and `AtlasGates.Model` behaviours; the kernel calls compiled callbacks; the model is wired by config. | `AtlasFlow.Generated`, `AtlasGates.Definitions`' `flows.json` embedding, Flow's legacy definition parser (`definition.ex`; legacy flows are compiled), Flow's reads of `description["flows"]`/`["flow_runtime"]`, the `deployed_yaml` hash check and its config (one compile cannot diverge), Gates' and Flow's dependency on the `flows.json` paths | Flow tests on neutral models (manual clock); compiled `digest/0` equals the pinned digests; restart mid-wait keeps runs |
| 4 | **Runtime cutover.** `AtlasRuntime.Model`: turn, agent, guidance, read_first. | Runtime's description lookups (`execution/engine.ex`, `interactions/guidance.ex`) | Runtime unit tests on a neutral model |
| 5 | **Control cutover.** `AtlasControl.Model`: shell, start page, kinds, forms, keys, actions, todo, answers, read_first. Test-env tab and `guidance.control` move to `env/test.json` via `runtime.exs`. | description interpretation in `pages.ex`, `workers.ex`, `turns.ex`, `read_first.ex`; the `atlas-test.json` patch in `fly/core.Dockerfile` | Control page/answer tests on a neutral model; e2e pages |
| 6 | **Facts cutover.** `AtlasFacts.Model`. At boot, rela's `_schema` must equal `rela_schema/0`; `_description` answers rela's schema only. | `server.ex` `extra/1` and `runtime_description!/2`, `subflows.ex`, `flow_runtime.ex`, `flows.ex`, the interpreters replaced by generated code (`guards`, `completion`, `progress`, `late`, `review`, `components`, `connector` rule parsing), `RelaDSL.Runtime` (the `target:` macro), config `extra`/`flow_runtime` (`runtime.exs`, `fly/prod/core.json`, `fly/rehearse-transfer.py`), Dockerfile COPY of `atlas.json`/`flow-runtime.json`/`flows.json`. `rela/atlas.json` and `rela/flow-runtime.json` stop being written: proofs only. The manifest drops `output_sha256` (`verify.py` text). | Facts write/derive tests on a neutral model; e2e smoke reads the proof; boot refusal test on schema mismatch |
| 7 | **Configured deciding person.** `{:person, :<name>}` (decision, use_case) becomes `{:person, config: role}`; the core's settings (`fly/<env>/core.json`) `actors`; Flow and Control resolve it at boot and refuse a missing key; a missing person fact only makes the owner wait. The owner data changes, so `decide` and the affected use_case subflows get new digests: `migrate … rekey: true, states: :same`, checked against the base proofs. | named persons in `model/contract` (CI grep: no `{:person, :` literal) | rekey migration test; boot refusal test (missing key); a missing person waits; digests are new and declared |

## 6. Risks, what stays hand-written, adding a kind

**Risks**

1. **Macro output equivalence.** Generated callbacks must behave exactly like today's interpreters. Each cutover first ports the interpreter's tests to the neutral model, and the proofs show every macro change as a diff.
2. **Compile coupling.** A behaviour change in a platform app forces a model recompile. That is fine in one release build, but behaviour changes need a version note.
3. **Boot misconfiguration.** A missing model, an unconfigured actor (`actors.<role>`), or a rela schema that differs from `rela_schema/0` refuses boot. There is no fallback, by design (decision 7).
4. **YAML fidelity.** This is a slice 0 / slice 2 risk: normalise the sources and never add style hints.
5. **Slice 7 re-keys live runs.** The rekey keeps state, entry and deadlines (`run.ex`).

**Stays hand-written**

| File | Why |
| --- | --- |
| `rela/data-entry.yaml` | rela-server setting |
| `env/<env>.json`, `fly/<env>/core.json` | environment settings (clients; the core on Fly); the core's now also has `actors` |
| `rela/scripts/{config.py,verify.py,*.sh}`, `rela/tests/test_config.py` | packaging and fits; existing Python only |
| golden files, ADRs | approval records |

`flow-runtime.json` is no longer hand-written: migrations are DSL, approved against the base proof.

**Adding a kind** (with a subflow, assignable, gated, a new role)

| | Today | After |
| --- | --- | --- |
| Hand-edited | 8 files (module YAML, module JSON, bindings, acl, subflow file, composition, golden, golden test) | 3 files + golden: `model/contract/<module>/<kind>.ex` (new), `<module>/module.ex`, `compositions/<org>.ex` |
| Platform code touched | 0 | 0 (callbacks are generated) |
| Generated | 8, from 2 commands | Rela inputs + proofs, from 1 command; `--check` shows the macro output |

The exact inventories (`e2e/test/composition_test.exs`, Flow goldens) are still updated in the same change.

## 7. Open product questions

1. **What happens when an environment has no `actors.decider` configured?** *Recommendation:* refuse boot. A fallback to the coordinator agent would be a hidden second path.
2. **Is one deciding person per environment enough, or is a list needed (any of them may answer)?** *Recommendation:* one now. `config: role` can later resolve to a list in `env/<env>.json` without changing the contract or any digest.
