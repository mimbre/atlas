defmodule Model.MixProject do
  use Mix.Project

  # Atlas's model: the domain, by module and concept (D-0083). Each concept holds its
  # kind, its relations, its subflows and gates; a module groups concepts into one Rela
  # file; the composition selects modules and runs the subflows. The DSL and its checks
  # belong to model/dsl. The profiles are private compositions for tests (MIX_ENV=test).
  def project do
    [
      app: :model,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: [{:rela_dsl, path: "../dsl"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  @model ["foundation", "software", "eyra", "compositions"]
  defp elixirc_paths(:test), do: @model ++ ["profiles"]
  defp elixirc_paths(_), do: @model
end
