import Config

# What `mix model.gen` generates from the model, and where. The contract is the
# composition: its Rela project goes to rela/ (rela_project), the files Atlas runs the
# subflows by to model/targets (flows.json, per environment), with each subflow's
# diagram and the proof of the run identities (digests.json).
config :rela_dsl,
  contract: Model.AtlasEyra,
  environment_targets: [test: [rela: "../targets/test/rela", atlas: "../targets/test/atlas"]],
  targets: [atlas: "../targets/atlas", diagrams: "../targets/diagrams", proof: "../targets/proof"],
  rela_project: "../../rela",
  # Headers name the contract file from the repository's root.
  root: "../.."
