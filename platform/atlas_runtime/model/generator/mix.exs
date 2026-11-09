defmodule AtlasRuntimeModel.Generator.MixProject do
  use Mix.Project

  # The generator of the Runtime's private model: the DSL a model contract is written in,
  # the compile-time model target and the file targets. It holds none of the Runtime's
  # values: the entities are in the contract, a project of its own that depends on this
  # one; this one compiles and is tested without it, on a neutral example.
  def project do
    [
      app: :atlas_runtime_model_generator,
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
