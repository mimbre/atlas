import Config

# The Bus hands facts and reads to this endpoint (Facts); it never knows what they mean.
# Kept "state" (a Bus wire name): it crosses the Bus link as the address and sender of
# facts, reads and answers to the Runtime services linked to the core.
config :atlas_bus, store: "state", environment: "test"

# Gates records every verdict as a fact of this kind (rela's description defines it); its
# code names no kind.
config :atlas_gates, verdict_kind: "gate_verdict"

# The To-Do Flow gives the one a run is handed over to (work acquisition decision
# 2026-11-17, decision 4; M3 S3): its kind and ids, the Assignment it is assigned through
# (the component relation and its relation to the holder) and its neutral texts
# (`{subject}`: the key of what was handed over, `{from}`: who handed it over). The model's
# words, kept here: Flow's code names no kind (AtlasFlow.Runs.HandOver).
config :atlas_flow, :hand_over,
  kind: "to_do",
  id_prefix: "TD-",
  digits: 2,
  assignment: "assignment",
  assigned_to: "assigned_to",
  values: [status: "open"],
  title: "Pick up {subject}",
  instructions:
    "{from} handed {subject} over to you. Until you pick it up, nobody supervises its flow " <>
      "and no work of it is offered to a Runtime. Open {subject} and pick it up yourself, " <>
      "then close this To-Do."

# The model Facts, Flow, Gates, Runtime and Control run (D-0083): the domain, compiled into
# the release and wired here, never named by a platform app. A private instance's settings may
# name another (runtime.exs, "model"); unit tests wire neutral models of their own.
if config_env() != :test, do: config(:atlas, model: Model.AtlasEyra)

import_config "#{config_env()}.exs"
