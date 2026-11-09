defmodule Atlas.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "../../platform",
      # The umbrella's apps by name: platform/ also holds folders that are no app (clients,
      # ops), which Mix would warn about on every command.
      apps: [
        :atlas_bus,
        :atlas_code,
        :atlas_control,
        :atlas_facts,
        :atlas_flow,
        :atlas_gates,
        :atlas_learn,
        :atlas_runtime
      ],
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # The core as one release, for Fly (platform/ops/core.Dockerfile); on a Mac it runs with `mix run`.
      releases: [
        atlas: [
          applications: [
            atlas_bus: :permanent,
            model: :permanent,
            atlas_facts: :permanent,
            atlas_gates: :permanent,
            atlas_flow: :permanent,
            # Code's receiver of Flow's integrate effect, on the Bus started above (code.* in
            # the core's settings); not the local Code service, which this release never runs.
            atlas_code: :permanent,
            atlas_runtime: :permanent,
            atlas_control: :permanent
          ],
          include_executables_for: [:unix]
        ],
        # Code alone, for a process supervisor: `bin/atlas_code eval "AtlasCode.Server.run()"`
        # starts it like `mix atlas_code.server` without Mix's startup (platform/atlas_runtime/host/README.md).
        # No runtime.exs: it belongs to the core, as for the mix task.
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
    do: [{:model, path: "model/contract", env: Mix.env()}]
end
