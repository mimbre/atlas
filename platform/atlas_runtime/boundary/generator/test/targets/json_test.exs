defmodule AtlasRuntimeBoundary.Generator.Targets.JsonTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.{Example, Targets.Json}

  @golden Path.expand("../golden/example.json", __DIR__)

  test "the example contract's file matches the golden file" do
    assert [{"example.json", body}] = Json.files(Example.__schema__(), name: "example")
    assert body == File.read!(@golden)
  end

  test "one file per contract, named by the option, with only the schema's sections" do
    assert [{"lending.json", body}] = Json.files(Example.__schema__(), name: "lending")

    assert body |> JSON.decode!() |> Map.keys() |> Enum.sort() == [
             "capabilities",
             "invalid_input",
             "models",
             "version"
           ]

    without = %{Map.delete(Example.__schema__(), :capabilities) | invalid_input: nil}
    [{_, body}] = Json.files(without, name: "x")
    assert body |> JSON.decode!() |> Map.keys() |> Enum.sort() == ["models", "version"]
  end

  test "enum, one_of, datetime, capabilities and outcomes as data" do
    [{_, body}] = Json.files(Example.__schema__(), name: "example")
    json = JSON.decode!(body)
    book = Enum.find(json["models"], &(&1["name"] == "book"))
    fields = Map.new(book["fields"], &{&1["name"], &1})

    assert fields["condition"] == %{
             "name" => "condition",
             "type" => "enum",
             "values" => ["new", "worn", "badly-worn"],
             "required" => true
           }

    assert %{"type" => "one_of", "models" => ["shelf", "branch"], "tag" => "kind"} =
             fields["place"]

    assert %{"type" => "datetime", "format" => "ISO-8601", "required" => false} = fields["due_at"]
    assert %{"type" => "list of enum", "values" => ["large_print", "audio"]} = fields["labels"]

    assert [lend, count, _find, download] = json["capabilities"]

    assert lend == %{
             "name" => "lend",
             "input" => "lend_input",
             "right" => "lend",
             "outcomes" => [
               %{"name" => "lent", "model" => "book"},
               %{"name" => "short", "model" => "shortage"},
               %{"name" => "declined", "model" => "refusal"},
               %{"name" => "missing"}
             ]
           }

    refute Map.has_key?(count, "input")

    scan = Enum.find(json["models"], &(&1["name"] == "scan"))

    assert Enum.find(scan["fields"], &(&1["name"] == "content")) == %{
             "name" => "content",
             "type" => "stream",
             "description" => "byte stream",
             "required" => true
           }

    assert download == %{
             "name" => "download",
             "input" => "download_input",
             "right" => "browse",
             "outcomes" => [%{"name" => "downloaded", "model" => "scan"}, %{"name" => "missing"}]
           }

    assert json["invalid_input"] ==
             %{"outcome" => "declined", "set" => %{"why" => "unreadable"}, "detail" => "note"}
  end
end
