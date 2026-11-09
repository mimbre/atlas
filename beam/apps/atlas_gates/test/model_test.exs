defmodule AtlasGates.ModelTest do
  # Changes the configured model: not alongside the tests that evaluate its gates.
  use ExUnit.Case, async: false

  test "Gates evaluates the gates of the model it is wired to, and none without one" do
    assert AtlasGates.Definitions.gates() == AtlasGates.Neutral.gates()
    model = Application.fetch_env!(:atlas, :model)
    on_exit(fn -> Application.put_env(:atlas, :model, model) end)
    Application.delete_env(:atlas, :model)
    assert_raise ArgumentError, fn -> AtlasGates.Definitions.gates() end
    Application.put_env(:atlas, :model, AtlasGates.Facts)
    assert_raise ArgumentError, ~r/no gates/, fn -> AtlasGates.Definitions.gates() end
  end
end
