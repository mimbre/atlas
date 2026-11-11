defmodule AtlasLearn.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_learn,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  # No application callback and no store: Learn runs when the coordinator runs
  # `mix atlas_learn.report`, reads the other components through their own read surfaces
  # and writes one report. It depends on no layer.
  def application do
    [extra_applications: [:logger]]
  end
end
