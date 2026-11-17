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
      # What `mix runtime_backend.gen` generates, and where (§1.8, §8.5): per contract of
      # the one router (S2), its route description and OpenAPI document, for clients in
      # other languages, in ../targets/rest/<contract>/. Clients of the tcp listener send a
      # bearer token (§8.1); only the work contract declares that listener, and naming a
      # listener a contract declares no rights for fails generation. The OpenAPI has no
      # servers: the host is configuration. Headers name the contract file from the
      # repository's root.
      runtime_backend: [
        contracts: [
          work_api: AtlasRuntimeBackend.Work,
          operations_api: AtlasRuntimeBackend.Operations,
          history_api: AtlasRuntimeBackend.History
        ],
        targets: [
          routes: "../targets/rest",
          openapi:
            {"../targets/rest",
             contracts: [:work_api],
             title: "Atlas Runtime backend: work",
             security: [tcp: :bearer]},
          openapi:
            {"../targets/rest",
             contracts: [:operations_api], title: "Atlas Runtime backend: operations"},
          openapi:
            {"../targets/rest",
             contracts: [:history_api], title: "Atlas Runtime backend: history"}
        ],
        root: "../../../.."
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
