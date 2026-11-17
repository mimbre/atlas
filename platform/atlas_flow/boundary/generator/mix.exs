defmodule AtlasFlowBoundary.Generator.MixProject do
  use Mix.Project

  # The generator of Flow's boundary contracts: the DSL a contract is written in, the
  # targets and `mix flow_boundary.gen`. A renamed copy of the Runtime's boundary generator
  # (D36: one generator per intent folder), not a dependency on it. It holds none of Flow's
  # values: those are in the contract, a project of its own that depends on this one; this
  # one compiles and is tested without it.
  def project do
    [
      app: :atlas_flow_boundary_generator,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
