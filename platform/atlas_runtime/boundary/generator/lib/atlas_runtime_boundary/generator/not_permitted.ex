defmodule AtlasRuntimeBoundary.Generator.NotPermitted do
  @moduledoc """
  What a facade (`AtlasRuntimeBoundary.Generator.Targets.Boundary`) returns, without
  calling the implementation, when the client lacks the capability's `right`.
  """
  defstruct [:capability, :right]

  @type t :: %__MODULE__{capability: atom(), right: atom()}
end
