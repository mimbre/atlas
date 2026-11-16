defmodule AtlasFlow.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_flow,
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

  def application do
    [extra_applications: [:logger], mod: {AtlasFlow.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Flow reaches Facts, Gates and Code over the Bus, and the Runtime as a remote client of
  # its backend (ADR 0006): over HTTP, with `req` (Finch/Mint, which also speak the HTTP
  # CONNECT proxy of the tailnet path), never by calling it. It runs the model it is wired
  # to by configuration (AtlasFlow.Model) and depends on none; its tests write neutral
  # models in the Rela DSL. The Runtime is a test dependency only: the client's contract
  # test starts its real backend in the test (AtlasFlow.Runtime.Client.Http).
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:req, "~> 0.5.16"},
      {:atlas_runtime, in_umbrella: true, only: :test},
      {:rela_dsl, path: "../../products/software_factory/model/generator", only: :test}
    ]
end
