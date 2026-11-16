defmodule AtlasRuntimeBoundary.MixProject do
  use Mix.Project

  # The Runtime's boundary contracts (the ports), in the Runtime's own vocabulary.
  # Only declarations live here; the DSL, rules and targets belong to ../generator.
  def project do
    [
      app: :atlas_runtime_boundary,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: [{:atlas_runtime_boundary_generator, path: "../generator"}],
      # What `mix runtime_boundary.gen` generates, and where: one file per contract and
      # target. Headers name the contract file from the repository's root.
      runtime_boundary: [
        contracts: [
          work: AtlasRuntimeBoundary.Work,
          operations: AtlasRuntimeBoundary.Operations,
          history: AtlasRuntimeBoundary.History
        ],
        targets: [json: "../targets/json"],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # test/support: facades of the S2 contracts on skeleton implementations, for the tests.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
