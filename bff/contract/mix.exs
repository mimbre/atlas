defmodule AtlasBFFContract.MixProject do
  use Mix.Project

  # Atlas's presentation, payload models and Control/Runtime wire contracts.
  # Only declarations live here; the DSL, rules and targets belong to bff/generator.
  def project do
    [
      app: :atlas_bff_contract,
      version: "0.16.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_bff, path: "../generator"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
