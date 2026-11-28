# From products/software_factory: MIX_ENV=test mix run --no-start ../../tools/control-fixtures/product_pages_test.exs
Code.require_file("product_pages.exs", __DIR__)
ExUnit.start()

defmodule ControlFixtures.ProductPagesTest do
  use ExUnit.Case, async: false

  test "product BFF renders synthetic decisions, scenes, to-dos and lists for both surfaces" do
    pages = ControlFixtures.ProductPages.build!()
    tabs = [
      %{"id" => "decision", "label" => "Decisions", "to" => "/k/decision", "section" => "work"},
      %{"id" => "scene", "label" => "Scenes", "to" => "/k/scene", "section" => "work"},
      %{"id" => "todo", "label" => "To-Dos", "to" => "/k/to_do", "section" => "work"}
    ]

    for {path, title} <- [
          {"/k/decision/D-7", "How do we store examples?"},
          {"/k/scene/SC-1", "Make examples easy to inspect"},
          {"/k/to_do/TD-12", "Prepare the local examples"}
        ] do
      page = Map.fetch!(pages, path)
      assert Enum.any?(page["blocks"], &(get_in(&1, ["props", "title"]) == title))
      assert :ok = AtlasBFF.Markup.check(Enum.map(page["blocks"], & &1["id"]), page["markup"])
      assert {:ok, projected} = AtlasControl.Console.project(page, tabs)
      assert {:ok, _} = AtlasBFFContract.Console.compile(projected)
    end

    for path <- ["/k/decision", "/k/scene", "/k/to_do", "/k/issue"] do
      assert Enum.any?(pages[path]["blocks"], &(&1["type"] == "list"))
    end

    assert Enum.any?(pages["/k/to_do/TD-12"]["blocks"], &(&1["type"] == "instruction"))
    assert Enum.any?(pages["/k/decision/D-7"]["blocks"], &(&1["type"] == "option"))
  end
end
