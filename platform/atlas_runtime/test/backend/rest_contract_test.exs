defmodule AtlasRuntime.BackendTest.RestContract do
  @moduledoc """
  Carried to S1d (with `lib/atlas_runtime/backend/rest.ex` and the facade
  `AtlasRuntime.Boundary.Work`): the Runtime's own router is generated from the same
  backend contract as the test router, with the socket's rights.
  """
  use ExUnit.Case, async: true

  test "the Runtime's own router is generated from the same contract, with the socket's rights" do
    assert AtlasRuntime.Backend.Rest.__routes__() == AtlasRuntime.Test.WorkRest.__routes__()

    assert AtlasRuntime.Backend.Rest.__rights__(:socket) ==
             [:submit, :cancel, :read, :read_all, :choose_slot]
  end
end
