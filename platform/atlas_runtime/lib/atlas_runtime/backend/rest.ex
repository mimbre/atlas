defmodule AtlasRuntime.Backend.Rest do
  @moduledoc """
  The backend's one router (design §8, §13.1 Q11), generated from the backend contracts on
  the boundary's facades: the work contract, with the event stream, and the operations
  contract. No route, status or serialization is written here. BK2′ adds
  `history: {AtlasRuntimeBackend.History, facade: AtlasRuntime.Boundary.History}`.
  """
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contracts: [
      work:
        {AtlasRuntimeBackend.Work,
         facade: AtlasRuntime.Boundary.Work, stream: AtlasRuntime.Backend.Events},
      operations: {AtlasRuntimeBackend.Operations, facade: AtlasRuntime.Boundary.Operations}
    ]
end
