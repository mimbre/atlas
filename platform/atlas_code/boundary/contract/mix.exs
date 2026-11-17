defmodule AtlasCodeBoundary.MixProject do
  use Mix.Project

  # Code's boundary contract (the port), in Code's own vocabulary. Only declarations live
  # here; the DSL, rules and targets belong to ../generator.
  def project do
    [
      app: :atlas_code_boundary,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_code_boundary_generator, path: "../generator"}],
      # What `mix code_boundary.gen` generates, and where: one file per contract and target.
      # Headers name the contract file from the repository's root.
      code_boundary: [
        contracts: [code: AtlasCodeBoundary.Code],
        targets: [json: "../targets/json"],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
