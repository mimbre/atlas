defmodule AtlasRuntimeBackend.Operations do
  @moduledoc """
  The Runtime's backend for the operations contract (design 2026-11-16-runtime-backend §8,
  §13 S2, §13.1 Q4, Q11, Q12): how `AtlasRuntimeBoundary.Operations` is carried to the
  machine's operator. It decides nothing about the Runtime; every decision sits behind the
  boundary.

  All eight operations capabilities are exposed, one resource each (§1.8), so the
  "`/v1/control`" of §8.2 is the `/v1/control/<action>` family. Only the Unix socket
  (`$ATLAS_RUNTIME_HOME/backend.sock`, §8.1) grants `inspect` and `operate`: its client
  is the machine's own operator (Q4). It is served by the same router as the work contract
  (`AtlasRuntimeBackend.Generator.Targets.Rest`, `contracts:`), which answers the
  facade's refusals alike for both: a missing right is 403 `not-permitted`, an input that
  does not validate is 400 `invalid`.

  Declarations only. The generator (`AtlasRuntimeBackend.Generator.Schema`) turns them into
  `__schema__/0`, which its targets read.
  """
  use AtlasRuntimeBackend.Generator.Schema

  version "0.1.0"
  boundary AtlasRuntimeBoundary.Operations

  expose [
    :runtime_info,
    :policy,
    :pause,
    :resume,
    :drain,
    :stop,
    :release_slot,
    :clear_quota_mark
  ]

  ## Listeners (§8.1, Q4)

  # The socket owner, as local:<user>: the machine's own operator. Only this listener has
  # operate, also after S3.
  rights :socket, [:inspect, :operate]

  target :rest, carries: :entities do
    ## Resources (§8.2, Q12)

    resource :get, "/v1/runtime", capability: :runtime_info
    resource :get, "/v1/policy", capability: :policy
    resource :post, "/v1/control/pause", capability: :pause
    resource :post, "/v1/control/resume", capability: :resume
    resource :post, "/v1/control/drain", capability: :drain
    resource :post, "/v1/control/stop", capability: :stop, body: [:force]
    resource :post, "/v1/slots/:slot/release", capability: :release_slot

    resource :post, "/v1/harnesses/:harness/clear-quota-mark", capability: :clear_quota_mark

    ## Status codes (Q12): the body of a success is the outcome's fields; every error is
    ## application/problem+json with a type.

    # Runtime info: on GET /v1/runtime, and after pause, resume and drain (also when the
    # Runtime is already in that mode).
    status :runtime_info, 200
    status :policy, 200
    # Accepted: the Runtime stops after answering; backend.sock disappearing confirms it.
    status :stopping, 202
    # Also when the slot had nothing to release.
    status :released, 200

    status :refused,
      by: :reason,
      cases: [slot_busy: {409, "slot-busy"}, invalid: {400, "invalid"}]

    # No such slot, or no such harness.
    status :not_found, 404, type: "not-found"
    status :cleared, 200

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
  end
end
