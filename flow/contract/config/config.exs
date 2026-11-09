import Config

# What `mix atlas.flow.gen` generates from this contract, and where. The contract is the
# Issue subflow for now; the composition (AtlasFlowContract.Software) replaces it when
# the other subflows arrive.
config :atlas_flow_generator,
  contract: AtlasFlowContract.Issue,
  targets: [rela: "../targets/rela", diagrams: "../targets/diagrams"],
  # Headers name the contract file from the repository's root.
  root: "../.."
