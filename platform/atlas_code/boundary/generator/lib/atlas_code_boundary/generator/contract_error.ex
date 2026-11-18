defmodule AtlasCodeBoundary.Generator.ContractError do
  @moduledoc """
  Raised by a facade (`AtlasCodeBoundary.Generator.Targets.Boundary`) when a call
  breaks the contract: a client that is not `{id, rights}`, or an implementation that
  returns something other than one of the capability's declared outcomes, or one that
  does not validate. An invalid input is the caller's data, not a broken contract: the
  facade answers it (`invalid_input`, or `AtlasCodeBoundary.Generator.InvalidInput`).
  """
  defexception [:message]
end
