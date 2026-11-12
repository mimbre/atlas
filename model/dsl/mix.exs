defmodule RelaDSL.MixProject do
  use Mix.Project

  # The Rela DSL (model/dsl): the DSL a subflow and its gates are written in, and the
  # checks a definition must pass to compile. It holds none of Atlas's flows: those
  # are in the model, a project of its own that depends on this one; this one
  # compiles and tests without it.
  def project do
    [
      app: :rela_dsl,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
