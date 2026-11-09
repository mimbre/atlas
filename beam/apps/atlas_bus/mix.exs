defmodule AtlasBus.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_bus,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [{:atlas_transport, path: "../../../transport"}]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {AtlasBus.Application, []}]
  end
end
