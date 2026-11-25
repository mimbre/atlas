defmodule AtlasRuntimeBoundary.Generator.Targets.JsonTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBoundary.Generator.{Example, Targets.Json}

  test "keys sorted, indented by two, one trailing newline" do
    assert [{"example.json", body}] = Json.files(Example.__schema__(), name: "example")
    assert body == layout(JSON.decode!(body))
  end

  test "the version, and every model of the contract with its fields, in the contract's order" do
    schema = Example.__schema__()
    [{_, body}] = Json.files(schema, name: "example")
    json = JSON.decode!(body)

    assert json["version"] == schema.version

    assert Enum.map(json["models"], & &1["name"]) ==
             Enum.map(schema.models, &Atom.to_string(&1.name))

    for {model, entry} <- Enum.zip(schema.models, json["models"]) do
      assert Enum.map(entry["fields"], &{&1["name"], &1["required"]}) ==
               Enum.map(model.fields, &{Atom.to_string(&1.name), &1.required})
    end

    assert Enum.map(json["capabilities"], & &1["name"]) ==
             Enum.map(schema.capabilities, &Atom.to_string(&1.name))
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

    assert [lend, count, _find, download, upload] = json["capabilities"]

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

    upload_input = Enum.find(json["models"], &(&1["name"] == "upload_input"))

    assert Enum.find(upload_input["fields"], &(&1["name"] == "pages")) == %{
             "name" => "pages",
             "type" => "stream",
             "description" => "byte stream",
             "required" => true
           }

    assert upload == %{
             "name" => "upload",
             "input" => "upload_input",
             "right" => "lend",
             "outcomes" => [
               %{"name" => "received"},
               %{"name" => "declined", "model" => "refusal"}
             ]
           }

    assert json["invalid_input"] ==
             %{"outcome" => "declined", "set" => %{"why" => "unreadable"}, "detail" => "note"}
  end

  # The layout the file target promises: keys sorted, two spaces per level, a newline at the end.
  defp layout(value), do: IO.iodata_to_binary(layout(value, "")) <> "\n"

  defp layout(map, at) when is_map(map) and map_size(map) > 0 do
    inner =
      for {k, v} <- Enum.sort(map), do: [at, "  ", JSON.encode!(k), ": ", layout(v, at <> "  ")]

    ["{\n", Enum.intersperse(inner, ",\n"), "\n", at, "}"]
  end

  defp layout(list, at) when is_list(list) and list != [] do
    inner = for v <- list, do: [at, "  ", layout(v, at <> "  ")]
    ["[\n", Enum.intersperse(inner, ",\n"), "\n", at, "]"]
  end

  defp layout(value, _at), do: JSON.encode!(value)
end
