defmodule AtlasBus.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_bus,
      version: "0.1.0",
      build_path: "../../products/software_factory/_build",
      config_path: "../../products/software_factory/config/config.exs",
      deps_path: "../../products/software_factory/deps",
      lockfile: "../../products/software_factory/mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      # Tests wait on events, never on the clock (platform/frameworks/test_await).
      deps: [{:atlas_test_await, path: "../frameworks/test_await", only: :test}]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AtlasBus.Application, []}]
  end
end
