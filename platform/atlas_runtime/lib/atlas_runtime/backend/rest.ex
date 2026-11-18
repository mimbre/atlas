defmodule AtlasRuntime.Backend.Rest do
  @moduledoc """
  The backend's one router (design §8, §13.1 Q11), generated from the backend contracts on
  the boundary's facades: the work contract, with the event stream, the operations
  contract and the history contract. No route, status or serialization is written here.
  """
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contracts: [
      work:
        {AtlasRuntimeBackend.Work,
         facade: AtlasRuntime.Boundary.Work, stream: AtlasRuntime.Backend.Events},
      operations: {AtlasRuntimeBackend.Operations, facade: AtlasRuntime.Boundary.Operations},
      history: {AtlasRuntimeBackend.History, facade: AtlasRuntime.Boundary.History}
    ]
end
