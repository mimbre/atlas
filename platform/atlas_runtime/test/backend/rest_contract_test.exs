defmodule AtlasRuntime.BackendTest.RestContract do
  @moduledoc """
  Carried to S1d (with `lib/atlas_runtime/backend/rest.ex` and the facade
  `AtlasRuntime.Boundary.Work`), and since S2b on the operations facade too: the Runtime's
  own router is generated from the same backend contracts as the test router, with the
  socket's rights (the work rights plus `inspect` and `operate`, design §13.1 Q4).
  """
  use ExUnit.Case, async: true

  test "the Runtime's own router is generated from the same contracts, with the socket's rights" do
    assert AtlasRuntime.Backend.Rest.__routes__() == AtlasRuntime.Test.WorkRest.__routes__()

    assert AtlasRuntime.Backend.Rest.__rights__(:socket) ==
             [:submit, :cancel, :read, :read_all, :choose_slot, :inspect, :operate]
  end
end
