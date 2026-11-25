defmodule AtlasRuntimeBackend.WorkSourceTest do
  use ExUnit.Case, async: true

  # Decision 2026-11-17-work-acquisition §5, M1: the work source contract over HTTP. A
  # Runtime is the client; a source serves the routes.

  @schema AtlasRuntimeBackend.WorkSource.__schema__()
  @rest hd(@schema.targets)
  @dir Path.expand("../../targets/rest/work_source_api", __DIR__)

  test "carries the work source boundary, every capability exposed" do
    assert @schema.boundary == AtlasRuntimeBoundary.WorkSource
    assert @schema.exposed == [:poll, :report, :get_blob, :put_blob]
    assert @schema.not_exposed == []
    assert Version.compare(@schema.version, "0.2.0") != :lt
    assert [%{name: :rest, carries: :entities}] = @schema.targets
  end

  test "one listener, the source's: a per-Runtime credential holds lease and nothing else" do
    assert @schema.rights == [%{listener: :runtime, rights: [:lease]}]
    assert Enum.find(@rest.errors, &(&1.kind == :unauthenticated)).status == 401
    refute Enum.any?(@rest.errors, &(&1.kind == :origin_refused))
  end

  test "the resources, and lease_lost as 410 lease-lost" do
    assert for(r <- @rest.resources, do: {r.method, r.path, r.capability, r.body}) == [
             {:post, "/v1/poll", :poll,
              [
                :runtime_id,
                :incarnation,
                :build,
                :policy_version,
                :offer,
                :holdings,
                :configuration_refused
              ]},
             {:post, "/v1/leases/:lease_id/reports", :report, [:revision, :report]},
             {:get, "/v1/leases/:lease_id/blobs/:sha256", :get_blob, nil},
             {:put, "/v1/leases/:lease_id/blobs/:sha256", :put_blob, nil}
           ]

    statuses = Map.new(@rest.statuses, &{&1.outcome, &1})
    assert %{status: 410, type: "lease-lost"} = statuses.lease_lost

    assert %{status: 200, stream: :content, content_type: "application/octet-stream"} =
             statuses.blob

    assert @rest.streams == []
  end

  # M3 plan §9 Q2: the source serves put_blob; the bytes are the body, streamed, and the
  # declared size is the Blob-Size header, so a source can refuse before reading.
  test "put_blob: a streamed octet-stream body with Blob-Size, sha256 and lease in the path" do
    put = Enum.find(@rest.resources, &(&1.capability == :put_blob))
    assert put.params == [:lease_id, :sha256]
    assert put.headers == [{"blob-size", :size}]
    assert put.query == []

    assert %{field: :content, content_type: "application/octet-stream", max_bytes: {m, f}} =
             put.upload

    assert is_integer(apply(m, f, [])) and apply(m, f, []) > 0

    statuses = Map.new(@rest.statuses, &{&1.outcome, &1})
    assert %{status: 200, type: nil} = statuses.stored
    assert %{status: 409, type: "not-referenced"} = statuses.not_referenced
    assert %{status: 413, type: "too-large"} = statuses.too_large
    assert %{by: :reason} = rejected = statuses.rejected
    assert %{status: 422} = Enum.find(rejected.cases, &(&1.value == :digest_mismatch))

    # A body refused before it is read answers as the outcome too_large does.
    errors = Map.new(@rest.errors, &{&1.kind, &1})

    assert Map.take(errors.too_large, [:status, :type]) ==
             Map.take(statuses.too_large, [:status, :type])

    assert errors.unsupported_media_type.status == 415
  end

  test "routes.json is generated for implementers; no OpenAPI yet (deferred, §5)" do
    routes = @dir |> Path.join("routes.json") |> File.read!() |> JSON.decode!()
    assert routes["x-comment"] =~ "backend/contract/lib/work_source_api.ex"
    assert routes["version"] == @schema.version

    assert Enum.map(routes["routes"], & &1["capability"]) ==
             ["poll", "report", "get_blob", "put_blob"]

    put = Enum.find(routes["routes"], &(&1["capability"] == "put_blob"))
    assert put["method"] == "PUT"
    assert put["path"] == "/v1/leases/{lease_id}/blobs/{sha256}"
    assert put["headers"] == %{"blob-size" => %{"field" => "size", "required" => true}}
    assert put["upload"]["field"] == "content"
    assert put["upload"]["content_type"] == "application/octet-stream"
    refute File.exists?(Path.join(@dir, "openapi.json"))
  end
end
