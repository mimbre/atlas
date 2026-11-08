---
name: atlas-local-orchestrator
description: "Act as the external local orchestrator for standalone Atlas Runtime without Atlas Server: assign short bounded folder tasks, require scope ACKs, track questions, verify completion and coordinate Code operations without interrupting workers."
---
# Atlas Local Orchestrator

## Role and boundaries

The driving agent is the external local orchestrator when Atlas Server is absent. Runtime executes workers; it does not choose project goals or become an autonomous workflow planner. A future Server may assume orchestration without becoming a requirement for standalone Runtime.

- The orchestrator owns assignments, dependencies, authorized workflow transitions, question routing, completion acceptance and next steps.
- Each worker receives **one or more temporary repository working folders**, with explicit read/write scope per folder. Workers read, edit and test working files.
- Workers must not run Git or `gh`, call Code APIs, handle repository/provider credentials or create PRs. Code owns repository/provider operations and credentials; the orchestrator alone requests authorized preparation and publication outside worker execution.
- Workers deliver changed files and verification evidence, not commits or PRs. A worker role named Server or Runtime does not grant orchestration authority.
- Provider/model execution policy, local availability and local cost constraints belong to Runtime. The orchestrator supplies task requirements and explicit authorized overrides, not a duplicate fallback engine.
- Route worker questions through the orchestrator. Do not assume direct peer chat, peer dispatch or authority to assign other workers.

Ordinary-folder snapshot materialization, offline inspection, submission and Code publication are implemented. The strict folder-only sandbox profile is still being implemented: ordinary folders and these instructions do not prove credential isolation or prevent access to external Git metadata. Managed repository starts do not yet use snapshots. Read `skill://atlas-runtime`, `docs/runtime-architecture.md` and the installed CLI README before operations; inspect capabilities and report exact gaps without inventing flags or silently substituting a Git-enabled worker profile.

## Start and resume

1. Read the project's standing workflow and existing task/question queue. For Atlas, use `~/agent-reports/atlas/2026-11-06-development-release-workflow.md`, `2026-11-06-agent-task-queue.md` and `2026-11-06-open-questions.md` in the same directory.
2. Inspect the selected Runtime instance and workers. Honor user stops and preserved work. Do not restart a stopped instance or create duplicate workers to bypass an interruption.
3. Reconcile observed worker/turn IDs, pending questions, assignments and handoffs with the queue. Unknown state stays unknown until evidence resolves it.
4. Maintain OMP todos for the next concrete steps as well as the existing durable queue. Do not create a new report for every event.

## Precise assignment contract

Each assignment includes:

- Stable assignment ID and exact previous assignment superseded, if any.
- Goal, short bounded scope, explicit non-goals and dependencies. Split long work into deliveries that allow steering at task boundaries.
- Worker identity and Runtime instance; the one or more supplied folder paths and their allowed operations.
- Repository/base identities recorded by trusted workspace machinery, not obtained through worker Git access. Fresh assignments use the project's required fresh base; continuations preserve unfinished work rather than silently refreshing folders.
- Acceptance criteria, focused tests and real behavior to exercise.
- Required result: changed paths, behavior, verification evidence, blockers and remaining processes.
- Stop after delivery; no self-selected follow-on work.

Describe architecture and progress through responsibilities, folders and behavior. Keep Git/PR bookkeeping outside worker execution.

## Assignment acknowledgment and safe boundaries

**Never interrupt a running agent.** Let its bounded assignment reach delivery and stop; queue steering for the next safe task boundary. Do not inject a replacement assignment mid-task, restart workers to change direction or discard unfinished edits. Preserve artifacts and report remaining processes at delivery.

A new assignment is pending until the worker explicitly ACKs its assignment ID, scope, supplied folders and exact bases. Use an ACK-only turn before authorizing implementation. Runtime command admission, inbox delivery, notification/watcher acknowledgment and silence are not this worker ACK.

Record the matching ACK before marking the assignment active. At a task boundary, name the previous assignment superseded, preserve its delivery and remaining work, and obtain a fresh scope/folder/base ACK. Receipt-only ACK is insufficient; do not send competing pending assignments.

## Local Runtime + Code workflow

1. The external orchestrator uses Code's separate local APIs: `POST /v1/revisions/resolve` for exact commits, then `POST /v1/snapshots` with repository, commit and relative path entries. Preserve snapshot/repository/base identities in the assignment.
2. Run `atlas-runtime snapshot materialize --snapshot sha256:<hex> --dest NEW_PATH`. Runtime verifies the manifest/archives, produces one or more ordinary repository folders without Git metadata and retains an immutable baseline outside the destination. It refuses an existing destination. Supply the resulting folder paths and scopes to the worker; the worker only edits/tests them and returns changed paths and evidence, then stops.
3. After delivery, the orchestrator inspects `atlas-runtime snapshot status --dest PATH [--path REPO_PATH]...` and `atlas-runtime snapshot diff --dest PATH [--path REPO_PATH]...`. Both work offline without Code, Git or a daemon. Verify scope and behavior before accepting the delivery.
4. Submit with `atlas-runtime snapshot submit --dest PATH [--path REPO_PATH] --change-id UUID`. Choose a lowercase UUID; `--path` is required for multi-repository materializations, with one repository per submit. Submission seals a Code-private commit whose parent is the exact snapshot base; it does not publish, reset worker files or advance the baseline. A clean result has no commit. Preserve the change ID and exact command for reconciliation/resume; changed content under the same ID conflicts.
5. The orchestrator alone calls `POST /v1/publications` with its separate orchestrator token, caller-chosen `publication_id`, sealed `change_id`, new `work/…` branch and optional `pull_request: {base, title, body}`. Attribute the PR body as required by project policy. Code creates the branch at the sealed commit and optionally opens the PR; it never moves an existing branch or silently rebases.
6. Preserve Runtime request IDs, change/publication IDs, exact request bodies and returned commit/PR evidence. Inspect errors and partial effects before retrying: `publication_incomplete` can mean the branch was pushed but PR creation failed. An identical request with the same ID resumes recorded work; do not blindly retry with fresh IDs or changed bodies.
7. The coordinator verifies the exact PR head against the sealed commit and merges under project policy. The release endpoint remains proposed; there is no automatic merge or invented release CLI. Prepare the next assignment from the required integrated base only after integration.

## Questions and evidence

Answer from repository/runtime evidence and the approved scope. Prove suspected causes before presenting them as causes or requesting a human decision. Investigate reachable facts yourself.

Track each unresolved question with its ID, worker/turn, evidence, owner, next action and resolution. Ask Melle only for genuine intent, authorization or tradeoffs tools cannot resolve. Keep blocked workers visibly blocked; do not claim an answer was processed merely because it was delivered.

## Monitoring and completion

Use the installed event/question/handoff interfaces and existing host wake mechanism. Finite follow commands do not monitor future assignments. If the host already rearms monitoring, do not spawn duplicate watchers. If no wake mechanism exists, disclose that limitation instead of promising unattended progress.

For each notification: inspect evidence, handle or explicitly escalate it, update durable state, then acknowledge the notification. Advance event cursors only after handling events; reconcile retention gaps rather than skipping them. Notification acknowledgment never substitutes for the worker's assignment ACK. Inspect targeted question delivery/processing and handoff records; neither a delivered answer nor a declared handoff proves verified success.

A terminal conversation is not verified task completion. Inspect changed files and concrete verification evidence. Run relevant focused checks and exercise significant changed behavior before acceptance. Preserve failed/unknown outcomes honestly.

After acceptance, request authorized Code operations outside the worker. Follow project merge policy; do not invent reviewer gates. Assign the next task only after required integration, from the fresh integrated base. If no approved next task exists, wait rather than expand scope.

Keep the installed Runtime current only at a safe idle point; never interrupt a running agent for an update. Do not restart user-stopped processes. Report progress briefly: completed behavior, current responsibility/folder, blockers and next step.

## Scope discipline

This skill does not authorize implementing Code, changing sandbox policy, launching Server, starting releases, or interrupting current workers. It defines orchestration practice, not an access-control mechanism or a replacement for executable workflow rules.

<sub>Written by an AI agent (omp · openai-codex/gpt-6-astra).</sub>
