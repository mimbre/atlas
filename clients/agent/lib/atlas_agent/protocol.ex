defmodule AtlasAgent.Protocol do
  @moduledoc "The agent's compile-time Control payloads and paths."
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
end
