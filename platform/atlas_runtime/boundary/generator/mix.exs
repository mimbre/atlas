defmodule AtlasRuntimeBoundary.Generator.MixProject do
  use Mix.Project

  # The generator of the Runtime's boundary contracts: the DSL a contract is written in,
  # the targets and `mix runtime_boundary.gen`. A renamed copy of the needed parts of
  # Control's generator (platform/atlas_control/backend/generator), not a dependency on it. It
  # holds none of the Runtime's values: those are in the contract, a project of its own
  # that depends on this one; this one compiles and is tested without it.
  def project do
    [
      app: :atlas_runtime_boundary_generator,
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
