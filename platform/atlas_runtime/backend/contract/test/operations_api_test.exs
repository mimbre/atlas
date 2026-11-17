defmodule AtlasRuntimeBackend.OperationsTest do
  use ExUnit.Case, async: true

  @schema AtlasRuntimeBackend.Operations.__schema__()
  @rest hd(@schema.targets)

  test "carries the operations boundary, exposing every capability" do
    assert @schema.boundary == AtlasRuntimeBoundary.Operations
    capabilities = for c <- AtlasRuntimeBoundary.Operations.__schema__().capabilities, do: c.name
    assert length(capabilities) == 8
    assert @schema.exposed == capabilities
    assert @schema.not_exposed == []
    assert [%{name: :rest, carries: :entities}] = @schema.targets
  end

  test "Q4: only the socket grants operate (and inspect)" do
    assert @schema.rights == [%{listener: :socket, rights: [:inspect, :operate]}]

    for %{listener: listener, rights: rights} <- @schema.rights,
        listener != :socket,
        do: refute(:operate in rights, "#{listener} grants operate")
  end

  test "§8.2, Q12: one resource per capability" do
    routes = for r <- @rest.resources, do: {r.method, r.path, r.capability, r.query, r.body}

    assert routes == [
             {:get, "/v1/runtime", :runtime_info, [], nil},
             {:get, "/v1/policy", :policy, [], nil},
             {:post, "/v1/control/pause", :pause, [], nil},
             {:post, "/v1/control/resume", :resume, [], nil},
             {:post, "/v1/control/drain", :drain, [], nil},
             {:post, "/v1/control/stop", :stop, [], [:force]},
             {:post, "/v1/slots/:slot/release", :release_slot, [], nil},
             {:post, "/v1/harnesses/:harness/clear-quota-mark", :clear_quota_mark, [], nil}
           ]

    assert @rest.streams == []
  end

  test "Q12: the status of every outcome" do
    statuses = Map.new(@rest.statuses, &{&1.outcome, {code(&1), &1.headers, &1.body}})

    assert statuses == %{
             runtime_info: {{200, nil}, [], nil},
             policy: {{200, nil}, [], nil},
             stopping: {{202, nil}, [], nil},
             released: {{200, nil}, [], nil},
             refused:
               {{:reason, %{slot_busy: {409, "slot-busy"}, invalid: {400, "invalid"}}}, [], nil},
             not_found: {{404, "not-found"}, [], nil},
             cleared: {{200, nil}, [], nil}
           }
  end

  test "the errors are the work contract's, so one router answers them alike" do
    work = hd(AtlasRuntimeBackend.Work.__schema__().targets)
    assert Enum.sort(@rest.errors) == Enum.sort(work.errors)
  end

  defp code(%{by: nil, status: status, type: type}), do: {status, type}

  defp code(%{by: by, cases: cases}),
    do: {by, Map.new(cases, &{&1.value, {&1.status, &1.type}})}
end
