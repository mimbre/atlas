defmodule AtlasRuntimeBackend.HistoryTest do
  use ExUnit.Case, async: true

  @schema AtlasRuntimeBackend.History.__schema__()
  @rest hd(@schema.targets)

  test "carries the history boundary, exposing both capabilities" do
    assert @schema.boundary == AtlasRuntimeBoundary.History
    capabilities = for c <- AtlasRuntimeBoundary.History.__schema__().capabilities, do: c.name
    assert @schema.exposed == capabilities
    assert @schema.exposed == [:list_turns, :get_turn]
    assert @schema.not_exposed == []
    assert [%{name: :rest, carries: :entities}] = @schema.targets
  end

  test "Q2, Q4: the socket reads all history" do
    assert @schema.rights == [%{listener: :socket, rights: [:read, :read_all]}]
  end

  test "the errors are the work contract's, so one router answers them alike" do
    work = hd(AtlasRuntimeBackend.Work.__schema__().targets)
    assert Enum.sort(@rest.errors) == Enum.sort(work.errors)
  end

  test "§8.2: one resource per capability, no stream" do
    routes = for r <- @rest.resources, do: {r.method, r.path, r.capability, r.query}

    assert routes == [
             {:get, "/v1/turns", :list_turns,
              [{"slot", :slot}, {"since", :since}, {"cursor", :cursor}, {"limit", :limit}]},
             {:get, "/v1/turns/:turn_id", :get_turn, []}
           ]

    assert @rest.streams == []
  end
end
