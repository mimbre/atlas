# Tests that need rela's Python tooling or a rela binary run at the integration level:
# mix test --include integration (with rela/scripts/requirements.txt installed).
ExUnit.start(exclude: [:integration])
