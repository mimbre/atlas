defmodule AtlasFlowGenerator.MixProject do
  use Mix.Project

  # The generator of Atlas's flows: the DSL a subflow and its gates are written in,
  # and the checks a definition must pass to compile. It holds none of Atlas's
  # flows: those are in the contract, a project of its own that depends on this
  # one; this one compiles and tests without it.
  def project do
    [
      app: :atlas_flow_generator,
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
