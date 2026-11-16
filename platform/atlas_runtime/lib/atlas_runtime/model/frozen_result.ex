defmodule AtlasRuntime.Model.FrozenResult do
  @moduledoc """
  The compile-time model target of the Runtime's private frozen results (design §1.7,
  §3.9): `frozen_result` with its struct, `new/1` and the persisted form
  `frozen/{frozen_id}.json` (`encode`/`decode`). Only the work core uses it; a caller sees
  a frozen result only through the work contract's `frozen`.
  """
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.FrozenResult
end
