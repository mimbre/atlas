import Config

# What `mix runtime_model.gen` generates from the model contracts, and where.
config :atlas_runtime_model_generator,
  contracts: [work: AtlasRuntimeModel.Work, runtime_mode: AtlasRuntimeModel.RuntimeMode],
  targets: [json: "../targets/json"],
  # Headers name the contract file from the repository's root.
  root: "../../../.."
