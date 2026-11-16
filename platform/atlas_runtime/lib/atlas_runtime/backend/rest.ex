defmodule AtlasRuntime.Backend.Rest do
  @moduledoc """
  The Runtime backend's `rest` router (design 2026-11-16-runtime-backend §1.8, §8),
  generated from the backend contract `AtlasRuntimeBackend.Work` on the work facade
  `AtlasRuntime.Boundary.Work`: its routes, status codes and serialization are declared
  there, not written here. It is a Plug; `AtlasRuntime.Backend.Listener` serves it and
  puts the client in `conn.assigns`, and `AtlasRuntime.Backend.Events` keeps its event
  stream open.
  """
  use AtlasRuntimeBackend.Generator.Targets.Rest,
    contract: AtlasRuntimeBackend.Work,
    facade: AtlasRuntime.Boundary.Work,
    stream: AtlasRuntime.Backend.Events
end
