defmodule AtlasRuntimeBackend.Generator.PathsTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Paths

  test "parse" do
    assert Paths.parse("/") == {:ok, []}

    assert Paths.parse("/v1/books/:book_id") ==
             {:ok, [{:literal, "v1"}, {:literal, "books"}, {:param, :book_id}]}

    assert {:error, _} = Paths.parse("/v1/:a/:a")
    assert {:error, _} = Paths.parse("/v1/{id}")
    assert {:error, _} = Paths.parse("v1")
  end

  test "a literal wins over a parameter at the first segment where they differ" do
    {:ok, loans} = Paths.parse("/books/:id/loans")
    {:ok, part} = Paths.parse("/books/:id/:part")

    assert [{:loans, %{id: "b 1"}}] =
             Paths.match([part: part, loans: loans], ["books", "b%201", "loans"])

    assert [{:part, %{id: "b1", part: "x"}}] =
             Paths.match([part: part, loans: loans], ["books", "b1", "x"])

    assert Paths.match([part: part], ["books", "", "x"]) == []
    assert Paths.match([part: part], ["books", "b1"]) == []
  end

  test "several routes with one shape all match, in order" do
    {:ok, a} = Paths.parse("/v1/books")
    assert [{:search, %{}}, {:list, %{}}] = Paths.match([search: a, list: a], ["v1", "books"])
  end

  test "build" do
    {:ok, segments} = Paths.parse("/v1/books/:book_id")
    assert Paths.build(segments, %{book_id: "W 1/2"}) == "/v1/books/W%201%2F2"
  end
end
