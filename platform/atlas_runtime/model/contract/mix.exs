defmodule AtlasRuntimeModel.MixProject do
  use Mix.Project

  # The Runtime's private model: the entities it keeps for itself and their persistence
  # form. Only declarations live here; the DSL and targets belong to ../generator. The
  # innermost layer: it depends on its own generator only, never on boundary or backend.
  def project do
    [
      app: :atlas_runtime_model,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: [{:atlas_runtime_model_generator, path: "../generator"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
