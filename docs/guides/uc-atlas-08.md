# Breakdown in one turn (UC-Atlas-08, IS-Atlas-19)

An agent keeps its scene while its running turn breaks it down. Creating the first
child updates Expected immediately. Flow saves the deferred handover in Facts and
applies it after Runtime records the turn's end. Restarting Flow loses no handover.
Runtime treats a nonempty description-defined handover field as a barrier to a new
turn, while retaining the existing turn's ownership and authority. Only Flow clears
that barrier, by transferring ownership or cancelling the pending move. Runtime snapshots
local processes and turns before ownership so an old ownership reply cannot be paired
with a newer ended turn to bypass a handover saved between those reads (IS-Atlas-123). A normal end,
crash, silence or restart therefore cannot repeatedly replace the old owner's turn
and starve the transfer. Without a pending handover, same-owner continuation remains.
A later human assignment cancels that deferred move and Runtime stops the old turn.

The agent uses Control, just like other clients:

```sh
ATLAS_AS=breaker atlas turn --env test
ATLAS_AS=breaker atlas put use_case --in SC-Atlas-01 --title 'First part' --env test
ATLAS_AS=breaker atlas put issue --in UC-Atlas-01 --title 'Build the part' --env test
ATLAS_AS=breaker atlas turn end 'Created both use cases and their issues' --env test
```

Use generated keys returned by the commands. `atlas turn --json` includes the turn's
key, its original item rather than its Assignment, and that item's page and instructions.
`turn end` records an outcome fact as the agent. Runtime alone sets lifecycle fields.
Control requires a single running turn still owned by that agent, a matching turn key,
and nonempty text. It refuses replacement of a different outcome.

For a sandboxed port, explicitly include `put turn` in the agent's local `allowed`
setting alongside its other commands. The existing restricted default stays in place;
this change does not start a model or grant commands to deployed agents.

The private stub test is `bin/atlas-dev e2e uc-atlas-08`. It creates two use cases and an issue
under each before ending the turn, sees both in the TUI, checks the outcome and subsequent
handover to the coordinator without a replacement turn, and checks a human cancellation
of a second turn. The file
runs after the shared ownership scenarios because introducing their coordinator earlier
would change those scenarios' initial fixtures.

The description names `runtime.turn.outcome` and each flow's `handover_field`; the engines
name no entity. Deferred handover records are internal Flow data and hidden from pages.
The outcome and handover properties are additive schema changes. Delivery must follow
the normal backup-before-pull and description rollout rules. No prod migration or
activation has been performed by this implementation.

<sub>Written by an AI agent (Codex · GPT-6, herdr-projects atlas · t-0027).</sub>
