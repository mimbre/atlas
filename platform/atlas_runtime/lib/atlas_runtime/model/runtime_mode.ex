defmodule AtlasRuntime.Model.RuntimeMode do
  @moduledoc """
  The compile-time model target of the Runtime's persisted mode (design §1.7, §13.1 Q6):
  `runtime_mode` with its struct, `new/1` and the one-file persisted form `mode.json`
  (`encode_file`/`decode_file`). The core keeps it; a caller sees only `runtime_info`,
  through `AtlasRuntime.Boundary.Operations`.
  """
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.RuntimeMode
end
