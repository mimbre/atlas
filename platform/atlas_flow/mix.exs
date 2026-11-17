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

  # Flow reaches Facts, Gates and Code's effect receiver over the Bus. It runs the model it
  # is wired to by configuration (AtlasFlow.Model) and depends on none; its tests write
  # neutral models in the Rela DSL.
  #
  # Code: Flow serves Runtimes their bases from Code (work acquisition M3; D41), through
  # Code's boundary facade AtlasCode.Boundary in the same BEAM (ADR 0006), named only by its
  # adapter AtlasFlow.Code.Client.Boundary (the boundary test's facade exception). The
  # dependency is `runtime: false`: depending on Code starts nothing where Flow runs; the
  # core release starts `atlas_code` itself, and the adapter's test starts a Code of its own.
  #
  # Flow is the Runtime's work source (M3): the neutral change set (atlas_changeset) for
  # results, and Plug on Bandit for the backend that carries the source's contract (already
  # locked; the Runtime uses them). `req` is the push client's (AtlasFlow.Runtime.Client),
  # until M3 removes it. The Runtime is a test dependency only: Flow never calls it.
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_code, in_umbrella: true, runtime: false},
      {:atlas_changeset, path: "../frameworks/changeset"},
      {:plug, "~> 1.19"},
      {:bandit, "~> 1.10"},
      {:req, "~> 0.5.16"},
      {:atlas_runtime, in_umbrella: true, only: :test},
      {:rela_dsl, path: "../../products/software_factory/model/generator", only: :test}
    ]
end
