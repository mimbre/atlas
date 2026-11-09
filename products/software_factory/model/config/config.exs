import Config

# What `mix model.gen` generates from the model, and where. The contract is the
# composition: its Rela project goes to targets/rela/ (rela_project), the files Atlas runs the
# subflows by to targets/model (flows.json, per environment), with each subflow's
# diagram and the proof of the run identities (digests.json).
config :rela_dsl,
  contract: Model.AtlasEyra,
  environment_targets: [test: [rela: "../targets/model/test/rela", atlas: "../targets/model/test/atlas"]],
  targets: [atlas: "../targets/model/atlas", diagrams: "../targets/model/diagrams", proof: "../targets/model/proof"],
  rela_project: "../targets/rela",
  # Headers name the contract file from the repository's root.
  root: "../../.."
