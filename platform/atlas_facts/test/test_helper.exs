# Tests that need rela's Python tooling or a rela binary run at the integration level:
# mix test --include integration (with platform/atlas_facts/rela/scripts/requirements.txt installed).
# The read latency measurement (IS-Atlas-85) runs on its own: mix test --only bench.
ExUnit.start(AtlasTestAwait.exunit_options(exclude: [:integration, :bench]))

# Facts stores by the model it is wired to: here the neutral workshop, unless a test gives
# one of its own (`model:`).
Application.put_env(:atlas, :model, AtlasFacts.Workshop)
