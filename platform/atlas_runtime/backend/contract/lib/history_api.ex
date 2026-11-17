defmodule AtlasRuntimeBackend.History do
  @moduledoc """
  The Runtime's backend for the history contract (design 2026-11-16-runtime-backend §8,
  §13 S2, §13.1 Q1, Q2, Q4): how `AtlasRuntimeBoundary.History` is carried to clients in
  other processes. It decides nothing about history; every decision sits behind the
  boundary.

  Both history capabilities are exposed, one resource each (§1.8). A client on the Unix
  socket (`$ATLAS_RUNTIME_HOME/backend.sock`, §8.1) is its owner and gets `read` and
  `read_all`, as for work. It is served by the same router as the work and operations
  contracts (`AtlasRuntimeBackend.Generator.Targets.Rest`, `contracts:`), so a missing
  right is 403 `not-permitted` and an input that does not validate is 400 `invalid`, as
  there. `GET /v1/turns/{turn_id}` and work's `GET /v1/turns/{turn_id}/output` have
  different segment counts, so they do not overlap.

  Declarations only. The generator (`AtlasRuntimeBackend.Generator.Schema`) turns them into
  `__schema__/0`, which its targets read.
  """
  use AtlasRuntimeBackend.Generator.Schema

  version "0.1.0"
  boundary AtlasRuntimeBoundary.History

  expose [:list_turns, :get_turn]

  ## Listeners (§8.1, Q2, Q4)

  # The socket owner, as local:<user>: it reads all history, also the turns of no work.
  rights :socket, [:read, :read_all]

  target :rest, carries: :entities do
    ## Resources (§8.2)

    resource :get, "/v1/turns",
      capability: :list_turns,
      query: [slot: :slot, since: :since, cursor: :cursor, limit: :limit]

    resource :get, "/v1/turns/:turn_id", capability: :get_turn

    ## Status codes: the body of a success is the outcome's fields; every error is
    ## application/problem+json with a type.

    # One page of turn summaries, with its cursor and more.
    status :turns, 200
    status :found, 200
    # No such turn visible to the caller.
    status :not_found, 404, type: "not-found"

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
  end
end
