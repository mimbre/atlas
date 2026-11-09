import Config

# The Bus hands facts and reads to this endpoint (Facts); it never knows what they mean.
# Kept "state" (a Bus wire name): it crosses the Bus link as the address and sender of
# facts, reads and answers to Runtime nodes that run their own checkout and config.
config :atlas_bus, store: "state", environment: "test"

# Gates records every verdict as a fact of this kind (rela's description defines it); its
# code names no kind.
config :atlas_gates, verdict_kind: "gate_verdict"

# The model Facts, Flow, Gates, Runtime and Control run (D-0083): the domain, compiled into
# the release and wired here, never named by a platform app. A private instance's settings may
# name another (runtime.exs, "model"); unit tests wire neutral models of their own.
if config_env() != :test, do: config(:atlas, model: Model.AtlasEyra)

import_config "#{config_env()}.exs"
