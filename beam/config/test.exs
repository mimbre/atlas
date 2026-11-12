import Config

# Unit tests start the layers themselves, with fakes where rela or a socket would be.
config :atlas_facts, start: false
config :atlas_control, start: false
config :logger, level: :warning
config :atlas_flow, start: false
config :atlas_gates, start: false
config :atlas_runtime, start: false
