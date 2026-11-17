defmodule AtlasRuntimeBackend.Generator.Targets.RoutesTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Example.{Api, Bare, Extended, Rest}
  alias AtlasRuntimeBackend.Generator.Targets.Routes

  @golden Path.expand("../golden/routes.json", __DIR__)

  defp routes(schema), do: schema |> Routes.files([]) |> then(fn [{_, b}] -> JSON.decode!(b) end)

  test "the extended example's file matches the golden file" do
    assert [{"api/routes.json", body}] = Routes.files(Extended.__schema__(), name: "api")
    assert [{"routes.json", ^body}] = Routes.files(Extended.__schema__(), [])
    assert body == File.read!(@golden)
  end

  test "the same route table the generated router answers by" do
    json = routes(Api.__schema__())

    for route <- Rest.__routes__() do
      entry = Enum.find(json["routes"], &(&1["capability"] == Atom.to_string(route.capability)))
      assert entry["method"] == route.method |> Atom.to_string() |> String.upcase()
      assert entry["path"] == Routes.template(route.path)
      assert Map.has_key?(entry, "stream") == route.stream

      assert Enum.map(entry["outcomes"], &{&1["outcome"], &1["status"], &1["type"]}) ==
               Enum.map(route.outcomes, &{Atom.to_string(&1.outcome), &1.status, &1.type})
    end

    assert length(json["routes"]) == length(Rest.__routes__())
  end

  test "paths, bound request parts, statuses and events" do
    json = routes(Api.__schema__())
    by = Map.new(json["routes"], &{&1["capability"], &1})

    assert %{
             "method" => "POST",
             "path" => "/v1/books",
             "right" => "lend",
             "headers" => %{"request-key" => %{"field" => "request_key", "required" => false}},
             "body" => ["title", "place", "until"]
           } = by["lend"]

    assert by["find_book"]["path"] == "/v1/books/{book_id}"
    assert by["search"]["query"] == %{"title" => %{"field" => "title", "required" => true}}
    assert Map.has_key?(by["find_book"], "etag")
    bare = Map.new(routes(Bare.__schema__())["routes"], &{&1["capability"], &1})
    refute Map.has_key?(bare["find_book"], "etag")

    lent = Enum.find(by["lend"]["outcomes"], &(&1["outcome"] == "lent"))
    assert lent["headers"] == %{"location" => "/v1/books/{book.book_id}"}
    assert lent["body"] == "book"

    assert %{"events" => ["book", "tick", "restart"], "resume_header" => "last-event-id"} =
             by["watch"]["stream"]

    assert Enum.map(by["watch"]["outcomes"], &{&1["outcome"], &1["opens_with"]}) ==
             [{"watching", nil}, {"restart", "restart"}]

    assert %{"name" => "book", "model" => "book_changed", "id" => "sequence"} in json["events"]
    assert %{"name" => "guest", "rights" => ["browse"]} in json["listeners"]
  end

  test "picks up errors, etag and headers from the contract's data" do
    json = routes(Extended.__schema__())
    by = Map.new(json["routes"], &{&1["capability"], &1})

    assert %{"kind" => "unauthenticated", "status" => 401, "type" => "unauthenticated"} in json[
             "errors"
           ]

    assert %{"kind" => "origin_refused", "status" => 403, "type" => "origin-refused"} in json[
             "errors"
           ]

    assert by["find_book"]["etag"] == %{
             "field" => "edition",
             "request_header" => "if-none-match",
             "not_modified" => 304
           }

    refute Map.has_key?(by["search"], "etag")
    returned = Enum.find(by["give_back"]["outcomes"], &(&1["outcome"] == "returned"))
    assert returned["headers"] == %{"replayed" => "true"}
  end

  test "an unknown option or target is refused" do
    assert_raise ArgumentError, ~r/unknown option :servers/, fn ->
      Routes.files(Api.__schema__(), servers: [])
    end

    assert_raise ArgumentError, ~r/no target :grpc/, fn ->
      Routes.files(Api.__schema__(), target: :grpc)
    end
  end
end
