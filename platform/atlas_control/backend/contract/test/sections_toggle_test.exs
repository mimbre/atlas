defmodule AtlasBFFContract.SectionsToggleTest do
  @moduledoc "Page sections no longer have a toggle operation."
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Console

  test "sections_toggle is not a Console operation" do
    refute "sections_toggle" in Console.operations()
    refute Console.operation?(%{"name" => "sections_toggle"})
  end
end
