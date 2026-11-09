# Capacity and lifecycle on current develop

The private S0/S9 contribution uses existing slots, independently of enrollment.
The core's `capacity.pool` names existing dev1–dev6 workers and their exact machine,
backend and model bindings. It does not provision workers or activate scheduling.
Capacity owners are supported for ownership turns; passes still require enrollment.

Capacity reconstructs reservations from Facts and selects waiting work in state-entry
order, then key order. Control's Workers page shows the waiting order and reason, or
reports capacity unavailable when the queue cannot be read. Manual ownership stays
manual. A different-vendor requirement waits when predecessor evidence or a fitting
vendor is unavailable.

Each allocation gets a fresh durable pick. Retries reuse identity only within that
allocation. Facts checks the live run, generation, entry, attempt, worker, backend,
model and machine before execution starts. Item-wide fences include manual work and
work owned by another Engine. A stop request, lost reporter or expired lease cannot
establish quiescence; unknown executions retain reservations.

Standalone, itemless turns reserve their worker too. Lifecycle writes compare both
the exact attempt and the explicitly absent pick. Refused completion stays retained
and nonrenewing until stored. A running Turn retries completion without launching
another adapter; an itemless reporter retries on an explicit repeated end while its
process lives. Neither path promises durable local completion replay after Runtime loss.

The issue's existing author flow lives in `Model.Delivery`. Its capacity owner and
the pull request's capacity owners have explicit entry-preserving migrations from
current develop. Prior migration chains remain available. Code's approved-revision
integrate effect, blocked/retry behavior, settlement, recovery, S14 follow-through,
ToDo and explicit restart behavior remain part of the current model. Global Flow,
DSL and generated outputs must be reconciled with these contracts; generated targets
come from the current `mix model.gen` generator.

Private deterministic proofs use the real model, Bus, Facts and private disk store,
with synthetic execution ports. They establish no live Rela, native provider,
distributed-store, activation or production-readiness proof. The Native #151 permission
gate remains open. D0091 applies only to its frozen Rela packet89334298.
