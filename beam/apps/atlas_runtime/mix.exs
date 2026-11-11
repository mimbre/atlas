defmodule AtlasRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_runtime,
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
    [extra_applications: [:logger, :inets], mod: {AtlasRuntime.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime reaches other layers only over Bus; the shared contract supplies wire codecs.
  defp deps,
    do: [{:atlas_bus, in_umbrella: true}, {:atlas_bff_contract, path: "../../../bff/contract"}]
end
