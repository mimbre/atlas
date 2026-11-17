defmodule AtlasRuntime.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_runtime,
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
    [extra_applications: [:logger, :inets], mod: {AtlasRuntime.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Runtime reaches other layers only over Bus; the shared contract supplies wire codecs.
  # It runs the model it is wired to by configuration (AtlasRuntime.Model) and depends on
  # none; its tests write a neutral model in the Rela DSL.
  # Its own contracts (design 2026-11-16-runtime-backend §1.2): the boundary, the private
  # model behind it (the facade AtlasRuntime.Boundary.Work and AtlasRuntime.Model.Work), and
  # the backend that carries it, served by Plug on Bandit (the umbrella's first Hex
  # dependencies, locked in products/software_factory/mix.lock). The boundary contract is
  # also the backend contract's dependency; `override: true` makes this one count when a
  # linked checkout (the e2e copies) resolves the two paths to different places.
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_bff_contract, path: "../atlas_control/backend/contract"},
      {:atlas_runtime_boundary, path: "boundary/contract", override: true},
      {:atlas_runtime_model, path: "model/contract"},
      {:atlas_runtime_backend, path: "backend/contract"},
      # The neutral change set (D42): the frozen result's shape and its csf_ fingerprints.
      {:atlas_changeset, path: "../frameworks/changeset"},
      {:plug, "~> 1.19"},
      {:bandit, "~> 1.10"},
      {:rela_dsl, path: "../../products/software_factory/model/generator", only: :test}
    ]
end
