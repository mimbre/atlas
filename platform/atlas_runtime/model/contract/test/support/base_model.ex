defmodule AtlasRuntimeModel.Test.Base do
  @moduledoc false
  # The compile-time target over the base model, as the base store will use it.
  use AtlasRuntimeModel.Generator.Targets.Model, contract: AtlasRuntimeModel.Base
end
