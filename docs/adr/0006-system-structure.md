# 0006: Autonomous systems: model, boundary and backend

Status: proposed, 2026-11-16 (decisions: Melle, in the Runtime design discussion and the brief for this record). The working design is `~/agent-reports/atlas/2026-11-16-runtime-backend.md`, outside the repository; its §0 records these decisions with their source. This record extends ADR 0001 (generator, contract and targets) from Control's BFF to every system.

## Context

Atlas consists of systems: Flow, Facts, Control, Runtime, Code, Gates and Learn. Whether the Bus is a system in this sense is not covered by this record.

The systems' interfaces grew in different ways:
- Control has a declared BFF contract (ADR 0001).
- The Runtime is reached through several channels: a JSON-lines socket, a read socket, a turn mirror that writes Facts, and Flow passes over the Bus. None of these is declared in one place.

The same words also mean slightly different things in different systems. An "assignment" in Flow is not "work" in the Runtime, and a "turn" in Facts is not the Runtime's turn record. That difference is why each system exists, so it should not be flattened into one model.

Designing the Runtime as a backend that any client (Flow, CLI, TUI, scripts) can use made the missing rules visible.

## Decision

1. **Systems are autonomous.**
   - Each system owns its vocabulary, its boundary contracts and its storage. There is no shared data model.
   - Crossing a boundary is a translation. Entities that two systems both care about are synced explicitly at the boundary, with stable IDs and contract tests.
   - Facts is the only Rela client.

2. **Every system has the same shape.**
   - It has a `model/` (private entities and how they are stored), a `boundary/` (the public interface), and optionally a `backend/` (remote access; a system that has one is a backend).
   - Each part is an *intent folder*, named after its intent, containing exactly `generator/`, `contract/` and `targets/`.
   - A `boundary/` may hold several contracts with distinct purposes, all in the system's own vocabulary.
   - Targets are generated and never edited by hand. Hand-written code implements behaviour only.

3. **Dependencies point inward: `backend → boundary → model`.**
   - `model` knows nothing outside itself.
   - `boundary` owns the translations between model entities and boundary entities.
   - `backend` uses `boundary` only.
   - A public contract never references the private model, so clients never compile against it.

4. **The boundary contract is spec-based and contract-first.**
   - It is declared once, and its targets are generated (ADR 0001's rules apply).
   - It is agnostic of the outside world: no transport, serialization, authentication or client types.
   - Its generated Elixir target serves both directions:
     - a facade, which is the only entry point;
     - a behaviour, which the system must implement for every capability, with exact types.
   - A missing capability, or one with the wrong arity, fails compilation. Wrong values and undeclared outcomes are refused by the facade when it is called.
   - Boundary entities are plain generated structs. No Ecto type crosses the boundary, and private entities never cross it either.
   - A contract carries a version only where it needs one.

5. **Co-located systems call each other in-process.**
   - Two systems in the same BEAM call each other's generated boundary Elixir target, never each other's internals.
   - Being co-located removes the network, not the boundary.
   - A backend is added only where remote access is needed.

6. **Contracts can have several targets.**
   - A boundary may have several targets, for example entities (plain structs) and blocks (presentation). The entity → block translation is declared once, in the boundary.
   - A backend may have several targets, for example `rest`, `console_bff`, `mobile_bff` or `socket`. Each one chooses which boundary target it carries.
   - A BFF is a backend target shaped around one client's experience, named for that client. It is added only when a real client needs it.
   - If a system has a backend, every boundary target must be carried by at least one backend target. The backend generator refuses a contract where one isn't.

7. **Adoption is gradual.**
   - The Runtime adopts this first, in its slice 1: `model/`, `boundary/` and a `backend/` with a `rest` target.
   - Other systems adopt it when they are next changed, with no separate refactor now.
   - Control follows later, in two steps:
     1. a mechanical rename, in which `bff/` becomes `backend/` with a `console_bff`-style target;
     2. separately, a non-mechanical change that moves its view shaping into a block target of its boundary.

## Alternatives considered

- **One shared data model for all systems.** Rejected. It erases the vocabulary differences that justify separate systems, and it couples every system to every schema change.
- **One shared generator for all intent folders.** Not now. Each intent folder carries its own generator, and duplication is accepted. Whether to merge the copies can be reconsidered once the type model is stable.
- **A separate BFF per client as its own layer.** Rejected. A BFF is a target of the backend contract, over the same exposure. It is not a separate system or contract.

## Consequences

- Each system's interface is visible from its folder tree. Its shape (capabilities and their arity, exposure, carried targets) is checked at compile time.
- Translations are generated from declarations and live at the boundary. There is more code at the edges, and none of it is hidden coupling.
- Generators are duplicated for now. A later ADR can merge them.
- Moving an existing system takes work. The Runtime goes first; other systems move when they are next changed, and their existing interfaces stay until then.
- Two statements in the README no longer hold in general, and will be updated separately:
  - that the Bus is the only way the parts talk to each other. Co-located systems now call each other's boundary target, and remote clients call a backend.
  - that Control is the one interface for clients. The Runtime's backend is called by clients directly.
- ADR 0001's paths were amended to `platform/atlas_control/backend/…` with Control's rename.

<sub>Written by an AI agent (omp · claude-opus-5-5, RuntimeBffDesigner).</sub>
