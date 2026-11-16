defmodule AtlasLearn.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_learn,
      version: "0.1.0",
      build_path: "../../products/software_factory/_build",
      config_path: "../../products/software_factory/config/config.exs",
      deps_path: "../../products/software_factory/deps",
      lockfile: "../../products/software_factory/mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # No application callback and no store: Learn runs when the coordinator runs
  # `mix atlas_learn.report`, reads the other components through their own read surfaces
  # and writes one report. It depends on no layer; inets carries its HTTP reads.
  def application do
    [extra_applications: [:logger, :inets]]
  end

  # Test only: a Bandit listener stands in for Runtime's backend socket (the versions
  # products/software_factory/mix.lock already pins).
  defp deps,
    do: [{:plug, "~> 1.19", only: :test}, {:bandit, "~> 1.10", only: :test}]
end
