defmodule AtlasAgent.ToolsTest do
  use ExUnit.Case, async: true

  alias AtlasAgent.Tools

  # What Control's kinds page (`/_kinds`) and a create form say, by hand; the kinds are
  # made up, as the agent knows none.
  @part %{
    "kind" => "part",
    "title" => "Part (part)",
    "fields" => [
      ["Kind", "part"],
      ["About", "A part of a thing."],
      ["Create asks", "title, notes"],
      ["Id", "made: PA- and the next number (PA-NN)"],
      ["Belongs under", "thing"],
      ["Has under it", "nothing"],
      [
        "Fields",
        "title: text; required; asked on create\nsize: one of s, m\nnotes: text of several lines; asked on create\nremote_id: text; set by a connector, never in a form"
      ]
    ],
    "actions" => [
      %{"label" => "Create part", "key" => "c", "to" => "/k/part/new"},
      %{"label" => "Update part", "key" => "u", "to" => "/k/_/<key>/edit"},
      %{"label" => "Delete part", "key" => "d", "to" => "/k/_/<key>/delete"}
    ]
  }

  @form %{
    "title" => "Create part",
    "submit_to" => %{"endpoint" => "create", "params" => %{"kind" => "part"}},
    "inputs" => [
      %{"name" => "title", "label" => "Title", "kind" => "text", "required" => true},
      %{"name" => "notes", "label" => "Notes", "kind" => "multiline"}
    ]
  }

  test "put: the create form's inputs, the kind it goes in, the command line" do
    tool = Tools.put(@part, @form)

    assert tool["tool"] == "put"
    assert tool["kind"] == "part"
    assert tool["in"] == "thing"
    assert tool["title"] == "Create part"
    assert tool["about"] == "A part of a thing."
    assert Enum.map(tool["asks"], & &1["name"]) == ["title", "notes"]
    assert hd(tool["asks"])["required"]
    assert tool["usage"] == "put part --in <thing key> --title <text> --notes <lines>"
  end

  test "put of a top kind goes in nothing" do
    fields =
      Enum.map(@part["fields"], fn
        ["Belongs under", _] -> ["Belongs under", "nothing; a top kind"]
        pair -> pair
      end)

    top = %{@part | "fields" => fields}

    assert Tools.put(top, @form)["in"] == nil
  end

  test "set: the fields a user may change, not those only a connector fills" do
    tool = Tools.set(@part)
    # Named as Control names the update action on every page.
    assert tool["title"] == "Update part"
    assert Tools.set(Map.delete(@part, "actions"))["title"] == "Set part"
    assert Enum.map(tool["fields"], & &1["name"]) == ["title", "size", "notes"]
    assert tool["usage"] == "set <part key> <field>=<text> ..."
  end

  test "find and write?" do
    tools = [Tools.put(@part, @form), Tools.set(@part)]
    assert Tools.find(tools, "put", "part")["kind"] == "part"
    assert Tools.find(tools, "put", "other") == nil
    assert Tools.write?(Tools.set(@part))
    assert Tools.write?(%{"tool" => "delete"})
    refute Tools.write?(%{"tool" => "get"})
  end

  test "the kind of a page, from its path" do
    assert Tools.kind_of_path("/k/part/PA-01") == "part"
    assert Tools.kind_of_path("/k/part") == nil
    assert Tools.kind_of_path("/") == nil
  end
end
