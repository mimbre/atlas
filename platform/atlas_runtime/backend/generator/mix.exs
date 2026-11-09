defmodule AtlasRuntimeBackend.Generator.MixProject do
  use Mix.Project

  # The generator of a backend: the resource DSL a backend contract is written in, its
  # targets and `mix runtime_backend.gen`. A self-contained copy of the needed parts of
  # Control's generator (platform/atlas_control/backend/generator), not a dependency on it. It
  # holds no project values: those are in a backend contract, a project of its own that
  # depends on this one; this one compiles and is tested on a neutral example.
  #
  # The router target generates Plug code into the module that uses it, so this project
  # needs Plug only for its own tests; it has its own mix.lock.
  def project do
    [
      app: :atlas_runtime_backend_generator,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: [{:plug, "~> 1.19", only: :test}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
