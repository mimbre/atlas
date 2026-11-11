defmodule AtlasTui.Blocks do
  @moduledoc """
  The view model Control sends, decoded: a struct per block, model and kind of markup in
  Control's contract (`AtlasBFFContract.Contract`, bff/contract), `decode/1` and
  `view_model/1`. Made from the contract when this module compiles; see
  `AtlasBFF.Targets.Client`.
  """
  use AtlasBFF.Targets.Client, contract: AtlasBFFContract.Contract
end
