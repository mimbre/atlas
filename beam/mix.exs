defmodule Atlas.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: [],
      # The core as one release, for Fly (fly/core.Dockerfile); on a Mac it runs with `mix run`.
      releases: [
        atlas: [
          applications: [
            atlas_bus: :permanent,
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
end
