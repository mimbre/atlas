defmodule AtlasRuntimeBoundary.MixProject do
  use Mix.Project

  # The Runtime's boundary contracts (the ports), in the Runtime's own vocabulary.
  # Only declarations live here; the DSL, rules and targets belong to ../generator.
  def project do
    [
      app: :atlas_runtime_boundary,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_runtime_boundary_generator, path: "../generator"}],
      # What `mix runtime_boundary.gen` generates, and where (S1: the work contract only;
      # several contracts from S2). Headers name the contract file from the repository's root.
      runtime_boundary: [
        contracts: [work: AtlasRuntimeBoundary.Work],
        targets: [json: "../targets/json"],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
