defmodule AtlasRuntimeBackend.Generator.Targets.JsonTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Example.Api
  alias AtlasRuntimeBackend.Generator.Targets.Json

  @golden Path.expand("../golden/api.json", __DIR__)

  test "the example contract's file matches the golden file" do
    assert [{"api.json", body}] = Json.files(Api.__schema__(), name: "api")
    assert body == File.read!(@golden)
  end

  test "exposure, rights, events and the target's routes and statuses as data" do
    [{"lending.json", body}] = Json.files(Api.__schema__(), name: "lending")
    json = JSON.decode!(body)

    assert Map.keys(json) |> Enum.sort() == [
             "events",
             "exposed",
             "not_exposed",
             "rights",
             "targets",
             "version"
           ]

    assert json["not_exposed"] == ["audit"]
    assert %{"name" => "book", "model" => "book_changed", "id" => "sequence"} in json["events"]
    assert %{"name" => "tick", "model" => "tick"} in json["events"]

    [rest] = json["targets"]

    assert %{
             "method" => "POST",
             "path" => "/v1/books",
             "headers" => %{"request-key" => "request_key"},
             "body" => ["title", "place", "until"]
           } =
             hd(rest["resources"])

    refused = Enum.find(rest["statuses"], &(&1["outcome"] == "refused"))

    assert %{
             "by" => "reason",
             "cases" => [%{"value" => "invalid", "status" => 400, "type" => "invalid"} | _]
           } = refused

    refute Map.has_key?(refused, "status")
  end
end
