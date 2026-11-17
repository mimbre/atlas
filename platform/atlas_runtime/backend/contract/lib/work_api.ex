defmodule AtlasRuntimeBackend.Work do
  @moduledoc """
  The Runtime's backend for the work contract (design 2026-11-16-runtime-backend §8, slice
  S1): how `AtlasRuntimeBoundary.Work` is carried to clients in other processes. It
  decides nothing about work; every decision sits behind the boundary.

  Shared by every target: the nine S1 work capabilities are exposed (S5a's `get_frozen` and
  `get_frozen_blob` are not yet); a client on the Unix
  socket (`$ATLAS_RUNTIME_HOME/backend.sock`, §8.1) is its owner and gets every work right,
  `choose_slot` included; the notifications are the stream's events. The one target in S1
  is `rest` (§8.2–§8.4), carrying the boundary's entities.

  S3 adds the loopback TCP listener's rights ceiling (§8.1: a token's rights are cut to
  it; never `choose_slot`) and its refusals before the router runs: 401
  `unauthenticated` and 403 `origin-refused`. Still to come in S3: `ETag` and
  `If-None-Match` on `GET /v1/work/{id}`, `Idempotent-Replayed` on `existing` (a plain 200
  here), and the route description and OpenAPI files.

  Declarations only. The generator (`AtlasRuntimeBackend.Generator.Schema`) turns them into
  `__schema__/0`, which its targets read.
  """
  use AtlasRuntimeBackend.Generator.Schema

  version "0.1.0"
  boundary AtlasRuntimeBoundary.Work

  expose [
    :submit,
    :retry,
    :cancel,
    :get_work,
    :find_work,
    :list_work,
    :capacity,
    :turn_output,
    :subscribe
  ]

  # S5a: the frozen-result reads are in the boundary before their resources exist; S5a P11
  # exposes them (§8.2: GET …/attempts/{n}/frozen and …/frozen/blobs/{sha256}).
  not_exposed [:get_frozen, :get_frozen_blob]

  ## Listeners (§8.1)

  # The socket owner, as local:<user>. Agents cannot reach the socket (I8).
  rights :socket, [:submit, :cancel, :read, :read_all, :choose_slot]

  # Loopback TCP behind the reachability path (§8.1, §9): a client is its Bearer token, and
  # its token's rights are cut to this ceiling. Never choose_slot: naming a slot is for the
  # socket only.
  rights :tcp, [:submit, :cancel, :read, :read_all]

  ## Events (§3.6, §8.4): the change sequence is the event id.

  event :work, :work_changed, id: :sequence
  event :capacity, :capacity_available, id: :sequence
  event :heartbeat, :heartbeat
  event :reset, :reset, id: :current_sequence

  target :rest, carries: :entities do
    ## Resources (§8.2)

    # The Idempotency-Key header carries the client key; the body is the rest of the request.
    resource :post, "/v1/work",
      capability: :submit,
      body: :input,
      header: ["Idempotency-Key": :client_key]

    resource :get, "/v1/work/:work_id", capability: :get_work
    resource :get, "/v1/work", capability: :find_work, query: [key: :client_key]

    resource :get, "/v1/work",
      capability: :list_work,
      query: [state: :state, changed_since: :changed_since]

    resource :post, "/v1/work/:work_id/attempts", capability: :retry, body: [:resume]
    # Not DELETE: the record stays.
    resource :post, "/v1/work/:work_id/cancel", capability: :cancel, body: [:mode, :reason]
    resource :get, "/v1/capacity", capability: :capacity
    resource :get, "/v1/turns/:turn_id/output", capability: :turn_output, query: [cursor: :cursor]

    # Server-Sent Events (§8.4): resume with Last-Event-ID; outside the window, or from
    # another incarnation, the stream opens with reset.
    stream "/v1/events",
      capability: :subscribe,
      events: [:work, :capacity, :heartbeat, :reset],
      resume_header: "Last-Event-ID",
      into: :from,
      open: [subscribed: nil, reset: :reset]

    ## Status codes (§8.3): every error body is application/problem+json with a type. A
    ## success body is the outcome's entity, serialized directly (body:), with no envelope;
    ## cancelling gives the work, whose current attempt's cancel_stage holds the stage.

    status :accepted, 201, body: :work, header: [location: "/v1/work/{work.work_id}"]
    status :existing, 200, body: :work
    # 503 for capacity, never for the request rate (D21); the only 503.
    status :at_capacity, 503, type: "at-capacity", header: ["Retry-After": :retry_after]

    status :refused,
      by: :reason,
      cases: [
        not_permitted: {403, "not-permitted"},
        conflict: {409, "idempotency-conflict"},
        invalid: {400, "invalid"},
        unsupported_workspace: {422, "unsupported-workspace"},
        policy_forbids: {422, "policy-forbids"},
        no_permitted_option: {422, "no-permitted-option"},
        resume_unavailable: {422, "resume-unavailable"}
      ]

    status :pruned, 410, type: "pruned"
    # Never seen.
    status :not_found, 404, type: "not-found"
    status :cancelling, 202, body: :work
    status :ended, 200, body: :work
    status :found, 200, body: :work
    status :works, 200
    # works (with its sequence), capacity and page are the entities themselves.
    # Retry-After when no new work can be taken.
    status :capacity, 200, header: ["Retry-After": :retry_after]
    status :page, 200

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"

    # The TCP listener's refusals before the router runs (§8.1, §8.3), sent with the
    # router's __problem__/2: a missing, malformed, unknown or disabled token, and any
    # request with an Origin header.
    error :unauthenticated, 401, type: "unauthenticated"
    error :origin_refused, 403, type: "origin-refused"
  end
end
