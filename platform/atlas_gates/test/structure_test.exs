defmodule AtlasGates.StructureTest do
  @moduledoc """
  Gates' structure shows its purpose: definitions, rules, requests, verdicts, the record
  and the ways to Facts, never a module named after a transport or a tool.
  """
  use ExUnit.Case, async: true

  @tools ~r/(Github|GitHub|Json|JSON|Http|HTTP|Ssh|SSH|Script|Socket|Cli|CLI|Shell)/

  test "no module is named after a transport or a tool" do
    {:ok, modules} = :application.get_key(:atlas_gates, :modules)
    assert length(modules) > 5

    for module <- modules, name = inspect(module), not String.starts_with?(name, "Mix.Tasks") do
      refute name =~ @tools, "#{name} is named after a tool; name it after what Gates does"
    end
  end
end
