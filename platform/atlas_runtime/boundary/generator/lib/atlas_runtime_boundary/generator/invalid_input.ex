defmodule AtlasRuntimeBoundary.Generator.InvalidInput do
  @moduledoc """
  What a facade (`AtlasRuntimeBoundary.Generator.Targets.Boundary`) returns, without
  calling the implementation, when a capability's input does not validate and the
  capability declares no outcome for that (the contract's `invalid_input`). `reasons`
  are the texts `new/1` gives, with the path of each field.
  """
  defstruct [:capability, :reasons]

  @type t :: %__MODULE__{capability: atom(), reasons: [String.t()]}
end
