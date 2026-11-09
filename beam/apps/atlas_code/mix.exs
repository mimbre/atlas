defmodule AtlasCode.MixProject do
  use Mix.Project

  def project do
    [
      app: :atlas_code,
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

  # The local Code service runs only when `mix atlas_code.server` or the `atlas_code`
  # release starts it (`AtlasCode.Server`). The application itself starts Code's effect
  # receiver, and only on a node that configures one (the core; `AtlasCode.Application`).
  def application do
    [
      mod: {AtlasCode.Application, []},
      extra_applications: [:logger, :inets, :crypto, :ssl, :public_key]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The Bus for the effect receiver's endpoint and the digests of Flow's requests. Not a
  # runtime dependency: the local Code service neither ships nor starts it; the core, which
  # configures the receiver, starts it before Code (the `atlas` release).
  defp deps, do: [{:atlas_bus, in_umbrella: true, runtime: false}]
end
