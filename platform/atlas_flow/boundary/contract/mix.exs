defmodule AtlasFlowBoundary.MixProject do
  use Mix.Project

  # Flow's boundary contract (the port), in Flow's own vocabulary (Flow Engine plan §3.3).
  # Only declarations live here; the DSL, rules and targets belong to ../generator. There is
  # no backend: Flow is not remote, so its callers are in the same BEAM (ADR 0006).
  def project do
    [
      app: :atlas_flow_boundary,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [{:atlas_flow_boundary_generator, path: "../generator"}],
      # What `mix flow_boundary.gen` generates, and where: one file per contract and target.
      # Headers name the contract file from the repository's root.
      flow_boundary: [
        contracts: [tasks: AtlasFlowBoundary.Tasks],
        targets: [json: "../targets/json"],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
