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

  There is no `put_blob` route (0.4.0, IS-Atlas-100): a result travels over Git, pushed to
  the source's Code under the work's `result_ref`, never uploaded as blobs.

  Declarations only. The generator
  (`AtlasRuntimeBackend.Generator.Schema`) turns the declarations into `__schema__/0`,
  which its targets read.
  """
  use AtlasRuntimeBackend.Generator.Schema

  # 0.2.0: put_blob is carried (an added route; nothing earlier changed). 0.3.0: the poll
  # body may carry configuration_refused (boundary 0.4.0, IS-Atlas-27), sent only when the
  # Runtime has a refusal to report, so a 0.2.0 source never receives it. 0.4.0: put_blob is
  # gone (boundary 0.5.0, IS-Atlas-100); a 0.3.0 Runtime calls it only for blobs a source
  # names as missing, and a 0.4.0 source names none.
  version "0.4.0"
  boundary AtlasRuntimeBoundary.WorkSource

  expose [:poll, :report, :get_blob]

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
        conflict: {409, "revision-conflict"}
      ]

    error :invalid, 400, type: "invalid"
    error :not_permitted, 403, type: "not-permitted"
    error :no_route, 404, type: "no-route"
    # The listener's refusal before the router runs: no valid credential.
    error :unauthenticated, 401, type: "unauthenticated"
    # A body past the source's limit, before the source reads it.
    error :too_large, 413, type: "too-large"
  end
end
