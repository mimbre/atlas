# Tests that need rela's Python tooling or a rela binary run at the integration level:
# mix test --include integration (with rela/scripts/requirements.txt installed).
ExUnit.start(exclude: [:integration])

# Facts stores by the model it is wired to: here the neutral workshop, unless a test gives
# one of its own (`model:`).
Application.put_env(:atlas, :model, AtlasFacts.Workshop)
