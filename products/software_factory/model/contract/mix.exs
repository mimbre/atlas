defmodule Model.MixProject do
  use Mix.Project

  # Atlas's model: the domain, by module and concept (D-0083). Each concept holds its
  # kind, its relations, its subflows and gates; a module groups concepts into one Rela
  # file; the composition selects modules and runs the subflows. The DSL and its checks
  # belong to products/software_factory/model/generator. The profiles are private compositions for tests and private
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
  # Flow's (AtlasFlow.Model, AtlasFlow.Subflow), Gates'
  # (AtlasGates.Model), Runtime's (AtlasRuntime.Model), Control's (AtlasControl.Model) and
  # Facts' (AtlasFacts.Model),
  # at compile time only: the model starts no platform app. The
  # platform never depends on the model; it is wired by configuration
  # (`config :atlas, model: Model.AtlasEyra`).
  defp deps,
    do: [
      {:rela_dsl, path: "../generator"},
      {:atlas_flow, path: "../../../../platform/atlas_flow", runtime: false, env: Mix.env()},
      {:atlas_gates, path: "../../../../platform/atlas_gates", runtime: false, env: Mix.env()},
      {:atlas_runtime,
       path: "../../../../platform/atlas_runtime", runtime: false, env: Mix.env()},
      {:atlas_control,
       path: "../../../../platform/atlas_control", runtime: false, env: Mix.env()},
      {:atlas_facts, path: "../../../../platform/atlas_facts", runtime: false, env: Mix.env()}
    ]

  # The profiles are compiled everywhere but in prod: a private instance (e2e) runs one.
  @model ["foundation", "software", "eyra", "compositions"]
  defp elixirc_paths(:prod), do: @model
  defp elixirc_paths(_), do: @model ++ ["profiles"]
end
