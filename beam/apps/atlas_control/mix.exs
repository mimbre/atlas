defmodule AtlasControl.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_control,
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
    [extra_applications: [:logger], mod: {AtlasControl.Application, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Control reaches the other layers only over the Bus. Its blocks come from Control's
  # contract (bff/contract), read at compile time. It serves pages for the model it is
  # wired to by configuration (AtlasControl.Model) and depends on none; its tests write
  # neutral models in the Rela DSL.
  defp deps,
    do: [
      {:atlas_bus, in_umbrella: true},
      {:atlas_transport, path: "../../../transport"},
      {:atlas_bff_contract, path: "../../../bff/contract"},
      {:rela_dsl, path: "../../../model/dsl", only: :test}
    ]
end
