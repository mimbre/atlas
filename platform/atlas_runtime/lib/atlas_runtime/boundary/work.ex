defmodule AtlasRuntime.Boundary.Work do
  @moduledoc """
  The Boundary Elixir target of the Runtime's work contract (design §1.5): the only way in
  for every caller (the backend, tests, any co-located system). It checks the right, builds
  the input, calls `AtlasRuntime.Work` and checks that the answer is a declared outcome.
  `AtlasRuntime.Work` implements `AtlasRuntime.Boundary.Work.Implementation`. The
  translations between the private model (`AtlasRuntime.Model.Work`) and the contract's
  models are checked here against `AtlasRuntimeBoundary.WorkMappings` (§1.5 (c)).
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Work,
    implementation: AtlasRuntime.Work,
    mappings: AtlasRuntimeBoundary.WorkMappings,
    model: AtlasRuntime.Model.Work
end
