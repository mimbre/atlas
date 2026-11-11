defmodule AtlasFlowContract.MixProject do
  use Mix.Project

  # Atlas's flows: the subflows, one file per subject, and the gates they name.
  # Only declarations live here; the DSL and its checks belong to flow/generator.
  def project do
    [
      app: :atlas_flow_contract,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_flow_generator, path: "../generator"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
