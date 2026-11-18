# Tests tagged :rela run the pinned rela; they run only when ATLAS_RELA_BIN names its folder.
# A bare assert_receive waits up to 30 s for its message (bin/lib/test_waits.rb), not 100 ms.
ExUnit.start(
  assert_receive_timeout: 30_000,
  exclude: if(System.get_env("ATLAS_RELA_BIN") in [nil, ""], do: [:rela], else: [])
)

# Gates and Flow run the model they are wired to: here, the one under test.
Application.put_env(:atlas, :model, Model.AtlasEyra)

# Flow told of Code's receiver of integrate effects, as the core's runtime.exs tells it.
Application.put_env(:atlas_flow, :effect_receivers, %{
  "code" => %{"contract" => 1, "address" => "code/effects", "operations" => ["integrate"]}
})
