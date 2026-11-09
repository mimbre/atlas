# One platform, many products: T0–T3

Architect design. No product code changes. Paths are relative to `atlas/`. Words used here:

- **the platform**: Bus, Facts, Flow, Gates, Control, Runtime, Code, Learn, the clients and the Rela DSL;
- **the factory**: the software factory called Atlas today (scenes, use cases, issues, decisions and their flows). It is one product on the platform, and its domain app is `:model` today;
- **a laptop product**: a product built on the platform that runs a shared server plus one laptop application per tenant (T2);
- **a federated-data product**: a product whose nodes hold data that never leaves them (T3).

It builds on `docs/design/rela-dsl.md` (D-0083) and does not repeat it. Its slices are cited as DSL 1–7.

**Priority.** Only S1–S4 and the escape hatch (E1, E2) are to be built, after DSL 3–7. Multi-tenant (T2) and federated (T3) shape the architecture now, but their sections and slices S5–S13 are **design only, not scheduled** (§9).

## 0. Decisions

| # | Decision | Section |
| --- | --- | --- |
| 1 | A product is **one domain app plus one release project**. Platform apps hold behaviours, adapters and the kernel. They never name a product, a kind, a person or an organisation. | §1 |
| 2 | The platform owns the **foundation** model module (person, agent, assignment, turn, guidance, decision, gate verdict, flow run, audit, plus installation). Every product includes it. Platform runtime code still names none of its kinds. | §1.1 |
| 3 | Every component speaks only the Bus. Whether a component runs in-process or remote is a **release and link setting**, never a code branch. | §2.2 |
| 4 | **Instances, builders and built.** A released instance (prod) builds the next version (test) and other products. Builder and built never connect; the only channel is code (review → develop → CI). The platform has no "builder" concept. | §2.0 |
| 5 | **One home per fact.** Each kind is written on exactly one side; the other side keeps read-only copies, replicated by position. There is no multi-master. | §2.3 |
| 6 | **Sensitive data and credentials stay on their owner's node.** Servers hold facts, decisions and evidence only. | §2.4 |
| 7 | Links between machines use **mutual TLS with short-lived certificates per installation**. The token in `hello` is removed in the same cutover. | §3 |
| 8 | T2 server: **one core per tenant**, each with its own BEAM, its own rela and its own SQLite store, behind a TLS-passthrough router. | §4 |
| 9 | Code becomes a **Bus effect receiver**, so Flow publishes and integrates instead of the coordinator. | §5 |
| 10 | rela runs **headless** with SQLite: one store per instance, opened by one rela process. PostgreSQL is used only where several processes must share one store, which no topology here needs. | §6.2 |
| 11 | **Escape hatch.** Prod can be recovered without prod: roll back to the previous release with compatible data, or fix forward by hand with workers, Code and CI. | §7 |

## 1. Platform and product

### 1.1 What is platform

| Part | App / folder today | Holds |
| --- | --- | --- |
| Bus | `atlas_bus` | envelopes, router, links (§2.2, §3) |
| Facts | `atlas_facts` | the store kernel over rela, the ledger, the connector kernel and adapters (GitHub is an adapter, not a product) |
| Flow | `atlas_flow` | the run kernel and the pass, gate and effect activities |
| Gates | `atlas_gates` | the gate kernel and verdict recording |
| Control | `atlas_control` | sessions, and pages from the BFF contract |
| Runtime | `atlas_runtime`, `tools/runtime` (Go) | worker execution, sandboxes and providers |
| Code | `atlas_code` | repositories, snapshots, changes, reviews and integrations |
| Learn | `atlas_learn` | observation reports |
| DSL | `model/dsl` (`:rela_dsl`) | macros, checks, digests and `mix model.gen` |
| Contract | `bff/{generator,contract,targets}` | Control's wire contract; it contains no product words (checked with `grep`) |
| Clients | `clients/{tui,agent,viewer}`, `bin/atlas` | rendering only; they know no kind |
| Foundation | today `model/contract/foundation/` | the platform's own model module, written in the DSL and included by every product |

The foundation belongs to the platform because every product has the same pattern: people decide, agents work, rules and advice gate, and evidence stays. It moves to `platform/foundation` (app `:rela_foundation`). Platform apps never depend on it: kind names reach them only through the behaviours (`AtlasFlow.Model`, …).

### 1.2 What a product is

```
products/<p>/
  model/     app :<p>           # domain, by module and concept; includes the foundation
  release/   mix project        # releases per role (§6), config/runtime.exs
  rela/      generated          # its rela description (today's rela/)
  targets/   generated proofs   # today's model/targets/
  env/       <env>.json         # its instances; actors, links, components
  deploy/    e.g. fly/          # its hosting, rollback included (§7)
  e2e/  skills/  docs/          # its never-break flows, its agent instructions, its guides
```

Dependencies point one way only: `products/<p>/* → platform/*`. A product never depends on another product. If two products need the same domain module (for example the factory's `software` module: issue, pull request, review, test, delivery), it moves to `modules/<name>/`. That is a shared domain library, not platform, so no platform app may depend on it.

### 1.3 Naming

| Thing | Platform | Product |
| --- | --- | --- |
| Top folder | `platform/` (beam, dsl, foundation, bff, clients, tools, docs) | `products/<p>/` |
| OTP apps | `atlas_*`, `rela_dsl`, `rela_foundation` | `:<p>` (for the factory: `:factory`, namespace `Factory.`) |
| Releases | none; the platform defines no release | `<p>_<role>`: `factory_core`, `factory_node`, `<p>_server`, `<p>_laptop` |
| Instances | none | `products/<p>/env/<instance>.json` |
| Docs | `platform/docs/` names no product, except as a labelled example | `products/<p>/docs/` |
| Prose | "the platform", "<component>" | the product's name; the factory is "the factory" |

Proposed answer (open question Q1): the `atlas_` code prefix stays with the platform, and the product loses the bare name in code (`:model` becomes `:factory`). In platform docs, the bare word "Atlas" is not used for the product.

**Boundary guard** (`beam/apps/atlas_bus/test/boundary_test.exs`). Today it refuses `{:model` and `Model.`. After the change it refuses:

1. a platform `mix.exs` that names an app under `products/` or `modules/`;
2. platform source that names a product's root namespace;
3. platform source that names any kind of any product. The kind names are read from each product's committed `targets/proof/description.json`, which replaces the hand-written `@entities` list.

### 1.4 Product content that sits in or leaks into the platform today

| Where | What | Moves to | Slice |
| --- | --- | --- | --- |
| `model/contract/` (app `:model`), `model/targets/`, `rela/` | the factory's domain, proofs and generated description, at top level next to the platform | `products/factory/{model,targets,rela}`; the foundation moves to `platform/foundation` | S4 |
| `env/*.json` | the factory's instances, including a named TUI user and hosting app names | `products/factory/env/` | S4 |
| `fly/**`, `bin/atlas-ops`, `tools/runtime.py`, `tools/runtime_process.py`, `tools/prod-backup/` | the factory's hosting: Fly apps, tunnel, keychain, backups | `products/factory/deploy/` | S4 |
| `e2e/`, `skills/`, `docs/guides/uc-*.md`, `tools/orchestrator/` | the factory's never-break flows, agent roles, use-case guides and coordinator watcher | `products/factory/` | S4 |
| `beam/mix.exs:11-30` | the factory's releases (`atlas`, `atlas_code`) inside the platform umbrella | `products/factory/release/mix.exs` | S4 |
| `beam/config/runtime.exs` | reads the factory's `env/<env>.json`, `rela/flow-runtime.json`, `rela/flows.yaml` and `model/targets/test/rela/flows.yaml`; `ATLAS_ROLE` core/runtime; accepts only `test` and `prod` | the product's release config; the paths go with DSL 3 and 6; roles become releases (§6) | S4, S5 |
| `beam/config/config.exs:10` | `verdict_kind: "gate_verdict"`, a foundation kind name in platform config | `AtlasGates.Model`, from the foundation | DSL 3 |
| `beam/apps/atlas_facts/lib/atlas_facts/application.ex:7` | `@sources %{"github" => …}`, a connector registry fixed inside Facts | the release config chooses adapters; the adapter module stays | S3 |
| `beam/apps/atlas_code/lib/atlas_code.ex:1667` | the rule that a review body must carry the factory's attribution sentence | Code `config.json` review policy (when absent, there is no rule) | S3 |
| `beam/apps/atlas_code/lib/atlas_code.ex:1742`, `:1607` | the review location prefix `work/review-` and the commit author name | Code `config.json` | S3 |
| `beam/apps/atlas_runtime/lib/atlas_runtime/execution/command_admissions.ex:306` | worker network hosts `github.com` and `api.github.com` | removed once workers have no Git (S2) | S2 |
| `beam/apps/atlas_runtime/lib/atlas_runtime/integrations/atlas_server/lifecycle.ex:169` | `"TU-"`, the turn kind's key prefix, a model rule hard-coded in Runtime | the `AtlasRuntime.Model` key function; the module is renamed `Integrations.Core` | DSL 4, S3 |
| `beam/apps/atlas_runtime/lib/atlas_runtime/handoffs/handoff_records.ex:12`, `interactions/peer_question_records.ex:87`; `atlas_gates/lib/mix/tasks/atlas.gates.evaluate.ex`; `atlas_learn/lib/atlas_learn.ex` | the factory's coordinator role named in platform provenance and docs; the `pull_request` handoff (a boundary-test exemption) | the platform word "orchestrator"; the pull-request handoff is deleted once Code publishes through Flow (S2), after checking for other callers | S2, S3 |
| `beam/apps/atlas_control/lib/atlas_control/pages.ex:2764-2765` | a comment example with a person's name and an organisation-specific key | a neutral example | S3 |
| `beam/apps/atlas_control/lib/atlas_control/session.ex:612` | the actor is the instance's single `tui_user`: there is no sign-in | the person from the verified client certificate (§3) | S9 |
| Description interpreters in Facts, Flow, Control and Runtime | they read the factory's generated JSON | removed by DSL 3–6 | DSL |

There is also a layer leak to fix on the way (S3), although it is not product content: Flow's pass validation knows Runtime's provider names and permission modes (`beam/apps/atlas_flow/lib/atlas_flow/activities/pass.ex:16-21`). Runtime should validate these itself.

## 2. Composition

### 2.0 Instances: builders and built

An **instance** is one running deployment of one product release. It has its own Bus, Facts store, instance id (§6, S5) and data. A **stage** (`test` or `prod`) says only whether test-only faults are allowed. "Builder" and "built" are roles that instances play. They are not platform concepts: a builder is an instance whose product model has kinds about building (for the factory: scenes, use cases, issues, decisions, gate verdicts) and whose release lists a Code receiver (§5).

| Instance | Runs | Builds | Reaches what it builds through |
| --- | --- | --- | --- |
| factory prod | master: release N | factory N+1 (its own next version) and other products | Code effects → review → develop → CI |
| factory test | develop: N+1 under construction | nothing; its facts are test data | — |
| product P test | P's develop | nothing | — |
| product P prod | P's master | possibly things for its own users (for example per-tenant apps) | its own Code receivers and their repositories |

A release turns test into the new prod. master receives develop's tested tree, and CI deploys it as prod. Test's data never moves.

Platform rules:

1. **Builder and built never connect** (D-0072). There is no link, shared Bus, shared store or copy between them. Every envelope and every `hello` carries the instance id, and a prod Bus or Control refuses a test envelope or client (as today). In T2 and T3, a peer link joins only instances of the same product and stage.
2. **Code is the only channel.** The builder's Code effect opens a review, which is merged to develop; CI deploys test; a release promotes the tree to master; CI deploys prod. CI holds the deploy credentials. Neither instance holds the other's data or credentials.
3. **Each instance migrates its own data.** A release moves code, never facts.
4. **Self-hosting is a special case,** not a separate path: the repository is the builder's own. As a result, a release that breaks prod also breaks the builder of its fix. §7 therefore gives a recovery path that does not depend on the builder.

The same rules hold one level down: P prod building for its users is P's business. Those artefacts are platform instances only if they run a release.

### 2.1 Topologies

| | Releases (per machine) | Links | Who is home |
| --- | --- | --- | --- |
| **T0** dev | one BEAM: all components + model + local headless rela (SQLite in the data directory) | none (in-process Bus) | the one core |
| **T1** factory | server: `factory_core` (Bus, Facts, Gates, Flow, Control), with headless rela beside it (SQLite on its volume); per person's machine: `factory_node` (Bus, Runtime, Code); clients | `runtime` and `code` links, node → core; private network today | the server core, for all facts |
| **T2** laptop product *(design only)* | server: one `<p>_server` per tenant (each with its own rela and SQLite) + router; per tenant laptop: `<p>_laptop` (Bus, Facts, Gates, Flow, Control, Runtime, Code + local rela with SQLite, one BEAM) | one `peer` link, laptop → its tenant's server core, over the public internet; the laptop dials out | the laptop core for the tenant's work; the server core for server kinds (§2.3) |
| **T3** federated *(design only)* | per node: `<p>_node` (core + Runtime with a network-less sandbox + local rela with SQLite) | `peer` links node ↔ node, an open protocol | each node, for its own data's facts and release decisions |

### 2.2 In-process or remote, one contract

A link is a Bus-to-Bus connection with a **role**. The role decides which endpoints the far side may attach and which envelopes may cross. Today this policy is hard-coded for Runtime in `beam/apps/atlas_bus/lib/atlas_bus/link.ex:34-66`. It becomes a table in the Bus:

| Role | Far side may attach | Crosses (beyond read/fact/answer as today) |
| --- | --- | --- |
| `runtime` | `runtime@<m>`, `runtime@<m>/…` | `flow_pass` request/answer, `runtime.output` (as today) |
| `code` | `code@<m>/effects` | `flow_effect` requests from `flow/effects` only, and their answers back to `flow/effects` |
| `peer` *(design only)* | `peer@<m>` | `peer.offer`/`peer.ack` (§2.3); `flow_effect` to receivers that the other side declares |

The same release runs as T0 or T1 depending on settings alone. No component asks which topology it is in. `hello` carries the instance id, the release version and the model digest, and the link is refused on any mismatch.

### 2.3 Authority and replication (T2, T3; design only)

- Each kind declares its home side and what may leave it. This needs new DSL constructs after DSL 6: `home :server | :installation` and `share :kind, to: :server, fields: [...]`. By default nothing leaves.
- **Replication by position.** The sender reads "shared facts stored after position N" (a new Facts read). The receiver stores them as **copies**, written by `peer:<installation>`; Facts refuses any other writer for a copy kind. Sending resumes from the last acknowledged position, so there is no queue. Offers are idempotent by `(origin, position)`.
- **Asking the other side.** A side records a fact of its own; the other side's flow reads the copy and answers with a fact of its own home. Remote services are effects (§5), and their receiver runs on the side that holds the credential.

| Facts (T2) | Home | Copy on |
| --- | --- | --- |
| the tenant's work: study, data plan, proposed fields, the person's approvals, runs, turns, test evidence | laptop core | server, declared kinds and fields only |
| installation, enrolment, revocation; a second approver's decision; release records; advice produced on the server | server core | laptop (its own installation only) |
| the person's exports, sample data, worker folders, repository and vendor credentials | laptop, outside Facts | never |

- **Offline.** The laptop keeps working on its home facts. A flow that waits for a server fact simply waits.
- **Hand-off.** There is one home installation per tenant at a time. Moving to a new laptop is an operator action: revoke the old installation, enrol the new one, then replicate the copies down. Local-only data does not move.
- **Not built:** multi-master or CRDTs, conflict resolution, query-filtered sync, two writers for one kind, sync between model versions, Erlang distribution over the internet, automatic home moves.

### 2.4 The general rule

Sensitive data and credentials stay on their owner's node, and servers hold facts, decisions and evidence only. Three things enforce this:

1. **The model.** Nothing replicates without `share`, and fields are listed one by one. A blob is never a fact; facts refer to blobs by `sha256`.
2. **The link policy.** `peer` carries only `peer.*` frames and declared effect requests, with no `read` across.
3. **Credentials.** Each lives only in the component that uses it (Code's home, an effect receiver's home, the person's own vendor login, D-0037). A credential is never a fact, never a tracked setting and never Bus content.

T3 adds three things, all built on existing parts:

- **Sandboxed runs.** Runtime runs submitted scripts with the network denied and the node's data mounted read-only.
- **Held output.** Output is a node-local blob; only its fact may be shared.
- **Owner-approved release.** Releasing output is an effect whose `approved` field must equal the output fingerprint the owner approved. This is the rule `integrate` already uses (`beam/apps/atlas_flow/lib/atlas_flow/activities/effect.ex:72-73`).

A copy keeps its origin home and owner, and only that home can decide its release.

## 3. Transport and identity without a private network (design only)

| Choice | Recommendation | Why |
| --- | --- | --- |
| Encryption | TLS 1.3 with OTP `:ssl` on every link | no new dependency; the link already carries JSON lines over a socket (`link/server.ex:15-25`, `link/client.ex:66-73`) |
| Server identity | a public CA certificate for the link host name | laptops trust it through the OS store (`:public_key.cacerts_get/0`) |
| Client identity | **mTLS**, with one key pair per installation, generated on that machine | a stolen token works anywhere, but a certificate is bound to a key; rotation becomes renewal; the server stores no secrets |
| Issuer | one private CA per instance group (factory prod, factory test, each product stage); a T3 node pins the CAs of its peers | test and prod certificates cannot cross (§2.0); federation needs no shared authority |
| Certificate content | URI SAN `atlas:install/<id>`, plus instance, tenant, person, machine and role; valid for 7 days | the core reads identity from the certificate, never from `hello` |
| Enrolment | a one-time code shown in the server Console, bound to tenant and person, valid 15 minutes and single-use; the laptop sends a certificate request (CSR) with it | no shared secrets |
| Renewal and revocation | renewal over the live link from day 5; `installation.status = revoked` is a server-home fact, checked at every `hello`, and live links close when it changes | short lifetimes limit exposure without a revocation list |
| `hello` | keeps the instance id; `machine` must equal the certificate's; adds the release and model digest; **the token field is deleted** | one path |
| Limits | 5 s to `hello`; 1 MiB per line on `peer`; a frame-rate limit per installation; one live link per installation | the link is publicly exposed |

T1 can use the same link with or without WireGuard. Known limit: OTP `:ssl` cannot use a non-exportable hardware key, so the key is an owner-only (0600) file that any process of the same user can copy.

## 4. Tenant isolation on the T2 server (design only)

| | Core per tenant behind a router (recommended) | Shared core with tenant scoping |
| --- | --- | --- |
| Platform change | none in Facts, Flow, Gates or Control; the server release is the T1 core | a tenant in every envelope, read, run, page, ledger and rela query |
| Leak surface | a wrong route reaches a core that refuses the certificate | one missed filter leaks data across tenants |
| Store | one headless rela process per tenant with its own SQLite file; deleting a tenant means deleting a directory | one store for all tenants, which needs PostgreSQL because SQLite allows only one process |
| Cost | one BEAM + rela per tenant (memory not measured), many per host | lower per tenant |
| Upgrades | per tenant, which matches per-laptop versions (§6) | all tenants at once |

The router does TLS passthrough by SNI. It never holds keys or plaintext. Each core terminates mTLS itself and refuses any certificate whose tenant is not its own. SQLite's single-process limit fits this design exactly: each tenant has one rela.

## 5. Code as an effect receiver (T1)

Today Code is a loopback HTTP service with runtime and orchestrator tokens (`beam/apps/atlas_code/lib/atlas_code.ex:1-80`). The coordinator makes reviews, review updates and integrations using the orchestrator token. Flow's effect activity is ready, but no receiver is enabled (`beam/integration/flow_effect.exs:1-10`).

**Design**

- `atlas_code` depends on `atlas_bus` and joins the boundary test's `@layers`.
- **Operations as functions.** Review, review update and integration are extracted into functions (`AtlasCode.Reviews`, `AtlasCode.Integrations`). The effect receiver calls them, and so does the manual path (§7.2).
- **The receiver.** `AtlasCode.Effects` attaches `code@<machine>/effects` and accepts `flow_effect` requests only from `flow/effects`. Each effect maps to one of the functions above:
  - `create` → review;
  - `update` → review update;
  - `integrate` → integration, which needs the `approved` fingerprint.

  The record id is derived from the effect id. Code already returns the recorded result for an identical repeat and refuses a different body under the same id with `409 conflict`.
- **Lookup** answers from the record and never acts. A record in an incomplete phase (such as `pushed`) is answered `unknown`, so Flow blocks for reconciliation.
- **The contract.** `AtlasFlow.EffectReceiverContract` (`beam/apps/atlas_flow/test/support/effect_receiver.ex:164`) moves to `AtlasBus.EffectReceiverContract` in Bus test support. Code proves it at unit level against a fixture bare repository and a fixture `gh`, with no timers.
- **Placement.** Code runs in-process in T0, in `factory_node` over the `code` link role in T1, and in the laptop BEAM in T2.

**Cutover (S2, no hybrid).** The factory's pull-request subflow declares the `create`, `update` and `integrate` effects. The sealed change handle reaches the subject from Runtime's submission record, not from an agent's declaration. The factory release lists the receiver. In the same slice, the following are deleted:

- HTTP endpoints 7–9 (`/v1/reviews`, `/v1/review-updates`, `/v1/integrations`) and the orchestrator token;
- the coordinator's publish and integrate steps (`skills/`, `tools/orchestrator/`);
- the pull-request handoff and its boundary exemption.

The runtime token keeps snapshots and changes, which are Runtime's local interface.

## 6. Release engineering

### 6.1 Releases, config, upgrades

```elixir
# products/factory/release/mix.exs (path deps on platform/beam/apps/* and ../model)
releases: [
  factory_core: [applications: [atlas_bus: :permanent, atlas_facts: :permanent, atlas_gates: :permanent,
                                atlas_flow: :permanent, atlas_control: :permanent, factory: :load]],
  factory_node: [applications: [atlas_bus: :permanent, atlas_runtime: :permanent,
                                atlas_code: :permanent, factory: :load]],
  factory_dev:  [applications: [... all of the above ...]]                      # T0
]
# products/<p>/release/mix.exs (design only)
  <p>_server: [bus, facts, gates, flow, control, <p>: :load]                     # one per tenant
  <p>_laptop: [bus, facts, gates, flow, control, runtime, code, <p>: :load],
              overlays: rel/overlays (the pinned headless rela binary)
```

- **Config.** Each product's `config/runtime.exs` reads `env/<instance>.json`. It sets `config :atlas, model: <P>.Composition`, the links, the `effect_receivers` and the connector adapters. `ATLAS_ROLE` disappears: the release *is* the role.
- **Instance id and stage.** The envelope's `environment` becomes an opaque instance id; today it must be `test` or `prod` (`beam/config/runtime.exs:9-13`). A separate setting, `stage: test | prod`, decides whether test-only faults are allowed (S5).
- **Upgrades.** No hot upgrades. Every upgrade is stop, swap, start and migrate. On a laptop, the swapped-in release must be signed with an offline release key.
- **Migrations.** The `digests.json` history is append-only, so every released digest has a chain of forward migrations. At boot, each open run follows its chain. A run whose digest is not in the history refuses boot. Rollback (§7.1) adds a way back for one release.
- **Version window (open question Q3).** A peer link needs equal model digests. Tenant cores upgrade first. An older laptop gets `refused: upgrade <version>`, keeps working offline, and resumes from its acknowledged position once it has upgraded.

### 6.2 rela storage: headless, SQLite

The platform switches to rela's headless server: API, SSE and MCP, with no web UI (rela PR #2199, not released yet). Headless stores data only in SQLite or PostgreSQL, not in the filesystem store used today (`fly/rela-run.sh:21` checks `/data/rela/entities`). SQLite is single-process: a second process that opens the project is refused.

| Where | Store | Consequence |
| --- | --- | --- |
| T0, private e2e instances, tests | SQLite in the instance's data directory; Facts starts rela as a supervised port and it stops with the BEAM (`AtlasFacts.Rela.Local` beside `Rela.Http`) | one rela per data directory; parallel instances and tests each get their own directory; nothing else opens the file |
| T1 server | SQLite on rela's volume, with one rela process | the fits check, `rela validate` and backups run on a **held copy**, never against the open file; a one-time move from the filesystem store to SQLite uses the existing hold/move tooling (whether rela converts the store itself is to be confirmed once #2199 is released) |
| T2 tenant cores, T2 laptops, T3 nodes *(design only)* | one SQLite per tenant, installation or node; on a laptop, in a directory that workers are denied | the single-process limit matches one rela per core |
| PostgreSQL | only where several processes must share one store | no topology here needs it; it would be needed only by a shared multi-tenant core (rejected in §4) or by rela run as several replicas (not planned) |

Facts stays rela's only client. rela's API and MCP must not be reachable by workers or clients:

- in T1, rela runs on a separate private machine;
- in T0 and T2, rela listens on a Unix socket, or on a loopback port whose credential sits in a path that workers are denied. Which of these headless supports is to be verified.

SSE might feed the "since position" read (S10). That is an option to evaluate, not an assumption.

## 7. Escape hatch: when prod cannot build its own fix

**Requirement.** Recovering prod must never need prod (§2.0, rule 4). There are two means, used in order: first roll back (no code change), then, if needed, fix forward by hand (without the factory). Neither depends on prod's Bus, Facts, Flow or Control, or on the factory's model. Both need GitHub, CI and Fly.

### 7.1 Roll back to the previous release

- **What.** Redeploy prod's previous image pair (core and rela, labelled `master-<commit>`) with the existing `fly/deploy.sh`. A new CI job, `rollback-prod`, does this. It is started by hand, sits behind a protected CI environment that needs a maintainer's approval, and takes a required reason. Its target can only be the previous pair recorded by the last `deploy-prod`. Nobody needs personal Fly credentials.
- **Kept.** `deploy-prod` records the pair it replaces and keeps the last two prod pairs in the registry, checking that they are still there at each deploy. Before upgrading it takes a backup while rela is held: the SQLite file is copied with rela stopped (§6.2). The backup is kept until the next release.
- **Data compatibility.** `mix model.gen --check --base master` classifies every release, and CI refuses a merge to master without a class:

| Class | Condition | Rollback |
| --- | --- | --- |
| code-only | no rela schema change and no new subflow digest | redeploy N's pair |
| reversible | every schema change has a `down` step, and every `migrate` has `back:` (the inverse state map, re-keyed to N's digest) | N+1's image runs the down migration on held data, then N's pair is deployed |
| irreversible | anything else | allowed only with a decision, recorded before the release, that accepts restoring the pre-deploy backup; writes made since the deploy are lost |

- **Proof.** For a reversible release, CI applies up then down to a copy of the latest backup. The data must come back equal, and runs must keep their states. Every release candidate's rollback is also rehearsed on test: deploy N+1, roll back to N, run the smoke check. Test never connects to prod.
- **DSL change.** `migrate … back:` and schema `down` extend rela-dsl §3; `--check` enforces them.
- **Limit.** Only one release back. If the up migration itself was bad, the only remedy is restoring the backup.

### 7.2 Fix forward by hand, without prod

Use this when rollback is not enough, for example when N is broken too or the fix must go forward.

| Part | How, without prod |
| --- | --- |
| Workers | standalone `atlas-runtime` on the person's machine (no server connection, as today), working on a Code snapshot |
| Code | the person's local Code; the worker submits a sealed change (runtime token, as today), and the person reads it with `atlas-runtime snapshot diff` |
| Publishing | `atlas-code emergency review|integrate --change <id> --reason <text>`, a terminal command over the same review and integration functions as the receiver (§5). It uses the person's own `gh` login, refuses to run without a reason, and records `by: person:<login>, emergency: true, reason` |
| Gate | GitHub branch protection: CI green plus approval by a second maintainer; no factory gate takes part |
| Deploy | the usual CI: develop → test, then master → prod |

- **Not a second platform path.** No component calls this command, Flow never uses it, and no prod state depends on it. S2 removes the *agent's* orchestrator-token access. The emergency command needs a person's own GitHub login, which no agent holds: Runtime's sandboxes deny `~/.config/gh`.
- **Who may use it.** Maintainers named in the repository's maintainer team who are also reviewers of the CI prod environment. At least two people are involved: one acts and another approves. Agents never use it. If no second maintainer can be reached, only rollback is allowed.
- **Recorded afterwards.** All evidence lives outside prod: Code's emergency records, the pull request and its review, the CI runs, and the rollback run with its reason. Once prod drives work again, two things happen:
  - Learn's `code_changes` observation reports the emergency records when it is run against the Code home that holds them (it reads Code's records from disk);
  - the product records the intervention as its own facts. For the factory, that is a decision or incident linked to the pull request, which the GitHub connector already copies.

  This is where "every time a person steps in, the reason is recorded" is met. The platform guarantees that the evidence exists, and the product records the reason.

## 8. Threat and failure model

### 8.1 Threats (T2; design only)

| Threat | Effect | Control | Remaining |
| --- | --- | --- | --- |
| Forged node or laptop | attaches endpoints, injects facts | without a deployment-CA certificate the handshake fails; enrolment codes are single-use, last 15 minutes and are bound to a tenant and a person | social engineering of a code |
| Stolen installation key | impersonation until expiry | 7-day certificates; a revocation fact checked at `hello`; one live link per installation | a process of the same user can copy the key |
| Cross-tenant leak | one tenant reads another's facts | a core and a SQLite store per tenant; the router only passes TLS through; each core refuses foreign certificates | provisioning error (the core checks its data directory's tenant id) |
| Malicious laptop app forging evidence | fake passes, approvals or fields | anything the server acts on is checked on the server: the receiver rebuilds from the approved revision and checks the approved field list and the second approval | a tenant can only deceive itself |
| Sensitive data leaving the laptop | exports or credentials reach the server | nothing is replicated without `share`; blobs are never facts; `peer` carries no `read` | a model author who shares a sensitive field |
| DoS on the public listener | the server is exhausted | edge rate limits; 5 s to `hello`; 1 MiB frames; per-installation rates; per-tenant cores | volumetric attacks |
| Replayed or reordered offers | duplicate or stale copies | idempotent by `(origin, position)`; positions only increase | none known |
| Compromised server core | lies to its laptop | only facts, decisions and evidence are there; the laptop treats them as copies | trust in the operator |

### 8.2 Failures (T1; needed now)

| Failure | Effect | Control | Remaining |
| --- | --- | --- | --- |
| A release breaks prod | the factory cannot build its own fix | roll back (§7.1), then fix forward by hand (§7.2) | — |
| The previous image is missing | no rollback | the last two pairs are kept and checked at each deploy | a registry outage |
| N cannot read N+1's data | the rolled-back core refuses boot | release classes, the round-trip proof, the fits check before deploy | an irreversible release means restoring the backup, with loss |
| A bad up migration | damaged data | the pre-deploy backup, taken while held | writes since the deploy are lost |
| The manual path is misused (by an agent, or by one person alone) | unreviewed code reaches prod | a person's own credentials; branch protection requiring a second maintainer; CI | a compromised maintainer account |
| Emergency work goes unrecorded | the lesson is lost | Code's emergency records with a reason; the Learn report | people must still record the reason in prod |
| GitHub or CI is down while prod is broken | neither means works | none in the platform | the user may want a maintainer-held Fly deploy token for `fly/deploy.sh` (not designed here) |
| Test and prod get connected | test data reaches prod | the instance id on every envelope and `hello`; separate networks; separate CAs (S7) | — |
| A second process opens prod's SQLite file (backup, check) | it is refused, or reads a stale state | held copies only | — |
| A worker reaches rela's API or MCP directly | Facts' checks are bypassed | rela on a private machine (T1); a denied socket or credential (T0) | to verify against headless's options |

## 9. Slices

Each slice is mergeable alone and green, tested at the lowest level, with injected clocks and no hybrid path.

**Build order:** DSL 3–7 → E1 → S1 → E2 → S2 → S3 → S4. E2 must land before S2, because S2 deletes the HTTP publishing path that is today's de facto manual route.

| # | Slice | Status | Depends on | Deletes |
| --- | --- | --- | --- | --- |
| E1 | **Rollback.** The `rollback-prod` CI job, keeping the last two pairs, the held pre-deploy backup, release classes in `model.gen --check`, `migrate back:` and schema `down`, the round-trip proof on a backup copy, the rehearsal on test | **build**, needed now (T1) | DSL 3–7 | — |
| S1 | **Code effect receiver.** Code operations extracted into functions, `AtlasCode.Effects`, `AtlasBus.EffectReceiverContract`, the `code` link role; passes the contract on fixtures; not enabled yet | **build** (T1) | DSL 3–7 | the "Code migration stays blocked" note in `beam/integration/flow_effect.exs` |
| E2 | **Manual path.** `atlas-code emergency review|integrate` with the person's `gh` and a required reason, emergency records, a runbook in `products/factory/docs`, branch-protection settings documented | **build**, needed now (T1) | S1 | — |
| S2 | **Flow publishes and integrates** | **build** (T1) | S1, E2 | HTTP endpoints 7–9, the orchestrator token, the coordinator's publish and integrate steps, the pull-request handoff and its exemption, the worker GitHub hosts |
| S3 | **Product values out of platform apps** (§1.4) | **build** (T1) | DSL 3–5 | the literals in §1.4 |
| S4 | **Repository split**, `:model` → `:factory`, the release project, the extended boundary guard | **build** (T1) | DSL 6–7 | the release definitions in `beam/mix.exs`, `ATLAS_ROLE` |
| S5 | Instance id and stage | design only, not scheduled | S4 | the `test`/`prod`-only checks |
| S6 | T0 dev release with `AtlasFacts.Rela.Local` (headless, SQLite) | design only, not scheduled | S4; a released headless rela | the manual separate rela start for dev |
| S7 | TLS link with installation certificates (cutover of every link) | design only, not scheduled | S4 | the `hello` token, `ATLAS_BUS_LINK_TOKEN`, the keychain token items |
| S8 | Enrolment, renewal, revocation | design only, not scheduled | S7 | — |
| S9 | Client identity from the certificate | design only, not scheduled | S7, S8 | `tui_user` |
| S10 | Peer link and replication (`share`/`home`) | design only, not scheduled | S5, S7; DSL 6 + a new construct | — |
| S11 | Per-tenant server cores and router | design only, not scheduled | S10 | — |
| S12 | Laptop release, signed updates, migrations per installation | design only, not scheduled | S6, S10, S11 | — |
| S13 | Federated nodes: sandbox, held output, owner release, open protocol | design only, not scheduled | S10, S12 | — |

**rela headless.** The switch to headless rela (§6.2) has no slice of its own here. It happens when #2199 is released, and from then on E1's backups and checks work on held SQLite copies.

## 10. Open questions for the user

These are undecided. Each one gives the architect's recommendation for the user to accept or reject.

1. **Which keeps the name "Atlas": the platform or the factory?** Recommendation: the platform keeps the `atlas_` code names, and the factory becomes `:factory` in code.
2. **Whose model-vendor account do laptop agents use (T2)?** Recommendation: the person's own login, as with D-0037's people-owned Runtimes. A paid relay would be a separate server-side effect receiver.
3. **May sync pause until a laptop upgrades, with no version window (T2)?** Recommendation: yes, because a version window means translating between schemas, which is a second path.
4. **When does the factory take the TLS link cutover (S7)?** Recommendation: only when T2 is scheduled. Until then, keep tokens over WireGuard.
