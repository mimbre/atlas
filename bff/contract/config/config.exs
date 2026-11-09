import Config

# What `mix atlas.gen` generates from this contract, and where.
config :atlas_bff,
  contract: AtlasBFFContract.Contract,
  targets: [
    json: "../targets/json",
    # The Swift package; its fixture tests check that hello, welcome and boot lines carry
    # this contract's version in `spec`.
    swift: {"../targets/swift", package: "AtlasControlKit", version_field: "spec"}
  ],
  # Headers name the contract file from the repository's root.
  root: "../.."
