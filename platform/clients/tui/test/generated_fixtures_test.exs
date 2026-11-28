defmodule AtlasTui.GeneratedFixturesTest do
  use ExUnit.Case, async: true

  test "every generated block specimen decodes without a fallback" do
    [{"fixtures.json", body}] =
      AtlasBFF.Targets.Fixtures.files(AtlasBFFContract.Contract.__schema__())

    fixtures = JSON.decode!(body)["fixtures"]

    for block <- fixtures["blocks"], variant <- block["variants"] do
      decoded = AtlasTui.Blocks.decode(variant["sample"])
      refute match?(%AtlasTui.Blocks.Fallback{}, decoded), "#{block["name"]}: #{variant["case"]}"
    end
  end
end
