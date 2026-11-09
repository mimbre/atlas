import Config

# What `mix atlas.flow.gen` generates from this contract, and where. The contract is the
# composition of every subflow; flows.json holds every gate of AtlasFlowContract.Gates.
# Rela checks the generated flows.yaml in a copy of the Rela description (rela/), where
# rela/scripts/assemble.py copies it.
config :atlas_flow_generator,
  contract: AtlasFlowContract.Software,
  gates: AtlasFlowContract.Gates,
  targets: [rela: "../targets/rela", atlas: "../targets/atlas", diagrams: "../targets/diagrams"],
  rela_project: "../../rela",
  # Headers name the contract file from the repository's root.
  root: "../.."
