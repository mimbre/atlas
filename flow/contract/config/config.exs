import Config

# What `mix atlas.flow.gen` generates from this contract, and where. The contract is the
# Issue subflow for now; the composition (AtlasFlowContract.Software) replaces it when
# the other subflows arrive. flows.json holds every gate of AtlasFlowContract.Gates.
config :atlas_flow_generator,
  contract: AtlasFlowContract.Issue,
  gates: AtlasFlowContract.Gates,
  targets: [rela: "../targets/rela", atlas: "../targets/atlas", diagrams: "../targets/diagrams"],
  # Headers name the contract file from the repository's root.
  root: "../.."
