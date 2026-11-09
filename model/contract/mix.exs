defmodule Model.MixProject do
  use Mix.Project

  # Atlas's model: the domain, by module and concept (D-0083). Each concept holds its
  # kind, its relations, its subflows and gates; a module groups concepts into one Rela
  # file; the composition selects modules and runs the subflows. The DSL and its checks
  # belong to model/dsl. The profiles are private compositions for tests and private
  # instances (every MIX_ENV but prod).
  def project do
    [
      app: :model,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps()
    ]
  end

  def application, do: [extra_applications: [:logger]]

  # The DSL it is written in, and the platform's behaviours it implements (D-0083):
  # Flow's (AtlasFlow.Model, AtlasFlow.Subflow, AtlasFlow.Legacy), Gates'
  # (AtlasGates.Model), Runtime's (AtlasRuntime.Model) and Control's (AtlasControl.Model),
  # at compile time only: the model starts no platform app. The
  # platform never depends on the model; it is wired by configuration
  # (`config :atlas, model: Model.AtlasEyra`).
  defp deps,
    do: [
      {:rela_dsl, path: "../dsl"},
      {:atlas_flow, path: "../../beam/apps/atlas_flow", runtime: false, env: Mix.env()},
      {:atlas_gates, path: "../../beam/apps/atlas_gates", runtime: false, env: Mix.env()},
      {:atlas_runtime, path: "../../beam/apps/atlas_runtime", runtime: false, env: Mix.env()},
      {:atlas_control, path: "../../beam/apps/atlas_control", runtime: false, env: Mix.env()}
    ]

  # The profiles are compiled everywhere but in prod: a private instance (e2e) runs one.
  @model ["foundation", "software", "eyra", "compositions"]
  defp elixirc_paths(:prod), do: @model
  defp elixirc_paths(_), do: @model ++ ["profiles"]
end
