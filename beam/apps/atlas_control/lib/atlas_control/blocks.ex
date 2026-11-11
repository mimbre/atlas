defmodule AtlasControl.Blocks do
  @moduledoc """
  The builders of the view model Control sends: a macro per block, model and kind of
  markup in Control's contract (`AtlasBFFContract.Contract`, bff/contract), and
  `view_model/2`. Made from the contract when this module compiles; see
  `AtlasBFF.Targets.Server`. Callers `require AtlasControl.Blocks, as: Blocks`.
  """
  use AtlasBFF.Targets.Server, contract: AtlasBFFContract.Contract
end
