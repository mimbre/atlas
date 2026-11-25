defmodule RelaDSL.Description.OfficeTest do
  use ExUnit.Case, async: true

  alias RelaDSL.{Atlas, Limits, Office, Project}

  defp files,
    do: Project.files(Office.__rela__(:description), "app:\n  name: Office\n", "flows: {}\n")

  test "the Rela project of the neutral composition has its files, in order" do
    files = files()

    assert Enum.map(files, &elem(&1, 0)) == [
             "schema.yaml",
             "modules/post/schema.yaml",
             "compositions/office/bindings.yaml",
             "acl.yaml",
             "atlas.json",
             "flow-runtime.json",
             "flows.yaml",
             "atlas.manifest.json"
           ]
  end

  test "the manifest hashes the selected closure, data-entry.yaml and flows.yaml; atlas.json is a proof" do
    files = Map.new(files())
    manifest = JSON.decode!(files["atlas.manifest.json"])
    sha = &(:crypto.hash(:sha256, &1) |> Base.encode16(case: :lower))

    assert manifest["inputs"] == %{
             "schema.yaml" => sha.(files["schema.yaml"]),
             "modules/post/schema.yaml" => sha.(files["modules/post/schema.yaml"]),
             "compositions/office/bindings.yaml" =>
               sha.(files["compositions/office/bindings.yaml"]),
             "data-entry.yaml" => sha.("app:\n  name: Office\n")
           }

    refute Map.has_key?(manifest, "output_sha256")
    assert manifest["flows"] == %{"source" => "flows.yaml", "sha256" => sha.("flows: {}\n")}
  end

  test "each leaf of atlas.json comes from its one author: concept, module or composition" do
    letter = Office.__rela__({:entity, :letter})
    assert letter.extension["primary"] == "title"
    assert letter.extension["start"] == %{"key" => "l", "label" => "Letters"}
    assert letter.extension["properties"]["body"] == %{"multiline" => true}
    assert letter.schema["properties"]["title"]["required"] == true
    assert Office.__rela__({:entity, :nothing}) == nil
    assert Office.__rela__({:relation, :desk}).extension["component"]["key"] == "DK-{key}"
    assert Office.__rela__(:description).extension["progress"]["order"] == ["draft", "sent"]
  end

  test "the run mapping derives the choosing states, the input roles and their grants" do
    runtime =
      RelaDSL.Description.Plain.unorder(Office.__rela__(:description).flow_runtime)[
        "flow_runtime"
      ]

    assert runtime["selection"]["letter"]["choice_states"] == ["stuck"]
    assert runtime["inputs"]["roles"] == %{"editor" => "written_by"}
    assert runtime["inputs"]["acl"] == %{"editor" => %{"update" => ["letter"]}}
    assert runtime["fields"] == %{"flow" => "flow", "state" => "state"}
  end

  test "each environment compiles its subflows with its own limits, as flows.json holds them" do
    gates = Office.__rela__(:gates)

    [prod, test] =
      for env <- [:prod, :test] do
        [definition] =
          Map.values(Atlas.definitions(Limits.resolve(Office.__flows__(), gates, env), gates))

        [letter] = Office.subflows(env)
        assert letter.states() == ~w(dropped sent stuck write)
        assert letter.states() == Enum.sort(Map.keys(definition["states"]))
        definition
      end

    refute prod == test
  end
end
