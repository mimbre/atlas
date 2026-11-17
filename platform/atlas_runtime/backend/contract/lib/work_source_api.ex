defmodule AtlasRuntimeBackend.WorkSource do
  @moduledoc """
  How the work source contract (`AtlasRuntimeBoundary.WorkSource`, decision
  2026-11-17-work-acquisition §5, M1) is carried over HTTP between a Runtime and a remote
  work source. The direction is the reverse of the Runtime's other backend contracts: the
  source serves these routes (Flow's work source server, M3), and the Runtime is the
  client, through the compile-time `AtlasRuntimeBackend.Generator.Targets.Client` (the
  puller, M2). The Runtime has no listener for it. It decides nothing about work; every
  decision sits behind the source's boundary.

  One listener, the source's: TLS 1.3 at the URL a Runtime is configured with, where a
  Runtime is its per-Runtime credential (a bearer token, 401 `unauthenticated` without a
  valid one). A credential holds `lease` and nothing else.

  `mix runtime_backend.gen` describes the routes for implementers in other languages in
  `../targets/rest/work_source_api/routes.json`; together with the boundary's
  `work_source.json` that is what a source implements against. An OpenAPI document is
  deferred until a second implementer exists (§5).

  `put_blob` is declared by the boundary but not carried yet: its bytes are a streamed
  request body, which this generator does not carry yet (S5c P1/P2, #290/#293). Until
  then it is `not_exposed`, and the Runtime's in-BEAM callers reach it only through the
  boundary's facade.

  Declarations only. The generator (`AtlasRuntimeBackend.Generator.Schema`) turns them
  into `__schema__/0`, which its targets read.
  """
  use AtlasRuntimeBackend.Generator.Schema

  version "0.1.0"
  boundary AtlasRuntimeBoundary.WorkSource

  expose [:poll, :report, :get_blob]
  # A streamed request body (S5c P1/P2); carried once the generator carries one.
  not_exposed :put_blob

  ## Listener: the source's TLS listener, a client being its per-Runtime credential.

  rights :runtime, [:lease]

  target :rest, carries: :entities do
    ## Resources

    # A long-poll: the source answers early with a lease or a cancel, else at poll_max.
    resource :post, "/v1/poll", capability: :poll, body: :input
    # The lease is in the path; the body is the revision and the report.
    resource :post, "/v1/leases/:lease_id/reports", capability: :report, body: :input
    resource :get, "/v1/leases/:lease_id/blobs/:sha256", capability: :get_blob

    ## Status codes: every error body is application/problem+json with a type; a success
    ## body is the outcome's fields.

    status :polled, 200
    status :recorded, 200
    # The lease is not, or no longer, the work's current one: nothing was recorded.
    status :lease_lost, 410, type: "lease-lost"
    # Chunked; its sha256 and size go in headers, so the Runtime verifies as it reads.
    status :blob, 200,
      stream: :content,
      content_type: "application/octet-stream",
      header: ["Blob-Sha256": :sha256, "Blob-Size": :size]

    status :not_found, 404, type: "not-found"

    status :rejected,
      by: :reason,
      cases: [
        invalid: {400, "invalid"},
        conflict: {409, "revision-conflict"},
        digest_mismatch: {422, "digest-mismatch"}
      ]

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
    # The listener's refusal before the router runs: no valid credential.
    error :unauthenticated, 401, type: "unauthenticated"
  end
end
