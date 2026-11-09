import Config

# What `mix model.gen` generates from this contract, and where. The contract is the
# composition of every subflow; flows.json holds every gate of Model.Gates.
# Rela checks the generated flows.yaml in a copy of the Rela description (rela/), where
# rela/scripts/assemble.py copies it.
config :rela_dsl,
  contract: Model.Software,
  gates: Model.Gates,
  environment_targets: [test: [rela: "../targets/test/rela", atlas: "../targets/test/atlas"]],
  targets: [rela: "../targets/rela", atlas: "../targets/atlas", diagrams: "../targets/diagrams"],
  rela_project: "../../rela",
  # Headers name the contract file from the repository's root.
  root: "../.."
