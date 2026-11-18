defmodule AtlasGates.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_gates,
      version: "0.1.0",
      build_path: "../../products/software_factory/_build",
      config_path: "../../products/software_factory/config/config.exs",
      deps_path: "../../products/software_factory/deps",
      lockfile: "../../products/software_factory/mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [mod: {AtlasGates.Application, []}, extra_applications: [:logger, :crypto]]
  end

  # Gates reaches the other layers only over the Bus. The gate definitions are the
  # model's, wired by configuration (AtlasGates.Model); its tests wire a neutral model.
  # Tests wait on events, never on the clock (platform/frameworks/test_await).
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_test_await, path: "../frameworks/test_await", only: :test}
    ]
end
