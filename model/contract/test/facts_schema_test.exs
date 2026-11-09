defmodule Model.FactsSchemaTest do
  @moduledoc """
  Facts refuses to start unless rela serves the schema the model was built with
  (`rela_schema/0`). The fixture is what the pinned rela (26.11.2) serves for `rela/` at
  `GET /api/v1/_schema`; regenerate it from a running rela when the model's kinds change.
  """
  use ExUnit.Case, async: true

  @served "test/fixtures/rela-served-schema.json" |> File.read!() |> JSON.decode!()

  test "the schema the model says rela serves is the one rela serves" do
    assert AtlasFacts.Model.mismatch(Model.AtlasEyra, @served) == nil
    assert Model.AtlasEyra.rela_schema() == Map.take(@served, ["entities", "relations", "types"])
  end

  test "a schema that differs is refused, and says where" do
    served = put_in(@served, ["entities", "decision", "properties", "title", "required"], false)
    reason = AtlasFacts.Model.mismatch(Model.AtlasEyra, served)
    assert reason =~ "entities.decision.properties.title.required is false, built true"
    assert reason =~ "Deploy rela and the core from the same build"
  end

  test "the store's rules, what a write brings along and the connector are compiled in" do
    lookup = %{
      "current" => fn -> nil end,
      "fact" => fn _, _ -> nil end,
      "list" => fn _ -> {:ok, []} end,
      "fingerprint" => &AtlasBus.SubjectFingerprint.of/2
    }

    assert [
             %{"as" => "component", "kind" => "assignment", "key" => "AS-D-0100"},
             %{"as" => "fact", "key" => "D-0100"}
           ] =
             Model.AtlasEyra.with_change(
               "decision",
               %{"op" => "create", "key" => "D-0100", "values" => %{}, "links" => %{}},
               lookup
             )

    assert {:refuse, [why]} =
             Model.AtlasEyra.check(
               "decision",
               %{"op" => "delete", "key" => "D-0100", "values" => %{}, "links" => %{}},
               %{"by" => "melle"},
               Map.put(lookup, "incoming", fn _, _, _ -> [] end)
             )

    assert why =~ "never deleted"

    assert %{"system" => "github", "names" => %{"kind" => "issue", "prefix" => "IS-Atlas-"}} =
             Model.AtlasEyra.connector("pull_request")

    assert Model.AtlasEyra.connector("scene") == nil
  end
end
