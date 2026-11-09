defmodule Model.DescriptionTest do
  use ExUnit.Case, async: true

  alias Model.AtlasEyra
  alias RelaDSL.{DefinitionDigest, Project}

  @rela "../../rela"

  defp committed(path), do: File.read!(Path.join(@rela, path))
  defp description, do: AtlasEyra.__rela__(:description)

  defp files,
    do: Project.files(description(), committed("data-entry.yaml"), committed("flows.yaml"))

  # The safety net of the cutover (Rela DSL design, slice 2): what the model generates is
  # what rela/ holds, byte for byte. mix model.gen --check says the same in CI.
  test "every file of the Rela project is what the model generates, byte for byte" do
    files = files()

    assert Enum.map(files, &elem(&1, 0)) == [
             "schema.yaml",
             "modules/foundation/schema.yaml",
             "modules/foundation/audit/schema.yaml",
             "modules/software/schema.yaml",
             "modules/eyra/schema.yaml",
             "compositions/atlas-eyra/bindings.yaml",
             "acl.yaml",
             "atlas.json",
             "flow-runtime.json",
             "flows.yaml",
             "atlas.manifest.json"
           ]

    for {path, body} <- files, do: assert(body == committed(path), path)
  end

  test "nothing else in the project's generated folders, and only data-entry.yaml is hand-written" do
    generated = Enum.map(files(), &elem(&1, 0))

    on_disk =
      for folder <- Project.owned_folders(),
          path <- Path.wildcard(Path.join([@rela, folder, "**", "*"])),
          File.regular?(path),
          do: Path.relative_to(path, @rela)

    assert on_disk -- generated == []

    assert Path.wildcard(Path.join(@rela, "*.{yaml,json}"))
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() ==
             Enum.sort([
               "data-entry.yaml" | Enum.filter(generated, &(not String.contains?(&1, "/")))
             ])
  end

  test "the manifest names every input that is packaged, and none that is gone" do
    manifest = JSON.decode!(committed("atlas.manifest.json"))
    sha = &(:crypto.hash(:sha256, committed(&1)) |> Base.encode16(case: :lower))
    for {path, digest} <- manifest["inputs"], do: assert(sha.(path) == digest, path)
    assert manifest["output_sha256"] == sha.("atlas.json")
    assert manifest["flows"] == %{"source" => "flows.yaml", "sha256" => sha.("flows.yaml")}

    refute Enum.any?(
             Map.keys(manifest["inputs"]),
             &String.ends_with?(&1, ["atlas.json", "sources.json"])
           )
  end

  test "each kind's and relation's introspection is its part of the committed atlas.json" do
    extension = JSON.decode!(committed("atlas.json"))

    for kind <- Map.keys(description().schema["entities"]) do
      part = AtlasEyra.__rela__({:entity, kind})
      assert part.extension == extension["entities"][kind], kind
      assert part.schema == description().schema["entities"][kind]
    end

    for name <- Map.keys(description().schema["relations"]),
        do:
          assert(
            AtlasEyra.__rela__({:relation, name}).extension == extension["relations"][name],
            name
          )

    # Every kind of the extension is a kind of the schema.
    assert Map.keys(extension["entities"]) -- Map.keys(description().schema["entities"]) == []
  end

  test "each subflow's compiled digest is that of its committed flows.json entry, per environment" do
    digests = AtlasEyra.__rela__(:digests)
    proof = JSON.decode!(File.read!("../targets/proof/digests.json"))

    for {env, target} <- [
          prod: "../targets/atlas/flows.json",
          test: "../targets/test/atlas/flows.json"
        ],
        {name, definition} <- JSON.decode!(File.read!(target))["flows"] do
      compiled = digests[env][String.to_atom(name)]
      assert compiled.digest == DefinitionDigest.of(definition), "#{env} #{name}"
      assert proof["subflows"][name][to_string(env)]["digest"] == compiled.digest
      assert compiled.states == Enum.sort(Map.keys(definition["states"]))
    end

    # The decide pair after #109, as definition_digest_test pins the one before it.
    assert digests.prod.decide.digest ==
             "bfd535ea5c570cc586c606825745a7f767bf138a5f5289093f629a99e06fb042"

    assert digests.test.decide.digest ==
             "b4a73029ce91d1bb1727498feb0c4b277315956c8b1ac547f15d1454eb5ccae8"
  end

  test "the run migrations of flow-runtime.json are the migrate declarations, in order" do
    committed =
      JSON.decode!(committed("flow-runtime.json"))
      |> get_in(["flow_runtime", "selection", "decide", "migrations"])

    declared =
      for %{subflow: :decide, opts: o} <- AtlasEyra.__rela__(:migrations), do: {o[:from], o[:to]}

    assert Enum.map(committed, &{&1["from"], &1["to"]}) == declared

    proof = JSON.decode!(File.read!("../targets/proof/digests.json"))["subflows"]["decide"]
    history = for {_env, e} <- proof, h <- e["history"], do: h["digest"]
    for {from, to} <- declared, do: assert(from in history and to in history)
    assert "118c1cf31028979df064344d708a59f8ee19ad97493b47d66ac2d66cbb8dbb00" in history
  end

  describe "the profiles (private dependency proofs)" do
    test "foundation alone has no software or product plan, and binds verdicts to decisions only" do
      d = Model.Profiles.Foundation.__rela__(:description)

      for kind <- ~w(scene use_case issue pull_request agent_request),
          do: refute(Map.has_key?(d.schema["entities"], kind), kind)

      refute Map.has_key?(d.schema["relations"], "accepted_by")
      assert d.schema["relations"]["about"]["to"] == ["decision"]
      assert d.extension["entities"]["decision"]["authority"]["decider"]["relation"] == "about"
      refute Map.has_key?(d.extension, "flows")
      runtime = RelaDSL.Description.Plain.unorder(d.flow_runtime)["flow_runtime"]
      assert runtime["selection"] == %{}
      assert runtime["inputs"]["roles"] == %{}
    end

    test "incident reuses foundation, audit and software, with its own kind and no product plan" do
      d = Model.Profiles.Incident.__rela__(:description)
      assert Map.has_key?(d.schema["entities"], "incident")
      refute Map.has_key?(d.schema["entities"], "scene")
      refute Map.has_key?(d.schema["relations"], "accepted_by")

      assert Map.keys(d.extension["flows"]) ==
               ~w(build_and_merge restore_service review_and_merge)

      assert d.extension["entities"]["issue"]["create"]["id"]["prefix"] == "IS-Maint-"

      assert List.last(d.extension["flows"]["build_and_merge"]["states"])["owner"] ==
               %{"kind" => "agent", "key" => "runner"}
    end
  end

  # What test_assembly.py proved about the images: each Dockerfile's COPY rela/... lines
  # carry every packaged input, so verify.py passes in the image.
  test "both image recipes copy every input the manifest names, atlas.json and the manifest" do
    manifest = JSON.decode!(committed("atlas.manifest.json"))
    needed = Map.keys(manifest["inputs"]) ++ ["atlas.json", "atlas.manifest.json"]

    for recipe <- ["core", "rela"] do
      copied =
        for line <- String.split(File.read!("../../fly/#{recipe}.Dockerfile"), "\n"),
            String.starts_with?(line, "COPY rela/"),
            [_ | args] = String.split(line),
            {sources, [_target]} = Enum.split(args, -1),
            source <- sources,
            relative = String.replace_prefix(source, "rela/", ""),
            path <-
              if(File.dir?(Path.join(@rela, relative)),
                do: Path.wildcard(Path.join([@rela, relative, "**", "*"])),
                else: [Path.join(@rela, relative)]
              ),
            File.regular?(path),
            do: Path.relative_to(path, @rela)

      assert needed -- copied == [], "#{recipe}.Dockerfile misses #{inspect(needed -- copied)}"
    end
  end
end
