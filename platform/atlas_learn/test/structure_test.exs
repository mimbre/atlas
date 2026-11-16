defmodule AtlasLearn.StructureTest do
  @moduledoc """
  Learn's structure shows its purpose: its modules are named after what they observe, find
  or write, never after a transport or a tool, which stay private inside the observation
  that needs them.
  """
  use ExUnit.Case, async: true

  @tools ~r/(Github|GitHub|Json|JSON|Http|HTTP|Ssh|SSH|Script|Socket|Cli|CLI)/

  test "no module is named after a transport or a tool" do
    {:ok, modules} = :application.get_key(:atlas_learn, :modules)
    assert length(modules) > 5

    for module <- modules, name = inspect(module), not String.starts_with?(name, "Mix.Tasks") do
      refute name =~ @tools, "#{name} is named after a tool; name it after what Learn does"
    end
  end
end
