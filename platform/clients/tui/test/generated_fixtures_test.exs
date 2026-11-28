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

    for block <- fixtures["blocks"],
        variant <- AtlasBFF.Targets.FixtureVariants.combinations(block) do
      decoded = AtlasTui.Blocks.decode(variant["sample"])
      refute match?(%AtlasTui.Blocks.Fallback{}, decoded), "#{block["name"]}: #{variant["case"]}"
    end
  end

  test "the actual TUI view renders generated Markdown and plain text specimens" do
    [{"fixtures.json", body}] =
      AtlasBFF.Targets.Fixtures.files(AtlasBFFContract.Contract.__schema__())

    fixtures = JSON.decode!(body)["fixtures"]
    text = Enum.find(fixtures["blocks"], &(&1["name"] == "text"))

    for syntax <- ["plain", "markdown"] do
      sample =
        AtlasBFF.Targets.FixtureVariants.combine(text, ["syntax"], %{
          "syntax" => syntax,
          "text" => "long"
        })["sample"]

      page = %{
        "op" => "page",
        "path" => "/k/example",
        "reason" => "open",
        "title" => "Example",
        "blocks" => [sample],
        "markup" => []
      }

      screen =
        page
        |> AtlasTui.ConsoleProjectionFixture.model()
        |> AtlasTui.View.render(100, 40, 5)
        |> AtlasTui.View.plain()

      assert screen =~ "An example heading"
      assert screen =~ "First item"
    end
  end

  test "recursively generated nested optional fields reach the TUI decoder" do
    schema = AtlasBFFContract.Contract.__schema__()

    block =
      schema
      |> AtlasBFF.Targets.FixtureCombinations.stream(:block, :item)
      |> Stream.take(10_000)
      |> Enum.find(fn sample ->
        case sample["props"]["fields"] do
          [pair] -> Map.has_key?(pair, "value") and Map.has_key?(pair, "syntax")
          _ -> false
        end
      end)

    assert block
    assert [%{"value" => _, "syntax" => _}] = block["props"]["fields"]
    refute match?(%AtlasTui.Blocks.Fallback{}, AtlasTui.Blocks.decode(block))
    models = Map.new(schema.models, &{&1.name, &1.fields})

    assert :ok =
             AtlasBFF.Targets.Protocol.validate_value!(
               models,
               {:list, :pair},
               block["props"]["fields"]
             )
  end
end
