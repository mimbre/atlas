defmodule AtlasControl.SpecTest do
  use ExUnit.Case, async: true

  require AtlasControl.Blocks, as: Blocks

  # The builders themselves are tested in the generator (bff/generator), on a neutral
  # contract; here: that Control's are made from Control's contract.
  test "Control's builders are its contract's blocks, models and markup" do
    schema = AtlasBFFContract.Contract.__schema__()
    assert Blocks.version() == schema.version

    for entry <- schema.models ++ schema.blocks,
        do: assert(macro_exported?(Blocks, entry.name, 1), "no builder for #{entry.name}")

    for entry <- schema.markup,
        do: assert(macro_exported?(Blocks, entry.name, 3), "no builder for #{entry.name}")
  end

  test "a builder call in Control with a missing prop fails at compile time" do
    assert_raise CompileError, ~r/confirm.cancel_to is required/, fn ->
      Code.compile_string("""
      defmodule Caller#{System.unique_integer([:positive])} do
        require AtlasControl.Blocks, as: Blocks
        def page, do: Blocks.confirm(title: "T", text: "x")
      end
      """)
    end
  end
end
