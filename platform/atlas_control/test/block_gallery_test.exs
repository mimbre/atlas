defmodule AtlasControl.BlockGalleryTest do
  use ExUnit.Case, async: true

  alias AtlasControl.{BlockGallery, Pages, Shell, Shop}

  test "all visual block examples come from the current shared schema and project for Console" do
    gallery = BlockGallery.render(:block_gallery)
    rows = Enum.find(gallery.blocks, &(&1["type"] == "list"))["props"]["rows"]
    names = AtlasBFFContract.Contract.__schema__().blocks |> Enum.map(&to_string(&1.name))
    assert length(rows) == 2 * (length(names) - 1)
    assert Enum.any?(rows, &(&1["to"] == "/_blocks/unknown/required"))
    assert Enum.any?(rows, &(&1["to"] == "/_blocks/unknown/full"))

    for row <- rows do
      route = Pages.route(row["to"])
      assert {:block_gallery_sample, name, variant} = route
      assert name in names and variant in ~w(required full)
      page = BlockGallery.render(route)
      assert [%{"type" => ^name}] = page.blocks

      message = %{
        "op" => "page",
        "path" => row["to"],
        "title" => page.title,
        "back" => page.back,
        "blocks" => page.blocks,
        "markup" => page.markup
      }

      result = AtlasControl.Console.project(message, [])
      assert match?({:ok, _}, result), inspect({row, result})
      {:ok, projected} = result
      assert {:ok, _} = AtlasBFFContract.Console.compile(projected)
    end
  end

  test "configured gallery is navigable in the shell and samples stay within its tab" do
    model =
      AtlasControl.Model.catalog(Shop.Shelled, %{
        "tabs" => [
          %{
            "id" => "blocks",
            "label" => "Blocks",
            "to" => "/_blocks",
            "section" => "browse",
            "key" => "g b"
          }
        ]
      })

    assert {:ok, shell} = Shell.boot(model, nil, "/_blocks/text/full")
    assert shell["initial_to"] == "/_blocks/text/full"
    assert shell["active_tab"] == "blocks"
  end
end
