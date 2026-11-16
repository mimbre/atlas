defmodule AtlasRuntime.Boundary.Operations do
  @moduledoc """
  The facade of the operations contract (`AtlasRuntimeBoundary.Operations`; design §1.2,
  §1.3, §13.1 Q4–Q9, Q13): what callers outside the core use to inspect and operate the
  Runtime. Generated: one function per capability, which checks the caller's right and
  the input before it calls `AtlasRuntime.Operations`, and checks what that answers
  against the declared outcomes.

  A missing right is `%AtlasRuntimeBoundary.Generator.NotPermitted{}` and a bad input
  `%AtlasRuntimeBoundary.Generator.InvalidInput{}` (or `release_slot`'s declared
  `refused(reason: :invalid)`), for every capability and before the implementation runs;
  neither is a declared outcome.

  The persisted mode (`runtime_mode` in `AtlasRuntime.Model.RuntimeMode`, Q6) translates
  into `runtime_info` one way, checked here against `AtlasRuntimeBoundary.OperationsMappings`:
  `from_model(mode, supply: [...])`, also `as: :stopping`; there is no `to_model`.
  """
  use AtlasRuntimeBoundary.Generator.Targets.Boundary,
    contract: AtlasRuntimeBoundary.Operations,
    implementation: AtlasRuntime.Operations,
    mappings: AtlasRuntimeBoundary.OperationsMappings,
    model: AtlasRuntime.Model.RuntimeMode
end
