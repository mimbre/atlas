defmodule AtlasBFF.MixProject do
  use Mix.Project

  # The generator of Control's BFF: the DSL a contract is written in, the rules of
  # markup, and the targets. It holds none of Atlas's values: the blocks are in
  # the contract, a project of its own that depends on this one; this one compiles
  # without it.
  def project do
    [
      app: :atlas_bff,
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
