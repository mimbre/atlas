defmodule AtlasBFFContract.SectionsToggleTest do
  @moduledoc """
  Contract 0.16.0: `sections_toggle` is a local Console operation, by name only, that folds
  and unfolds the page's collapsible sections. It needs the version a 0.15.0 client lacks.
  """
  use ExUnit.Case, async: true

  alias AtlasBFFContract.Console

  test "sections_toggle is a local operation that takes nothing but its name" do
    assert "sections_toggle" in Console.operations()
    assert Console.operation?(%{"name" => "sections_toggle"})
    refute Console.operation?(%{"name" => "sections_toggle", "to" => "/workers"})
  end

  test "it arrives with contract 0.16.0" do
    assert Version.compare(AtlasBFFContract.Contract.__schema__().version, "0.16.0") != :lt
  end
end
