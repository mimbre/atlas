defmodule AtlasControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_control,
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
    [extra_applications: [:logger], mod: {AtlasControl.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Control reaches the other layers over the Bus, and Flow, which runs in the same BEAM,
  # through Flow's boundary target (ADR 0006): the facade AtlasFlow.Boundary.Tasks, never
  # Flow's internals. It is a compile-time dependency only (`runtime: false`): the release
  # starts Flow, and Control starts nothing of it. Its blocks come from Control's
  # contract (platform/atlas_control/backend/contract), read at compile time. It serves pages for the model it is
  # wired to by configuration (AtlasControl.Model) and depends on none; its tests write
  # neutral models in the Rela DSL.
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_flow, in_umbrella: true, runtime: false},
      {:atlas_bff_contract, path: "backend/contract"},
      {:rela_dsl, path: "../../products/software_factory/model/generator", only: :test}
    ]
end
