defmodule AtlasRuntimeBoundary.Test.OperationsFacade do
  @moduledoc """
  A facade of the operations contract, generated as the Runtime's own will be, on a
  skeleton implementation: it proves the contract compiles into a facade and a behaviour.
  Test-only; nothing starts it.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Operations,
    implementation: AtlasRuntimeBoundary.Test.OperationsSkeleton
end
