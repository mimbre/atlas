defmodule AtlasTui.Protocol do
  @moduledoc "Compile-time Control endpoint payloads and reply selectors for the Console."
  use AtlasBFF.Targets.Protocol, contract: AtlasBFFContract.Contract, channel: :control
end
