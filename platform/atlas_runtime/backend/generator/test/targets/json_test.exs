defmodule AtlasRuntimeBackend.Generator.Targets.JsonTest do
  use ExUnit.Case, async: true

  alias AtlasRuntimeBackend.Generator.Example.Api
  alias AtlasRuntimeBackend.Generator.Targets.Json

  test "keys sorted, indented by two, one trailing newline; the contract's version" do
    assert [{"api.json", body}] = Json.files(Api.__schema__(), name: "api")
    assert body == layout(JSON.decode!(body))
    assert JSON.decode!(body)["version"] == Api.__schema__().version
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
