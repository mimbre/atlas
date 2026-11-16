defmodule AtlasCodeBoundary.Generator.NotPermitted do
  @moduledoc """
  What a facade (`AtlasCodeBoundary.Generator.Targets.Boundary`) returns, without
  calling the implementation, when the client lacks the capability's `right`.
  """
  defstruct [:capability, :right]

  @type t :: %__MODULE__{capability: atom(), right: atom()}
end
