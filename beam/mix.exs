defmodule Atlas.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The core as one release, for Fly (fly/core.Dockerfile); on a Mac it runs with `mix run`.
      releases: [
        atlas: [
          applications: [
            atlas_bus: :permanent,
            model: :permanent,
            atlas_facts: :permanent,
            atlas_gates: :permanent,
            atlas_flow: :permanent,
            atlas_runtime: :permanent,
            atlas_control: :permanent
          ],
          include_executables_for: [:unix]
        ],
        # Code alone, for a process supervisor: `bin/atlas_code eval "AtlasCode.Server.run()"`
        # starts it like `mix atlas_code.server` without Mix's startup (tools/runtime/README.md).
        # No runtime.exs: it belongs to the core and Runtime nodes, as for the mix task.
        atlas_code: [
          applications: [atlas_code: :permanent],
          runtime_config_path: false,
          include_executables_for: [:unix]
        ]
      ]
    ]
  end

  # The model Facts, Flow, Gates, Runtime and Control run (D-0083): the domain, written in
  # the Rela DSL and compiled into the release. No platform app depends on it; config :atlas, model:
  # wires it at boot. Outside prod it is compiled with its private profiles, which a private
  # instance can be wired to instead (its settings' "model").
  defp deps,
    do: [{:model, path: "../model/contract", env: Mix.env()}]
end
