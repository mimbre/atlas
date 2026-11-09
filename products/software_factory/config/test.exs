import Config

# Unit tests start the layers themselves, with fakes where rela or a socket would be.
config :atlas_facts, start: false
config :atlas_control, start: false
config :logger, level: :warning
config :atlas_flow, start: false
config :atlas_gates, start: false
config :atlas_runtime, start: false
# Flow told of Code's receiver as the core's runtime.exs tells it (`code` in its settings),
# so tests and scripts run the model as the core does. No receiver runs here unless a test
# or script starts one (AtlasCode.Effects.Endpoint); the endpoint then answers.
config :atlas_flow,
  effect_receivers: %{
    "code" => %{"contract" => 1, "address" => "code/effects", "operations" => ["integrate"]}
  }
