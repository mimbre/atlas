defmodule AtlasRuntimeModel.Generator.Targets.JsonTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeModel.Generator.{Example, Targets.Json}

  test "one file named after the contract: the schema shape and how records are encoded" do
    [{"library.json", body}] = Json.files(:library, Example.__schema__())
    json = JSON.decode!(body)

    assert Map.keys(json) == ["encoding", "entities", "version"]
    assert json["version"] == "1.2.0"

    assert Enum.map(json["entities"], & &1["name"]) ==
             ["author", "paper", "ebook", "review", "book", "loan_entry"]

    entities = Map.new(json["entities"], &{&1["name"], &1})
    assert entities["author"]["persistence"] == nil

    assert entities["book"]["persistence"] == %{
             "form" => "json_file",
             "path" => "books/{book_id}.json",
             "format_version" => 2
           }

    assert entities["loan_entry"]["persistence"]["path"] == "books/loans.json"
    types = Map.new(entities["book"]["fields"], &{&1["name"], &1["type"]})
    assert types["edition"] == "one of paper | ebook"
    assert types["authors"] == "list of author"
    assert types["reviews"] == "list of review"
    assert types["genre"] == "enum novel | poetry | essay"
    assert hd(entities["review"]["fields"])["type"] == "enum one | two | three"

    assert json["encoding"]["strict"] =~ "never migrated silently"
    assert String.ends_with?(body, "}\n")
  end

  test "no encoding without records" do
    schema = %{version: "1", entities: [%{name: :a, fields: [], persistence: nil}]}
    [{"only.json", body}] = Json.files(:only, schema)
    assert Map.keys(JSON.decode!(body)) == ["entities", "version"]
  end
end
