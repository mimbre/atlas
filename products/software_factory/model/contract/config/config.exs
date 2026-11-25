import Config

# What `mix model.gen` generates from the model, and where. The contract is the
# composition: its Rela project goes to targets/rela/ (rela_project), the files Atlas runs the
# subflows by to targets/ (flows.json, per environment), with each subflow's
# diagram.
config :rela_dsl,
  contract: Model.AtlasEyra,
  environment_targets: [test: [rela: "../targets/test/rela", atlas: "../targets/test/atlas"]],
  targets: [atlas: "../targets/atlas", diagrams: "../targets/diagrams"],
  rela_project: "../targets/rela",
  # Headers name the contract file from the repository's root.
  root: "../../../.."
