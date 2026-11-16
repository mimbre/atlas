defmodule AtlasRuntimeBackend.MixProject do
  use Mix.Project

  # The Runtime's backend contracts: how the boundary contracts are carried across a process
  # boundary (design 2026-11-16-runtime-backend §1.8, §8). Only declarations live here; the
  # DSL, rules and targets belong to ../generator. It depends on the boundary contract it
  # carries, never on the Runtime's private model.
  def project do
    [
      app: :atlas_runtime_backend,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: [
        {:atlas_runtime_backend_generator, path: "../generator"},
        {:atlas_runtime_boundary, path: "../../boundary/contract"}
      ],
      # What `mix runtime_backend.gen` generates, and where. S2 has no file target: the
      # route description (../targets/rest/routes.json) and OpenAPI come with S3, so
      # --check only compiles the contracts. Headers name the contract file from the
      # repository's root.
      runtime_backend: [
        contracts: [
          work_api: AtlasRuntimeBackend.Work,
          operations_api: AtlasRuntimeBackend.Operations
        ],
        targets: [],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
