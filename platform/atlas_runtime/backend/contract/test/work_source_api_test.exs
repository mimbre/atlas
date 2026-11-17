defmodule AtlasRuntimeBackend.WorkSourceTest do
  use ExUnit.Case, async: true

  # Decision 2026-11-17-work-acquisition §5, M1: the work source contract over HTTP. A
  # Runtime is the client; a source serves the routes.

  @schema AtlasRuntimeBackend.WorkSource.__schema__()
  @rest hd(@schema.targets)
  @dir Path.expand("../../targets/rest/work_source_api", __DIR__)

  test "carries the work source boundary; put_blob waits for streamed request bodies" do
    assert @schema.boundary == AtlasRuntimeBoundary.WorkSource
    assert @schema.exposed == [:poll, :report, :get_blob]
    assert @schema.not_exposed == [:put_blob]
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
              [:runtime_id, :incarnation, :build, :policy_version, :offer, :holdings]},
             {:post, "/v1/leases/:lease_id/reports", :report, [:revision, :report]},
             {:get, "/v1/leases/:lease_id/blobs/:sha256", :get_blob, nil}
           ]

    statuses = Map.new(@rest.statuses, &{&1.outcome, &1})
    assert %{status: 410, type: "lease-lost"} = statuses.lease_lost

    assert %{status: 200, stream: :content, content_type: "application/octet-stream"} =
             statuses.blob

    assert @rest.streams == []
  end

  test "routes.json is generated for implementers; no OpenAPI yet (deferred, §5)" do
    routes = @dir |> Path.join("routes.json") |> File.read!() |> JSON.decode!()
    assert routes["x-comment"] =~ "backend/contract/lib/work_source_api.ex"
    assert Enum.map(routes["routes"], & &1["capability"]) == ["poll", "report", "get_blob"]
    refute File.exists?(Path.join(@dir, "openapi.json"))
  end
end
