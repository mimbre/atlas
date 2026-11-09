defmodule AtlasFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_flow,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {AtlasFlow.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Flow reaches the other layers only over the Bus.
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_flow_generator, path: "../../../flow/generator"}
    ]
end
