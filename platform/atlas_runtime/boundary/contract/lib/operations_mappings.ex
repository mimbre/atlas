defmodule AtlasRuntimeBoundary.OperationsMappings do
  @moduledoc """
  How the Runtime's private `runtime_mode` record (design §1.7, §13.1 Q6) becomes the
  operations contract's `runtime_info` (`AtlasRuntimeBoundary.Operations`). Named as atoms
  only, like `AtlasRuntimeBoundary.WorkMappings`: this project depends on no model, and
  none of this is in the contract's `__schema__/0` or in `operations.json`. The Boundary
  target checks it against the model inside atlas_runtime (option `model:`).

  One way only. The persisted mode is `open`, `paused` or `draining`, each a value of
  `runtime_info.mode`; `stopping` is never persisted, so nothing maps back. Who changed the
  mode and when stay private. The rest of `runtime_info` is not the mode's: the core
  supplies it, `from_model(mode, supply: [...])`, also `as: :stopping` for `stop`.
  """
  use AtlasRuntimeBoundary.Generator.Mappings

  defmapping :runtime_mode, :runtime_info,
    direction: :from_model,
    drop: [:changed_at, :changed_by],
    supply: [:runtime_build, :incarnation, :policy_version, :slots]
end
