# Tests tagged :rela run the pinned rela; they run only when ATLAS_RELA_BIN names its folder.
ExUnit.start(exclude: if(System.get_env("ATLAS_RELA_BIN") in [nil, ""], do: [:rela], else: []))

# Gates and Flow run the model they are wired to: here, the one under test.
Application.put_env(:atlas, :model, Model.AtlasEyra)
