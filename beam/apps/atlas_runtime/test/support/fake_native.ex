defmodule AtlasRuntime.FakeNative do
  @moduledoc "The synthetic native CLI built by test_helper.exs (test/support/fake_native); never a provider."

  def path, do: System.fetch_env!("ATLAS_RUNTIME_FAKE_NATIVE")

  @doc "Writes an executable at `executable` that runs the fixture `mode` with its own argv."
  def install!(executable, mode, args \\ []) do
    words =
      Enum.map_join([path(), mode | args], " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))

    File.write!(executable, "#!/bin/sh\nexec #{words} \"$0\" \"$@\"\n")
    File.chmod!(executable, 0o700)
  end
end
