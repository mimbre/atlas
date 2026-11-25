defmodule AtlasRuntimeBackend.WorkSourceTest do
  use ExUnit.Case, async: true

  # Decision 2026-11-17-work-acquisition §5, M1: the work source contract over HTTP. A
  # Runtime is the client; a source serves the routes.

  @schema AtlasRuntimeBackend.WorkSource.__schema__()
  @rest hd(@schema.targets)
  @dir Path.expand("../../targets/rest/work_source_api", __DIR__)

  test "carries the work source boundary, every capability exposed" do
    assert @schema.boundary == AtlasRuntimeBoundary.WorkSource
    assert @schema.exposed == [:poll, :report, :get_blob]
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
                :configuration_refused,
                :upgrade
              ]},
             {:post, "/v1/leases/:lease_id/reports", :report, [:revision, :report]},
             {:get, "/v1/leases/:lease_id/blobs/:sha256", :get_blob, nil}
           ]

    statuses = Map.new(@rest.statuses, &{&1.outcome, &1})
    assert %{status: 410, type: "lease-lost"} = statuses.lease_lost

    assert %{status: 200, stream: :content, content_type: "application/octet-stream"} =
             statuses.blob

    assert @rest.streams == []
  end

  # 0.4.0 (IS-Atlas-100): a result travels over Git; there is no upload of blobs.
  test "no put_blob: no upload route, none of its outcomes" do
    refute Enum.any?(@rest.resources, &(&1.method == :put))
    statuses = Map.new(@rest.statuses, &{&1.outcome, &1})

    for outcome <- [:stored, :not_referenced, :too_large],
        do: refute(Map.has_key?(statuses, outcome))

    assert Enum.map(statuses.rejected.cases, & &1.value) == [:invalid, :conflict]
    refute Enum.any?(@rest.errors, &(&1.kind == :unsupported_media_type))
    assert Version.compare(@schema.version, "0.4.0") != :lt
  end

  test "routes.json is generated for implementers; no OpenAPI yet (deferred, §5)" do
    routes = @dir |> Path.join("routes.json") |> File.read!() |> JSON.decode!()
    assert routes["x-comment"] =~ "backend/contract/lib/work_source_api.ex"
    assert routes["version"] == @schema.version

    assert Enum.map(routes["routes"], & &1["capability"]) == ["poll", "report", "get_blob"]
    refute File.exists?(Path.join(@dir, "openapi.json"))
  end
end
