defmodule AtlasBFFContract.FixturesTargetTest do
  use ExUnit.Case, async: true

  test "the fixture target follows the full contract, including boot and page wire messages" do
    schema = AtlasBFFContract.Contract.__schema__()
    [{"fixtures.json", json}] = AtlasBFF.Targets.Fixtures.files(schema)
    fixtures = JSON.decode!(json)["fixtures"]
    assert Enum.map(fixtures["blocks"], & &1["name"]) == Enum.map(schema.blocks, &to_string(&1.name))
    control = Enum.find(fixtures["channels"], &(&1["channel"] == "control"))
    assert Enum.any?(control["messages"], &(&1["sample"]["op"] == "boot"))
    assert Enum.any?(control["messages"], &(&1["sample"]["op"] == "page"))
  end
end
