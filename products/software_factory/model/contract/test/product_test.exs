defmodule Model.ProductTest do
  @moduledoc """
  SC-Atlas-20: products are data, and a scene belongs to one. The generated schema has
  the kind `product` and the relation `of_product`; a scene's key carries its product's
  code (SC-<code>-NN), as Control and Flow read the id spec; the home page is the list of
  products.
  """
  use ExUnit.Case, async: true

  alias Model.AtlasEyra

  # The description the model generates (`targets/rela/`, checked by `mix model.gen --check`).
  defp schema, do: AtlasEyra.__rela__(:description).schema
  defp atlas, do: JSON.decode!(File.read!("../targets/rela/atlas.json"))

  test "the generated schema has the product and a scene's relation to its one product" do
    %{"entities" => %{"product" => product}, "relations" => %{"of_product" => of}} = schema()

    assert product["id_type"] == "manual" and product["id_prefix"] == "PD-"
    assert %{"required" => true} = product["properties"]["name"]
    assert %{"required" => true, "unique" => true} = product["properties"]["code"]
    assert Map.has_key?(product["properties"], "description")

    assert of["from"] == ["scene"] and of["to"] == ["product"]
    assert of["max_outgoing"] == 1
    assert of["inverse"]["id"] == "scenes"

    # Existing scenes stay valid before they are linked: the link is not required.
    refute Map.has_key?(of, "min_outgoing")

    assert Model.Product in Model.Eyra.__rela__(:module).concepts
  end

  test "a scene's create asks its product, and its key carries the product's code" do
    scene = atlas()["entities"]["scene"]["create"]

    assert scene["ask"] == ["title", "description", "of_product"]

    assert scene["id"] == %{
             "prefix" => "SC-",
             "code" => %{"relation" => "of_product", "field" => "code"},
             "digits" => 2
           }

    # Control reads it from kinds/0, Flow from ids/0.
    k = Enum.find(AtlasEyra.kinds(), &(&1.name == "scene"))
    assert k.id.prefix == "SC-" and k.id.code == %{relation: "of_product", field: "code"}
    assert "SC-" in k.id.prefixes
    assert AtlasEyra.ids()["scene"]["code"] == %{"relation" => "of_product", "field" => "code"}

    # A product's own key is a plain number; use cases and issues keep theirs.
    assert AtlasEyra.ids()["product"]["prefix"] == "PD-"
    assert AtlasEyra.ids()["use_case"]["prefix"] == "UC-Atlas-"
    assert AtlasEyra.ids()["issue"]["prefix"] == "IS-Atlas-"
  end

  test "the product is the model's top level: the home page lists products" do
    assert AtlasEyra.start_page().top == "product"

    # A scene belongs under its product, so it is no longer a top kind of its own.
    scene = Enum.find(AtlasEyra.kinds(), &(&1.name == "scene"))
    refute scene.top
    assert Enum.find(scene.relations, &(&1.name == "of_product")).parent

    tab = Enum.find(AtlasEyra.shell(%{})["tabs"], &(&1["id"] == "products"))
    assert tab["to"] == "/k/product"
  end
end
